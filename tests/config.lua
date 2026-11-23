-- Headless test for the shipped pico_lsp client config.
--
-- Run with tests/run.sh. Does not start the server.

local root = vim.env.PICO8_NVIM_ROOT or vim.fn.getcwd()
vim.opt.runtimepath:append(root)

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim config: " .. message)
  vim.cmd("cquit 1")
end

local config
local ok, value = pcall(vim.lsp.config, "pico_lsp")
if ok then
  config = value
else
  local indexed = vim.lsp.config["pico_lsp"]
  if type(indexed) == "table" then
    config = indexed
  end
end

if type(config) ~= "table" then
  fail("vim.lsp.config['pico_lsp'] is not available")
end
if type(config.filetypes) ~= "table"
  or not vim.tbl_contains(config.filetypes, "pico8")
then
  fail("pico8 is not a configured filetype")
end
if type(config.root_dir) ~= "function" then
  fail("root_dir is not the cart-directory callback")
end

local cmd = config.cmd
if type(cmd) ~= "table" or #cmd == 0 or type(cmd[1]) ~= "string" then
  fail("cmd is not a non-empty string list")
end

print("pico8.nvim config: ok")
vim.cmd("qa!")
