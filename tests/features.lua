-- Headless test for M27 client-side code lens and inlay hint enablement.
--
-- Covers the shipped config without require("pico_lsp").setup, the helper
-- defaults, setup options, the inlay toggle and its warning, direct server
-- responses, and non-PICO-8 buffers.
--
-- Run with tests/run.sh against a real pico-lsp binary:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local is_012 = vim.fn.has("nvim-0.12") == 1

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim features: " .. message)
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

local function cart_lines(extra)
  local lines = {
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
    "function _init()",
    " local x = 1",
    " local y = 'hi'",
    "end",
  }
  for _, line in ipairs(extra or {}) do
    lines[#lines + 1] = line
  end
  return lines
end

local function clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
end

local function features()
  return require("pico_lsp.client")
end

-- Neovim 0.11 takes a bufnr for codelens.get; 0.12 takes a filter table.
local function lenses(bufnr)
  if is_012 then
    return vim.lsp.codelens.get({ bufnr = bufnr })
  end
  return vim.lsp.codelens.get(bufnr)
end

local function lens_visible(bufnr)
  return #lenses(bufnr) > 0
end

local function wait_for_lens(bufnr, message)
  wait_for(function()
    return lens_visible(bufnr)
  end, message)
end

local function lens_title(bufnr)
  local first = lenses(bufnr)[1]
  if not first then
    return nil
  end
  local lens = first.lens or first
  return lens.command and lens.command.title or nil
end

local function document_params(bufnr)
  return { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
end

local function request(bufnr, method, params)
  local client = clients(bufnr)[1]
  if not client then
    fail("no pico_lsp client attached while requesting " .. method)
  end
  local response = client:request_sync(method, params, 5000, bufnr)
  if not response then
    fail("no response for " .. method)
  end
  if response.err then
    fail(method .. " failed: " .. vim.inspect(response.err))
  end
  return response.result
end

local function inlay_params(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = last, character = 0 },
    },
  }
end

-- The server may still be processing didOpen when a cart attaches. Retry the
-- direct request instead of sleeping.
local function wait_for_hints(bufnr, message)
  local result = {}
  local ok = vim.wait(8000, function()
    result = request(bufnr, "textDocument/inlayHint", inlay_params(bufnr)) or {}
    return type(result) == "table" and #result > 0
  end, 100)
  if not ok then
    fail(message)
  end
  return result
end

local function toggle()
  local notifications = {}
  local original = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  local ok, err = pcall(vim.cmd, "Pico8ToggleInlayHints")
  vim.notify = original
  if not ok then
    fail("Pico8ToggleInlayHints errored: " .. tostring(err))
  end
  return notifications
end

vim.filetype.add({ extension = { p8 = "pico8", lua = "lua" } })

-- Defaults must be enabled before any setup call ------------------------------

if features().options.codelens ~= true or features().options.inlay_hints ~= true then
  fail("client display options do not default to enabled")
end

-- Base-config users who never call setup still get the display -----------------

vim.lsp.config("pico_lsp", {
  cmd = { binary },
  settings = { pico8 = { inlayHints = true } },
})
vim.lsp.enable("pico_lsp")

local project_base = tmp .. "/base"
local base_cart = project_base .. "/cart.p8"
write(base_cart, cart_lines())

local base_buf = edit(base_cart)
wait_for(function()
  return #clients(base_buf) > 0
end, "pico-lsp did not attach to the base-config cart")
local base_client = clients(base_buf)[1]
if type(base_client.config.on_attach) ~= "function" then
  fail("the shipped config has no on_attach hook")
end

if is_012 then
  wait_for(function()
    return vim.lsp.codelens.is_enabled({ bufnr = base_buf })
  end, "code lens was not enabled by the shipped config on 0.12")
else
  wait_for_lens(base_buf, "the shipped config did not refresh the code lens on 0.11")
end
if not features().codelens_enabled(base_buf) then
  fail("the version-aware code lens check does not report the base-config buffer")
end
if not vim.lsp.inlay_hint.is_enabled({ bufnr = base_buf }) then
  fail("inlay hints were not enabled by the shipped config")
end

-- Direct server responses are independent of the client display state.
local lens_result = request(base_buf, "textDocument/codeLens", document_params(base_buf))
if type(lens_result) ~= "table" or #lens_result ~= 1 then
  fail("textDocument/codeLens did not return the budget lens")
end
if lens_result[1].command.command ~= "pico8.showCartInfo" then
  fail("code lens command is " .. tostring(lens_result[1].command.command))
