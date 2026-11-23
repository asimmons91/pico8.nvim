-- Headless smoke test for the pico8.nvim helper.
--
-- Run with tests/run.sh after installing pico-lsp:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = vim.env.PICO8_NVIM_ROOT or vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = vim.env.PICO_LSP_BIN or "pico-lsp"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local cart = tmp .. "/cart.p8"
local included = tmp .. "/lib.lua"
local unrelated = tmp .. "/other.lua"
vim.fn.writefile({
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
}, cart)
vim.fn.writefile({ "function lib() end" }, included)
vim.fn.writefile({ "print('unrelated')" }, unrelated)

vim.filetype.add({ extension = { p8 = "pico8" } })
vim.lsp.config("pico_lsp", {
  cmd = { binary },
  filetypes = { "pico8" },
  root_dir = tmp,
  settings = {
    pico8 = {
      glyphs = {
        { name = "logo", byte = 128, description = "custom font slot 0x80" },
      },
    },
  },
})
vim.lsp.enable("pico_lsp")
require("pico_lsp").setup()

local function fail(message)
  vim.api.nvim_err_writeln("nvim helper smoke: " .. message)
  vim.cmd("cquit 1")
end

local shift_keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local shift_first_byte = 0x80

local function map_for(bufnr, key, mode)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(key, mode, false, true)
  end)
end

local function check_shift_maps(bufnr, expected)
  for i = 1, #shift_keys do
    local key = shift_keys:sub(i, i)
    local mapping = map_for(bufnr, key, "i")
    if expected then
      if next(mapping) == nil
        or mapping.buffer ~= 1
        or mapping.expr ~= 1
        or type(mapping.callback) ~= "function"
      then
        fail("ftplugin did not install the " .. key .. " glyph mapping")
      end
      if not mapping.desc or not mapping.desc:find("PICO-8", 1, true) then
        fail("glyph mapping " .. key .. " has no PICO-8 description")
      end
      for _, mode in ipairs({ "n", "v", "o" }) do
        local other = map_for(bufnr, key, mode)
        if next(other) ~= nil
          and other.desc
          and other.desc:find("PICO-8", 1, true)
        then
          fail("glyph mapping " .. key .. " leaks into " .. mode .. " mode")
        end
      end
    elseif next(mapping) ~= nil then
      fail("glyph mapping " .. key .. " was installed when disabled")
    end
  end
end

vim.g.pico8_glyph_maps = nil
local default_probe = vim.api.nvim_create_buf(false, true)
vim.bo[default_probe].filetype = "pico8"
check_shift_maps(default_probe, false)
vim.api.nvim_buf_delete(default_probe, { force = true })

vim.g.pico8_glyph_maps = 0
local zero_probe = vim.api.nvim_create_buf(false, true)
vim.bo[zero_probe].filetype = "pico8"
check_shift_maps(zero_probe, false)
vim.api.nvim_buf_delete(zero_probe, { force = true })

vim.g.pico8_glyph_maps = 1

vim.cmd.edit(vim.fn.fnameescape(cart))
if not vim.wait(5000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) > 0
end, 50) then
  fail("pico-lsp did not attach to the cart")
end

if vim.bo.commentstring ~= "-- %s" then
  fail("ftplugin did not set commentstring")
end
if vim.bo.comments ~= ":---,:--,://" then
  fail("ftplugin did not set comments")
end

local cart_bufnr = vim.api.nvim_get_current_buf()
check_shift_maps(cart_bufnr, true)

local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = cart_bufnr })[1]
if not client then
  fail("pico-lsp did not attach to the cart buffer")
end

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "" })
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
local position = vim.lsp.util.make_position_params(0, client.offset_encoding)
local glyph_response
if not vim.wait(5000, function()
  glyph_response = client:request_sync("pico8/glyphs", {
    textDocument = position.textDocument,
    position = position.position,
  }, 2000, cart_bufnr)
  if not glyph_response or glyph_response.err or not glyph_response.result then
    return false
  end
  for _, entry in ipairs(glyph_response.result.glyphs) do
    if entry.name == "logo" then
      return true
    end
  end
  return false
end, 50) then
  fail("pico8/glyphs did not include the custom logo entry")
end

local glyph_by_byte = {}
local custom_logo
for _, entry in ipairs(glyph_response.result.glyphs) do
  glyph_by_byte[entry.byte] = entry.text
  if entry.name == "logo" then
    custom_logo = entry
  end
end
if not custom_logo.custom or custom_logo.byte ~= 128 then
  fail("custom logo entry did not resolve to byte 0x80")
end
if custom_logo.text ~= "█" then
  fail("custom font slot did not use canonical Unicode text")
end
local expected_parts = {}
for i = 0, #shift_keys - 1 do
  local text = glyph_by_byte[shift_first_byte + i]
  if not text then
    fail(string.format("missing P8SCII glyph 0x%02x", shift_first_byte + i))
  end
  table.insert(expected_parts, text)
end
local expected_text = table.concat(expected_parts)

local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
vim.api.nvim_feedkeys("i" .. shift_keys .. esc, "xt", false)
local inserted = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
if inserted ~= expected_text then
  fail("ftplugin glyph mappings inserted "
    .. vim.inspect(inserted)
    .. " instead of "
    .. vim.inspect(expected_text))
end

