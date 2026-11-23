-- pico8.nvim client setup: attach pico-lsp to cart-owned .lua buffers.
--
-- Enable with:
--   require("pico_lsp").setup()
--
-- The helper never runs for .p8 carts (the native lsp/pico_lsp.lua config
-- handles those) and ignores .lua files that are not included by a nearby
-- .p8 cart.

local M = {}

M.png_buffers = {}

local warned_missing_binary = false
local warned_glyph_maps = false

-- Cart edits are coalesced for this long before the helper rescans includes.
local RESCAN_DEBOUNCE_MS = 300

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

-- Match the server's splitIncludeTarget: strip a single hex-digit tab suffix
-- only from cartridge include paths. A `.lua:2` path stays literal.
local function strip_tab_selector(path)
  if #path < 2 then
    return path
  end
  local digit = path:sub(-1)
  if path:sub(-2, -2) ~= ":" or not digit:match("%x") then
    return path
  end
  local name = path:sub(1, -3)
  local lower = name:lower()
  if lower:sub(-7) ~= ".p8.png" and lower:sub(-3) ~= ".p8" then
    return path
  end
  return name
end

local function include_target(line)
  local rest = line:match("^%s*#include%s+(.+)$")
  if not rest then
    return nil
  end
  rest = vim.trim(rest)
  local quoted = rest:match('^"([^"]*)"') or rest:match("^'([^']*)'")
  if quoted then
    rest = quoted
  end
  rest = rest:gsub("\\", "/")
  rest = strip_tab_selector(rest)
  return rest
end

local function parse_targets(lines, directory)
  local targets = {}
  for _, line in ipairs(lines) do
    local include = include_target(line)
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
    return nil, vim.inspect(response.err)
  end
  local result = response.result
  if type(result) ~= "table" or not result.text or not result.virtualUri then
    return nil, "invalid pico8/decodeCart response"
  end
  return result, nil
end

local function open_virtual(result)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, result.virtualUri)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.text, "\n", { plain = true }))
  vim.b[buf].pico8_virtual_cart = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "pico8"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_set_current_buf(buf)
  return buf
end

function M.open_png(path)
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("Pico8OpenPng needs a .p8.png path")
    return
  end
  path = normalize(path)
  local result, err = decode_png(path)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end
  local buf = open_virtual(result)
  local config = resolved_config()
  config.root_dir = vim.fs.dirname(path)
  vim.lsp.start(config, { bufnr = buf })
  M.png_buffers[buf] = {
    source = result.sourceUri,
    virtual = result.virtualUri,
    version = tonumber(result.version) or 1,
  }
end

local function glyph_label(item)
  local byte = item.byte ~= nil and string.format("0x%02x", item.byte) or ""
  return string.format("%s  p8_%s  %s", item.text or "", item.name or "", item.description or byte)
end

function M.insert_glyph(name)
  if M.disabled then
    notify("helper is disabled", vim.log.levels.INFO)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return
  end

  local position = vim.lsp.util.make_position_params(0, client.offset_encoding)
  if not name or name == "" then
    local response = client:request_sync("pico8/glyphs", {
      textDocument = position.textDocument,
      position = position.position,
    }, 2000, bufnr)
    if not response or response.err or not response.result then
      notify("could not load P8SCII glyphs", vim.log.levels.ERROR)
      return
    end
    vim.ui.select(response.result.glyphs, {
      prompt = "P8SCII glyph",
      format_item = glyph_label,
    }, function(item)
      if item then
        M.insert_glyph(item.name)
      end
    end)
    return
  end

  local response = client:request_sync("workspace/executeCommand", {
    command = "pico8.insertGlyph",
    arguments = {
      {
        textDocument = position.textDocument,
        position = position.position,
        name = name,
      },
    },
  }, 3000, bufnr)
  if not response or response.err then
    notify("could not insert P8SCII glyph", vim.log.levels.ERROR)
    return
  end
  if response.result and response.result.edit then
    vim.lsp.util.apply_workspace_edit(response.result.edit, client.offset_encoding)
  end
end

-- PICO-8 assigns the 26 typeable symbols at P8SCII 0x80-0x99 to Shift-A..Z
-- in alphabetical order. The glyph text comes from the server catalog, so
-- custom pico8.glyphs entries and canonical Unicode spellings stay server-owned.
local shift_glyph_first_byte = 0x80
local shift_glyph_count = 26

