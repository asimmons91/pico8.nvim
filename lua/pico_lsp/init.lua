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

local default_settings = {
  pico8 = {
    apiVersion = "0.2.7",
    typeChecking = "basic",
    inlayHints = false,
  },
}

local warned_missing_binary = false
local warned_glyph_maps = false

local function notify(message, level)
  vim.notify("pico-lsp: " .. message, level or vim.log.levels.WARN)
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

local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
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
  -- .p8 includes can select a tab with a single hex-digit suffix.
  rest = rest:gsub(":%x$", "")
  return rest
end

local function cart_includes(cart, target)
  local lines = read_lines(cart)
  if not lines then
    return false
  end
  local directory = vim.fs.dirname(cart)
  for _, line in ipairs(lines) do
    local include = include_target(line)
    if include then
      local candidate = normalize(directory .. "/" .. include)
      if same_path(candidate, target) then
        return true
      end
    end
  end
  return false
end

local function find_cart(path)
  local directory = vim.fs.dirname(path)
  while directory do
    local carts = vim.fn.globpath(directory, "*.p8", false, true)
    table.sort(carts)
    for _, cart in ipairs(carts) do
      local normalized = normalize(cart)
      if not same_path(normalized, path) and cart_includes(normalized, path) then
        return normalized
      end
    end
    local parent = vim.fs.dirname(directory)
    if not parent or parent == directory then
      break
    end
    directory = parent
  end
  return nil
end

local function normalize_cmd(cmd)
  if type(cmd) == "string" and cmd ~= "" then
    return { cmd }
  end
  if type(cmd) == "table" and #cmd > 0 then
    return cmd
  end
  return nil
end

local function resolved_config(opts)
  local config
  local ok, value = pcall(function()
    return vim.lsp.config["pico_lsp"]
  end)
  if ok and type(value) == "table" then
    config = vim.deepcopy(value)
  else
    config = {}
  end
  config.name = "pico_lsp"
  config.cmd = normalize_cmd(opts.cmd) or config.cmd or { "pico-lsp" }
  config.settings = vim.tbl_deep_extend("force", default_settings, config.settings or {}, opts.settings or {})
  return config
end


local function ensure_client(root_dir, bufnr)
  local attached = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
  if #attached > 0 then
    return attached[1]
  end
  local existing = vim.lsp.get_clients({ name = "pico_lsp" })
  if #existing > 0 then
    pcall(vim.lsp.buf_attach_client, bufnr, existing[1].id)
    attached = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
    if #attached > 0 then
      return attached[1]
    end
  end
  local config = resolved_config(M.opts)
  config.root_dir = root_dir
  local started = vim.lsp.start(config, { bufnr = bufnr })
  if not started then
    return nil
  end
  vim.wait(5000, function()
    return #vim.lsp.get_clients({ name = "pico_lsp" }) > 0
  end, 50)
  return vim.lsp.get_clients({ name = "pico_lsp" })[1] or started
end

local function decode_png(path)
  local source = vim.uri_from_fname(path)
  local root_dir = vim.fs.dirname(path)
  local request_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(request_buf):lower():match("%.p8%.png$") then
    request_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(request_buf)
  end
  local client = ensure_client(root_dir, request_buf)
  if not client then
    return nil, "could not start pico_lsp"
  end
  local responses = vim.lsp.buf_request_sync(request_buf, "pico8/decodeCart", {
    textDocument = { uri = source },
  }, 5000)
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
  vim.bo[buf].filetype = "pico8"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_set_current_buf(buf)
  return buf
end

function M.open_png(path)
  if M.disabled then
    return
  end
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("Pico8OpenPng needs a .p8.png path")
    return
  end
  local result, err = decode_png(path)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end
  local buf = open_virtual(result)
  local config = resolved_config(M.opts)
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

local function attach(bufnr)
  if M.disabled or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "lua" then
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:sub(-4):lower() ~= ".lua" then
    return
  end
  if #vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr }) > 0 then
    return
  end

  local path = normalize(name)
  local cart = find_cart(path)
  if not cart then
    return
  end

  local config = resolved_config(M.opts)
  local cmd = config.cmd
  if type(cmd) == "table" and cmd[1] and vim.fn.executable(cmd[1]) == 0 then
    if not warned_missing_binary then
      warned_missing_binary = true
      notify("command not found: " .. cmd[1] .. " (set cmd in pico_lsp.setup)")
    end
    return
  end

  config.root_dir = vim.fs.dirname(cart)
  if not config.root_dir then
    return
  end

  local ok, err = pcall(vim.lsp.start, config, { bufnr = bufnr })
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function attach_loaded_lua_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr)
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  M.opts = opts
  M.disabled = opts.disable == true or vim.g.pico_lsp_helper_disabled == 1

  if M.group then
    pcall(vim.api.nvim_del_augroup_by_id, M.group)
  end
  if M.disabled then
    return
  end

  if opts.lsp ~= false then
    local config = {}
    local cmd = normalize_cmd(opts.cmd)
    if cmd then
      config.cmd = cmd
    end
    if type(opts.settings) == "table" then
      config.settings = opts.settings
    end
    if next(config) ~= nil then
      vim.lsp.config("pico_lsp", config)
    end
    local ok, err = pcall(vim.lsp.enable, "pico_lsp")
    if not ok then
      notify("could not enable pico_lsp: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  M.group = vim.api.nvim_create_augroup("pico_lsp_helper", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = M.group,
    pattern = "lua",
    callback = function(args)
      attach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = M.group,
    pattern = "*.lua",
    callback = function(args)
      attach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = M.group,
    pattern = "*.p8",
    callback = attach_loaded_lua_buffers,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = M.group,
    callback = function(args)
      M.png_buffers[args.buf] = nil
    end,
  })
  vim.api.nvim_create_user_command("Pico8OpenPng", function(args)
    M.open_png(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("Pico8ReloadPng", M.reload_png, { nargs = 0 })
  vim.api.nvim_create_user_command("Pico8InsertGlyph", function(args)
    M.insert_glyph(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  attach_loaded_lua_buffers()
end

return M