for key, codepoint in pairs({ U = "0055", O = "004F", X = "0058" }) do
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
  local keys = "i"
    .. vim.api.nvim_replace_termcodes("<C-v>u" .. codepoint .. "<Esc>", true, false, true)
  vim.api.nvim_feedkeys(keys, "xt", false)
  local line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
  if line ~= key then
    fail("CTRL-V u" .. codepoint .. " did not insert a literal " .. key .. ": " .. vim.inspect(line))
  end
end

local header = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("AA" .. esc, "xt", false)
local header_after = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
if header_after ~= header .. "A" then
  fail("Shift-A did not fall back to a literal letter outside code")
end
vim.api.nvim_buf_set_lines(0, 0, 1, false, { header })

local include_line = vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]
local include_col = #('#include "')
vim.api.nvim_win_set_cursor(0, { 4, include_col })
vim.api.nvim_feedkeys("iP" .. esc, "xt", false)
local include_after = vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]
if include_after
  ~= include_line:sub(1, include_col) .. "P" .. include_line:sub(include_col + 1)
then
  fail("Shift-P did not fall back to a literal letter in an include path")
end
vim.api.nvim_buf_set_lines(0, 3, 4, false, { include_line })

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "abcdefghij" })
local replace_line = vim.api.nvim_buf_line_count(0)
vim.api.nvim_win_set_cursor(0, { replace_line, 0 })
vim.api.nvim_feedkeys("RD" .. esc, "xt", false)
local replaced = vim.api.nvim_buf_get_lines(0, replace_line - 1, replace_line, false)[1]
if replaced ~= "Dbcdefghij" then
  fail("Replace mode did not preserve a single-character replacement: " .. vim.inspect(replaced))
end
vim.api.nvim_buf_set_lines(0, replace_line - 1, replace_line, false, {})

vim.bo[cart_bufnr].filetype = "lua"
check_shift_maps(cart_bufnr, false)
vim.bo[cart_bufnr].filetype = "pico8"
check_shift_maps(cart_bufnr, true)

local no_client_probe = vim.api.nvim_create_buf(false, true)
vim.bo[no_client_probe].filetype = "pico8"
vim.api.nvim_buf_set_lines(no_client_probe, 0, -1, false, { "" })
vim.api.nvim_buf_call(no_client_probe, function()
  vim.api.nvim_feedkeys("iA" .. esc, "xt", false)
end)
if vim.api.nvim_buf_get_lines(no_client_probe, 0, -1, false)[1] ~= "A" then
  fail("Shift-A did not fall back to a literal letter without a client")
end
vim.api.nvim_buf_delete(no_client_probe, { force = true })

local function check_wrap(leader, message)
  local probe = vim.api.nvim_create_buf(false, true)
  vim.bo[probe].filetype = "pico8"
  if vim.g.pico8_glyph_maps == 1 then
    local probe_mapping = map_for(probe, "A", "i")
    if next(probe_mapping) == nil then
      fail("ftplugin did not install glyph maps on a non-current pico8 buffer")
    end
  end
  vim.bo[probe].formatoptions = "tcq"
  vim.bo[probe].textwidth = 30
  vim.api.nvim_buf_set_lines(probe, 0, -1, false, {
    leader .. " this is a long comment line that should wrap onto another comment line",
  })
  vim.api.nvim_buf_call(probe, function()
    vim.cmd("normal! gqG")
  end)
  local wrapped = vim.api.nvim_buf_get_lines(probe, 0, -1, false)
  if #wrapped < 2 then
    fail("ftplugin comment formatting did not wrap the " .. leader .. " comment")
  end
  for _, line in ipairs(wrapped) do
    if line:sub(1, #leader + 1) ~= leader .. " " then
      fail("ftplugin comment formatting did not continue the " .. leader .. " prefix: " .. line)
    end
  end
  vim.api.nvim_buf_delete(probe, { force = true })
end

check_wrap("--", "dash")
check_wrap("//", "slash")

vim.cmd.edit(vim.fn.fnameescape(included))
if not vim.wait(5000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0
end, 50) then
  fail("helper did not attach the included .lua buffer")
end
if next(vim.fn.maparg("A", "i", false, true)) ~= nil then
  fail("glyph maps leaked into an included .lua buffer")
end

vim.api.nvim_win_set_cursor(0, { 1, #vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] })
vim.cmd("Pico8InsertGlyph left")
if not vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  return text:find("⬅️", 1, true) ~= nil
end, 50) then
  fail("Pico8InsertGlyph did not insert the left glyph")
end

vim.cmd.edit(vim.fn.fnameescape(unrelated))
vim.wait(100, function()
  return true
end)
if #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0 then
  fail("helper attached an unrelated .lua buffer")
end

local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
  if not vim.wait(5000, function()
    return vim.api.nvim_buf_get_name(0):match("^pico8%-cart:") ~= nil
      and #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0
  end, 50) then
    fail("Pico8OpenPng did not open an attached virtual buffer")
  end
  if vim.bo.modifiable then
    fail("Pico8OpenPng opened a modifiable buffer")
  end
  vim.cmd("Pico8ReloadPng")
  if vim.api.nvim_buf_get_name(0):match("^pico8%-cart:") == nil then
    fail("Pico8ReloadPng replaced the virtual buffer")
  end
end

print("nvim helper smoke: ok")
vim.cmd("qa!")
