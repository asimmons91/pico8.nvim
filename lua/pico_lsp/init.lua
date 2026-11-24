-- pico8.nvim client setup: attach pico-lsp to cart-owned .lua buffers.
--
-- Enable with:
--   require("pico_lsp").setup()
--
-- The helper never runs for .p8 carts (the native lsp/pico_lsp.lua config
-- handles those) and ignores .lua files that are not included by a nearby
-- .p8 cart.

local M = {}

local cart_module = require("pico_lsp.cart")
local glyphs = require("pico_lsp.glyphs")
local includes = require("pico_lsp.includes")

M.png_buffers = {}

M.cart_info = cart_module.cart_info
M.cart_status = cart_module.cart_status
M.refresh_cart_info = cart_module.refresh_cart_info

local warned_missing_binary = false

-- Cart edits are coalesced for this long before the helper rescans includes.
local RESCAN_DEBOUNCE_MS = 300

-- BufUnload can be aborted by another autocmd; poll briefly for the buffer to
-- be released, then stop. One hundred 10 ms retries is about one second.
local UNLOAD_POLL_MS = 10
local UNLOAD_RETRY_LIMIT = 100

-- Parsed include sets per normalized cart path. Entries hold either a loaded
-- buffer's changedtick or a disk file's mtime and size so a cache hit never
-- re-reads the cart.
local INCLUDE_CACHE_LIMIT = 64
local include_cache = {}
local include_cache_order = {}

-- Resolved owner per normalized Lua path. Cleared whenever a cart changes.
local owner_cache = {}

-- Helper-managed attachments per buffer: { client_id, root_dir, cart, cart_uri }.
-- Only entries recorded here may be detached by the helper.
local managed = {}

-- PICO-8 comment settings for helper-managed includes. The target commentstring
-- matches the stock Lua value; comments adds PICO-8's `//` leader so
-- comment-aware formatting recognizes it.
local PICO8_COMMENTS = ":---,:--,://"
local PICO8_COMMENTSTRING = "-- %s"
local LUA_COMMENTS = ":---,:--"
local LUA_COMMENTSTRING = "-- %s"

-- Comment option values changed by the helper, keyed by buffer number. Only
-- options whose value the helper actually replaced are recorded.
local comment_restore = {}

-- One debounce timer and generation per cart being edited.
local rescan_timers = {}
local rescan_generations = {}
-- Tracks a pending post-unload revalidation so a reload can cancel it.
local unload_generations = {}

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

local function same_path(a, b)
  if vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1 then
    return a:lower() == b:lower()
  end
  return a == b
end

-- Include-set keys use the same case rules as path comparison.
local function path_key(path)
  if vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1 then
    return path:lower()
  end
  return path
end

local function option_value(value)
  return value or ""
end

local function is_stock_comments(value)
  value = option_value(value)
  return value == "" or value == LUA_COMMENTS
end

local function is_stock_commentstring(value)
  value = option_value(value)
  return value == "" or value == LUA_COMMENTSTRING
end

local function set_include_vars(bufnr, record)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.b[bufnr].pico8_cart = record.cart_uri
  vim.b[bufnr].pico8_cart_root = record.root_dir
end