local function glyph_text(byte, key)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable then
    return ""
  end
  local mode = vim.fn.mode(1)
  if mode == "R" or mode == "r" then
    return key
  end

  local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
  if not client then
    if not warned_glyph_maps then
      warned_glyph_maps = true
      notify("no pico_lsp client attached; PICO-8 Shift glyph maps fall back to uppercase letters")
    end
    return key
  end

  local position = vim.lsp.util.make_position_params(0, client.offset_encoding)
  local response = client:request_sync("pico8/glyphs", {
    textDocument = position.textDocument,
    position = position.position,
  }, 2000, bufnr)
  if not response or response.err or not response.result then
    if not warned_glyph_maps then
      warned_glyph_maps = true
      notify("could not load P8SCII glyphs; Shift glyph maps fall back to uppercase letters", vim.log.levels.ERROR)
    end
    return key
  end

  -- Later entries win so a custom definition can override a built-in byte.
  local text = ""
  for _, entry in ipairs(response.result.glyphs or {}) do
    if entry.byte == byte then
      text = entry.text or ""
    end
  end
  if text == "" then
    return key
  end
  return text
end

function M.install_glyph_maps(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  for i = 0, shift_glyph_count - 1 do
    local key = string.char(string.byte("A") + i)
    local byte = shift_glyph_first_byte + i
    vim.keymap.set("i", key, function()
      return glyph_text(byte, key)
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
  local path = vim.uri_to_fname(info.source)
  local result, err = decode_png(path)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.text, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  info.version = info.version + 1
  vim.lsp.buf_notify(buf, "textDocument/didOpen", {
    textDocument = {
      uri = info.virtual,
      languageId = "pico8",
      version = info.version,
      text = result.text,
    },
  })
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

  client._pico8_helper = true
  managed[bufnr] = {
    client_id = client.id,
    root_dir = root_dir,
    cart = cart,
    cart_uri = vim.uri_from_fname(cart),
  }
end

local function safe_attach(bufnr)
  local ok, err = pcall(attach, bufnr)
  if not ok then
    log_debug("pico-lsp: attachment failed: " .. tostring(err))
  end
end

local function detach_managed(bufnr, record)
  managed[bufnr] = nil
  if not record or not vim.api.nvim_buf_is_loaded(bufnr) then
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
      managed[bufnr] = nil
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
          record.cart = cart
          record.cart_uri = vim.uri_from_fname(cart)
        else
          detach_managed(bufnr, record)
          safe_attach(bufnr)
        end
      elseif not attached_client(bufnr, record.client_id) then
        managed[bufnr] = nil
      end
    end
  end
end

-- A plugin/module reload creates a new module instance with an empty managed
-- map while Neovim keeps the clients. Re-adopt clients this helper started
-- (marked below) when their cart still owns the buffer, and detach marked
-- clients whose owner is gone or changed. User-started clients are unmarked, so
-- they remain untouched.
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
          if client._pico8_helper then
            if not adopted and cart and root_dir and root_matches(client, root_dir) then
              managed[bufnr] = {
                client_id = client.id,
                root_dir = root_dir,
                cart = cart,
                cart_uri = vim.uri_from_fname(cart),
              }
              adopted = true
            else
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

local function rescan()
  local ok, err = pcall(revalidate_managed)
  if not ok then
    log_debug("pico-lsp: ownership revalidation failed: " .. tostring(err))
  end
  attach_loaded_lua_buffers()
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

  local function finish()
    vim.defer_fn(function()
      if M.disabled or unload_generations[cart] ~= generation then
        return
      end
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        finish()
        return
      end
      unload_generations[cart] = nil
      invalidate_cart(cart)
      rescan()
    end, 10)
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
  notify("include cache cleared; loaded buffers rescanned", vim.log.levels.INFO)
end

local function define_commands(enabled)
  vim.api.nvim_create_user_command("Pico8Refresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Clear the pico-lsp include cache and rescan loaded buffers" })
  if not enabled then
    return
  end
  vim.api.nvim_create_user_command("Pico8OpenPng", function(args)
    M.open_png(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("Pico8ReloadPng", M.reload_png, { nargs = 0 })
  vim.api.nvim_create_user_command("Pico8InsertGlyph", function(args)
    M.insert_glyph(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })
end

function M.setup(opts)
  opts = opts or {}
  M.opts = opts
  M.disabled = opts.disable == true or vim.g.pico_lsp_helper_disabled == 1

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

  if M.disabled then
    return
  end

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
  vim.api.nvim_create_autocmd("FileType", {
    group = M.group,
    pattern = "lua",
    callback = function(args)
      safe_attach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = M.group,
    pattern = "*.lua",
    callback = function(args)
      safe_attach(args.buf)
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
        managed[bufnr] = nil
      end
    end,
  })

  attach_loaded_lua_buffers()
end

return M
