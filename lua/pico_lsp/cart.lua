-- Cached `pico8/cartInfo` state, statusline formatting, and cart commands.
--
-- `cart_info` and `cart_status` only read the cache. They never send a request
-- or wait for the server, so a statusline can call them on every redraw.
-- Requests are asynchronous and coalesced per cart root by a generation
-- counter: at most one request is in flight and at most one follow-up is
-- pending for each root.

local M = {}

-- Edit-triggered refreshes are coalesced for this long. InsertLeave and saves
-- refresh immediately.
local DEBOUNCE_MS = 500
local REQUEST_TIMEOUT_MS = 5000

-- The notification stays compact when a cart has many files or includes.
local MAX_DETAIL_LINES = 8

local DEFAULT_FIELDS = { "tokens", "chars", "compressed" }

-- CartInfo uses zero-based LSP lines; Neovim cursor lines are one-based.
local LINE_OFFSET = 1

-- Cache state keyed by the server's rootUri.
-- state = {
--   gen, attempt, inflight, pending,
--   request_buf, request_uri, client_id,
--   info, last_error, timer,
--   callbacks = { { gen = number, fn = function } },
-- }
local root_state = {}

-- Buffer bookkeeping used to clear a root only when no buffer uses it.
local buffer_roots = {}
local buffer_clients = {}
local root_buffers = {}

local debounce_timers = {}
local debounce_generations = {}

local group = nil
local commands_defined = false
local last_error = nil
-- Incremented by shutdown so scheduled callbacks from the previous setup do not
-- repopulate a cleared cache.
local epoch = 0

local send_request
local handle_response

local function notify(message, level)
  vim.notify("pico-lsp: " .. message, level or vim.log.levels.INFO)
end

local function log_debug(message)
  local ok, logger = pcall(function()
    return vim.lsp.log
  end)
  if ok and logger and type(logger.debug) == "function" then
    pcall(logger.debug, message)
  end
end

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number"
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
end

local function client_for(bufnr)
  if not valid_buffer(bufnr) then
    return nil
  end
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
end

local function is_virtual(bufnr)
  if vim.b[bufnr].pico8_virtual_cart == true then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^pico8%-cart:") ~= nil then
    return true
  end
  -- Match the shipped config: a real directory named `pico8-cart:demo` is a
  -- normal path, while a URI component `pico8-cart:/...` is a virtual buffer.
  return name:match("[/\\]pico8%-cart:[/\\]") ~= nil or name:match("[/\\]pico8%-cart:$") ~= nil
end

-- The helper tracks the decoded PNG virtual URI. Neovim 0.11 expands URI-like
-- buffer names into filesystem paths, so deriving the URI from the name is only
-- a fallback for virtual buffers the helper did not create.
local function virtual_uri(bufnr)
  local ok, helper = pcall(require, "pico_lsp")
  if ok and helper and type(helper.png_buffers) == "table" then
    local info = helper.png_buffers[bufnr]
    if info and type(info.virtual) == "string" and info.virtual ~= "" then
      return info.virtual
    end
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local position = name:find("pico8%-cart:")
  if position then
    return name:sub(position)
  end
  return nil
end

local function document_uri(bufnr)
  if is_virtual(bufnr) then
    return virtual_uri(bufnr) or vim.uri_from_bufnr(bufnr)
  end
  return vim.uri_from_bufnr(bufnr)
end

-- Helper-managed includes carry the owning cart URI. For other Lua buffers the
-- server response re-keys the cache after the first successful request.
local function is_helper_include(bufnr)
  local cart_uri = vim.b[bufnr].pico8_cart
  return type(cart_uri) == "string" and cart_uri ~= ""
end

local function preferred_key(bufnr, uri)
  if is_virtual(bufnr) then
    return uri
  end
  if is_helper_include(bufnr) then
    return vim.b[bufnr].pico8_cart
  end
  return uri
end