local function clear_include_vars(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.b[bufnr].pico8_cart = nil
  vim.b[bufnr].pico8_cart_root = nil
end

-- Apply PICO-8 comment defaults only to options that still have a stock or
-- empty value. A custom value is left untouched and never recorded. Exact
-- PICO-8 values are treated as custom, so a module reload cannot claim them.
local function apply_include_comments(bufnr)
  if comment_restore[bufnr] ~= nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local comments = option_value(vim.bo[bufnr].comments)
  local commentstring = option_value(vim.bo[bufnr].commentstring)
  local previous = {}
  if is_stock_comments(comments) and comments ~= PICO8_COMMENTS then
    previous.comments = comments
  end
  if is_stock_commentstring(commentstring) and commentstring ~= PICO8_COMMENTSTRING then
    previous.commentstring = commentstring
  end
  if next(previous) == nil then
    return
  end

  if previous.comments ~= nil then
    vim.bo[bufnr].comments = PICO8_COMMENTS
  end
  if previous.commentstring ~= nil then
    vim.bo[bufnr].commentstring = PICO8_COMMENTSTRING
  end
  comment_restore[bufnr] = previous
end

-- Restore only values that are still the ones the helper set. A later user
-- change is preserved. The record is removed even when the buffer unloaded
-- before restore could run.
local function restore_include_comments(bufnr)
  local previous = comment_restore[bufnr]
  if not previous then
    return
  end
  comment_restore[bufnr] = nil
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if previous.comments ~= nil and vim.bo[bufnr].comments == PICO8_COMMENTS then
    vim.bo[bufnr].comments = previous.comments
  end
  if previous.commentstring ~= nil and vim.bo[bufnr].commentstring == PICO8_COMMENTSTRING then
    vim.bo[bufnr].commentstring = previous.commentstring
  end
end

local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
end

local function drop_include(cart)
  include_cache[cart] = nil
  for i = #include_cache_order, 1, -1 do
    if include_cache_order[i] == cart then
      table.remove(include_cache_order, i)
    end
  end
end

local function store_include(cart, entry)
  include_cache[cart] = entry
  for i = #include_cache_order, 1, -1 do
    if include_cache_order[i] == cart then
      table.remove(include_cache_order, i)
    end
  end
  include_cache_order[#include_cache_order + 1] = cart
  while #include_cache_order > INCLUDE_CACHE_LIMIT do
    local evicted = table.remove(include_cache_order, 1)
    include_cache[evicted] = nil
  end
end

local function parse_targets(lines, directory)
  local targets = {}
  for _, line in ipairs(lines) do
    local include = includes.target(line)
    if include then
      targets[path_key(normalize(directory .. "/" .. include))] = true
    end
  end
  return targets
end

local function loaded_bufnr_for(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and same_path(normalize(name), path) then
      return bufnr
    end
  end
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate) then
      local name = vim.api.nvim_buf_get_name(candidate)
      if name ~= "" and same_path(normalize(name), path) then
        return candidate
      end
    end
  end
  return nil
end

-- Return the parsed include set for a cart. A loaded cart buffer is the source
-- of truth; otherwise the file is read from disk and cached by mtime/size.
local function cart_targets(cart)
  local directory = vim.fs.dirname(cart)
  if not directory then
    return nil
  end

  local bufnr = loaded_bufnr_for(cart)
  if bufnr then
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local entry = include_cache[cart]
    if entry and entry.tick == tick then
      return entry.targets
    end
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not ok then
      drop_include(cart)
      return nil
    end
    local targets = parse_targets(lines, directory)
    store_include(cart, { tick = tick, targets = targets })
    return targets
  end

  local stat = vim.uv.fs_stat(cart)
  if not stat then
    drop_include(cart)
    return nil
  end
  local entry = include_cache[cart]
  if
    entry
    and entry.mtime
    and entry.mtime.sec == stat.mtime.sec
    and entry.mtime.nsec == stat.mtime.nsec
    and entry.size == stat.size
  then
    return entry.targets
  end
  local lines = read_lines(cart)
  if not lines then
    drop_include(cart)
    return nil
  end
  local targets = parse_targets(lines, directory)
  store_include(cart, {
    mtime = { sec = stat.mtime.sec, nsec = stat.mtime.nsec },
    size = stat.size,
    targets = targets,
  })
  return targets
end

local function find_cart(path)
  local key = path_key(path)
  local cached = owner_cache[key]
  if cached ~= nil then
    return cached.cart
  end

  local directory = vim.fs.dirname(path)
  while directory do
    local carts = vim.fn.globpath(directory, "*.p8", false, true)
    table.sort(carts)
    for _, cart in ipairs(carts) do
      local normalized = normalize(cart)
      if not same_path(normalized, path) then
        local targets = cart_targets(normalized)
        if targets and targets[key] then
          owner_cache[key] = { cart = normalized }
          return normalized
        end
      end
    end
    local parent = vim.fs.dirname(directory)
    if not parent or parent == directory then
      break
    end
    directory = parent
  end

  owner_cache[key] = { cart = nil }
  return nil
end

local function invalidate_owner_cache()
  if next(owner_cache) ~= nil then
    owner_cache = {}
  end
end

local function invalidate_cart(cart)
  drop_include(cart)
  owner_cache = {}
end

local function normalize_cmd(cmd)
  if type(cmd) == "string" and cmd ~= "" then
    return { cmd }
  end
  if type(cmd) == "table" and #cmd > 0 and type(cmd[1]) == "string" then
    return cmd
  end
  return nil
end

local function valid_cmd(cmd)
  if type(cmd) == "function" then
    return cmd
  end
  return normalize_cmd(cmd)
end

-- Same precedence as lsp/pico_lsp.lua. Used only when the shipped config is
-- absent, for example when the helper is loaded without `lsp/` on
-- `runtimepath`.
local function command()
  local configured = vim.g.pico_lsp_cmd
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" and #configured > 0 and type(configured[1]) == "string" then
    return configured
  end
  if vim.env.PICO_LSP_BIN and vim.env.PICO_LSP_BIN ~= "" then
    return { vim.env.PICO_LSP_BIN }
  end
  return { "pico-lsp" }
end

local function is_virtual(bufnr, name)
  if vim.b[bufnr].pico8_virtual_cart == true or name:match("^pico8%-cart:") ~= nil then
    return true
  end
  return name:match("[/\\]pico8%-cart:[/\\]") ~= nil or name:match("[/\\]pico8%-cart:$") ~= nil
end

local function enable_client_features(lsp_client, bufnr)
  local ok, client = pcall(require, "pico_lsp.client")
  if ok and client and type(client.attach) == "function" then
    pcall(client.attach, lsp_client, bufnr)
  end
  local glyph_ok, glyph_module = pcall(require, "pico_lsp.glyphs")
  if glyph_ok and glyph_module and type(glyph_module.attach) == "function" then
    pcall(glyph_module.attach, lsp_client, bufnr)
  end
end

-- Make the configured `pico8` settings available during initialize, before the
-- server's asynchronous `workspace/configuration` pull completes. Attach-time
-- requests such as the glyph prefetch would otherwise use server defaults.
local function before_init(params, config)
  local settings = config.settings
  local pico8 = type(settings) == "table" and settings.pico8 or nil
  if type(pico8) ~= "table" then
    return
  end
  local options = params.initializationOptions
  if type(options) ~= "table" then
    if options ~= nil and options ~= vim.NIL then
      return
    end
    options = {}
  end
  if options.pico8 == nil or options.pico8 == vim.NIL then
    options.pico8 = pico8
  end
  params.initializationOptions = options
end

-- Minimal config for helper-only installs without `lsp/pico_lsp.lua`. It also
-- gives manual `vim.lsp.enable("pico_lsp")` a complete config instead of a
-- partial one that would attach a rootless client.
local function fallback_config()
  return {
    cmd = command(),
    filetypes = { "pico8" },
    root_dir = function(bufnr, on_dir)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" or is_virtual(bufnr, name) then
        return
      end
      on_dir(vim.fs.dirname(vim.fs.normalize(name)))
    end,
    on_attach = function(lsp_client, bufnr)
      enable_client_features(lsp_client, bufnr)
    end,
    before_init = before_init,
  }
end

local function resolved_config()
  local config
  local ok, value = pcall(function()
    return vim.lsp.config["pico_lsp"]
  end)
  if ok and type(value) == "table" then
    config = vim.deepcopy(value)
  else
    config = fallback_config()
  end
  config.name = "pico_lsp"
  config.cmd = valid_cmd(config.cmd) or command()
  local settings = vim.deepcopy(config.settings or {})
  config.settings = next(settings) ~= nil and settings or nil
  return config
end

local function client_root(client)
  local root = client and client.config and client.config.root_dir
  if type(root) ~= "string" or root == "" then
    root = client and client.root_dir
  end
  if type(root) ~= "string" or root == "" then
    return nil
  end
  return normalize(root)
end

local function root_matches(client, root_dir)
  local root = client_root(client)
  if not root then
    return false
  end
  return same_path(root, root_dir)
end

local function find_client_for_root(root_dir)
  -- Include clients that are still initializing so two BufEnter callbacks cannot
  -- start duplicate clients for the same cart root.
  for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })) do
    if root_matches(client, root_dir) and not client:is_stopped() then
      return client
    end
  end
  return nil
