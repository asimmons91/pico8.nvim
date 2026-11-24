-- Headless test for M30 include navigation and .p8.png auto-open.
--
-- Covers `include`/`includeexpr`, `gf` path forms, cart-relative resolution,
-- missing targets, option undo, PNG auto-open, failure buffers, command
-- completion, reload, and the disabled-helper path.
--
-- Run with tests/run.sh against a real pico-lsp binary:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local project = tmp .. "/project"
local outside = tmp .. "/outside"
local absolute = tmp .. "/absolute"

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim includes: " .. message)
  vim.cmd("cquit 1")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function edit(path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function buffer_name(bufnr)
  return vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr or 0))
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
  end
end

local function assert_contains(text, needle, message)
  if type(text) ~= "string" or text:find(needle, 1, true) == nil then
    fail(message .. ": " .. vim.inspect(text))
  end
end

local function line_of(bufnr, needle)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  fail("could not find a line containing " .. vim.inspect(needle))
end

local function virtual_buffers()
  local found = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("pico8%-cart:") ~= nil then
      found[#found + 1] = bufnr
    end
  end
  return found
end

local function clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function all_clients()
  return vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })
end

local function capture_notify(fn)
  local notifications = {}
  local original = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    fail("auto-open command errored: " .. tostring(err))
  end
  return notifications
end

-- Include fixtures -------------------------------------------------------------

local absolute_include = absolute .. "/abs.lua"
write(project .. "/cart.p8", {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "#include   padded.lua",
  "#include 'single.lua'",
  '#include "sub/nested.p8:2"',
  '#include "space dir/with space.lua"',
  '#include "../outside/abs.lua"',
  '#include "literal.lua:2"',
  '#include "sub\\back.lua"',
  '#include "' .. absolute_include .. '"',
  '#include "missing.lua"',
  "x = 1",
})
write(project .. "/lib.lua", { "print('lib')" })
write(project .. "/padded.lua", { "print('padded')" })
write(project .. "/single.lua", { "print('single')" })
write(project .. "/sub/nested.p8", { "pico-8 cartridge // pico-8.com", "version 42", "__lua__" })
write(project .. "/sub/back.lua", { "print('back')" })
write(project .. "/space dir/with space.lua", { "print('space')" })
write(project .. "/literal.lua:2", { "print('literal')" })
write(outside .. "/abs.lua", { "print('abs')" })
write(absolute_include, { "print('absolute')" })

local include_pattern = '^\\s*#include\\s\\+'
local includeexpr = 'v:lua.require("pico_lsp.includes").includeexpr(v:fname)'

-- `gf` works before setup: the ftplugin options do not need the helper ---------

local cart = project .. "/cart.p8"
local cart_buf = edit(cart)
assert_equal(vim.bo[cart_buf].include, include_pattern, "ftplugin did not set include")
assert_equal(vim.bo[cart_buf].includeexpr, includeexpr, "ftplugin did not set includeexpr")

local function gf(needle)
  edit(cart)
  vim.cmd("cd " .. vim.fn.fnameescape(outside))
  -- Force cart-relative resolution through includeexpr instead of relying on
  -- the default 'path' entry for the current file's directory.
  vim.bo.path = ",,"
  vim.api.nvim_win_set_cursor(0, { line_of(cart_buf, needle), 12 })
  local before = #vim.api.nvim_list_bufs()
  local ok, err = pcall(vim.cmd, "normal! gf")
  return ok, err, before, vim.api.nvim_get_current_buf()
end

local cases = {
  { needle = "lib.lua", expected = project .. "/lib.lua" },
  { needle = "padded.lua", expected = project .. "/padded.lua" },
  { needle = "single.lua", expected = project .. "/single.lua" },
  { needle = "nested.p8:2", expected = project .. "/sub/nested.p8" },
  { needle = "with space.lua", expected = project .. "/space dir/with space.lua" },
  { needle = "../outside/abs.lua", expected = outside .. "/abs.lua" },
  { needle = "literal.lua:2", expected = project .. "/literal.lua:2" },
  { needle = "sub\\back.lua", expected = project .. "/sub/back.lua" },
  { needle = absolute_include, expected = absolute_include },
}

for _, case in ipairs(cases) do
  local ok, err = gf(case.needle)
  if not ok then
    fail("gf failed for " .. case.needle .. ": " .. tostring(err))
  end
  assert_equal(buffer_name(0), vim.fs.normalize(case.expected), "gf opened the wrong target for " .. case.needle)
end

-- A missing target reports a normal error and creates neither a file nor buffer.

local ok, err, before = gf("missing.lua")
if ok then
  fail("gf unexpectedly opened a missing include")