end
if not lens_result[1].command.title:find("tokens", 1, true) then
  fail("code lens title does not contain the cart budget")
end

local hint_result = wait_for_hints(base_buf, "textDocument/inlayHint returned no hints with pico8.inlayHints = true")
local labels = {}
for _, hint in ipairs(hint_result) do
  labels[#labels + 1] = tostring(hint.label)
end
if not table.concat(labels, " "):find("number", 1, true) then
  fail("inlay hints do not include the inferred number type: " .. vim.inspect(labels))
end

-- Helper defaults, toggle, and no warning when the server setting is on --------

require("pico_lsp").setup()
if vim.fn.exists(":Pico8ToggleInlayHints") ~= 2 then
  fail("setup did not register :Pico8ToggleInlayHints")
end

local project_default = tmp .. "/default"
local default_cart = project_default .. "/cart.p8"
write(default_cart, cart_lines())
local default_buf = edit(default_cart)
wait_for(function()
  return #clients(default_buf) > 0
end, "pico-lsp did not attach to the helper-default cart")
if is_012 then
  wait_for(function()
    return vim.lsp.codelens.is_enabled({ bufnr = default_buf })
  end, "helper defaults did not enable code lens")
else
  wait_for_lens(default_buf, "helper defaults did not refresh the code lens")
end
if not vim.lsp.inlay_hint.is_enabled({ bufnr = default_buf }) then
  fail("helper defaults did not enable inlay hints")
end

local notifications = toggle()
if #notifications > 0 then
  fail("toggling hints warned while pico8.inlayHints was true: " .. vim.inspect(notifications))
end
if vim.lsp.inlay_hint.is_enabled({ bufnr = default_buf }) then
  fail("the first toggle did not disable inlay hints")
end
notifications = toggle()
if #notifications > 0 then
  fail("re-enabling hints warned while pico8.inlayHints was true: " .. vim.inspect(notifications))
end
if not vim.lsp.inlay_hint.is_enabled({ bufnr = default_buf }) then
  fail("the second toggle did not re-enable inlay hints")
end

-- Setup options suppress the client-side display ---------------------------------

require("pico_lsp").setup({ codelens = false, inlay_hints = false })

local project_off = tmp .. "/options-off"
local off_cart = project_off .. "/cart.p8"
write(off_cart, cart_lines())
local off_buf = edit(off_cart)
wait_for(function()
  return #clients(off_buf) > 0
end, "pico-lsp did not attach with display options disabled")

if is_012 then
  if vim.lsp.codelens.is_enabled({ bufnr = off_buf }) then
    fail("setup({ codelens = false }) left code lens enabled")
  end
else
  -- No enable call means no request and no cached lens.
  if vim.wait(500, function()
    return lens_visible(off_buf)
  end, 25) then
    fail("setup({ codelens = false }) still refreshed the code lens")
  end
end
if vim.lsp.inlay_hint.is_enabled({ bufnr = off_buf }) then
  fail("setup({ inlay_hints = false }) left inlay hints enabled")
end

-- The server still answers direct requests; only the display is suppressed.
lens_result = request(off_buf, "textDocument/codeLens", document_params(off_buf))
if type(lens_result) ~= "table" or #lens_result == 0 then
  fail("the server stopped returning lenses when the client display was off")
end

require("pico_lsp").setup()

-- Included .lua buffers are not pico8 buffers ----------------------------------

local project_include = tmp .. "/include"
local include_cart = project_include .. "/cart.p8"
local include_lib = project_include .. "/lib.lua"
write(include_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
})
write(include_lib, { "function lib() end" })

local include_cart_buf = edit(include_cart)
wait_for(function()
  return #clients(include_cart_buf) > 0
end, "pico-lsp did not attach to the include cart")
local include_lib_buf = edit(include_lib)
wait_for(function()
  return #clients(include_lib_buf) > 0
end, "the helper did not attach the included .lua buffer")

if vim.lsp.inlay_hint.is_enabled({ bufnr = include_lib_buf }) then
  fail("inlay hints were enabled for a non-pico8 buffer")
end
if features().codelens_enabled(include_lib_buf) then
  fail("code lens was enabled for a non-pico8 buffer")
end
notifications = toggle()
if #notifications == 0 then
  fail("toggling hints outside a pico8 buffer did not notify")
end
if vim.lsp.inlay_hint.is_enabled({ bufnr = include_lib_buf }) then
  fail("the toggle changed a non-pico8 buffer")