end

local function attached_client(bufnr, client_id)
  local clients = vim.lsp.get_clients({
    name = "pico_lsp",
    bufnr = bufnr,
    id = client_id,
    _uninitialized = true,
  })
  return clients[1]
end

local function forget_marker(bufnr, client_id)
  local client = client_id and vim.lsp.get_client_by_id(client_id)
  if client and client._pico8_helper_buffers then
    client._pico8_helper_buffers[bufnr] = nil
  end
end

-- Forget every piece of helper-owned state for a buffer. Every managed detach
-- path goes through here so buffer variables and comment values cannot outlive
-- ownership.
local function release_include(bufnr, record)
  managed[bufnr] = nil
  clear_include_vars(bufnr)
  restore_include_comments(bufnr)
  if record then
    forget_marker(bufnr, record.client_id)
  end
end

local function wait_initialized(client)
  if client and not client.initialized then
    vim.wait(5000, function()
      return client.initialized == true or client:is_stopped()
    end, 50)
  end
  return client
end

local function ensure_client(root_dir, bufnr)
  root_dir = normalize(root_dir)
  local attached = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr, _uninitialized = true })
  for _, client in ipairs(attached) do
    if root_matches(client, root_dir) then
      return wait_initialized(client)
    end
  end

  local existing = find_client_for_root(root_dir)
  if existing then
    pcall(vim.lsp.buf_attach_client, bufnr, existing.id)
    local client = attached_client(bufnr, existing.id)
    if client then
      return wait_initialized(client)
    end
  end

  local config = resolved_config()
  config.root_dir = root_dir
  local ok, started = pcall(vim.lsp.start, config, { bufnr = bufnr })
  if not ok or not started then
    return nil
  end
  local client = wait_initialized(vim.lsp.get_client_by_id(started))
  if client and attached_client(bufnr, client.id) then
    return client
  end
  return nil
end

local function decode_png(path)
  path = normalize(path)
  local source = vim.uri_from_fname(path)
  local root_dir = vim.fs.dirname(path)
  -- Decode through a scratch request buffer so a PNG-rooted client is never
  -- attached to the user's current cart or Lua buffer.
  local request_buf = vim.api.nvim_create_buf(false, true)
  local client = ensure_client(root_dir, request_buf)
  if not client then
    pcall(vim.api.nvim_buf_delete, request_buf, { force = true })
    return nil, "could not start pico_lsp"
  end
  local responses = vim.lsp.buf_request_sync(request_buf, "pico8/decodeCart", {
    textDocument = { uri = source },
  }, 5000)
  pcall(vim.api.nvim_buf_delete, request_buf, { force = true })
  local response = responses and responses[client.id]
  if not response then
    return nil, "timed out waiting for pico8/decodeCart"
  end
  if response.err then
    local message = type(response.err) == "table" and response.err.message or response.err
    if type(message) ~= "string" or message == "" then
      message = vim.inspect(response.err)
    end
    return nil, message
  end
  local result = response.result
  if type(result) ~= "table" or not result.text or not result.virtualUri then
    return nil, "invalid pico8/decodeCart response"
  end
  return result, nil
end

local function set_virtual_text(buf, text)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function ensure_path_undo(buf)
  local undo = vim.b[buf].undo_ftplugin or ""
  if not undo:find("setlocal path<", 1, true) then
    local addition = "setlocal path<|unlet! b:pico8_path_scoped b:pico8_path_value"
    vim.b[buf].undo_ftplugin = undo ~= "" and (undo .. "|" .. addition) or addition
  end
end

-- Scope 'path' to the source directory unless the user has a custom value.
-- `force` is used when restoring a stale buffer whose local path may have been
-- derived from the virtual buffer name.
local function scope_virtual_path(buf, root_dir, force)
  local effective = vim.fn.eval("&path")
  if not force and effective ~= "" and effective ~= ".,," then
    return
  end
  local tracked = vim.b[buf].pico8_path_scoped
  if tracked and vim.bo[buf].path ~= vim.b[buf].pico8_path_value then
    -- A later user/plugin value replaced ours. An empty/default value is not a
    -- fresh local path; scope it again below.
    vim.b[buf].pico8_path_scoped = nil
    vim.b[buf].pico8_path_value = nil
    if vim.bo[buf].path ~= "" and vim.bo[buf].path ~= ".,," then
      return
    end
  end
  if force and not tracked and vim.bo[buf].path ~= "" and vim.bo[buf].path ~= ".,," then
    -- A fresh user/plugin path was set during the restore; preserve it.
    return
  end
  local global = vim.fn.eval("&g:path")
  if global ~= "" and global ~= ".,," then
    -- A custom global path should not be masked by a stale local value.
    vim.bo[buf].path = ""
    vim.b[buf].pico8_path_scoped = nil
    vim.b[buf].pico8_path_value = nil
    return
  end
  vim.bo[buf].path = includes.path_value(root_dir)
  vim.b[buf].pico8_path_scoped = true
  vim.b[buf].pico8_path_value = vim.bo[buf].path
  ensure_path_undo(buf)