end
assert_contains(tostring(err), "E447", "gf did not report a missing include")
assert_equal(#vim.api.nvim_list_bufs(), before, "gf created a buffer for a missing include")
if vim.fn.filereadable(project .. "/missing.lua") == 1 then
  fail("gf created the missing include file")
end

-- The resolver follows the server's tab-selector rule --------------------------

local includes = require("pico_lsp.includes")
local directory = vim.fs.normalize(project)
assert_equal(includes.resolve('#include "literal.lua:2"', directory), directory .. "/literal.lua:2", ".lua:2 should stay literal")
assert_equal(includes.resolve('#include "nested.p8:2"', directory), directory .. "/nested.p8", ".p8:2 should strip the selector")
assert_equal(includes.resolve("#include nested.p8:a", directory), directory .. "/nested.p8", ".p8:a should strip the selector")
assert_equal(includes.resolve("#include nested.p8:g", directory), directory .. "/nested.p8:g", "a non-hex suffix should stay literal")
assert_equal(includes.resolve('#include "x.p8.png:2"', directory), directory .. "/x.p8.png", ".p8.png:2 should strip the selector")
assert_equal(includes.resolve('#include "sub\\\\back.lua"', directory), directory .. "/sub/back.lua", "backslashes should normalize")
assert_equal(includes.resolve("  lib.lua  ", directory), directory .. "/lib.lua", "padding should be trimmed")
assert_equal(includes.resolve("/tmp/absolute.lua", directory), "/tmp/absolute.lua", "absolute paths should stay absolute")
assert_equal(includes.resolve("", directory), "", "an empty target should be returned unchanged")
assert_equal(includes.resolve("#include", directory), "#include", "a directive without a path should stay unchanged")
if includes.target("#include") ~= nil then
  fail("a directive without a path parsed as a target")
end
if includes.target('#include"lib.lua"') ~= nil then
  fail("a directive without whitespace parsed as a target")
end
assert_equal(includes.target("  #include\t\"lib.lua\""), "lib.lua", "a tab after #include should parse")

-- A virtual buffer resolves through the tracked cart root ----------------------

local virtual_probe = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(virtual_probe, 0, -1, false, { '#include "lib.lua"' })
vim.b[virtual_probe].pico8_cart_root = project
vim.bo[virtual_probe].filetype = "pico8"
vim.api.nvim_buf_call(virtual_probe, function()
  vim.api.nvim_win_set_cursor(0, { 1, 10 })
  assert_equal(vim.bo.includeexpr, includeexpr, "virtual buffer did not get includeexpr")
  assert_equal(includes.includeexpr("lib.lua"), directory .. "/lib.lua", "virtual buffer did not use b:pico8_cart_root")
end)
vim.api.nvim_buf_delete(virtual_probe, { force = true })

-- User settings and undo -------------------------------------------------------

vim.o.include = "^GLOBAL_INCLUDE"
local undo_cart = tmp .. "/undo/cart.p8"
write(undo_cart, { "pico-8 cartridge // pico-8.com", "version 42", "__lua__", "x = 1" })
local undo_buf = edit(undo_cart)
assert_equal(vim.bo[undo_buf].include, include_pattern, "a global include value replaced the buffer-local default")
vim.bo[undo_buf].filetype = "text"
assert_equal(vim.fn.eval("&include"), "^GLOBAL_INCLUDE", "ftplugin undo did not restore the global include")
assert_equal(vim.fn.eval("&includeexpr"), "", "ftplugin undo did not clear includeexpr")
vim.o.include = ""

vim.o.includeexpr = "GLOBAL_EXPR"
local global_expr_buf = edit(tmp .. "/undo/expr.p8")
assert_equal(vim.bo[global_expr_buf].includeexpr, "GLOBAL_EXPR", "a user includeexpr was replaced")
vim.bo[global_expr_buf].filetype = "text"
assert_equal(vim.fn.eval("&includeexpr"), "GLOBAL_EXPR", "a user includeexpr was not preserved")
vim.o.includeexpr = ""

local local_cart = tmp .. "/undo/local.p8"
write(local_cart, { "pico-8 cartridge // pico-8.com", "version 42", "__lua__", "x = 1" })
local local_buf = edit(local_cart)
vim.bo[local_buf].filetype = "text"
vim.bo[local_buf].include = "^USER_INCLUDE"
vim.bo[local_buf].includeexpr = "USER_EXPR"
vim.bo[local_buf].filetype = "pico8"
assert_equal(vim.bo[local_buf].include, "^USER_INCLUDE", "a buffer-local include was replaced")
assert_equal(vim.bo[local_buf].includeexpr, "USER_EXPR", "a buffer-local includeexpr was replaced")

-- PNG auto-open ----------------------------------------------------------------

require("pico_lsp").setup({ cmd = { binary } })

local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) ~= 1 then
  fail("missing PNG fixture: " .. png_fixture)
