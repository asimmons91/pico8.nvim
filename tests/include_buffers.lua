-- Headless test for M29 included .lua buffer settings.
--
-- Covers PICO-8 comment defaults, stock/custom detection, safe restore,
-- buffer variables, :Pico8OpenCart, ownership changes, and the disabled
-- helper path.
--
-- Run with tests/run.sh against a real pico-lsp binary:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local PICO8_COMMENTS = ":---,:--,://"
local PICO8_COMMENTSTRING = "-- %s"
local LUA_COMMENTS = ":---,:--"
local LUA_COMMENTSTRING = "-- %s"

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim include buffers: " .. message)
  vim.cmd("cquit 1")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function cart_lines(includes)
  local lines = {
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
  }
  for _, include in ipairs(includes or {}) do
    lines[#lines + 1] = '#include "' .. include .. '"'
  end
  lines[#lines + 1] = "x = 1"
  return lines
end

local function edit(path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function clients(bufnr)
  return vim.lsp.get_clients({
    name = "pico_lsp",
    bufnr = bufnr,
    _uninitialized = true,
  })
end

local function initialized_clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function all_clients()
  return vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
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

local function capture_notify(fn)
  local notifications = {}
  local original = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    fail("command errored: " .. tostring(err))
  end
  return notifications
end

local function buffer_name(bufnr)
  return vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
end

local function wait_attached(bufnr, message)
  wait_for(function()
    return #initialized_clients(bufnr) > 0
  end, message)
end

local function wait_detached(bufnr, message)
  wait_for(function()
    return #clients(bufnr) == 0 and vim.b[bufnr].pico8_cart == nil
  end, message)
end

vim.filetype.add({ extension = { p8 = "pico8", lua = "lua" } })
vim.lsp.config("pico_lsp", { cmd = { binary } })
require("pico_lsp").setup()

-- A managed include gets PICO-8 comment settings and buffer variables ---------

local project = tmp .. "/space dir"
local cart = project .. "/cart.p8"
local lib = project .. "/lib.lua"
write(cart, cart_lines({ "lib.lua" }))
write(lib, { "function lib() end", "", "local value = 1" })

local cart_buf = edit(cart)
wait_attached(cart_buf, "pico-lsp did not attach to the cart")

local lib_buf = edit(lib)
wait_attached(lib_buf, "the helper did not attach the included .lua buffer")

assert_equal(vim.bo[lib_buf].filetype, "lua", "an include changed filetype")
assert_equal(vim.bo[lib_buf].comments, PICO8_COMMENTS, "the include comments value")
assert_equal(vim.bo[lib_buf].commentstring, PICO8_COMMENTSTRING, "the include commentstring value")
assert_equal(vim.b[lib_buf].pico8_cart, vim.uri_from_fname(cart), "b:pico8_cart")
assert_equal(vim.b[lib_buf].pico8_cart_root, vim.fs.normalize(project), "b:pico8_cart_root")
if next(vim.fn.maparg("A", "i", false, true)) ~= nil then
  fail("glyph maps leaked into an included .lua buffer")
end

-- gcc uses --, and gq continues a // comment block.
vim.api.nvim_buf_set_lines(lib_buf, 0, -1, false, { "local commented = true" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal gcc")
local commented = vim.api.nvim_buf_get_lines(lib_buf, 0, -1, false)
assert_equal(commented[1], "-- local commented = true", "gcc on an include")

local original_formatoptions = vim.bo[lib_buf].formatoptions
local original_textwidth = vim.bo[lib_buf].textwidth
vim.bo[lib_buf].formatoptions = "cq"
vim.bo[lib_buf].textwidth = 30
vim.api.nvim_buf_set_lines(lib_buf, 0, -1, false, {
  "// this is a long comment line that should wrap onto another comment line",
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! gqG")
local wrapped = vim.api.nvim_buf_get_lines(lib_buf, 0, -1, false)
if #wrapped < 2 then
  fail("gq did not wrap a // comment block")
end
for _, line in ipairs(wrapped) do
  if line:sub(1, 3) ~= "// " then
    fail("gq did not continue the // comment leader: " .. line)
  end
end
vim.bo[lib_buf].formatoptions = original_formatoptions
vim.bo[lib_buf].textwidth = original_textwidth
vim.api.nvim_buf_set_lines(lib_buf, 0, -1, false, { "function lib() end", "", "local value = 1" })
vim.cmd("silent write")

-- :Pico8OpenCart opens the owning cart in the current window ----------------

edit(lib)
local include_win = vim.api.nvim_get_current_win()
vim.cmd("Pico8OpenCart")
assert_equal(vim.api.nvim_get_current_win(), include_win, "Pico8OpenCart changed the window")
assert_equal(buffer_name(vim.api.nvim_get_current_buf()), vim.fs.normalize(cart), "Pico8OpenCart opened the wrong buffer")
assert_equal(vim.bo.filetype, "pico8", "Pico8OpenCart did not open a cart")

local cart_notifications = capture_notify(function()
  vim.cmd("Pico8OpenCart")
end)
if #cart_notifications == 0 then
  fail("Pico8OpenCart did not notify on a cart buffer")
end
assert_contains(cart_notifications[1].message, "already a PICO-8 cart", "the cart-buffer message")

-- An unrelated .lua file keeps stock Lua settings and reports no owner.
local unrelated = tmp .. "/unrelated folder/other.lua"
write(unrelated, { "print('unrelated')" })
local unrelated_buf = edit(unrelated)
if #clients(unrelated_buf) > 0 then
  fail("the helper attached an unrelated .lua buffer")
end
assert_equal(vim.bo[unrelated_buf].comments, LUA_COMMENTS, "unrelated comments")
assert_equal(vim.bo[unrelated_buf].commentstring, LUA_COMMENTSTRING, "unrelated commentstring")
assert_equal(vim.b[unrelated_buf].pico8_cart, nil, "unrelated b:pico8_cart")
assert_equal(vim.b[unrelated_buf].pico8_cart_root, nil, "unrelated b:pico8_cart_root")

local unrelated_notifications = capture_notify(function()
  vim.cmd("Pico8OpenCart")
end)
if #unrelated_notifications == 0 then
  fail("Pico8OpenCart did not notify on an unrelated buffer")
end
assert_contains(unrelated_notifications[1].message, "no owning cart", "the unrelated-buffer message")

-- A decoded PNG is already a cart.
local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
  local png_buf = vim.api.nvim_get_current_buf()
  local png_notifications = capture_notify(function()
    vim.cmd("Pico8OpenCart")
  end)
  if #png_notifications == 0 then
    fail("Pico8OpenCart did not notify on a decoded PNG cart")
  end
  assert_contains(png_notifications[1].message, "already a PICO-8 cart", "the PNG-buffer message")
  vim.cmd("bwipeout! " .. png_buf)
end

-- Managed detach restores stock values and clears the variables ---------------

edit(lib)
wait_attached(lib_buf, "the include did not reattach before the detach test")
local lib_client = initialized_clients(lib_buf)[1]
vim.lsp.buf_detach_client(lib_buf, lib_client.id)
wait_detached(lib_buf, "detaching the managed client did not clear the include state")
assert_equal(vim.bo[lib_buf].comments, LUA_COMMENTS, "detach did not restore stock comments")
assert_equal(vim.bo[lib_buf].commentstring, LUA_COMMENTSTRING, "detach did not restore stock commentstring")
assert_equal(vim.b[lib_buf].pico8_cart_root, nil, "detach did not clear b:pico8_cart_root")

vim.cmd("Pico8Refresh")
wait_attached(lib_buf, "Pico8Refresh did not reattach the include")
assert_equal(vim.bo[lib_buf].comments, PICO8_COMMENTS, "reattach did not restore PICO-8 comments")
assert_equal(vim.b[lib_buf].pico8_cart, vim.uri_from_fname(cart), "reattach did not restore b:pico8_cart")

-- A user change after attach is preserved on detach.
vim.bo[lib_buf].comments = ":custom-comment"
lib_client = initialized_clients(lib_buf)[1]
vim.lsp.buf_detach_client(lib_buf, lib_client.id)
wait_detached(lib_buf, "the user-change detach did not clear the include state")
assert_equal(vim.bo[lib_buf].comments, ":custom-comment", "detach overwrote a user comment change")
vim.bo[lib_buf].comments = LUA_COMMENTS

-- Custom settings are never overwritten and never recorded -------------------

local custom_project = tmp .. "/custom"
local custom_cart = custom_project .. "/cart.p8"
local custom_lib = custom_project .. "/lib.lua"
write(custom_cart, cart_lines({ "lib.lua" }))
write(custom_lib, { "function custom_lib() end" })

local custom_cart_buf = edit(custom_cart)
wait_attached(custom_cart_buf, "pico-lsp did not attach to the custom-settings cart")
local custom_lib_buf = edit(custom_lib)
wait_attached(custom_lib_buf, "the helper did not attach the custom-settings include")
local custom_client = initialized_clients(custom_lib_buf)[1]
vim.lsp.buf_detach_client(custom_lib_buf, custom_client.id)
wait_detached(custom_lib_buf, "the custom-settings include did not detach")
vim.bo[custom_lib_buf].comments = ":---"
vim.bo[custom_lib_buf].commentstring = "// %s"
vim.cmd("Pico8Refresh")
wait_attached(custom_lib_buf, "the custom-settings include did not reattach")
assert_equal(vim.bo[custom_lib_buf].comments, ":---", "the helper overwrote custom comments")
assert_equal(vim.bo[custom_lib_buf].commentstring, "// %s", "the helper overwrote a custom commentstring")
custom_client = initialized_clients(custom_lib_buf)[1]
vim.lsp.buf_detach_client(custom_lib_buf, custom_client.id)
wait_detached(custom_lib_buf, "the custom-settings include did not detach again")
assert_equal(vim.bo[custom_lib_buf].comments, ":---", "detach overwrote custom comments")
assert_equal(vim.bo[custom_lib_buf].commentstring, "// %s", "detach overwrote a custom commentstring")

-- A custom value in one option does not block the other option.
vim.bo[custom_lib_buf].comments = ":---"
vim.bo[custom_lib_buf].commentstring = ""
vim.cmd("Pico8Refresh")
wait_attached(custom_lib_buf, "the mixed-settings include did not reattach")
assert_equal(vim.bo[custom_lib_buf].comments, ":---", "mixed settings overwrote custom comments")
assert_equal(
  vim.bo[custom_lib_buf].commentstring,
  PICO8_COMMENTSTRING,
  "mixed settings did not fill in an empty commentstring"
)
custom_client = initialized_clients(custom_lib_buf)[1]
vim.lsp.buf_detach_client(custom_lib_buf, custom_client.id)
wait_detached(custom_lib_buf, "the mixed-settings include did not detach")
assert_equal(vim.bo[custom_lib_buf].comments, ":---", "mixed detach overwrote custom comments")
assert_equal(vim.bo[custom_lib_buf].commentstring, "", "mixed detach did not restore an empty commentstring")

-- Exact PICO-8 values are treated as user values: they are not claimed and
-- are not restored to stock on detach.
vim.bo[custom_lib_buf].comments = PICO8_COMMENTS
vim.bo[custom_lib_buf].commentstring = PICO8_COMMENTSTRING
vim.cmd("Pico8Refresh")
wait_attached(custom_lib_buf, "the already-PICO-8 include did not reattach")
custom_client = initialized_clients(custom_lib_buf)[1]
vim.lsp.buf_detach_client(custom_lib_buf, custom_client.id)
wait_detached(custom_lib_buf, "the already-PICO-8 include did not detach")
assert_equal(vim.bo[custom_lib_buf].comments, PICO8_COMMENTS, "detach restored an already-PICO-8 comments value")
assert_equal(
  vim.bo[custom_lib_buf].commentstring,
  PICO8_COMMENTSTRING,
  "detach restored an already-PICO-8 commentstring value"
)

-- Empty values are treated as stock and restored as empty --------------------

local empty_project = tmp .. "/empty"
local empty_cart = empty_project .. "/cart.p8"
local empty_lib = empty_project .. "/lib.lua"
write(empty_cart, cart_lines({ "lib.lua" }))
write(empty_lib, { "function empty_lib() end" })

local empty_cart_buf = edit(empty_cart)
wait_attached(empty_cart_buf, "pico-lsp did not attach to the empty-settings cart")
local empty_lib_buf = edit(empty_lib)
wait_attached(empty_lib_buf, "the helper did not attach the empty-settings include")
local empty_client = initialized_clients(empty_lib_buf)[1]
vim.lsp.buf_detach_client(empty_lib_buf, empty_client.id)
wait_detached(empty_lib_buf, "the empty-settings include did not detach")
vim.bo[empty_lib_buf].comments = ""
vim.bo[empty_lib_buf].commentstring = ""
vim.cmd("Pico8Refresh")
wait_attached(empty_lib_buf, "the empty-settings include did not reattach")
assert_equal(vim.bo[empty_lib_buf].comments, PICO8_COMMENTS, "empty comments were not filled in")
assert_equal(vim.bo[empty_lib_buf].commentstring, PICO8_COMMENTSTRING, "empty commentstring was not filled in")
empty_client = initialized_clients(empty_lib_buf)[1]
vim.lsp.buf_detach_client(empty_lib_buf, empty_client.id)
wait_detached(empty_lib_buf, "the empty-settings include did not detach again")
assert_equal(vim.bo[empty_lib_buf].comments, "", "empty comments were not restored")
assert_equal(vim.bo[empty_lib_buf].commentstring, "", "empty commentstring was not restored")

-- Ownership changes update both variables in place ---------------------------

local owner_project = tmp .. "/owner"
local owner_a = owner_project .. "/a.p8"
local owner_b = owner_project .. "/b.p8"
local owner_lib = owner_project .. "/lib.lua"
write(owner_a, cart_lines({ "lib.lua" }))
write(owner_b, cart_lines(nil))
write(owner_lib, { "function owner_lib() end" })

local owner_a_buf = edit(owner_a)
wait_attached(owner_a_buf, "pico-lsp did not attach to owner cart A")
local owner_lib_buf = edit(owner_lib)
wait_attached(owner_lib_buf, "the helper did not attach the owner include")
assert_equal(vim.b[owner_lib_buf].pico8_cart, vim.uri_from_fname(owner_a), "initial owner cart")

write(owner_a, cart_lines(nil))
write(owner_b, cart_lines({ "lib.lua" }))
edit(owner_a)
vim.cmd("Pico8Refresh")
wait_for(function()
  return vim.b[owner_lib_buf].pico8_cart == vim.uri_from_fname(owner_b)
end, "an ownership change did not update b:pico8_cart")
assert_equal(vim.b[owner_lib_buf].pico8_cart_root, vim.fs.normalize(owner_project), "ownership root")
assert_equal(vim.bo[owner_lib_buf].comments, PICO8_COMMENTS, "ownership change reset comments")
edit(owner_lib)
vim.cmd("Pico8OpenCart")
assert_equal(buffer_name(vim.api.nvim_get_current_buf()), vim.fs.normalize(owner_b), "Pico8OpenCart used a stale owner")

-- Disabling the helper restores settings and keeps the command --------------

edit(lib)
wait_attached(lib_buf, "the include was not attached before the disable test")
require("pico_lsp").setup({ disable = true })
wait_detached(lib_buf, "disabling the helper did not detach the include")
assert_equal(vim.bo[lib_buf].comments, LUA_COMMENTS, "disable did not restore stock comments")
assert_equal(vim.bo[lib_buf].commentstring, LUA_COMMENTSTRING, "disable did not restore stock commentstring")
assert_equal(vim.b[lib_buf].pico8_cart_root, nil, "disable did not clear b:pico8_cart_root")
if vim.fn.exists(":Pico8OpenCart") ~= 2 then
  fail("a disabled helper removed :Pico8OpenCart from an earlier enabled setup")
end
local disabled_notifications = capture_notify(function()
  vim.cmd("Pico8OpenCart")
end)
if #disabled_notifications == 0 then
  fail("Pico8OpenCart did not notify when the helper was disabled")
end
assert_contains(disabled_notifications[1].message, "helper is disabled", "the disabled-helper message")
assert_equal(buffer_name(vim.api.nvim_get_current_buf()), vim.fs.normalize(lib), "the disabled command changed buffers")

-- Cleanup --------------------------------------------------------------------

vim.lsp.enable("pico_lsp", false)
-- Opening a cart schedules a native attach. Let queued starts settle before
-- stopping so a start cannot race the stop and create a new client.
vim.wait(100, function()
  return false
end)
for _ = 1, 3 do
  local stopping = all_clients()
  if #stopping == 0 then
    break
  end
  for _, client in ipairs(stopping) do
    pcall(client.stop, client, true)
  end
  if vim.wait(1000, function()
    return #all_clients() == 0
  end, 25) then
    break
  end
end
if #all_clients() ~= 0 then
  local remaining = {}
  for _, client in ipairs(all_clients()) do
    remaining[#remaining + 1] = string.format(
      "id=%d root=%s initialized=%s stopped=%s",
      client.id,
      tostring(client.config.root_dir),
      tostring(client.initialized),
      tostring(client:is_stopped())
    )
  end
  fail("clients did not stop during cleanup: " .. table.concat(remaining, "; "))
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

print("pico8.nvim include buffers: ok")
vim.cmd("qa!")