-- Compare file URIs by path so percent-encoding or normalization differences
-- never reject a valid owning-cart response.
local function same_uri(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  if a:sub(1, 5) ~= "file:" or b:sub(1, 5) ~= "file:" then
    return false
  end
  local ok_a, path_a = pcall(vim.uri_to_fname, a)
  local ok_b, path_b = pcall(vim.uri_to_fname, b)
  return ok_a and ok_b and vim.fs.normalize(path_a) == vim.fs.normalize(path_b)
end

local function stop_timer(timer)
  if not timer then
    return
  end
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then
    pcall(timer.close, timer)
  end
end

local function close_debounce(bufnr)
  local timer = debounce_timers[bufnr]
  debounce_timers[bufnr] = nil
  debounce_generations[bufnr] = nil
  stop_timer(timer)
end

local function record_error(key, message)
  last_error = { key = key, message = message, at = os.time() }
  local state = root_state[key]
  if state then
    state.last_error = message
  end
  log_debug("pico-lsp: cart info refresh failed: " .. message)
end

local function clear_error(key)
  local state = root_state[key]
  if state then
    state.last_error = nil
  end
  if last_error and last_error.key == key then
    last_error = nil
  end
end

local function error_message(err)
  if type(err) == "table" then
    local message = err.message
    if type(message) == "string" and message ~= "" then
      if message:find("cart%-not%-found") then
        return "no cart found for this buffer"
      end
      return message
    end
    return vim.inspect(err)
  end
  return tostring(err)
end

local function ensure_state(key, client_id)
  local state = root_state[key]
  if not state then
    state = {
      gen = 0,
      inflight = false,
      pending = false,
      callbacks = {},
    }
    root_state[key] = state
  end
  if client_id then
    state.client_id = client_id
  end
  return state
end

local function remove_buffer_from_root(bufnr, key)
  local buffers = root_buffers[key]
  if not buffers then
    return
  end
  buffers[bufnr] = nil
  if next(buffers) ~= nil then
    return
  end
  root_buffers[key] = nil
  local state = root_state[key]
  if state then
    stop_timer(state.timer)
    state.timer = nil
    state.callbacks = {}
  end
  root_state[key] = nil
  if last_error and last_error.key == key then
    last_error = nil
  end
end

local function unmark_buffer(bufnr)
  local key = buffer_roots[bufnr]
  buffer_roots[bufnr] = nil
  buffer_clients[bufnr] = nil
  if key then
    remove_buffer_from_root(bufnr, key)
  end
end

local function mark_buffer(bufnr, key, client_id)
  local previous = buffer_roots[bufnr]
  if previous and previous ~= key then
    remove_buffer_from_root(bufnr, previous)
  end
  buffer_roots[bufnr] = key
  buffer_clients[bufnr] = client_id
  local buffers = root_buffers[key]
  if not buffers then
    buffers = {}
    root_buffers[key] = buffers
  end
  buffers[bufnr] = true
end

local function rekey_state(state, old_key, new_key, bufnr, client_id)
  if old_key == new_key then
    return state, new_key
  end

  client_id = client_id or state.client_id
  buffer_roots[bufnr] = nil
  buffer_clients[bufnr] = nil

  local old_buffers = root_buffers[old_key]
  if old_buffers then
    old_buffers[bufnr] = nil
  end

  local target = root_state[new_key]
  if target then
    if state.pending then
      target.pending = true
      state.pending = false
    end
    for _, callback in ipairs(state.callbacks) do
      -- Moved callbacks are answered by the target's next pending response.
      callback.gen = target.gen
      target.callbacks[#target.callbacks + 1] = callback
    end
    state.callbacks = {}
    if not old_buffers or next(old_buffers) == nil then
      stop_timer(state.timer)
      state.timer = nil
      root_state[old_key] = nil
      root_buffers[old_key] = nil
    end
    state = target
  else
    root_state[new_key] = state
    root_state[old_key] = nil
    root_buffers[new_key] = old_buffers or {}
    root_buffers[old_key] = nil
  end

  mark_buffer(bufnr, new_key, client_id)
  return state, new_key
end

local function finish_callbacks(state, generation, result, err)
  -- Snapshot the list: a callback may start another refresh, which appends to
  -- state.callbacks while this loop is running.
  local callbacks = state.callbacks or {}
  state.callbacks = {}
  local remaining = {}
  for _, callback in ipairs(callbacks) do
    if callback.gen <= generation then
      local ok, callback_err = pcall(callback.fn, result, err)
      if not ok then
        log_debug("pico-lsp: cart info callback failed: " .. tostring(callback_err))
      end
    else
      remaining[#remaining + 1] = callback
    end
  end
  for _, callback in ipairs(remaining) do
    state.callbacks[#state.callbacks + 1] = callback
  end
end

local function discard_state(state, message)
  state.inflight = false
  state.pending = false
  if state.timer then
    stop_timer(state.timer)
    state.timer = nil
  end
  finish_callbacks(state, state.gen, nil, message)
end

local function send_pending_if_ready(state, key)
  if state.pending and not state.inflight then
    state.pending = false
    send_request(state, key)
  end
end

-- Prefer the latest requester. If it closed or detached while its request was
-- pending, another buffer sharing the root can still serve the request.
local function request_target(state, key)
  local bufnr = state.request_buf
  if valid_buffer(bufnr) and client_for(bufnr) then
    return bufnr, document_uri(bufnr)
  end
  for candidate in pairs(root_buffers[key] or {}) do
    if valid_buffer(candidate) and client_for(candidate) then
      return candidate, document_uri(candidate)
    end
  end
  return nil
end

send_request = function(state, key)
  if state.inflight then
    state.pending = true
    return
  end

  local bufnr, uri = request_target(state, key)
  local client = bufnr and client_for(bufnr) or nil
  if not client or not valid_buffer(bufnr) or not uri or uri == "" then
    discard_state(state, "no pico_lsp client attached to this buffer")
    return
  end

  state.request_buf = bufnr
  state.request_uri = uri
  state.client_id = client.id

  local generation = state.gen
  state.attempt = (state.attempt or 0) + 1
  local attempt = state.attempt
  state.inflight = true
  state.pending = false

  if state.timer then
    stop_timer(state.timer)
    state.timer = nil
  end
  local ok, timer = pcall(vim.uv.new_timer)
  if ok and timer then
    state.timer = timer
    local started = pcall(timer.start, timer, REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function()
      if root_state[key] ~= state or state.attempt ~= attempt or not state.inflight then
        return
      end
      -- Invalidate the attempt so a late response is discarded.
      state.attempt = state.attempt + 1
      state.inflight = false
      stop_timer(timer)
      state.timer = nil
      local message = "pico8/cartInfo timed out"
      record_error(key, message)
      finish_callbacks(state, generation, nil, message)
      send_pending_if_ready(state, key)
    end))
    if not started then
      stop_timer(timer)
      state.timer = nil
    end
  end

  local client_id = client.id
  local params = { textDocument = { uri = uri } }
  local sent_ok, sent = pcall(client.request, client, "pico8/cartInfo", params, function(err, result)
    vim.schedule(function()
      handle_response(key, state, generation, attempt, bufnr, uri, client_id, err, result)
    end)
  end, bufnr)

  if not sent_ok or sent == false then
    if state.attempt == attempt then
      state.attempt = state.attempt + 1
    end
    if state.timer then
      stop_timer(state.timer)
      state.timer = nil
    end
    state.inflight = false
    local message = sent_ok and "pico8/cartInfo request was not sent" or tostring(sent)
    record_error(key, message)
    finish_callbacks(state, generation, nil, message)
    send_pending_if_ready(state, key)
  end
end

handle_response = function(key, state, generation, attempt, bufnr, uri, client_id, err, result)
  if root_state[key] ~= state or state.attempt ~= attempt then
    return
  end

  state.inflight = false
  if state.timer then
    stop_timer(state.timer)
    state.timer = nil
  end

  -- A newer generation owns the current data. Its pending request will answer
  -- this generation's callbacks; do not overwrite the cache from stale data.
  if generation ~= state.gen then
    send_pending_if_ready(state, key)
    return
  end

  local message
  if err then
    message = error_message(err)
    record_error(key, message)
    finish_callbacks(state, generation, nil, message)
    send_pending_if_ready(state, key)
    return
  end

  if type(result) ~= "table" or type(result.rootUri) ~= "string" or result.rootUri == "" then
    message = "invalid pico8/cartInfo response"
    record_error(key, message)
    finish_callbacks(state, generation, nil, message)
    send_pending_if_ready(state, key)
    return
  end

  -- Discard responses for a buffer that closed, was renamed, detached, or
  -- re-attached to a different client while the request was in flight.
  local current_client = client_for(bufnr)
  local current_uri = valid_buffer(bufnr) and document_uri(bufnr) or nil
  local preferred = current_uri and preferred_key(bufnr, current_uri) or nil
  local helper_owner = vim.b[bufnr].pico8_cart
  if
    not current_client
    or current_client.id ~= client_id
    or current_uri ~= uri
    or (not same_uri(preferred, key) and not same_uri(preferred, result.rootUri))
    or (type(helper_owner) == "string" and helper_owner ~= "" and not same_uri(result.rootUri, helper_owner))
  then
    message = "the pico_lsp client detached before the cart info response arrived"
    log_debug("pico-lsp: discarding cart info response: " .. message)
    finish_callbacks(state, generation, nil, message)
    send_pending_if_ready(state, key)
    return
  end

  -- Answer callbacks before the rekey so callbacks for this generation see the
  -- fresh value; newer callbacks move with the state and are answered by its
  -- pending request.
  finish_callbacks(state, generation, result, nil)

  local target_state = state
  local target_key = key
  if result.rootUri ~= key then
    target_state, target_key = rekey_state(state, key, result.rootUri, bufnr, client_id)
  else
    mark_buffer(bufnr, key, client_id)
  end

  -- Store the fresh response under the response's rootUri, never under the
  -- buffer's old/provisional key.
  target_state.info = result
  target_state.last_error = nil
  clear_error(target_key)
  send_pending_if_ready(target_state, target_key)
end

local function request_key(bufnr, uri)
  return buffer_roots[bufnr] or preferred_key(bufnr, uri)
end

local function request_cart_info(bufnr, client, callback)
  local uri = document_uri(bufnr)
  if not uri or uri == "" then
    return nil
  end
  local key = request_key(bufnr, uri)
  local state = ensure_state(key, client.id)
  state.gen = state.gen + 1
  local generation = state.gen
  state.request_buf = bufnr
  state.request_uri = uri
  state.client_id = client.id
  if callback then
    state.callbacks[#state.callbacks + 1] = { gen = generation, fn = callback }
  end
  mark_buffer(bufnr, key, client.id)
  if state.inflight then
    state.pending = true
  else
    send_request(state, key)
  end
  return generation
end

local function cached(bufnr)
  local key = buffer_roots[bufnr]
  if not key then
    return nil
  end
  local state = root_state[key]
  return state and state.info or nil
end

local function segment(value, limit, unit)
  if type(value) ~= "number" or type(limit) ~= "number" or limit <= 0 then
    return nil
  end
  return string.format("%d/%d %s", value, limit, unit)
end

local function resolve_fields(fields)
  if type(fields) ~= "table" then
    return DEFAULT_FIELDS
  end
  return fields
end

function M.cart_info(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local info = cached(bufnr)
  if not info then
    return nil
  end
  return vim.deepcopy(info)
end

function M.cart_status(bufnr, opts)
  bufnr = resolve_bufnr(bufnr)
  local info = cached(bufnr)
  if not info then
    return nil
  end

  local fields = type(opts) == "table" and resolve_fields(opts.fields) or DEFAULT_FIELDS
  local parts = {}
  for _, field in ipairs(fields) do
    local value
    if field == "tokens" then
      value = segment(info.tokens, info.tokenLimit, "tok")
    elseif field == "chars" then
      value = segment(info.chars, info.charLimit, "ch")
    elseif field == "compressed" and info.compressedStatus ~= "unavailable" then
      value = segment(info.compressed, info.compressedLimit, "zip")
    end
    if value then
      parts[#parts + 1] = value
    end
  end
  return table.concat(parts, " · ")
end

function M.refresh_cart_info(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not valid_buffer(bufnr) then
    return
  end
  local client = client_for(bufnr)
  if not client then
    return
  end
  request_cart_info(bufnr, client, nil)
end

function M.attach(client, bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not client or client.name ~= "pico_lsp" or not valid_buffer(bufnr) then
    return
  end
  request_cart_info(bufnr, client, nil)
end

function M.detach(client_id, bufnr)
  if not bufnr or not client_id or buffer_clients[bufnr] ~= client_id then
    return
  end
  close_debounce(bufnr)
  unmark_buffer(bufnr)
end

-- The helper revalidated an included buffer onto a different owning cart
-- without detaching its client. Drop the old root mapping and refresh under the
-- new owner so the include never shows the old cart's budget.
function M.owner_changed(bufnr, new_uri)
  bufnr = resolve_bufnr(bufnr)
  if not valid_buffer(bufnr) then
    return
  end
  local client = client_for(bufnr)
  if not client then
    return
  end
  local key = buffer_roots[bufnr]
  if key and (type(new_uri) ~= "string" or new_uri == "" or not same_uri(key, new_uri)) then
    unmark_buffer(bufnr)
  end
  if type(new_uri) ~= "string" or new_uri == "" then
    return
  end
  local state = root_state[new_uri]
  if state and state.info then
    mark_buffer(bufnr, new_uri, client.id)
  end
  -- The helper updates ownership during BufWritePost, before the server has
  -- necessarily processed didSave/didChange. Defer so the server sees the new
  -- cart before it resolves the include.
  local expected_epoch = epoch
  vim.schedule(function()
    if expected_epoch ~= epoch then
      return
    end
    if valid_buffer(bufnr) then
      M.refresh_cart_info(bufnr)
    end
  end)
end

local function uri_label(uri)
  if type(uri) ~= "string" then
    return tostring(uri)
  end
  if uri:match("^pico8%-cart:") then
    return uri
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if ok and type(path) == "string" and path ~= "" then
    return path
  end
  return uri
end

local function uri_basename(uri)
  if type(uri) ~= "string" or uri == "" then
    return "?"
  end
  if uri:match("^pico8%-cart:") then
    local name = uri:match("([^/]+)$")
    return name or uri
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if ok and type(path) == "string" and path ~= "" then
    return vim.fs.basename(path)
  end
  return uri
end

local function compressed_text(info)
  local status = info.compressedStatus
  if status == "unavailable" then
    return "compressed n/a"
  end
  if type(info.compressed) == "number" and type(info.compressedLimit) == "number" then
    local suffix = status and (" (" .. status .. ")") or ""
    return string.format("%d/%d compressed%s", info.compressed, info.compressedLimit, suffix)
  end
  return nil
end

local function budget_summary(info)
  local parts = {}
  if type(info.tokens) == "number" and type(info.tokenLimit) == "number" then
    parts[#parts + 1] = string.format("%d/%d tokens", info.tokens, info.tokenLimit)
  end
  if type(info.chars) == "number" and type(info.charLimit) == "number" then
    parts[#parts + 1] = string.format("%d/%d chars", info.chars, info.charLimit)
  end
  local compressed = compressed_text(info)
  if compressed then
    parts[#parts + 1] = compressed
  end
  return table.concat(parts, " · ")
end

local function summary_level(info)
  if info.compressedStatus == "warning" or info.compressedStatus == "error" then
    return vim.log.levels.WARN
  end
  if type(info.tokens) == "number" and type(info.tokenLimit) == "number" and info.tokens > info.tokenLimit then
    return vim.log.levels.WARN
  end
  if type(info.chars) == "number" and type(info.charLimit) == "number" and info.chars > info.charLimit then
    return vim.log.levels.WARN
  end
  return vim.log.levels.INFO
end

local function detail_lines(info)
  local details = {}
  local seen_files = false
  for _, file in ipairs(info.files or {}) do
    seen_files = true
    details[#details + 1] = string.format(
      "%s: %d tok · %d ch",
      uri_basename(file.uri),
      tonumber(file.tokens) or 0,
      tonumber(file.chars) or 0
    )
  end
  for _, include in ipairs(info.includes or {}) do
    -- Readable includes already appear in `files` with the same counts. Only
    -- add directive-level detail that the file list cannot show.
    local flagged = include.missing or include.unreadable or include.nested
    if flagged or not seen_files then
      local label = include.path
      if type(label) ~= "string" or label == "" then
        label = uri_basename(include.uri)
      end
      local flags = {}
      if include.missing then
        flags[#flags + 1] = "missing"
      end
      if include.unreadable then
        flags[#flags + 1] = "unreadable"
      end
      if include.nested then
        flags[#flags + 1] = "nested"
      end
      details[#details + 1] = string.format(
        "%s: %d tok · %d ch%s",
        label,
        tonumber(include.tokens) or 0,
        tonumber(include.chars) or 0,
        #flags > 0 and (" (" .. table.concat(flags, ", ") .. ")") or ""
      )
    end
  end
  return details
end

local function format_cart_info(info)
  local lines = {
    uri_label(info.rootUri),
    budget_summary(info),
  }
  local details = detail_lines(info)
  local shown = math.min(#details, MAX_DETAIL_LINES)
  for index = 1, shown do
    lines[#lines + 1] = "  " .. details[index]
  end
  if #details > shown then
    lines[#lines + 1] = string.format(
      '  ... and %d more (use require("pico_lsp").cart_info())',
      #details - shown
    )
  end
  return table.concat(lines, "\n")
end

function M.show_cart_info(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not valid_buffer(bufnr) then
    notify("Pico8CartInfo needs a loaded buffer", vim.log.levels.WARN)
    return
  end
  local client = client_for(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end
  request_cart_info(bufnr, client, function(result, err)
    if not valid_buffer(bufnr) then
      return
    end
    if err then
      notify("could not read cart info: " .. err, vim.log.levels.WARN)
      return
    end
    if type(result) ~= "table" then
      notify("could not read cart info", vim.log.levels.WARN)
      return
    end
    vim.notify("pico-lsp: " .. format_cart_info(result), summary_level(result))
  end)
end

local function notify_include_tabs(owner_uri)
  local message = "code tabs belong to the owning cart"
  if type(owner_uri) == "string" and owner_uri ~= "" then
    message = message .. ": " .. uri_label(owner_uri)
  end
  notify(message .. "; open the cart to switch tabs")
end

local function clamp_line(value, count)
  local line = math.floor(tonumber(value) or 0) + LINE_OFFSET
  if line < 1 then
    line = 1
  end
  if line > count then
    line = count
  end
  return line
end

local function jump_to_tab(bufnr, win, tab)
  if not valid_buffer(bufnr) then
    return
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  local line = clamp_line(tab.startLine, count)

  local target = win
  if not (target and vim.api.nvim_win_is_valid(target) and vim.api.nvim_win_get_buf(target) == bufnr) then
    target = nil
    for _, candidate in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(candidate) == bufnr then
        target = candidate
        break
      end
    end
  end
  if not target or vim.api.nvim_win_get_buf(target) ~= bufnr then
    notify("the cart is no longer visible; tab jump cancelled", vim.log.levels.INFO)
    return
  end

  pcall(vim.api.nvim_win_set_cursor, target, { line, 0 })
  if target ~= vim.api.nvim_get_current_win() then
    pcall(vim.api.nvim_set_current_win, target)
  end
end

local function tab_label(tab, count)
  local start_line = clamp_line(tab.startLine, count)
  local end_line = math.max(start_line, clamp_line(tab.endLine, count))
  return string.format(
    "%d: %s (lines %d-%d)",
    tonumber(tab.index) or 0,
    tab.name or "Tab",
    start_line,
    end_line
  )
end

local function tabs_for(info, bufnr)
  local tabs = info.tabs
  if type(tabs) == "table" and #tabs > 0 then
    return tabs
  end
  -- Standalone .lua carts have no parsed tabs. Treat the whole buffer as one
  -- selectable tab so the command still behaves predictably.
  return {
    {
      index = 0,
      name = "main",
      startLine = 0,
      endLine = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1),
    },
  }
end

function M.pick_tab(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not valid_buffer(bufnr) then
    notify("Pico8Tabs needs a loaded buffer", vim.log.levels.WARN)
    return
  end
  local client = client_for(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end

  local uri = document_uri(bufnr)
  if is_helper_include(bufnr) then
    notify_include_tabs(vim.b[bufnr].pico8_cart)
    return
  end

  local win = vim.api.nvim_get_current_win()
  request_cart_info(bufnr, client, function(result, err)
    local info = result
    if err or type(info) ~= "table" then
      info = cached(bufnr)
    end
    if type(info) ~= "table" then
      notify(err and ("could not read cart info: " .. err) or "could not read cart info", vim.log.levels.WARN)
      return
    end
    if not valid_buffer(bufnr) then
      return
    end

    -- A Lua buffer whose owning cart is a different document is an include,
    -- even when the helper did not create its attachment.
    if
      not is_virtual(bufnr)
      and vim.bo[bufnr].filetype == "lua"
      and uri
      and info.rootUri
      and info.rootUri ~= uri
    then
      notify_include_tabs(info.rootUri)
      return
    end

    local tabs = tabs_for(info, bufnr)
    local count = vim.api.nvim_buf_line_count(bufnr)
    vim.ui.select(tabs, {
      prompt = "PICO-8 tab",
      format_item = function(tab)
        return tab_label(tab, count)
      end,
    }, function(tab)
      if tab then
        jump_to_tab(bufnr, win, tab)
      end
    end)
  end)
end

function M.last_error()
  return last_error
end

-- Save and InsertLeave autocmds run alongside Neovim's LSP autocmds. Defer the
-- request so didSave/didChange is sent before it; otherwise the server can
-- answer from the pre-save snapshot (for example after an include moves carts).
local function defer_refresh(bufnr)
  local expected_epoch = epoch
  vim.schedule(function()
    if expected_epoch ~= epoch then
      return
    end
    if not valid_buffer(bufnr) or not vim.bo[bufnr].modifiable then
      return
    end
    M.refresh_cart_info(bufnr)
  end)
end

local function schedule_refresh(bufnr)
  local generation = (debounce_generations[bufnr] or 0) + 1
  debounce_generations[bufnr] = generation
  local expected_epoch = epoch

  local timer = debounce_timers[bufnr]
  if not timer then
    local ok, created = pcall(vim.uv.new_timer)
    if not ok or not created then
      debounce_generations[bufnr] = nil
      return
    end
    timer = created
    debounce_timers[bufnr] = timer
  end

  local started = pcall(
    timer.start,
    timer,
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if expected_epoch ~= epoch or debounce_generations[bufnr] ~= generation then
        return
      end
      close_debounce(bufnr)
      if not valid_buffer(bufnr) or not vim.bo[bufnr].modifiable then
        return
      end
      M.refresh_cart_info(bufnr)
    end)
  )
  if not started then
    close_debounce(bufnr)
  end
end

function M.shutdown()
  epoch = epoch + 1
  local buffers = {}
  for bufnr in pairs(debounce_timers) do
    buffers[#buffers + 1] = bufnr
  end
  for _, bufnr in ipairs(buffers) do
    close_debounce(bufnr)
  end
  for _, state in pairs(root_state) do
    stop_timer(state.timer)
    state.timer = nil
    state.callbacks = {}
  end
  debounce_timers = {}
  debounce_generations = {}
  root_state = {}
  buffer_roots = {}
  buffer_clients = {}
  root_buffers = {}
  last_error = nil
end

local function define_commands()
  if commands_defined then
    return
  end
  commands_defined = true
  vim.api.nvim_create_user_command("Pico8CartInfo", function()
    M.show_cart_info(0)
  end, {
    nargs = 0,
    force = true,
    desc = "Show pico-lsp cart budget information",
  })
  vim.api.nvim_create_user_command("Pico8Tabs", function()
    M.pick_tab(0)
  end, {
    nargs = 0,
    force = true,
    desc = "Pick a PICO-8 code tab",
  })
end

local function ensure_autocmds()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  group = vim.api.nvim_create_augroup("pico_lsp_cart", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local data = args.data or {}
      local client = data.client_id and vim.lsp.get_client_by_id(data.client_id) or nil
      if client and client.name == "pico_lsp" then
        M.attach(client, args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.p8", "*.lua" },
    callback = function(args)
      if not valid_buffer(args.buf) or not vim.bo[args.buf].modifiable then
        return
      end
      if not client_for(args.buf) then
        return
      end
      defer_refresh(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function(args)
      if not valid_buffer(args.buf) or not vim.bo[args.buf].modifiable then
        return
      end
      if not client_for(args.buf) then
        return
      end
      defer_refresh(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(args)
      if not valid_buffer(args.buf) or not vim.bo[args.buf].modifiable then
        return
      end
      if not client_for(args.buf) then
        return
      end
      schedule_refresh(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      local data = args.data or {}
      local bufnr = data.bufnr or args.buf
      if bufnr and data.client_id then
        M.detach(data.client_id, bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      close_debounce(args.buf)
      unmark_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.shutdown()
    end,
  })
end

local function scan_attached_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if valid_buffer(bufnr) then
      local client = client_for(bufnr)
      if client then
        M.attach(client, bufnr)
      end
    end
  end
end

function M.refresh_all()
  scan_attached_buffers()
end

function M.setup()
  M.shutdown()
  ensure_autocmds()
  define_commands()
  scan_attached_buffers()
end

define_commands()
ensure_autocmds()

return M
