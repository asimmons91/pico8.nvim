-- Headless test for the helper without lsp/pico_lsp.lua on 'runtimepath'.
--
-- Run with tests/run.sh. PICO8_NVIM_FALLBACK_RTP contains only the plugin's
-- lua/ directory, so vim.lsp.config["pico_lsp"] is absent until setup publishes
-- the helper's fallback config.

local fallback_rtp = assert(
  vim.env.PICO8_NVIM_FALLBACK_RTP,
  "PICO8_NVIM_FALLBACK_RTP is not set"
)
vim.opt.runtimepath:append(fallback_rtp)

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim fallback: " .. message)
  vim.cmd("cquit 1")
end

local cart = tmp .. "/cart.p8"
local included = tmp .. "/lib.lua"
vim.fn.writefile({
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
}, cart)
vim.fn.writefile({ "function lib() end" }, included)

if vim.lsp.config["pico_lsp"] ~= nil then
  fail("lsp/pico_lsp.lua is unexpectedly available")
end

vim.filetype.add({ extension = { p8 = "pico8", lua = "lua" } })
vim.g.pico_lsp_cmd = { 42 }
require("pico_lsp").setup({ lsp = false, cmd = binary })

local config = vim.lsp.config["pico_lsp"]
if type(config) ~= "table" then
  fail("setup did not publish a fallback config")
end
if type(config.filetypes) ~= "table" or not vim.tbl_contains(config.filetypes, "pico8") then
  fail("fallback config has no pico8 filetype")
end
if type(config.root_dir) ~= "function" then
  fail("fallback config has no root_dir")
end

vim.cmd.edit(vim.fn.fnameescape(cart))
vim.lsp.enable("pico_lsp")
if not vim.wait(10000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0
end, 50) then
  fail("manual activation did not attach the fallback config")
end

local cart_client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 })[1]
local root = vim.fs.normalize(cart_client.config.root_dir or cart_client.root_dir or "")
if root ~= vim.fs.normalize(tmp) then
  fail("fallback root is " .. root .. " instead of " .. tmp)
end
if type(cart_client.config.cmd) ~= "table" or cart_client.config.cmd[1] ~= binary then
  fail("fallback command did not use PICO_LSP_BIN")
end

vim.cmd.edit(vim.fn.fnameescape(included))
if not vim.wait(10000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0
end, 50) then
  fail("helper did not attach without a shipped config")
end
local lib_client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 })[1]
if lib_client.id ~= cart_client.id then
  fail("helper attached a different client instead of the rooted fallback client")
end
if #vim.lsp.get_clients({ name = "pico_lsp" }) ~= 1 then
  fail("manual activation left multiple pico_lsp clients")
end
if lib_client.config.settings ~= nil then
  fail("fallback config duplicated server settings defaults")
end

for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp" })) do
  client:stop(true)
end
if not vim.wait(2000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) == 0
end, 20) then
  fail("client did not stop during cleanup")
end
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and name:sub(1, #tmp) == tmp then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end
if vim.fn.delete(tmp, "rf") ~= 0 then
  fail("could not remove the temporary directory")
end

print("pico8.nvim fallback: ok")
vim.cmd("qa!")
