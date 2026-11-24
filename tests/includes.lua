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
local deep_cwd = tmp .. "/cwd/deep"
vim.fn.mkdir(deep_cwd, "p")

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

local function unnamed_buffers()
  local count = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) == ""
    then
      count = count + 1
    end
  end
  return count
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
  '#include "sub/nested.p8:a"',
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
write(project .. "/virtual.lua", { "print('virtual')" })
write(outside .. "/abs.lua", { "print('abs')" })
write(outside .. "/lib.lua", { "print('cwd decoy')" })
write(outside .. "/missing.lua", { "print('cwd decoy')" })
write(outside .. "/virtual.lua", { "print('cwd decoy')" })
write(absolute_include, { "print('absolute')" })

local include_pattern = '^\\s*#include\\s\\+'
local includeexpr = 'v:lua.require("pico_lsp.includes").includeexpr(v:fname)'

-- `gf` works before setup: the ftplugin options do not need the helper ---------

local cart = project .. "/cart.p8"
local cart_buf = edit(cart)
assert_equal(vim.bo[cart_buf].include, include_pattern, "ftplugin did not set include")
assert_equal(vim.bo[cart_buf].includeexpr, includeexpr, "ftplugin did not set includeexpr")

local includes = require("pico_lsp.includes")

local cart_path = includes.path_value(project)
assert_equal(vim.bo[cart_buf].path, cart_path, "ftplugin did not scope path to the cart")

local function gf(needle, opts)
  opts = opts or {}
  edit(cart)
  vim.cmd("cd " .. vim.fn.fnameescape(opts.cwd or outside))
  -- The ftplugin scopes 'path' to the cart. A forced case deliberately points
  -- it elsewhere so includeexpr must resolve the target.
  vim.bo.path = opts.force and "/nonexistent-pico8-include-path" or cart_path
  local line = line_of(cart_buf, needle)
  local text = vim.api.nvim_buf_get_lines(cart_buf, line - 1, line, false)[1]
  local col = opts.col and opts.col(text) or 12
  vim.api.nvim_win_set_cursor(0, { line, col })
  local before = #vim.api.nvim_list_bufs()
  local ok, err = pcall(vim.cmd, "normal! gf")
  return ok, err, before, vim.api.nvim_get_current_buf()
end

local cases = {
  { needle = "lib.lua", expected = project .. "/lib.lua" },
  { needle = "padded.lua", expected = project .. "/padded.lua" },
  { needle = "single.lua", expected = project .. "/single.lua" },
  {
    needle = "nested.p8:2",
    expected = project .. "/sub/nested.p8",
    force = true,
    col = function(line)
      return #line - 2
    end,
  },
  {
    needle = "nested.p8:a",
    expected = project .. "/sub/nested.p8",
    force = true,
    col = function(line)
      return #line - 2
    end,
  },
  {
    needle = "with space.lua",
    expected = project .. "/space dir/with space.lua",
    force = true,
  },
  { needle = "../outside/abs.lua", expected = outside .. "/abs.lua", cwd = deep_cwd },
  { needle = "literal.lua:2", expected = project .. "/literal.lua:2", force = true },
  { needle = "sub\\back.lua", expected = project .. "/sub/back.lua", force = true },
  { needle = absolute_include, expected = absolute_include },
}

for _, case in ipairs(cases) do
  local ok, err = gf(case.needle, case)
  if not ok then
    fail("gf failed for " .. case.needle .. ": " .. tostring(err))
  end
  assert_equal(buffer_name(0), vim.fs.normalize(case.expected), "gf opened the wrong target for " .. case.needle)
end

-- The cart-scoped 'path' also keeps :find away from the working directory.

edit(cart)
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.bo.path = cart_path
vim.cmd("find lib.lua")
assert_equal(buffer_name(0), vim.fs.normalize(project .. "/lib.lua"), ":find used the working directory instead of the cart")

-- Cart directories with spaces are escaped correctly for 'path'.

