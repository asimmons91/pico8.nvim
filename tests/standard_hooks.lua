-- Headless test for M33 standard LSP hooks.
--
-- Covers Neovim's automatic formatexpr setup, gq range and single-line
-- formatting, the line-count refusal, and Neovim 0.12 gx document links with a
-- stubbed vim.ui.open. Run with tests/run.sh against a real pico-lsp binary.

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local is_012 = vim.fn.has("nvim-0.12") == 1

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim standard hooks: " .. message)
  vim.cmd("cquit 1")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
end

local function wait_for_attach(bufnr)
  wait_for(function()
    return #clients(bufnr) > 0
  end, "pico-lsp did not attach to " .. vim.api.nvim_buf_get_name(bufnr))
end

local function supports_range_formatting(bufnr)
  local client = clients(bufnr)[1]
  return client
    and client.server_capabilities
    and client.server_capabilities.documentRangeFormattingProvider ~= nil
end

local function supports_document_links(bufnr)
  local client = clients(bufnr)[1]
  return client
    and client.server_capabilities
    and client.server_capabilities.documentLinkProvider ~= nil
end

local function wait_for_range_formatting(bufnr)
  wait_for(function()
    return supports_range_formatting(bufnr)
  end, "server did not advertise range formatting")
  wait_for(function()
    return vim.bo[bufnr].formatexpr == "v:lua.vim.lsp.formatexpr()"
  end, "Neovim did not set formatexpr for range formatting")
end

local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local cart = tmp .. "/cart.p8"
local lib = tmp .. "/lib.lua"
local blank_cart = tmp .. "/blank.p8"

write(cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "function f(a,b)",
  "if (a) then",
  "x=1",
  "else",
  "x=2",
  "end",
  "end",
  "after=3",
  "__gfx__",
  "0000000000000000",
})
write(lib, { "function lib() end" })
write(blank_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  "x=1",
  "",
  "",
  "",
  "y=2",
})

require("pico_lsp").setup({ cmd = { binary } })

-- Range formatting through gq --------------------------------------------------

local bufnr = edit(cart)
wait_for_attach(bufnr)
local has_range = vim.wait(5000, function()
  return supports_range_formatting(bufnr)
end, 25)

if has_range then
  wait_for_range_formatting(bufnr)
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = 2
  vim.bo[bufnr].tabstop = 2

  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.cmd("normal! V4jgq")

  local formatted = lines(bufnr)
  local expected = {
    [5] = "function f(a,b)",
    [6] = "  if (a) then",
    [7] = "    x = 1",
    [8] = "  else",
    [9] = "    x = 2",
    [10] = "  end",
    [11] = "end",
    [12] = "after=3",
  }
  for line, want in pairs(expected) do
    if formatted[line] ~= want then
      fail(("line %d = %q, want %q"):format(line, formatted[line], want))
    end
  end
  if formatted[13] ~= "__gfx__" or formatted[14] ~= "0000000000000000" then
    fail("gq changed a non-code cart section")
  end

  -- A single-line selection formats only that line.
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  vim.cmd("normal! Vgq")
  if lines(bufnr)[12] ~= "after = 3" then
    fail("single-line gq did not format only the selected line")
  end

  -- A line-count-changing range is refused and leaves the buffer unchanged.
  local blank_bufnr = edit(blank_cart)
  wait_for_attach(blank_bufnr)
  local before = lines(blank_bufnr)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("normal! Vgq")
  if not vim.deep_equal(before, lines(blank_bufnr)) then
    fail("gq applied a partial edit for a line-count-changing range")
  end
else
  print("pico8.nvim standard hooks: server does not advertise range formatting; skipping gq checks")
end

-- Document links through gx ----------------------------------------------------

if is_012 then
  local cart_bufnr = edit(cart)
  wait_for_attach(cart_bufnr)
  local has_links = vim.wait(5000, function()
    return supports_document_links(cart_bufnr)
  end, 25)
  if has_links then
    vim.api.nvim_win_set_cursor(0, { 4, 10 })

    local mapping = vim.fn.maparg("gx", "n", false, true)
    if type(mapping) ~= "table" or type(mapping.callback) ~= "function" then
      fail("Neovim 0.12 has no gx mapping")
    end

    local opened = {}
    local original_open = vim.ui.open
    vim.ui.open = function(uri, _)
      opened[#opened + 1] = uri
      return nil, nil
    end

    local ok, err = pcall(mapping.callback)
    vim.ui.open = original_open
    if not ok then
      fail("gx failed: " .. tostring(err))
    end
    if #opened == 0 then
      fail("gx did not pass the include target to vim.ui.open")
    end
    if vim.fs.normalize(opened[1]) ~= vim.fs.normalize(lib) then
      fail(("gx opened %q, want %q"):format(opened[1], lib))
    end
  else
    print("pico8.nvim standard hooks: server does not advertise document links; skipping gx check")
  end
else
  print("pico8.nvim standard hooks: gx check skipped on Neovim 0.11")
end

-- Cleanup ----------------------------------------------------------------------

vim.lsp.enable("pico_lsp", false)
for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp" })) do
  client:stop(true)
end
if not vim.wait(3000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) == 0
end, 25) then
  fail("clients did not stop during cleanup")
end

local normalized_tmp = vim.fs.normalize(tmp)
for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(candidate)
  if name ~= "" then
    local normalized = vim.fs.normalize(name)
    if normalized == normalized_tmp or normalized:sub(1, #normalized_tmp + 1) == normalized_tmp .. "/" then
      pcall(vim.api.nvim_buf_delete, candidate, { force = true })
    end
  end
end
if vim.fn.delete(tmp, "rf") ~= 0 then
  fail("could not remove the temporary directory")
end

print("pico8.nvim standard hooks: ok")
vim.cmd("qa!")
