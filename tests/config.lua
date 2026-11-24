-- Headless test for the shipped pico_lsp config and cart-aware roots.
--
-- Run with tests/run.sh against a real pico-lsp binary. The attachment cases
-- start the server; the command-resolution cases load lsp/pico_lsp.lua
-- directly so they can vary the environment.

local root = vim.env.PICO8_NVIM_ROOT or vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim config: " .. message)
  vim.cmd("cquit 1")
end

local function get_config()
  local ok, value = pcall(function()
    return vim.lsp.config["pico_lsp"]
  end)
  if not ok or type(value) ~= "table" then
    fail("vim.lsp.config['pico_lsp'] is not available")
  end
  return value
end

local function write_cart(path, include)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
    '#include "' .. include .. '"',
    "x = 1",
  }, path)
  vim.fn.writefile({ "function lib() end" }, vim.fs.dirname(path) .. "/" .. include)
end

local function client_for(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
end

local function client_root(client)
  return vim.fs.normalize(client.config.root_dir or client.root_dir or "")
end

local function wait_for(predicate, message)
  if not vim.wait(10000, predicate, 50) then
    fail(message)
  end
end

-- Shipped configuration shape -------------------------------------------------

local config = get_config()
if config.name ~= "pico_lsp" then
  fail("config name is not pico_lsp")
end
if type(config.filetypes) ~= "table" or not vim.tbl_contains(config.filetypes, "pico8") then
  fail("pico8 is not a configured filetype")
end
if type(config.root_dir) ~= "function" then
  fail("root_dir is not the cart-directory callback")
end
if type(config.cmd) ~= "table" or #config.cmd == 0 or type(config.cmd[1]) ~= "string" then
  fail("cmd is not a non-empty string list")
end
if config.settings ~= nil then
  fail("shipped config duplicates server settings defaults")
end

-- Command resolution ----------------------------------------------------------

local function load_shipped()
  local chunk, err = loadfile(root .. "/lsp/pico_lsp.lua")
  if not chunk then
    fail("could not load lsp/pico_lsp.lua: " .. tostring(err))
  end
  return chunk()
end

local saved_cmd = vim.g.pico_lsp_cmd
local saved_env = vim.env.PICO_LSP_BIN

vim.g.pico_lsp_cmd = "/opt/pico-lsp"
local shipped = load_shipped()
if #shipped.cmd ~= 1 or shipped.cmd[1] ~= "/opt/pico-lsp" then
  fail("vim.g.pico_lsp_cmd string did not resolve to a one-element cmd list")
end
if vim.fn.exists(":Pico8InstallParser") ~= 2 then
  fail("the shipped config did not register :Pico8InstallParser")
end

vim.g.pico_lsp_cmd = { "/opt/pico-lsp", "--stdio" }
shipped = load_shipped()
if #shipped.cmd ~= 2 or shipped.cmd[1] ~= "/opt/pico-lsp" or shipped.cmd[2] ~= "--stdio" then
  fail("vim.g.pico_lsp_cmd list was not preserved")
end

vim.g.pico_lsp_cmd = ""
vim.env.PICO_LSP_BIN = "/env/pico-lsp"
shipped = load_shipped()
if #shipped.cmd ~= 1 or shipped.cmd[1] ~= "/env/pico-lsp" then
  fail("empty vim.g.pico_lsp_cmd did not fall through to PICO_LSP_BIN")
end

vim.env.PICO_LSP_BIN = ""
shipped = load_shipped()
if #shipped.cmd ~= 1 or shipped.cmd[1] ~= "pico-lsp" then
  fail("empty command environment did not fall through to pico-lsp")
end

vim.g.pico_lsp_cmd = { 42 }
shipped = load_shipped()
if #shipped.cmd ~= 1 or shipped.cmd[1] ~= "pico-lsp" then
  fail("malformed vim.g.pico_lsp_cmd did not fall through to pico-lsp")
end

vim.g.pico_lsp_cmd = saved_cmd
vim.env.PICO_LSP_BIN = saved_env

-- Root callback ---------------------------------------------------------------

local project_a = tmp .. "/project-a"
local project_b = tmp .. "/project-b"
local project_c = tmp .. "/project-c"
local project_d = tmp .. "/project-d"
local cart_a = project_a .. "/cart.p8"
local cart_b = project_b .. "/cart.p8"
local cart_c = project_c .. "/cart.p8"
local cart_d = project_d .. "/cart.p8"
local lib_a = project_a .. "/lib.lua"
local lib_d = project_d .. "/lib.lua"
write_cart(cart_a, "lib.lua")
write_cart(cart_b, "lib.lua")
write_cart(cart_c, "lib.lua")
write_cart(cart_d, "lib.lua")

local function roots_for(bufnr)
  local seen = {}
  config.root_dir(bufnr, function(dir)
    seen[#seen + 1] = dir
  end)
  return seen
end

local named = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(named, cart_a)
local named_roots = roots_for(named)
if #named_roots ~= 1 then
  fail("root_dir called on_dir " .. #named_roots .. " times for a named cart")
end
if vim.fs.normalize(named_roots[1]) ~= vim.fs.normalize(project_a) then
  fail("named cart root is " .. named_roots[1] .. " instead of " .. project_a)
end
vim.api.nvim_buf_delete(named, { force = true })

local unnamed = vim.api.nvim_create_buf(false, true)
if #roots_for(unnamed) ~= 0 then
  fail("root_dir activated for an unnamed buffer")
end
vim.api.nvim_buf_delete(unnamed, { force = true })

local virtual = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(virtual, "pico8-cart://cart.p8")
if #roots_for(virtual) ~= 0 then
  fail("root_dir activated for a pico8-cart: virtual buffer")
end
vim.api.nvim_buf_delete(virtual, { force = true })

local marked_virtual = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(marked_virtual, tmp .. "/marked/cart.p8")
vim.b[marked_virtual].pico8_virtual_cart = true
if #roots_for(marked_virtual) ~= 0 then
  fail("root_dir activated for a marked virtual cart")
end
vim.api.nvim_buf_delete(marked_virtual, { force = true })

local misleading = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(misleading, tmp .. "/pico8-cart:demo/cart.p8")
local misleading_roots = roots_for(misleading)
if #misleading_roots ~= 1 then
  fail("root_dir skipped a real cart under a pico8-cart:name directory")
end
if vim.fs.normalize(misleading_roots[1]) ~= vim.fs.normalize(tmp .. "/pico8-cart:demo") then
  fail("real pico8-cart:name directory root is " .. misleading_roots[1])
end
vim.api.nvim_buf_delete(misleading, { force = true })

-- Activation opt-out ----------------------------------------------------------

require("pico_lsp").setup({ lsp = false, cmd = { 42 } })
config = get_config()
if type(config.cmd) ~= "table" or config.cmd[1] ~= binary then
  fail("malformed setup cmd did not fall back to PICO_LSP_BIN")
end

local custom_cmd = binary .. "-setup-override"
require("pico_lsp").setup({ lsp = false, cmd = custom_cmd })
config = get_config()
if type(config.cmd) ~= "table" or config.cmd[1] ~= custom_cmd then
  fail("setup cmd was not applied when lsp is false")
end
vim.lsp.config("pico_lsp", { cmd = { binary } })
if vim.lsp.is_enabled and vim.lsp.is_enabled("pico_lsp") then
  fail("setup({ lsp = false }) enabled the client")
end

vim.cmd.edit(vim.fn.fnameescape(cart_a))
if vim.bo.filetype ~= "pico8" then
  fail("cart filetype is " .. vim.inspect(vim.bo.filetype) .. " instead of pico8")
end
if vim.wait(300, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) > 0
end, 20) then
  fail("setup({ lsp = false }) started a client")
end

-- Default activation and cart-directory roots ---------------------------------

require("pico_lsp").setup()

local cart_a_buf = vim.api.nvim_get_current_buf()
wait_for(function()
  return client_for(cart_a_buf) ~= nil
end, "pico-lsp did not attach to the cart")

local client_a = client_for(cart_a_buf)
if client_root(client_a) ~= vim.fs.normalize(project_a) then
  fail("first cart root is " .. client_root(client_a) .. " instead of " .. project_a)
end

vim.cmd.edit(vim.fn.fnameescape(cart_b))
local cart_b_buf = vim.api.nvim_get_current_buf()
wait_for(function()
  local client = client_for(cart_b_buf)
  return client ~= nil and client.id ~= client_a.id
end, "pico-lsp did not start a separate client for the sibling cart")

local client_b = client_for(cart_b_buf)
if client_root(client_b) ~= vim.fs.normalize(project_b) then
  fail("second cart root is " .. client_root(client_b) .. " instead of " .. project_b)
end
if client_root(client_a) == client_root(client_b) then
  fail("sibling carts share a root")
end

-- The helper attaches included .lua files to the owning cart's client ---------

vim.cmd.edit(vim.fn.fnameescape(lib_a))
wait_for(function()
  return client_for(vim.api.nvim_get_current_buf()) ~= nil
end, "helper did not attach the included .lua buffer")

local lib_client = client_for(vim.api.nvim_get_current_buf())
if lib_client.id ~= client_a.id then
  fail("helper attached included .lua to client " .. lib_client.id .. " instead of " .. client_a.id)
end

-- A helper-started client reads command and settings from the merged config ----

local wrapper = tmp .. "/pico-lsp-wrapper"
vim.fn.writefile({
  "#!/bin/sh",
  'exec "' .. binary .. '" "$@"',
}, wrapper)
vim.fn.setfperm(wrapper, "rwxr-xr-x")
vim.lsp.config("pico_lsp", {
  cmd = { wrapper },
  settings = {
    pico8 = { typeChecking = "strict" },
  },
})

vim.cmd.edit(vim.fn.fnameescape(lib_d))
local lib_d_buf = vim.api.nvim_get_current_buf()
wait_for(function()
  local client = client_for(lib_d_buf)
  return client ~= nil and client.id ~= client_a.id
end, "helper did not start a client for the second project")

local merged_client = client_for(lib_d_buf)
if merged_client.config.cmd[1] ~= wrapper then
  fail("helper ignored the merged cmd")
end
if not merged_client.config.settings
  or not merged_client.config.settings.pico8
  or merged_client.config.settings.pico8.typeChecking ~= "strict"
then
  fail("helper ignored the merged settings")
end
for _, key in ipairs({ "apiVersion", "inlayHints" }) do
  if merged_client.config.settings.pico8[key] ~= nil then
    fail("helper duplicated the server default for " .. key)
  end
end

-- A user root_dir override wins over the shipped callback ---------------------

local override_root = tmp .. "/override-root"
vim.fn.mkdir(override_root, "p")
vim.lsp.config("pico_lsp", { root_dir = override_root })
config = get_config()
if config.root_dir ~= override_root then
  fail("user root_dir override did not replace the shipped callback")
end

vim.cmd.edit(vim.fn.fnameescape(cart_c))
local cart_c_buf = vim.api.nvim_get_current_buf()
wait_for(function()
  local client = client_for(cart_c_buf)
  return client ~= nil and client_root(client) == vim.fs.normalize(override_root)
end, "user root_dir override did not win for a new cart")

-- Cleanup ---------------------------------------------------------------------

for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp" })) do
  client:stop(true)
end
if not vim.wait(2000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) == 0
end, 20) then
  fail("clients did not stop during cleanup")
end

local normalized_tmp = vim.fs.normalize(tmp)
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    local normalized = vim.fs.normalize(name)
    if normalized == normalized_tmp or normalized:sub(1, #normalized_tmp + 1) == normalized_tmp .. "/" then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end
if vim.fn.delete(tmp, "rf") ~= 0 then
  fail("could not remove the temporary directory")
end

print("pico8.nvim config: ok")
vim.cmd("qa!")