local spaced_project = tmp .. "/space cart"
local spaced_cart = spaced_project .. "/cart.p8"
write(spaced_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
})
write(spaced_project .. "/lib.lua", { "print('spaced cart lib')" })
local spaced_buf = edit(spaced_cart)
assert_equal(
  vim.bo[spaced_buf].path,
  includes.path_value(spaced_project),
  "ftplugin did not escape a cart path with spaces"
)
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { line_of(spaced_buf, "lib.lua"), 12 })
local spaced_ok, spaced_err = pcall(vim.cmd, "normal! gf")
if not spaced_ok then
  fail("gf failed for a cart path with spaces: " .. tostring(spaced_err))
end
assert_equal(buffer_name(0), vim.fs.normalize(spaced_project .. "/lib.lua"), "gf resolved a spaced cart path wrong")

-- Glob and semicolon characters in a cart path must not redirect gf.

local meta_project = tmp .. "/meta[1]"
local meta_cart = meta_project .. "/cart.p8"
write(meta_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
})
write(meta_project .. "/lib.lua", { "print('meta cart lib')" })
write(tmp .. "/meta1/lib.lua", { "print('glob decoy')" })
local meta_buf = edit(meta_cart)
assert_equal(vim.bo[meta_buf].path, includes.path_value(meta_project), "glob path was not replaced with the sentinel")
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { line_of(meta_buf, "lib.lua"), 12 })
local meta_ok, meta_err = pcall(vim.cmd, "normal! gf")
if not meta_ok then
  fail("gf failed for a cart path with glob characters: " .. tostring(meta_err))
end
assert_equal(buffer_name(0), vim.fs.normalize(meta_project .. "/lib.lua"), "gf followed a glob decoy")

local semi_project = tmp .. "/semi;dir"
local semi_cart = semi_project .. "/cart.p8"
write(semi_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
})
write(semi_project .. "/lib.lua", { "print('semi cart lib')" })
local semi_buf = edit(semi_cart)
assert_equal(vim.bo[semi_buf].path, includes.path_value(semi_project), "semicolon path was not escaped")
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { line_of(semi_buf, "lib.lua"), 12 })
local semi_ok, semi_err = pcall(vim.cmd, "normal! gf")
if not semi_ok then
  fail("gf failed for a cart path with a semicolon: " .. tostring(semi_err))
end
assert_equal(buffer_name(0), vim.fs.normalize(semi_project .. "/lib.lua"), "gf searched upward from a semicolon path")

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

local directory = vim.fs.normalize(project)
assert_equal(includes.resolve('#include "literal.lua:2"', directory), directory .. "/literal.lua:2", ".lua:2 should stay literal")
assert_equal(includes.resolve('#include "nested.p8:2"', directory), directory .. "/nested.p8", ".p8:2 should strip the selector")
assert_equal(includes.resolve("#include nested.p8:a", directory), directory .. "/nested.p8", ".p8:a should strip the selector")
assert_equal(includes.resolve("#include nested.p8:g", directory), directory .. "/nested.p8:g", "a non-hex suffix should stay literal")
assert_equal(includes.resolve('#include "x.p8.png:2"', directory), directory .. "/x.p8.png", ".p8.png:2 should strip the selector")
assert_equal(includes.resolve('#include "sub\\\\back.lua"', directory), directory .. "/sub/back.lua", "backslashes should normalize")
assert_equal(
  includes.resolve('#include "../outside/abs.lua"', directory),
  vim.fs.normalize(outside .. "/abs.lua"),
  "parent-relative paths should resolve against the cart"
)
assert_equal(includes.resolve("  lib.lua  ", directory), directory .. "/lib.lua", "padding should be trimmed")
assert_equal(includes.resolve("/tmp/absolute.lua", directory), "/tmp/absolute.lua", "absolute paths should stay absolute")
assert_equal(includes.resolve("", directory), "", "an empty target should be returned unchanged")
assert_equal(includes.resolve("#include", directory), "#include", "a directive without a path should stay unchanged")
assert_equal(
  includes.path_value("/tmp/a b,c;d"),
  "/tmp/a\\ b\\,c\\;d",
  "path entries should escape spaces, commas, and semicolons"
)
local meta_path = includes.path_value("/tmp/a[1]")
assert_equal(includes.path_value("/tmp/a*"), meta_path, "glob metacharacters should share the sentinel")
if meta_path:find("%[") ~= nil or meta_path:find("%*") ~= nil then
  fail("path_value left glob metacharacters in the path entry")
