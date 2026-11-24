-- P8SCII glyph catalog cache, insertion, picker, and completion.
--
-- The catalog is keyed by client and cart root so a client restart or a
-- different workspace cannot reuse another server's `pico8.glyphs` settings.
-- Shift glyph maps read the cached `byte -> text` map after an attach-time
-- prefetch; a cold cache makes at most one bounded synchronous request and then
-- falls back to the literal key until an explicit prefetch succeeds.

local M = {}

-- Keep the first Shift insertion bounded. The prefetch normally fills the
-- cache before a key is pressed, so this is a fallback rather than the hot path.
local SYNC_TIMEOUT_MS = 750
local PICKER_TIMEOUT_MS = 2000
local COMMAND_TIMEOUT_MS = 3000

-- Cache entries keyed by `client id + normalized root`.
local caches = {}

-- A missing client is reported once per session; a failed request is reported
-- once per client cache (see `entry.warned`).
local warned_missing_client = false

local function notify(message, level)
  vim.notify("pico-lsp: " .. message, level or vim.log.levels.WARN)
end

local function log_debug(message)
  local ok, logger = pcall(function()
    return vim.lsp.log
  end)
  if ok and logger and type(logger.debug) == "function" then
    pcall(logger.debug, message)
  end
end

local function normalize(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  local ok, normalized = pcall(vim.fs.normalize, absolute)
  if ok then
    return normalized
  end
  return absolute
end

local function error_text(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function find_client(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
end

local function client_root(client, bufnr)
  local root = client and client.config and client.config.root_dir
  if type(root) ~= "string" or root == "" then
    root = client and client.root_dir
  end
  if type(root) ~= "string" or root == "" then
    root = vim.b[bufnr] and vim.b[bufnr].pico8_cart_root
  end
  if type(root) ~= "string" or root == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      root = vim.fs.dirname(name)
    end
  end
  return type(root) == "string" and root ~= "" and normalize(root) or ""
end

local function cache_key(client, bufnr)
  return tostring(client.id) .. "\0" .. client_root(client, bufnr)
end

local function find_cache(client, bufnr)
  return caches[cache_key(client, bufnr)]
end

local function ensure_cache(client, bufnr)
  local key = cache_key(client, bufnr)
  local entry = caches[key]
  if not entry then
    entry = {
      client_id = client.id,
      root = client_root(client, bufnr),
      entries = nil,
      by_byte = {},
      names = {},
      warned = false,
      in_flight = false,
    }
    caches[key] = entry
  end
  return entry
end

-- Store the full server catalog. Later entries win, matching the server's
-- custom-glyph override rule, while `entries` keeps server order for the picker.
local function fill(entry, glyphs)
  entry.entries = type(glyphs) == "table" and glyphs or {}
  entry.by_byte = {}
  entry.names = {}
  for _, item in ipairs(entry.entries) do
    local byte = tonumber(item.byte)
    if byte and byte >= 0 and byte <= 255 then
      entry.by_byte[byte] = item.text or ""
    end
    if type(item.name) == "string" and item.name ~= "" then
      entry.names[item.name:lower()] = item
    end
  end
  entry.fetched_at = vim.uv.hrtime()
  entry.in_flight = false
end

local function request_entries_sync(client, bufnr, timeout)
  local ok, response, reason = pcall(
    client.request_sync,
    client,
    "pico8/glyphs",
    vim.empty_dict(),
    timeout,
    bufnr
  )
  if not ok then
    return nil, tostring(response)
  end
  if not response then
    return nil, reason or "request failed"
  end
  if response.err then
    return nil, error_text(response.err)
  end
  if type(response.result) ~= "table" or type(response.result.glyphs) ~= "table" then
    return nil, "invalid response"
  end
  return response.result.glyphs
end

local function ensure_sync(client, bufnr, warn)
  local entry = ensure_cache(client, bufnr)
  if entry.entries ~= nil then
    return entry
  end

  local entries, reason = request_entries_sync(client, bufnr, SYNC_TIMEOUT_MS)
  if not entries then
    log_debug("pico-lsp: could not load P8SCII glyphs: " .. tostring(reason))
    if warn and not entry.warned then
      entry.warned = true
      notify(warn, vim.log.levels.ERROR)
    end
    return nil
  end

  fill(entry, entries)
  entry.warned = false
  return entry
end

local function position_params(bufnr, client)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    win = 0
  end
  return vim.lsp.util.make_position_params(win, client.offset_encoding)
end

local function request_entries_at_position(client, bufnr)
  local position = position_params(bufnr, client)
  local ok, response, reason = pcall(
    client.request_sync,
    client,
    "pico8/glyphs",
    {
      textDocument = position.textDocument,
      position = position.position,
    },
    PICKER_TIMEOUT_MS,
    bufnr
  )
  if not ok then
    return nil, tostring(response)
  end
  if not response then
    return nil, reason or "request failed"
  end
  if response.err then
    return nil, error_text(response.err)
  end
  if type(response.result) ~= "table" or type(response.result.glyphs) ~= "table" then
    return nil, "invalid response"
  end
  return response.result.glyphs
end

local function glyph_label(item)
  local byte = item.byte ~= nil and string.format("0x%02x", item.byte) or ""
  return string.format("%s  p8_%s  %s", item.text or "", item.name or "", item.description or byte)
end

-- Match name, description, and both byte spellings. Server order is preserved.
local function filter_entries(entries, term)
  term = term:lower()
  local filtered = {}
  for _, item in ipairs(entries) do
    local fields = {
      item.name,
      item.description,
      item.byte ~= nil and string.format("0x%02x", item.byte) or nil,
      item.byte ~= nil and tostring(item.byte) or nil,
    }
    local matched = false
    for i = 1, 4 do
      local field = fields[i]
      if type(field) == "string" and field:lower():find(term, 1, true) then
        matched = true
        break
      end
    end
    if matched then
      filtered[#filtered + 1] = item
    end
  end
  return filtered
end

local function has_edits(edit)
  if type(edit) ~= "table" then
    return false
  end
  if type(edit.changes) == "table" and next(edit.changes) ~= nil then
    return true
  end
  if type(edit.documentChanges) == "table" and #edit.documentChanges > 0 then
    return true
  end
  return false
end

local function execute(client, bufnr, argument)
  local position = position_params(bufnr, client)
  local insert = {
    textDocument = position.textDocument,
    position = position.position,
  }
  -- The server rejects two forms at once, so set only the requested one.
  if argument.byte == nil then
    insert.name = argument.name
  else
    insert.byte = argument.byte
  end
  local params = {
    command = "pico8.insertGlyph",
    arguments = { insert },
  }

  local ok, response, reason = pcall(
    client.request_sync,
    client,
    "workspace/executeCommand",
    params,
    COMMAND_TIMEOUT_MS,
    bufnr
  )
  if not ok then
    notify("could not insert P8SCII glyph: " .. tostring(response), vim.log.levels.ERROR)
    return
  end
  if not response then
    notify(
      "could not insert P8SCII glyph: " .. tostring(reason or "request failed"),
      vim.log.levels.ERROR
    )
    return
  end
  if response.err then
    notify("could not insert P8SCII glyph: " .. error_text(response.err), vim.log.levels.ERROR)
    return
  end

  local result = response.result
  if type(result) ~= "table" then
    return
  end
  if result.edit and has_edits(result.edit) then
    local applied, err = pcall(
      vim.lsp.util.apply_workspace_edit,
      result.edit,
      client.offset_encoding
    )
    if not applied then
      notify("could not apply the P8SCII glyph edit: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function insert_name(bufnr, name)
  local client = find_client(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end
  execute(client, bufnr, { name = name })
end

local function insert_byte(bufnr, byte)
  local client = find_client(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end
  execute(client, bufnr, { byte = byte })
end

-- 1. Empty: picker. 2. Decimal 0..255. 3. Hex 0x00..0xff. 4. Name. 5. Search.
-- Numeric-looking out-of-range values error instead of becoming search terms.
local function parse_byte(value)
  if value:match("^%-?%d+$") then
    local number = tonumber(value)
    if not number or number < 0 or number > 255 then
      return nil, "byte must be between 0 and 255"
    end
    return number
  end

  local hex = value:match("^0[xX](%x+)$")
  if hex then
    local number = tonumber(hex, 16)
    if not number or number > 255 then
      return nil, "byte must be between 0 and 255"
    end
    return number
  end

  return nil
end

local function open_picker(bufnr, term)
  local client = find_client(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end

  local entries, reason = request_entries_at_position(client, bufnr)
  if not entries then
    log_debug("pico-lsp: position-filtered glyph request failed: " .. tostring(reason))
    local cached = find_cache(client, bufnr)
    if cached and cached.entries then
      entries = cached.entries
    else
      notify("could not load P8SCII glyphs: " .. tostring(reason or "request failed"), vim.log.levels.ERROR)
      return
    end
  end

  local list = term and filter_entries(entries, term) or entries
  if #list == 0 then
    if term and term ~= "" then
      notify(string.format("no P8SCII glyphs match %q", term), vim.log.levels.INFO)
    else
      notify("no P8SCII glyphs available", vim.log.levels.INFO)
    end
    return
  end

  vim.ui.select(list, {
    prompt = term and term ~= "" and ("P8SCII glyph: " .. term) or "P8SCII glyph",
    format_item = glyph_label,
  }, function(item)
    if item and item.name then
      insert_name(bufnr, item.name)
    end
  end)
end

function M.reset()
  caches = {}
  warned_missing_client = false
end

function M.clear(client_id)
  if client_id == nil then
    return
  end
  for key, entry in pairs(caches) do
    if entry.client_id == client_id then
      caches[key] = nil
    end
  end
end

function M.cache_for(bufnr, client)
  bufnr = resolve_bufnr(bufnr)
  client = client or find_client(bufnr)
  if not client then
    return nil
  end
  return find_cache(client, bufnr)
end

local function glyph_maps_enabled(bufnr)
  if vim.g.pico8_glyph_maps and vim.g.pico8_glyph_maps ~= 0 then
    return true
  end
  local marker = vim.b[bufnr].pico8_glyph_maps
  if marker == true or marker == 1 then
    return true
  end
  local api = package.loaded["pico_lsp"]
  return type(api) == "table" and type(api.opts) == "table" and api.opts.glyph_maps == true
end

local function prefetch_allowed(bufnr)
  -- A decoded .p8.png virtual cart is read-only; its insert-mode maps can never
  -- insert, so an attach-time catalog request would be wasted.
  return vim.bo[bufnr].modifiable and vim.b[bufnr].pico8_virtual_cart ~= true
end

function M.attach(client, bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not client or client.name ~= "pico_lsp" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if
    vim.bo[bufnr].filetype ~= "pico8"
    or not glyph_maps_enabled(bufnr)
    or not prefetch_allowed(bufnr)
  then
    return
  end
  M.prefetch(client, bufnr)
end

-- Fill the full catalog without blocking attachment. Failures are silent; the
-- first Shift insertion retries synchronously and reports its own failure.
function M.prefetch(client, bufnr)
  bufnr = resolve_bufnr(bufnr)
  if
    not client
    or not client.id
    or not vim.api.nvim_buf_is_valid(bufnr)
    or not prefetch_allowed(bufnr)
  then
    return false
  end
  local entry = ensure_cache(client, bufnr)
  if entry.entries ~= nil or entry.in_flight then
    return false
  end

  local key = cache_key(client, bufnr)
  entry.in_flight = true
  entry.warned = false

  local ok, success, request_id = pcall(
    client.request,
    client,
    "pico8/glyphs",
    vim.empty_dict(),
    function(err, result)
      entry.in_flight = false
      if caches[key] ~= entry then
        return
      end
      if err then
        log_debug("pico-lsp: P8SCII glyph prefetch failed: " .. error_text(err))
        return
      end
      if type(result) ~= "table" or type(result.glyphs) ~= "table" then
        log_debug("pico-lsp: P8SCII glyph prefetch returned an invalid response")
        return
      end
      fill(entry, result.glyphs)
    end,
    bufnr
  )
  if not ok or success == false then
    entry.in_flight = false
    log_debug("pico-lsp: P8SCII glyph prefetch could not start: " .. tostring(ok and request_id or success))
    return false
  end
  return true
end

-- Synchronous lookup used by the Shift expression mapping. A cache that already
-- has entries is authoritative: a missing byte falls back without a request.
function M.text_for_byte(bufnr, byte)
  bufnr = resolve_bufnr(bufnr)
  local client = find_client(bufnr)
  if not client then
    if not warned_missing_client then
      warned_missing_client = true
      notify("no pico_lsp client attached; PICO-8 Shift glyph maps fall back to uppercase letters")
    end
    return nil
  end

  local entry = ensure_cache(client, bufnr)
  if entry.entries ~= nil then
    return entry.by_byte[byte]
  end
  if entry.warned then
    return nil
  end

  entry = ensure_sync(
    client,
    bufnr,
    "could not load P8SCII glyphs; Shift glyph maps fall back to uppercase letters"
  )
  if not entry then
    return nil
  end
  return entry.by_byte[byte]
end

-- Command-line completion never starts a request. The user can run the command
-- once to populate the cache, or rely on attach-time prefetch.
function M.complete(arg_lead)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = find_client(bufnr)
  if not client then
    return {}
  end
  local entry = find_cache(client, bufnr)
  if not entry or entry.entries == nil then
    return {}
  end

  local prefix = (arg_lead or ""):lower()
  local seen = {}
  local names = {}
  for _, item in ipairs(entry.entries) do
    if type(item.name) == "string" and item.name ~= "" then
      local key = item.name:lower()
      if not seen[key] and key:sub(1, #prefix) == prefix then
        seen[key] = true
        names[#names + 1] = item.name
      end
    end
  end
  table.sort(names, function(a, b)
    local left = a:lower()
    local right = b:lower()
    if left == right then
      return a < b
    end
    return left < right
  end)
  return names
end

-- Base-config users do not call setup, so the module owns its detach cleanup.
-- The helper also clears on LspDetach; both paths are idempotent.
local ok, glyph_group = pcall(vim.api.nvim_create_augroup, "pico_lsp_glyphs", { clear = true })
if ok then
  pcall(vim.api.nvim_create_autocmd, "LspDetach", {
    group = glyph_group,
    callback = function(args)
      local data = args.data or {}
      M.clear(data.client_id)
    end,
  })
end

function M.insert(argument)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = find_client(bufnr)
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end

  local value = type(argument) == "string" and argument:match("^%s*(.-)%s*$") or ""
  if value == "" then
    open_picker(bufnr, nil)
    return
  end

  local byte, byte_error = parse_byte(value)
  if byte_error then
    notify(byte_error, vim.log.levels.ERROR)
    return
  end
  if byte ~= nil then
    insert_byte(bufnr, byte)
    return
  end

  -- Resolve an exact name from the full catalog so control entries still get the
  -- server's context error rather than becoming a picker search term.
  local entry = ensure_cache(client, bufnr)
  if entry.entries == nil then
    ensure_sync(client, bufnr, nil)
  end
  entry = find_cache(client, bufnr) or entry
  local name_entry = entry.entries and entry.names[value:lower()]
  if name_entry then
    insert_name(bufnr, name_entry.name)
    return
  end

  open_picker(bufnr, value)
end

return M