end

edit(png_fixture)
local png_buf = vim.api.nvim_get_current_buf()
if not vim.b[png_buf].pico8_virtual_cart or vim.api.nvim_buf_get_name(png_buf):match("pico8%-cart:") == nil then
  fail("nvim cart.p8.png did not open a virtual cart")
end
if vim.bo[png_buf].buftype ~= "nofile" or vim.bo[png_buf].modifiable then
  fail("auto-opened PNG buffer is not read-only nofile")
end
if vim.bo[png_buf].filetype ~= "pico8" then
  fail("auto-opened PNG buffer has filetype " .. vim.bo[png_buf].filetype)
end
assert_equal(vim.fs.normalize(vim.b[png_buf].pico8_cart_root or ""), vim.fs.normalize(vim.fs.dirname(png_fixture)), "auto-open did not set the source directory")
if not vim.wait(10000, function()
  return #clients(png_buf) > 0
end, 50) then
  fail("auto-opened PNG did not attach a pico_lsp client")
end
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) == vim.fs.normalize(png_fixture) then
    fail("the source PNG buffer was not deleted after auto-open")
  end
end
local png_info = require("pico_lsp").png_buffers[png_buf]
if not png_info or png_info.source ~= vim.uri_from_fname(vim.fs.normalize(png_fixture)) then
  fail("auto-open did not track the source PNG")
end

vim.cmd("Pico8ReloadPng")
assert_equal(vim.api.nvim_get_current_buf(), png_buf, "Pico8ReloadPng replaced the auto-opened buffer")
if vim.bo[png_buf].modifiable then
  fail("Pico8ReloadPng made the auto-opened buffer modifiable")
end

local completions = vim.fn.getcompletion("Pico8OpenPng " .. vim.fs.dirname(png_fixture) .. "/", "cmdline")
local found_completion = false
for _, completion in ipairs(completions) do
  if vim.fs.normalize(completion) == vim.fs.normalize(png_fixture) then
    found_completion = true
  end
end
if not found_completion then
  fail("Pico8OpenPng completion did not include the PNG fixture")
end
if vim.fn.getcompletion("Pico8ReloadPng ", "cmdline")[1] ~= nil then
  fail("Pico8ReloadPng unexpectedly offers file completion")
end
local reload_ok = pcall(vim.cmd, "Pico8ReloadPng extra")
if reload_ok then
  fail("Pico8ReloadPng accepted an argument")
end

-- Invalid PNGs leave an empty named scratch buffer -----------------------------

local bad_png = tmp .. "/bad/bad.p8.png"
write(bad_png, { "not a PNG" })
local bad_notifications = capture_notify(function()
  edit(bad_png)
end)
local bad_buf = vim.api.nvim_get_current_buf()
assert_equal(buffer_name(bad_buf), vim.fs.normalize(bad_png), "failed auto-open lost the source name")
assert_equal(vim.bo[bad_buf].buftype, "nofile", "failed auto-open left a normal buffer")
if vim.bo[bad_buf].modifiable then
  fail("failed auto-open left a modifiable buffer")
end
assert_equal(vim.b[bad_buf].pico8_virtual_cart, nil, "failed auto-open left a virtual marker")
assert_equal(require("pico_lsp").png_buffers[bad_buf], nil, "failed auto-open tracked the buffer")
assert_equal(#vim.api.nvim_buf_get_lines(bad_buf, 0, -1, false), 1, "failed auto-open left binary content")
assert_equal(vim.api.nvim_buf_get_lines(bad_buf, 0, -1, false)[1], "", "failed auto-open left binary content")
if #virtual_buffers() > 1 then
  fail("failed auto-open left an extra virtual buffer")
end
local saw_bad_error = false
for _, notification in ipairs(bad_notifications) do
  if notification.level == vim.log.levels.ERROR then
    saw_bad_error = true
  end
end
if not saw_bad_error then
  fail("failed auto-open did not report an error")
end

-- A client-start failure also leaves an empty named scratch buffer -------------

local failure_png = tmp .. "/failstart/fail.p8.png"
vim.fn.mkdir(vim.fs.dirname(failure_png), "p")
if not vim.uv.fs_copyfile(png_fixture, failure_png) then
  fail("could not copy the PNG fixture")
end
local original_start = vim.lsp.start
local failure_notifications = capture_notify(function()
  vim.lsp.start = function()
    return nil
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(failure_png))
  vim.lsp.start = original_start
  if not ok then
    error(err)
  end
end)
vim.lsp.start = original_start
local failure_buf = vim.api.nvim_get_current_buf()
assert_equal(buffer_name(failure_buf), vim.fs.normalize(failure_png), "client-start failure lost the source name")
assert_equal(vim.bo[failure_buf].buftype, "nofile", "client-start failure left a normal buffer")
assert_equal(vim.bo[failure_buf].modifiable, false, "client-start failure left a modifiable buffer")
assert_equal(vim.api.nvim_buf_get_lines(failure_buf, 0, -1, false)[1], "", "client-start failure left content")
assert_equal(require("pico_lsp").png_buffers[failure_buf], nil, "client-start failure tracked the buffer")
if #virtual_buffers() > 1 then
  fail("client-start failure left an extra virtual buffer")