end
if includes.target("#include") ~= nil then
  fail("a directive without a path parsed as a target")
end
if includes.target('#include"lib.lua"') ~= nil then
  fail("a directive without whitespace parsed as a target")
end
assert_equal(includes.target("  #include\t\"lib.lua\""), "lib.lua", "a tab after #include should parse")

-- A virtual buffer resolves through the tracked cart root ----------------------

local virtual_probe = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(virtual_probe, 0, -1, false, { '#include "virtual.lua"' })
vim.b[virtual_probe].pico8_cart_root = project
vim.bo[virtual_probe].filetype = "pico8"
vim.bo[virtual_probe].path = includes.path_value(project)
vim.api.nvim_set_current_buf(virtual_probe)
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { 1, 10 })
assert_equal(vim.bo.includeexpr, includeexpr, "virtual buffer did not get includeexpr")
assert_equal(includes.includeexpr("virtual.lua"), directory .. "/virtual.lua", "virtual buffer did not use b:pico8_cart_root")
local virtual_ok, virtual_err = pcall(vim.cmd, "normal! gf")
if not virtual_ok then
  fail("gf failed in a virtual cart: " .. tostring(virtual_err))
end
assert_equal(
  buffer_name(0),
  vim.fs.normalize(project .. "/virtual.lua"),
  "virtual cart gf used the working directory"
)
vim.api.nvim_buf_delete(virtual_probe, { force = true })

-- User settings and undo -------------------------------------------------------

vim.o.path = ".,,"
vim.o.include = "^GLOBAL_INCLUDE"
local undo_cart = tmp .. "/undo/cart.p8"
write(undo_cart, { "pico-8 cartridge // pico-8.com", "version 42", "__lua__", "x = 1" })
local undo_buf = edit(undo_cart)
assert_equal(vim.bo[undo_buf].include, include_pattern, "a global include value replaced the buffer-local default")
vim.bo[undo_buf].filetype = "text"
assert_equal(vim.fn.eval("&include"), "^GLOBAL_INCLUDE", "ftplugin undo did not restore the global include")
assert_equal(vim.fn.eval("&includeexpr"), "", "ftplugin undo did not clear includeexpr")
assert_equal(vim.fn.eval("&path"), ".,,", "ftplugin undo did not restore path")
vim.o.include = ""

vim.o.path = "/custom/path"
local custom_path_cart = tmp .. "/undo/path.p8"
write(custom_path_cart, { "pico-8 cartridge // pico-8.com", "version 42", "__lua__", "x = 1" })
local custom_path_buf = edit(custom_path_cart)
assert_equal(vim.bo[custom_path_buf].path, "", "ftplugin set a local path despite a custom global path")
assert_equal(vim.fn.eval("&path"), "/custom/path", "a custom global path was replaced")
vim.o.path = ".,,"

vim.o.includeexpr = "GLOBAL_EXPR"
local global_expr_buf = edit(tmp .. "/undo/expr.p8")
assert_equal(vim.bo[global_expr_buf].includeexpr, "GLOBAL_EXPR", "a user includeexpr was replaced")
vim.bo[global_expr_buf].filetype = "text"
assert_equal(vim.fn.eval("&includeexpr"), "GLOBAL_EXPR", "a user includeexpr was not preserved")
vim.o.includeexpr = ""

-- Renaming a cart updates the scoped path --------------------------------------