end

-- Apply the non-text virtual buffer state. Setting 'filetype' only when it is
-- missing (or its ftplugin did not run) avoids re-running the ftplugin and its
-- undo on a healthy buffer, which would discard user buffer-local
-- include/expr/path values.
local function apply_virtual_state(buf, root_dir, restore)
  vim.b[buf].pico8_virtual_cart = true
  vim.b[buf].pico8_cart_root = root_dir
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if vim.bo[buf].filetype ~= "pico8" or not vim.b[buf].did_ftplugin then
    vim.bo[buf].filetype = "pico8"
  end
  if restore then
    -- Run this after FileType/after-ftplugin so every restore path lists the
    -- stale cart consistently.
    vim.bo[buf].buflisted = true
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function is_virtual_state(buf)
  return vim.b[buf].pico8_virtual_cart == true and vim.bo[buf].buftype == "nofile"
end

local function apply_virtual_options(buf, result, root_dir, restore)
  apply_virtual_state(buf, root_dir, restore)
  set_virtual_text(buf, result.text)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function restore_virtual_state(buf, info)
  local ok, source = pcall(vim.uri_to_fname, info.source)
  if not ok or type(source) ~= "string" or source == "" then
    return
  end
  local root_dir = vim.fs.dirname(normalize(source))
  apply_virtual_state(buf, root_dir, true)
  scope_virtual_path(buf, root_dir, true)
end

local function open_virtual(result, root_dir)
  local buf = vim.api.nvim_create_buf(true, true)
  local named, name_err = pcall(vim.api.nvim_buf_set_name, buf, result.virtualUri)
  if not named then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, name_err
  end
  apply_virtual_options(buf, result, root_dir, false)
  vim.api.nvim_set_current_buf(buf)
  return buf, nil
end

-- A virtual buffer can already exist after :e, :split, or a second
-- :Pico8OpenPng. The helper's tracking map is authoritative on Neovim 0.11,
-- where a URI-like name is expanded under the current directory. The name
-- fallback strips any directory prefix so a cwd change cannot create a
-- duplicate.
local function find_virtual(virtual_uri)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local info = M.png_buffers[bufnr]
      if info and info.virtual == virtual_uri then
        return bufnr
      end
      if vim.b[bufnr].pico8_virtual_cart == true then
        local name = vim.api.nvim_buf_get_name(bufnr)
        local position = name:find("pico8%-cart:")
        if position and name:sub(position) == virtual_uri then
          return bufnr
        end
      end
    end
  end
  return nil
end

-- An auto-open failure must never leave the raw PNG loaded. Keep the source
-- buffer as an empty, read-only nofile buffer so the path stays visible and
-- :Pico8OpenPng can retry, while writes cannot create an empty PNG.
local function scratch_png_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, {})
  vim.b[bufnr].pico8_virtual_cart = nil
  vim.b[bufnr].pico8_cart_root = nil
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() ~= bufnr then
    pcall(vim.api.nvim_set_current_buf, bufnr)
  end
end

function M.open_png(path)
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return nil, "helper is disabled"
  end
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("Pico8OpenPng needs a .p8.png path")
    return nil, "Pico8OpenPng needs a .p8.png path"
  end
  path = normalize(path)
  local result, err = decode_png(path)
  if err then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  local root_dir = vim.fs.dirname(path)
  local config = resolved_config()
  config.root_dir = root_dir

  local existing = find_virtual(result.virtualUri)
  local stale = existing ~= nil and not is_virtual_state(existing)
  local created = false
  local buf = existing
  if buf then
    apply_virtual_options(buf, result, root_dir, stale)
    vim.api.nvim_set_current_buf(buf)
  else
    local create_err
    buf, create_err = open_virtual(result, root_dir)
    if not buf then
      notify("could not open the decoded cart buffer: " .. tostring(create_err), vim.log.levels.ERROR)
      return nil, create_err
    end
    created = true
  end

  scope_virtual_path(buf, root_dir, stale)
  local had_client = #vim.lsp.get_clients({
    name = "pico_lsp",
    bufnr = buf,
    _uninitialized = true,
  }) > 0
  local ok, started = pcall(vim.lsp.start, config, { bufnr = buf })
  local client = ok and started and attached_client(buf, started) or nil
  if not client then
    local message = ok and "could not attach pico_lsp to the decoded cart" or tostring(started)
    if created then
      local deleted, delete_err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
      if not deleted then
        log_debug("pico-lsp: could not delete the unattached virtual cart: " .. tostring(delete_err))
      end
      notify(message, vim.log.levels.ERROR)
      return nil, message
    end
    -- Do not delete an existing virtual cart because a reattach failed.
    notify("could not reattach pico_lsp to the decoded cart: " .. message, vim.log.levels.ERROR)
    return buf, nil
  end

  local info = M.png_buffers[buf]
  if existing then
    if not info then
      info = {}
      M.png_buffers[buf] = info
    end
    info.source = result.sourceUri
    info.virtual = result.virtualUri
    info.version = (tonumber(info.version) or tonumber(result.version) or 1) + 1
    -- A client that was already attached will not resend didOpen on reuse.
    -- A newly attached client sends it from vim.lsp.start.
    if had_client then
      vim.lsp.buf_notify(buf, "textDocument/didOpen", {
        textDocument = {
          uri = info.virtual,
          languageId = "pico8",
          version = info.version,
          text = result.text,
        },
      })
    end
    if vim.api.nvim_buf_is_valid(buf) then
      cart_module.refresh_cart_info(buf)
    end
  else
    M.png_buffers[buf] = {
      source = result.sourceUri,
      virtual = result.virtualUri,
      version = tonumber(result.version) or 1,
    }
  end
  return buf, nil