end
local saw_start_error = false
for _, notification in ipairs(failure_notifications) do
  if notification.level == vim.log.levels.ERROR then
    saw_start_error = true
  end
end
if not saw_start_error then
  fail("client-start failure did not report an error")
end

-- A start failure after a successful decode also removes the virtual buffer ----

local post_png = tmp .. "/poststart/post.p8.png"
vim.fn.mkdir(vim.fs.dirname(post_png), "p")
if not vim.uv.fs_copyfile(png_fixture, post_png) then
  fail("could not copy the post-decode PNG fixture")
end
local post_dir = vim.fs.dirname(post_png)
local request_buf = vim.api.nvim_create_buf(false, true)
local post_client_id = vim.lsp.start({
  name = "pico_lsp",
  cmd = { binary },
  root_dir = post_dir,
  filetypes = { "pico8" },
}, { bufnr = request_buf })
if not post_client_id then
  fail("could not start a client for the post-decode failure test")
end
if not vim.wait(10000, function()
  local client = vim.lsp.get_client_by_id(post_client_id)
  return client and client.initialized
end, 50) then
  fail("the post-decode test client did not initialize")
end
local post_notifications = capture_notify(function()
  vim.lsp.start = function()
    return nil
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(post_png))
  vim.lsp.start = original_start
  if not ok then
    error(err)
  end
end)
vim.lsp.start = original_start
vim.api.nvim_buf_delete(request_buf, { force = true })
local post_buf = vim.api.nvim_get_current_buf()
assert_equal(buffer_name(post_buf), vim.fs.normalize(post_png), "post-decode start failure lost the source name")
assert_equal(vim.bo[post_buf].buftype, "nofile", "post-decode start failure left a normal buffer")
assert_equal(vim.bo[post_buf].modifiable, false, "post-decode start failure left a modifiable buffer")
assert_equal(vim.api.nvim_buf_get_lines(post_buf, 0, -1, false)[1], "", "post-decode start failure left content")
assert_equal(require("pico_lsp").png_buffers[post_buf], nil, "post-decode start failure tracked the buffer")
assert_equal(#virtual_buffers(), 1, "post-decode start failure left a virtual buffer")
local saw_post_error = false
for _, notification in ipairs(post_notifications) do
  if
    notification.level == vim.log.levels.ERROR
    and notification.message:find("could not attach", 1, true) ~= nil
  then
    saw_post_error = true
  end
end
if not saw_post_error then
  fail("post-decode start failure did not report the attach error")
end

-- A disabled helper installs no PNG autocmd ------------------------------------

require("pico_lsp").setup({ disable = true })
local disabled_png = tmp .. "/disabled/disabled.p8.png"
vim.fn.mkdir(vim.fs.dirname(disabled_png), "p")
if not vim.uv.fs_copyfile(png_fixture, disabled_png) then
  fail("could not copy the disabled PNG fixture")
end
local disabled_buf = edit(disabled_png)
if vim.b[disabled_buf].pico8_virtual_cart then
  fail("a disabled helper auto-opened the PNG")
end
if #clients(disabled_buf) > 0 then
  fail("a disabled helper attached a client to the PNG")
end
if vim.api.nvim_buf_get_name(disabled_buf):match("pico8%-cart:") ~= nil then
  fail("a disabled helper opened a virtual cart")
end

-- Cleanup ----------------------------------------------------------------------

vim.lsp.enable("pico_lsp", false)
for _, client in ipairs(all_clients()) do
  client:stop(true)
end
if not vim.wait(3000, function()
  return #all_clients() == 0
end, 25) then
  local remaining = {}
  for _, client in ipairs(all_clients()) do
    remaining[#remaining + 1] = tostring(client.id)
  end
  fail("clients did not stop during cleanup: " .. table.concat(remaining, ", "))
end
if vim.fn.delete(tmp, "rf") ~= 0 then
  fail("could not remove the temporary directory")
end

print("pico8.nvim includes: ok")
vim.cmd("qa!")