local rename_root = tmp .. "/rename"
local rename_a = rename_root .. "/a"
local rename_b = rename_root .. "/b"
local rename_c = rename_root .. "/c"
write(rename_a .. "/cart.p8", {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "x = 1",
})
write(rename_a .. "/lib.lua", { "print('rename a')" })
write(rename_b .. "/lib.lua", { "print('rename b')" })
write(rename_c .. "/lib.lua", { "print('rename c')" })
local rename_buf = edit(rename_a .. "/cart.p8")
assert_equal(vim.bo[rename_buf].path, includes.path_value(rename_a), "initial rename path is wrong")
vim.cmd("silent saveas! " .. vim.fn.fnameescape(rename_b .. "/cart.p8"))
assert_equal(buffer_name(rename_buf), vim.fs.normalize(rename_b .. "/cart.p8"), ":saveas did not rename the buffer")
assert_equal(vim.bo[rename_buf].path, includes.path_value(rename_b), ":saveas left the old scoped path")
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { line_of(rename_buf, "lib.lua"), 12 })
local rename_ok, rename_err = pcall(vim.cmd, "normal! gf")
if not rename_ok then
  fail("gf failed after :saveas: " .. tostring(rename_err))
end
assert_equal(buffer_name(0), vim.fs.normalize(rename_b .. "/lib.lua"), ":saveas left gf in the old directory")
edit(rename_b .. "/cart.p8")
vim.cmd("file " .. vim.fn.fnameescape(rename_c .. "/cart.p8"))
assert_equal(vim.bo[rename_buf].path, includes.path_value(rename_c), ":file did not update the scoped path")
vim.cmd("cd " .. vim.fn.fnameescape(outside))
vim.api.nvim_win_set_cursor(0, { line_of(rename_buf, "lib.lua"), 12 })
local file_ok, file_err = pcall(vim.cmd, "normal! gf")
if not file_ok then
  fail("gf failed after :file: " .. tostring(file_err))
end
assert_equal(buffer_name(0), vim.fs.normalize(rename_c .. "/lib.lua"), ":file left gf in the old directory")
edit(rename_c .. "/cart.p8")
vim.bo[rename_buf].path = "/custom/path"
vim.cmd("file " .. vim.fn.fnameescape(rename_a .. "/cart.p8"))
assert_equal(vim.bo[rename_buf].path, "/custom/path", ":file replaced a custom path")

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
assert_equal(
  vim.bo[png_buf].path,
  includes.path_value(vim.fs.dirname(png_fixture)),
  "auto-open did not scope path to the source directory"
)
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

-- Reopening an existing PNG reuses the virtual buffer --------------------------

local png_buffer_count = #vim.api.nvim_list_bufs()
local png_unnamed = unnamed_buffers()

local function set_custom_png_options()
  vim.bo[png_buf].include = "^USER_INCLUDE"
  vim.bo[png_buf].includeexpr = "USER_EXPR"
  vim.bo[png_buf].path = "/custom/path"
end

local function assert_custom_png_options(label)
  assert_equal(vim.bo[png_buf].include, "^USER_INCLUDE", label .. " reset include")
  assert_equal(vim.bo[png_buf].includeexpr, "USER_EXPR", label .. " reset includeexpr")
  assert_equal(vim.bo[png_buf].path, "/custom/path", label .. " reset path")
end