end

local function auto_open_png(args)
  if M.disabled then
    return
  end
  local buf = M.open_png(args.file)
  if buf then
    if vim.api.nvim_buf_is_valid(args.buf) then
      local ok, delete_err = pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
      if not ok then
        log_debug("pico-lsp: could not delete the source PNG buffer: " .. tostring(delete_err))
      end
    end
    return
  end
  -- M.open_png notified the error; keep the buffer empty and read-only.
  scratch_png_buffer(args.buf)
end

function M.insert_glyph(argument)
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  glyphs.insert(argument)
end

-- `glyph_maps = true` installs the maps through the ftplugin. The global is
-- kept for base-config users and older configurations.
function M.glyph_maps_enabled(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if vim.g.pico8_glyph_maps and vim.g.pico8_glyph_maps ~= 0 then
    return true
  end
  if M.opts and M.opts.glyph_maps == true then
    return true
  end
  local marker = vim.b[bufnr].pico8_glyph_maps
  return marker == true or marker == 1
end

-- PICO-8 assigns the 26 typeable symbols at P8SCII 0x80-0x99 to Shift-A..Z
-- in alphabetical order. The glyph text comes from the cached server catalog,
-- so custom pico8.glyphs entries and canonical Unicode spellings stay
-- server-owned and Shift presses do not request the catalog every time.
local shift_glyph_first_byte = 0x80
local shift_glyph_count = 26

-- The cached catalog is position-independent, so the mapping keeps the
-- server's code-only behavior locally: only the __lua__ section is code, and
-- #include directives are never glyph targets. Buffers without cart sections
-- (for example a manually mapped Lua buffer) are treated as code.
local function in_code_context(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    win = 0
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    return false
  end
  local line = lines[lnum] or ""
  if line:match("^%s*#include%s") or line:match("^%s*#include$") then
    return false
  end

  local current_section = nil
  local saw_section = false
  for i, text in ipairs(lines) do
    local section = text:match("^%s*__([%a_]+)__%s*$")
    if section then
      saw_section = true
      if i == lnum then
        return false
      end
      if i < lnum then
        current_section = section
      end
    end
  end
  if not saw_section then
    return true
  end
  return current_section == "lua"
end

local function glyph_text(bufnr, byte, key)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return key
  end
  if not vim.bo[bufnr].modifiable then
    return ""
  end
  local mode = vim.fn.mode(1)
  if mode == "R" or mode == "r" then
    return key
  end
  if not in_code_context(bufnr) then
    return key
  end

  local text = glyphs.text_for_byte(bufnr, byte)
  if not text or text == "" then
    return key
  end
  return text
end

function M.install_glyph_maps(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  vim.b[bufnr].pico8_glyph_maps = true

  -- If a client is already attached, start the catalog fetch now. Attach-time
  -- prefetch covers the usual order; the module coalesces in-flight requests.
  local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
  if client then
    glyphs.prefetch(client, bufnr)
  end

  for i = 0, shift_glyph_count - 1 do
    local key = string.char(string.byte("A") + i)
    local byte = shift_glyph_first_byte + i
    vim.keymap.set("i", key, function()
      return glyph_text(bufnr, byte, key)
    end, {
      buffer = bufnr,
      expr = true,
      replace_keycodes = false,
      desc = string.format("PICO-8 Shift-%s glyph (P8SCII 0x%02x)", key, byte),
    })
  end
end

function M.reload_png()
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local info = M.png_buffers[buf]
  if not info then
    notify("current buffer is not a decoded .p8.png cart")
    return
  end
  local ok, path = pcall(vim.uri_to_fname, info.source)
  if not ok or type(path) ~= "string" or path == "" then
    notify("could not resolve the source .p8.png path", vim.log.levels.ERROR)
    return
  end
  M.open_png(path)
end

local function is_cart_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.b[bufnr].pico8_virtual_cart == true then
    return true
  end
  if vim.bo[bufnr].filetype == "pico8" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false
  end
  if is_virtual(bufnr, name) then
    return true
  end
  return name:lower():sub(-3) == ".p8"
end

function M.open_cart()
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if is_cart_buffer(bufnr) then
    notify("current buffer is already a PICO-8 cart", vim.log.levels.INFO)
    return
  end
  local record = managed[bufnr]
  local cart_uri = record and record.cart_uri or nil
  if type(cart_uri) ~= "string" or cart_uri == "" then
    notify("no owning cart found for this buffer")
    return
  end
  local ok, path = pcall(vim.uri_to_fname, cart_uri)
  if not ok or type(path) ~= "string" or path == "" then
    log_debug("pico-lsp: invalid owning cart URI: " .. tostring(cart_uri))
    notify("no owning cart found for this buffer")
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

-- Attach a cart-owned .lua buffer. A buffer that already has a pico_lsp client
-- was either started by the user or is already managed; never add a second
-- client or claim an attachment the helper did not make.
local function attach(bufnr)
  if M.disabled or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "lua" then
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:sub(-4):lower() ~= ".lua" then
    return
  end
  if #vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr, _uninitialized = true }) > 0 then
    return
  end

  local path = normalize(name)
  local cart = find_cart(path)
  if not cart then
    return
  end

  local directory = vim.fs.dirname(cart)
  if not directory then
    return
  end
  local root_dir = normalize(directory)

  local config = resolved_config()
  local cmd = config.cmd
  if type(cmd) == "table" and cmd[1] and vim.fn.executable(cmd[1]) == 0 then
    if not warned_missing_binary then
      warned_missing_binary = true
      notify("command not found: " .. cmd[1] .. " (set cmd in pico_lsp.setup)")
    end
    return
  end

  local client = find_client_for_root(root_dir)
  if client then
    local ok = pcall(vim.lsp.buf_attach_client, bufnr, client.id)
    if not ok or not attached_client(bufnr, client.id) then
      return
    end
  else
    config.root_dir = root_dir
    local ok, started = pcall(vim.lsp.start, config, { bufnr = bufnr })
    if not ok then
      notify(tostring(started), vim.log.levels.ERROR)
      return
    end
    if not started then
      return
    end
    client = vim.lsp.get_client_by_id(started)
    if not client or not attached_client(bufnr, client.id) then
      return
    end
  end

  -- Mark this buffer's attachment only. A user-started attachment can share the
  -- same client without becoming helper-managed.
  client._pico8_helper_buffers = client._pico8_helper_buffers or {}
  client._pico8_helper_buffers[bufnr] = true
  managed[bufnr] = {
    client_id = client.id,
    root_dir = root_dir,
    cart = cart,
    cart_uri = vim.uri_from_fname(cart),
  }
  set_include_vars(bufnr, managed[bufnr])
  apply_include_comments(bufnr)
end

local function safe_attach(bufnr)
  local ok, err = pcall(attach, bufnr)
  if not ok then
    log_debug("pico-lsp: attachment failed: " .. tostring(err))
  end
end

local function detach_managed(bufnr, record)
  release_include(bufnr, record)
  if not record then
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if not attached_client(bufnr, record.client_id) then
    return
  end
  local ok, err = pcall(vim.lsp.buf_detach_client, bufnr, record.client_id)
  if not ok then
    log_debug("pico-lsp: could not detach managed client: " .. tostring(err))
  end
end

local function revalidate_managed()
  local pending = {}
  for bufnr in pairs(managed) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      pending[#pending + 1] = bufnr
    else
      -- The buffer unloaded before restore could run; drop the record without
      -- writing options that may no longer belong to this buffer.
      release_include(bufnr, managed[bufnr])
    end
  end
  table.sort(pending)

  for _, bufnr in ipairs(pending) do
    local record = managed[bufnr]
    if record then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local path = name ~= "" and normalize(name) or nil
      local cart = path and find_cart(path) or nil
      if not cart then
        detach_managed(bufnr, record)
      elseif not same_path(cart, record.cart) then
        local directory = vim.fs.dirname(cart)
        local new_root = directory and normalize(directory) or nil
        if new_root and record.root_dir and same_path(new_root, record.root_dir) then
          local previous_cart_uri = record.cart_uri
          record.cart = cart
          record.cart_uri = vim.uri_from_fname(cart)
          set_include_vars(bufnr, record)
          if previous_cart_uri ~= record.cart_uri then
            cart_module.owner_changed(bufnr, record.cart_uri)
          end
        else
          detach_managed(bufnr, record)
          safe_attach(bufnr)
        end
      elseif not attached_client(bufnr, record.client_id) then
        release_include(bufnr, record)
      end
    end
  end
end

-- A plugin/module reload creates a new module instance with an empty managed
-- map while Neovim keeps the clients. Re-adopt clients this helper started for
-- this buffer (marked below) when their cart still owns the buffer, and detach
-- marked clients whose owner is gone or changed. User-started attachments are
-- unmarked, so they remain untouched even when they share a client with a
-- helper-managed attachment.
local function adopt_marked_clients()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local lower = name:lower()
      local is_lua = vim.bo[bufnr].filetype == "lua" or lower:sub(-4) == ".lua"
      if is_lua then
        local cart = name ~= "" and find_cart(normalize(name)) or nil
        local directory = cart and vim.fs.dirname(cart) or nil
        local root_dir = directory and normalize(directory) or nil
        local adopted = false
        local attached = vim.lsp.get_clients({
          name = "pico_lsp",
          bufnr = bufnr,
          _uninitialized = true,
        })
        for _, client in ipairs(attached) do
          if client._pico8_helper_buffers and client._pico8_helper_buffers[bufnr] then
            if not adopted and cart and root_dir and root_matches(client, root_dir) then
              managed[bufnr] = {
                client_id = client.id,
                root_dir = root_dir,
                cart = cart,
                cart_uri = vim.uri_from_fname(cart),
              }
              set_include_vars(bufnr, managed[bufnr])
              apply_include_comments(bufnr)
              adopted = true
            else
              client._pico8_helper_buffers[bufnr] = nil
              release_include(bufnr, managed[bufnr])
              local ok, err = pcall(vim.lsp.buf_detach_client, bufnr, client.id)
              if not ok then
                log_debug("pico-lsp: could not detach orphaned helper client: " .. tostring(err))
              end
            end
          end
        end
      end
    end
  end
end

local function attach_loaded_lua_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      safe_attach(bufnr)
    end
  end
end

-- Ownership can change for a Lua buffer whose client was started by the user;
-- M26 only tracks helper-managed attachments. Keep the cart cache's root in
-- sync for every attached Lua buffer, including user-started clients.
local function sync_cart_owners()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "lua" then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local path = name ~= "" and normalize(name) or nil
      if path then
        local attached = vim.lsp.get_clients({
          name = "pico_lsp",
          bufnr = bufnr,
          _uninitialized = true,
        })
        if #attached > 0 then
          local cart = find_cart(path)
          cart_module.owner_changed(bufnr, cart and vim.uri_from_fname(cart) or nil)
        end
      end
    end
  end
end

local function rescan()
  local ok, err = pcall(revalidate_managed)
  if not ok then
    log_debug("pico-lsp: ownership revalidation failed: " .. tostring(err))
  end
  attach_loaded_lua_buffers()
  sync_cart_owners()
end

local function close_rescan_timer(cart)
  local timer = rescan_timers[cart]
  if not timer then
    rescan_generations[cart] = nil
    return
  end
  rescan_timers[cart] = nil
  rescan_generations[cart] = nil
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then
    pcall(timer.close, timer)
  end
end

local function cancel_rescans()
  local carts = {}
  for cart in pairs(rescan_timers) do
    carts[#carts + 1] = cart
  end
  for _, cart in ipairs(carts) do
    close_rescan_timer(cart)
  end
  rescan_generations = {}
  unload_generations = {}
end

local function schedule_rescan(cart)
  local generation = (rescan_generations[cart] or 0) + 1
  rescan_generations[cart] = generation

  local timer = rescan_timers[cart]
  if not timer then
    local ok, created = pcall(vim.uv.new_timer)
    if not ok or not created then
      rescan_generations[cart] = nil
      return
    end
    timer = created
    rescan_timers[cart] = timer
  end

  local callback = vim.schedule_wrap(function()
    if rescan_generations[cart] ~= generation then
      return
    end
    close_rescan_timer(cart)
    if M.disabled then
      return
    end
    invalidate_cart(cart)
    rescan()
  end)

  local ok, result = pcall(timer.start, timer, RESCAN_DEBOUNCE_MS, 0, callback)
  if not ok or result == nil then
    close_rescan_timer(cart)
  end
end

local function on_cart_edit(cart)
  -- A loaded cart is parsed from its buffer, so a new include can be honored by
  -- the next BufEnter without waiting for the debounce. Only the ownership
  -- lookup needs to be dropped now; the full rescan stays debounced.
  invalidate_owner_cache()
  schedule_rescan(cart)
end

-- A cart that was written or reloaded has new authoritative buffer contents.
-- Drop its cached includes and rescan now; this is also what makes `:edit!`
-- pick up an external change without waiting for :Pico8Refresh.
local function rescan_cart(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local cart = normalize(name)
  close_rescan_timer(cart)
  unload_generations[cart] = nil
  invalidate_cart(cart)
  rescan()
end

-- An unloaded or deleted cart buffer no longer supplies include data. Drop its
-- cache and revalidate once the unload has actually finished; another autocmd
-- may yield before the buffer is released, so retry until it is unloaded.
local function forget_cart(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local cart = normalize(name)
  close_rescan_timer(cart)
  invalidate_cart(cart)
  local generation = (unload_generations[cart] or 0) + 1
  unload_generations[cart] = generation
  local attempts = 0

  local function finish()
    vim.defer_fn(function()
      if M.disabled or unload_generations[cart] ~= generation then
        return
      end
      attempts = attempts + 1
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        if attempts < UNLOAD_RETRY_LIMIT then
          finish()
        else
          unload_generations[cart] = nil
          log_debug("pico-lsp: cart unload did not complete; leaving revalidation to the next rescan")
        end
        return
      end
      unload_generations[cart] = nil
      invalidate_cart(cart)
      rescan()
    end, UNLOAD_POLL_MS)
  end

  finish()
end

function M.refresh()
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  cancel_rescans()
  include_cache = {}
  include_cache_order = {}
  owner_cache = {}
  rescan()
  cart_module.refresh_all()
  notify("include cache cleared; loaded buffers rescanned", vim.log.levels.INFO)
end

local function define_commands(enabled)
  vim.api.nvim_create_user_command("Pico8Refresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Clear the pico-lsp include cache and rescan loaded buffers" })
  -- The toggle only changes client-side display, not helper-owned attachments,
  -- so it stays available when the helper itself is disabled.
  vim.api.nvim_create_user_command("Pico8ToggleInlayHints", function()
    require("pico_lsp.client").toggle_inlay_hints(0)
  end, { nargs = 0, desc = "Toggle pico-lsp inlay hints for the current buffer" })
  if not enabled then
    return
  end
  vim.api.nvim_create_user_command("Pico8OpenPng", function(args)
    M.open_png(args.args ~= "" and args.args or nil)
  end, {
    nargs = "?",
    complete = "file",
    desc = "Decode a PICO-8 .p8.png cart into a read-only buffer",
  })
  vim.api.nvim_create_user_command("Pico8ReloadPng", M.reload_png, {
    nargs = 0,
    desc = "Reload the current decoded .p8.png cart",
  })
  vim.api.nvim_create_user_command("Pico8InsertGlyph", function(args)
    M.insert_glyph(args.args ~= "" and args.args or nil)
  end, {
    nargs = "?",
    desc = "Insert a P8SCII glyph by name or byte, or open the filtered picker",
    complete = function(arg_lead)
      return glyphs.complete(arg_lead)
    end,
  })
  vim.api.nvim_create_user_command("Pico8OpenCart", M.open_cart, {
    nargs = 0,
    desc = "Open the PICO-8 cart that includes this buffer",
  })
end

function M.setup(opts)
  opts = opts or {}
  M.did_setup = true
  M.opts = opts
  M.disabled = opts.disable == true or vim.g.pico_lsp_helper_disabled == 1
  -- The catalog belongs to the current client/server settings. A re-setup is a
  -- fresh configuration even when the helper stays enabled.
  glyphs.reset()

  -- Configure the shared client-display options even when the helper is
  -- disabled: the shipped lsp/pico_lsp.lua still attaches and reads them.
  local ok, client = pcall(require, "pico_lsp.client")
  if ok and client and type(client.setup) == "function" then
    client.setup(opts)
  end

  cancel_rescans()
  include_cache = {}
  include_cache_order = {}
  owner_cache = {}
  -- Rebuild records from clients this helper started, so a plugin module
  -- reload (which starts with an empty managed map) can still detach them.
  adopt_marked_clients()
  -- Preserve managed attachments across an enabled re-setup (config reload or
  -- plugin reload). Disabling the helper is a shutdown: detach only the clients
  -- it recorded, then clear the state.
  if M.disabled then
    local buffers = {}
    for bufnr in pairs(managed) do
      buffers[#buffers + 1] = bufnr
    end
    for _, bufnr in ipairs(buffers) do
      detach_managed(bufnr, managed[bufnr])
    end
    managed = {}
  end

  if M.group then
    pcall(vim.api.nvim_del_augroup_by_id, M.group)
    M.group = nil
  end

  define_commands(not M.disabled)

  -- The cart cache belongs to the client surface, not to the included-Lua
  -- helper. Keep its commands available when the helper is disabled, but clear
  -- cached data and timers on a disabled setup.
  if M.disabled then
    cart_module.shutdown()
    return
  end
  cart_module.setup(opts)

  -- Apply setup overrides to the merged config even when activation is left to
  -- the caller. A later user vim.lsp.config call still wins.
  local config = {}
  local cmd = valid_cmd(opts.cmd)
  if cmd then
    config.cmd = cmd
  end
  if type(opts.settings) == "table" then
    config.settings = opts.settings
  end
  local ok, existing = pcall(function()
    return vim.lsp.config["pico_lsp"]
  end)
  if not (ok and type(existing) == "table") then
    config = vim.tbl_deep_extend("force", fallback_config(), config)
  end
  if next(config) ~= nil then
    vim.lsp.config("pico_lsp", config)
  end

  if opts.lsp ~= false then
    -- Re-enabling an already enabled config makes Neovim sweep every FileType
    -- buffer, which detaches user-started pico_lsp clients from .lua buffers.
    -- The config stays enabled; new buffers still use the current config.
    local already_enabled = type(vim.lsp.is_enabled) == "function" and vim.lsp.is_enabled("pico_lsp")
    if not already_enabled then
      local ok, err = pcall(vim.lsp.enable, "pico_lsp")
      if not ok then
        notify("could not enable pico_lsp: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  M.group = vim.api.nvim_create_augroup("pico_lsp_helper", { clear = true })
  -- `nvim cart.p8.png` decodes through the helper instead of reading binary
  -- data. The command and autocmd are only installed when the helper is
  -- enabled; a disabled setup returned above.
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = M.group,
    pattern = "*.p8.png",
    callback = function(args)
      local ok, err = pcall(auto_open_png, args)
      if not ok then
        notify("could not auto-open " .. tostring(args.file) .. ": " .. tostring(err), vim.log.levels.ERROR)
        scratch_png_buffer(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = M.group,
    pattern = "lua",
    callback = function(args)
      safe_attach(args.buf)
    end,
  })
  -- Prefetch after every pico_lsp attachment, including user-configured
  -- clients whose on_attach does not call the shipped hook.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = M.group,
    callback = function(args)
      local data = args.data or {}
      local client = data.client_id and vim.lsp.get_client_by_id(data.client_id)
      if not client or client.name ~= "pico_lsp" then
        return
      end
      local ok, err = pcall(glyphs.attach, client, args.buf)
      if not ok then
        log_debug("pico-lsp: glyph prefetch attach failed: " .. tostring(err))
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = M.group,
    pattern = "*.lua",
    callback = function(args)
      safe_attach(args.buf)
    end,
  })
  -- A tracked virtual cart can be loaded directly with :buffer after
  -- :bdelete. Restore its virtual state before any reload command runs.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = M.group,
    callback = function(args)
      local info = M.png_buffers[args.buf]
      if not info or is_virtual_state(args.buf) then
        return
      end
      restore_virtual_state(args.buf, info)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = M.group,
    pattern = "*.p8",
    callback = function(args)
      rescan_cart(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = M.group,
    pattern = "*.p8",
    callback = function(args)
      rescan_cart(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = M.group,
    pattern = "*.p8",
    callback = function(args)
      forget_cart(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = M.group,
    pattern = "*.p8",
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name == "" then
        return
      end
      on_cart_edit(normalize(name))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = M.group,
    callback = function(args)
      local bufnr = args.buf
      M.png_buffers[bufnr] = nil
      managed[bufnr] = nil
      comment_restore[bufnr] = nil
      for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })) do
        if client._pico8_helper_buffers then
          client._pico8_helper_buffers[bufnr] = nil
        end
      end
      local name = vim.api.nvim_buf_get_name(bufnr)
      local is_cart = name ~= "" and name:lower():match("%.p8$") ~= nil
      local is_lua = name ~= "" and name:lower():match("%.lua$") ~= nil
      if is_cart then
        local cart = normalize(name)
        drop_include(cart)
        close_rescan_timer(cart)
      end
      if is_cart or is_lua then
        invalidate_owner_cache()
      end
      if is_cart then
        -- A wiped cart may have been deleted from disk; recheck its includes
        -- after the buffer list settles.
        vim.schedule(function()
          if not M.disabled then
            rescan()
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = M.group,
    callback = function(args)
      local data = args.data or {}
      local bufnr = data.bufnr or args.buf
      local record = bufnr and managed[bufnr]
      if record and record.client_id == data.client_id then
        release_include(bufnr, record)
      end
      if bufnr then
        forget_marker(bufnr, data.client_id)
      end
      glyphs.detach(data.client_id, bufnr)
    end,
  })

  -- A setup that enables glyph maps after carts are already open installs the
  -- mappings without waiting for another FileType event.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].filetype == "pico8"
      and M.glyph_maps_enabled(bufnr)
    then
      M.install_glyph_maps(bufnr)
    end
  end

  attach_loaded_lua_buffers()
end

return M