end

-- The toggle is safe on read-only .p8.png virtual buffers ------------------------

local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
  local png_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return #clients(png_buf) > 0
  end, "pico-lsp did not attach to the decoded PNG cart")
  if vim.bo[png_buf].modifiable then
    fail("the decoded PNG cart is unexpectedly modifiable")
  end
  toggle()
  if vim.lsp.inlay_hint.is_enabled({ bufnr = png_buf }) then
    fail("the toggle did not disable hints on the PNG cart")
  end
  toggle()
  if not vim.lsp.inlay_hint.is_enabled({ bufnr = png_buf }) then
    fail("the toggle did not re-enable hints on the PNG cart")
  end
  if vim.bo[png_buf].modifiable then
    fail("the toggle made the PNG cart modifiable")
  end
end

-- The toggle stays registered when the helper is disabled -----------------------

require("pico_lsp").setup({ disable = true })
if vim.fn.exists(":Pico8ToggleInlayHints") ~= 2 then
  fail("a disabled helper did not register :Pico8ToggleInlayHints")
end
edit(default_cart)
toggle()
if vim.lsp.inlay_hint.is_enabled({ bufnr = default_buf }) then
  fail("the toggle did not work with the helper disabled")
end
require("pico_lsp").setup()

-- Neovim 0.11 refreshes the lens on save ---------------------------------------

if not is_012 then
  edit(base_cart)
  local before = lens_title(base_buf)
  vim.api.nvim_buf_set_lines(base_buf, -1, -1, false, {
    "local refreshed_value = 'a much longer value for the budget lens'",
  })
  vim.cmd("silent write")
  wait_for(function()
    local after = lens_title(base_buf)
    return after ~= nil and after ~= before
  end, "the 0.11 code lens did not refresh after BufWritePost")
end

-- Explicit false and missing server settings both warn -------------------------
-- These run after the automatic client activation is disabled so a manual
-- client can carry settings the global config does not.

vim.lsp.enable("pico_lsp", false)
if not vim.wait(3000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) == 0
end, 25) then
  fail("clients did not stop before the manual-setting cases")
end

local function start_with_settings(name, settings)
  local project = tmp .. "/" .. name
  local cart = project .. "/cart.p8"
  write(cart, cart_lines())
  local bufnr = edit(cart)
  local config = vim.deepcopy(vim.lsp.config["pico_lsp"])
  config.root_dir = vim.fs.normalize(project)
  config.settings = settings
  local started = vim.lsp.start(config, { bufnr = bufnr })
  if not started then
    fail("could not start the " .. name .. " client")
  end
  wait_for(function()
    return #clients(bufnr) > 0
  end, "pico-lsp did not attach to the " .. name .. " cart")
  return bufnr
end

local false_buf = start_with_settings("setting-false", { pico8 = { inlayHints = false } })
local false_client = clients(false_buf)[1]
if features().server_inlay_hints(false_client) ~= false then
  fail("the explicit false server setting was not detected")
end
local false_hints = request(false_buf, "textDocument/inlayHint", inlay_params(false_buf))
if type(false_hints) ~= "table" or #false_hints ~= 0 then
  fail("textDocument/inlayHint returned hints with pico8.inlayHints = false: " .. vim.inspect(false_hints))
end
local false_settings = vim.deepcopy(false_client.settings)
-- The attach enabled the display; turn it off so the next toggle warns.
toggle()
notifications = toggle()
if #notifications == 0 then
  fail("enabling hints with pico8.inlayHints = false did not warn")
end
if not notifications[1].message:find("inlayHints", 1, true) then
  fail("the warning does not name pico8.inlayHints: " .. notifications[1].message)
end
if not vim.deep_equal(false_client.settings, false_settings) then
  fail("the inlay toggle changed the client's server settings")
end

local unset_buf = start_with_settings("setting-unset", {})
local unset_client = clients(unset_buf)[1]
if features().server_inlay_hints(unset_client) ~= nil then
  fail("a missing inlayHints setting should be unknown to the client")
end
local unset_hints = request(unset_buf, "textDocument/inlayHint", inlay_params(unset_buf))
if type(unset_hints) ~= "table" or #unset_hints ~= 0 then
  fail("textDocument/inlayHint returned hints without a server setting: " .. vim.inspect(unset_hints))
end
toggle()
notifications = toggle()
if #notifications == 0 then
  fail("enabling hints without a server setting did not warn")
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

print("pico8.nvim features: ok")
vim.cmd("qa!")