set_custom_png_options()
edit(png_fixture)
assert_equal(vim.api.nvim_get_current_buf(), png_buf, "reopening the PNG created a duplicate virtual buffer")
assert_custom_png_options("reopening the PNG")
assert_equal(#vim.api.nvim_list_bufs(), png_buffer_count, "reopening the PNG leaked a buffer")
assert_equal(unnamed_buffers(), png_unnamed, "reopening the PNG leaked an unnamed buffer")
set_custom_png_options()
vim.cmd("cd " .. vim.fn.fnameescape(tmp))
vim.cmd("split " .. vim.fn.fnameescape(png_fixture))
assert_equal(vim.api.nvim_get_current_buf(), png_buf, ":split on the PNG created a duplicate virtual buffer")
assert_custom_png_options(":split on the PNG")
assert_equal(#vim.api.nvim_list_bufs(), png_buffer_count, ":split on the PNG leaked a buffer")
assert_equal(unnamed_buffers(), png_unnamed, ":split on the PNG leaked an unnamed buffer")
set_custom_png_options()
vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
assert_equal(vim.api.nvim_get_current_buf(), png_buf, "Pico8OpenPng on an open PNG created a duplicate virtual buffer")
assert_custom_png_options("Pico8OpenPng on an open PNG")
assert_equal(#vim.api.nvim_list_bufs(), png_buffer_count, "Pico8OpenPng on an open PNG leaked a buffer")
assert_equal(unnamed_buffers(), png_unnamed, "Pico8OpenPng on an open PNG leaked an unnamed buffer")

-- A :bdelete'd virtual buffer is fully restored when reopened ------------------

vim.cmd("only")
vim.cmd("bdelete " .. png_buf)
assert_equal(vim.api.nvim_buf_is_loaded(png_buf), false, "bdelete did not unload the virtual buffer")
edit(png_fixture)
assert_equal(vim.api.nvim_get_current_buf(), png_buf, ":bdelete + :edit created a duplicate virtual buffer")
assert_equal(vim.api.nvim_buf_is_loaded(png_buf), true, "reopened virtual buffer is not loaded")
assert_equal(vim.bo[png_buf].buftype, "nofile", "reopened virtual buffer is not nofile")
assert_equal(vim.bo[png_buf].filetype, "pico8", "reopened virtual buffer lost its filetype")
assert_equal(vim.bo[png_buf].modifiable, false, "reopened virtual buffer is modifiable")
assert_equal(vim.bo[png_buf].buflisted, true, "reopened virtual buffer is unlisted")
assert_equal(vim.bo[png_buf].swapfile, false, "reopened virtual buffer enables swap")
assert_equal(vim.b[png_buf].pico8_virtual_cart, true, "reopened virtual buffer lost its marker")
assert_equal(
  vim.bo[png_buf].path,
  includes.path_value(vim.fs.dirname(png_fixture)),
  "reopened virtual buffer lost its scoped path"
)
assert_equal(#vim.api.nvim_list_bufs(), png_buffer_count, "reopening after bdelete leaked a buffer")
assert_equal(unnamed_buffers(), png_unnamed, "reopening after bdelete leaked an unnamed buffer")

-- Loading a :bdelete'd virtual buffer with :buffer restores it -----------------

vim.cmd("bdelete " .. png_buf)
assert_equal(vim.api.nvim_buf_is_loaded(png_buf), false, "bdelete did not unload the virtual buffer")
vim.cmd("buffer " .. png_buf)
assert_equal(vim.api.nvim_get_current_buf(), png_buf, ":buffer did not load the virtual buffer")
assert_equal(vim.bo[png_buf].buftype, "nofile", ":buffer left the virtual buffer as a normal buffer")
assert_equal(vim.bo[png_buf].filetype, "pico8", ":buffer lost the virtual buffer filetype")
assert_equal(vim.bo[png_buf].modifiable, false, ":buffer left the virtual buffer modifiable")
assert_equal(vim.bo[png_buf].buflisted, true, ":buffer left the virtual buffer unlisted")
assert_equal(vim.bo[png_buf].swapfile, false, ":buffer enabled swap for the virtual buffer")
assert_equal(vim.b[png_buf].pico8_virtual_cart, true, ":buffer lost the virtual marker")
assert_equal(
  vim.bo[png_buf].path,
  includes.path_value(vim.fs.dirname(png_fixture)),
  ":buffer lost the scoped path"
)
vim.cmd("Pico8ReloadPng")
if not vim.wait(10000, function()
  return #clients(png_buf) > 0
end, 50) then
  fail("Pico8ReloadPng after :buffer did not attach a client")
end
if #vim.api.nvim_buf_get_lines(png_buf, 0, -1, false) < 2 then
  fail("Pico8ReloadPng after :buffer did not restore the cart text")
end
assert_equal(vim.api.nvim_get_current_buf(), png_buf, "Pico8ReloadPng after :buffer changed buffers")
assert_equal(vim.bo[png_buf].buftype, "nofile", "Pico8ReloadPng after :buffer lost nofile")
assert_equal(vim.bo[png_buf].modifiable, false, "Pico8ReloadPng after :buffer made the buffer modifiable")
assert_equal(#vim.api.nvim_list_bufs(), png_buffer_count, ":buffer + reload leaked a buffer")
assert_equal(unnamed_buffers(), png_unnamed, ":buffer + reload leaked an unnamed buffer")

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
