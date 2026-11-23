-- Headless test for the M26 helper correctness work.
--
-- Covers unsaved includes, multi-include isolation, save and reload rescans,
-- debounced ownership changes, per-root client reuse, managed detach,
-- user-started clients, setup re-entry, and :Pico8Refresh.
--
-- Run with tests/run.sh against a real pico-lsp binary:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = assert(vim.env.PICO_LSP_BIN, "PICO_LSP_BIN is not set")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim correctness: " .. message)
  vim.cmd("cquit 1")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function cart_lines(includes)
  local list = includes
  if type(list) == "string" then
    list = { list }
  end
  local lines = {
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
  }
  for _, include in ipairs(list or {}) do
    lines[#lines + 1] = '#include "' .. include .. '"'
  end
  lines[#lines + 1] = "x = 1"
  return lines
end

local function set_cart_includes(bufnr, includes)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, cart_lines(includes))
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
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

local function root_of(client)
  return vim.fs.normalize(client.config.root_dir or client.root_dir or "")
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
end

local function fire_text_changed(bufnr)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
end

-- Wait for callbacks queued before this call (for example BufUnload's
-- scheduled rescan) to run without using a fixed sleep.
local function drain_schedule()
  local done = false
  vim.schedule(function()
    done = true
  end)
  wait_for(function()
    return done
  end, "scheduled callbacks did not run")
end

local function assert_root(client, directory, message)
  if root_of(client) ~= vim.fs.normalize(directory) then
    fail(message .. ": root is " .. root_of(client) .. " instead of " .. directory)
  end
end

local function expected_client(bufnr, client_id, message)
  local attached = clients(bufnr)
  if #attached ~= 1 or attached[1].id ~= client_id then
    local ids = {}
    for _, client in ipairs(attached) do
      ids[#ids + 1] = tostring(client.id)
    end
    fail(message .. ": expected client " .. client_id .. ", found [" .. table.concat(ids, ",") .. "]")
  end
end

local function count_by_root()
  local seen = {}
  for _, client in ipairs(all_clients()) do
    local root = root_of(client)
    seen[root] = (seen[root] or 0) + 1
  end
  return seen
end

vim.filetype.add({ extension = { p8 = "pico8", lua = "lua" } })
vim.lsp.config("pico_lsp", { cmd = { binary } })
require("pico_lsp").setup()

-- Refresh is safe with no carts and no managed buffers.
if not pcall(vim.cmd, "Pico8Refresh") then
  fail("Pico8Refresh errored with no carts open")
end

-- Unsaved includes ------------------------------------------------------------

local project_1 = tmp .. "/project-1"
local cart_1 = project_1 .. "/cart.p8"
local fresh = project_1 .. "/fresh.lua"
local keep = project_1 .. "/keep.lua"
write(cart_1, cart_lines(nil))
write(fresh, { "function fresh() end" })
write(keep, { "function keep() end" })

local cart_1_buf = edit(cart_1)
wait_for(function()
  return #initialized_clients(cart_1_buf) > 0
end, "pico-lsp did not attach to the first cart")
local cart_1_client = initialized_clients(cart_1_buf)[1]
assert_root(cart_1_client, project_1, "first cart")

-- Add two includes without saving. The cart buffer is the source of truth.
set_cart_includes(cart_1_buf, { "fresh.lua", "keep.lua" })
fire_text_changed(cart_1_buf)
for _, line in ipairs(vim.fn.readfile(cart_1)) do
  if line:find("#include", 1, true) then
    fail("the unsaved include reached disk before the test could check it")
  end
end

local fresh_buf = edit(fresh)
wait_for(function()
  return #initialized_clients(fresh_buf) > 0
end, "an unsaved #include did not attach the target buffer")
local fresh_client = initialized_clients(fresh_buf)[1]
if fresh_client.id ~= cart_1_client.id then
  fail("the unsaved include attached client " .. fresh_client.id .. " instead of " .. cart_1_client.id)
end
assert_root(fresh_client, project_1, "unsaved include")

local keep_buf = edit(keep)
wait_for(function()
  return #initialized_clients(keep_buf) > 0
end, "the second unsaved #include did not attach")
expected_client(keep_buf, cart_1_client.id, "the second unsaved include used another client")

-- Removing only one include must not disturb the other managed buffer.
set_cart_includes(cart_1_buf, { "keep.lua" })
fire_text_changed(cart_1_buf)
if #clients(fresh_buf) == 0 then
  fail("an unsaved cart edit detached synchronously instead of debouncing")
end
if vim.wait(100, function()
  return #clients(fresh_buf) == 0
end, 25) then
  fail("cart edits rescanned before the debounce elapsed")
end
wait_for(function()
  return #clients(fresh_buf) == 0
end, "removing an unsaved include did not detach the managed client")
expected_client(keep_buf, cart_1_client.id, "removing one include detached another managed buffer")
if #clients(cart_1_buf) == 0 then
  fail("removing an include stopped the cart's own client")
end

-- Adding it back through TextChangedI is visible on the next BufEnter, without
-- waiting for the debounce.
set_cart_includes(cart_1_buf, { "fresh.lua", "keep.lua" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = cart_1_buf })
edit(fresh)
if #clients(fresh_buf) == 0 then
  fail("an unsaved include was not visible on the next BufEnter")
end
expected_client(fresh_buf, cart_1_client.id, "re-added include attached another client")
expected_client(keep_buf, cart_1_client.id, "re-adding an include disturbed another managed buffer")

-- Sibling carts with the same include basename --------------------------------

local project_a = tmp .. "/project-a"
local project_b = tmp .. "/project-b"
local cart_a = project_a .. "/cart.p8"
local lib_a = project_a .. "/lib.lua"
local cart_b = project_b .. "/cart.p8"
local lib_b = project_b .. "/lib.lua"
write(cart_a, cart_lines("lib.lua"))
write(lib_a, { "function lib_a() end" })
write(cart_b, cart_lines("lib.lua"))
write(lib_b, { "function lib_b() end" })

local cart_a_buf = edit(cart_a)
wait_for(function()
  return #initialized_clients(cart_a_buf) > 0
end, "pico-lsp did not attach to cart A")
local client_a = initialized_clients(cart_a_buf)[1]
assert_root(client_a, project_a, "cart A")

local lib_a_buf = edit(lib_a)
wait_for(function()
  return #initialized_clients(lib_a_buf) > 0
end, "helper did not attach the first project's include")
local lib_a_client = initialized_clients(lib_a_buf)[1]
if lib_a_client.id ~= client_a.id then
  fail("the first project's include used an unrelated client")
end

local cart_b_buf = edit(cart_b)
wait_for(function()
  local attached = initialized_clients(cart_b_buf)[1]
  return attached ~= nil and attached.id ~= client_a.id
end, "pico-lsp did not start a separate client for cart B")
local client_b = initialized_clients(cart_b_buf)[1]
assert_root(client_b, project_b, "cart B")

local lib_b_buf = edit(lib_b)
wait_for(function()
  return #initialized_clients(lib_b_buf) > 0
end, "helper did not attach the second project's include")
local lib_b_client = initialized_clients(lib_b_buf)[1]
if lib_b_client.id ~= client_b.id then
  fail("the second project's include reused the first cart's client")
end
assert_root(lib_b_client, project_b, "second project's include")

-- Repeated buffer entry does not create duplicate clients.
local before = #all_clients()
for _ = 1, 5 do
  edit(cart_a)
  edit(lib_a)
  edit(cart_b)
  edit(lib_b)
end
if vim.wait(500, function()
  return #all_clients() ~= before
end, 50) then
  fail("repeated buffer entry changed the client count")
end
local roots = count_by_root()
for root_path, count in pairs(roots) do
  if count > 1 then
    fail("found " .. count .. " clients for root " .. root_path)
  end
end
if (roots[vim.fs.normalize(project_a)] or 0) ~= 1 then
  fail("repeated buffer entry lost cart A's client")
end
if (roots[vim.fs.normalize(project_b)] or 0) ~= 1 then
  fail("repeated buffer entry lost cart B's client")
end

-- User-started clients are never detached -------------------------------------

-- Remove all includes from project 1, then attach a client to the Lua buffer
-- directly. The helper must not claim that attachment.
set_cart_includes(cart_1_buf, {})
fire_text_changed(cart_1_buf)
wait_for(function()
  return #clients(fresh_buf) == 0 and #clients(keep_buf) == 0
end, "removing the includes before the user-client case did not detach")

local user_root = project_1 .. "/user-root"
vim.fn.mkdir(user_root, "p")
local user_config = vim.deepcopy(vim.lsp.config["pico_lsp"])
user_config.root_dir = vim.fs.normalize(user_root)
local started = vim.lsp.start(user_config, { bufnr = fresh_buf })
if not started then
  fail("could not start a user-managed pico_lsp client")
end
wait_for(function()
  return #initialized_clients(fresh_buf) == 1
end, "the user-managed client did not attach")
local user_client = initialized_clients(fresh_buf)[1]
local user_client_id = user_client.id
assert_root(user_client, user_root, "user-managed client")

-- Re-adding and removing the include must leave the user client alone after a
-- full rescan. The helper must not add the cart's client alongside it.
set_cart_includes(cart_1_buf, { "fresh.lua" })
fire_text_changed(cart_1_buf)
vim.cmd("Pico8Refresh")
expected_client(fresh_buf, user_client_id, "the helper changed a user-managed attachment when the include was added")
assert_root(clients(fresh_buf)[1], user_root, "user-managed client after include add")

set_cart_includes(cart_1_buf, {})
fire_text_changed(cart_1_buf)
vim.cmd("Pico8Refresh")
expected_client(fresh_buf, user_client_id, "the helper detached a user-managed client when the include was removed")
assert_root(clients(fresh_buf)[1], user_root, "user-managed client after include removal")

-- Saving a cart rescans immediately -------------------------------------------

local project_s = tmp .. "/project-s"
local save_cart = project_s .. "/cart.p8"
local save_a = project_s .. "/a.lua"
local save_b = project_s .. "/b.lua"
write(save_cart, cart_lines({ "a.lua", "b.lua" }))
write(save_a, { "function save_a() end" })
write(save_b, { "function save_b() end" })

local save_cart_buf = edit(save_cart)
wait_for(function()
  return #initialized_clients(save_cart_buf) > 0
end, "pico-lsp did not attach to the save fixture cart")
local save_client = initialized_clients(save_cart_buf)[1]

local save_a_buf = edit(save_a)
wait_for(function()
  return #initialized_clients(save_a_buf) > 0
end, "helper did not attach the first save-fixture include")
expected_client(save_a_buf, save_client.id, "first save-fixture include")

local save_b_buf = edit(save_b)
wait_for(function()
  return #initialized_clients(save_b_buf) > 0
end, "helper did not attach the second save-fixture include")
expected_client(save_b_buf, save_client.id, "second save-fixture include")

-- Removing one include and saving detaches it without affecting the other.
edit(save_cart)
set_cart_includes(save_cart_buf, { "b.lua" })
vim.cmd("silent write")
if #clients(save_a_buf) > 0 then
  fail("saving a cart did not detach a removed include synchronously")
end
expected_client(save_b_buf, save_client.id, "saving one include detached another managed buffer")
if #clients(save_cart_buf) == 0 then
  fail("saving a cart stopped the cart's own client")
end

-- Re-adding it and saving reattaches it to the same client.
set_cart_includes(save_cart_buf, { "a.lua", "b.lua" })
vim.cmd("silent write")
if #clients(save_a_buf) == 0 then
  fail("saving a cart did not attach an added include synchronously")
end
expected_client(save_a_buf, save_client.id, "saved include did not reuse the cart's client")

-- A nearer cart taking ownership moves the managed attachment ------------------

local project_e = tmp .. "/project-e"
local cart_e = project_e .. "/cart.p8"
local sub_e = project_e .. "/sub"
local sub_cart_e = sub_e .. "/cart.p8"
local shared_e = sub_e .. "/lib.lua"
write(cart_e, cart_lines("sub/lib.lua"))
write(sub_cart_e, cart_lines(nil))
write(shared_e, { "function shared() end" })

local cart_e_buf = edit(cart_e)
wait_for(function()
  return #initialized_clients(cart_e_buf) > 0
end, "pico-lsp did not attach to cart E")
local client_e = initialized_clients(cart_e_buf)[1]
assert_root(client_e, project_e, "cart E")

local shared_e_buf = edit(shared_e)
wait_for(function()
  return #initialized_clients(shared_e_buf) > 0
end, "helper did not attach cart E's nested include")
if initialized_clients(shared_e_buf)[1].id ~= client_e.id then
  fail("cart E's nested include did not use cart E's client")
end

local sub_cart_e_buf = edit(sub_cart_e)
wait_for(function()
  local attached = initialized_clients(sub_cart_e_buf)[1]
  return attached ~= nil and attached.id ~= client_e.id
end, "pico-lsp did not start a client for the nearer cart")
local sub_client_e = initialized_clients(sub_cart_e_buf)[1]
assert_root(sub_client_e, sub_e, "nearer cart")

-- The nearer cart gains an unsaved include that also covers the shared file.
vim.api.nvim_buf_set_lines(sub_cart_e_buf, 3, 3, false, { '#include "lib.lua"' })
fire_text_changed(sub_cart_e_buf)
wait_for(function()
  local attached = initialized_clients(shared_e_buf)
  return #attached == 1 and attached[1].id == sub_client_e.id
end, "the helper did not move the attachment to the nearer cart's root")

-- Removing it again returns ownership to the parent cart.
vim.api.nvim_buf_set_lines(sub_cart_e_buf, 3, 4, false, {})
fire_text_changed(sub_cart_e_buf)
wait_for(function()
  local attached = initialized_clients(shared_e_buf)
  return #attached == 1 and attached[1].id == client_e.id
end, "the helper did not return the attachment to the parent cart's root")

-- Unrelated cart edits must not disturb earlier managed attachments.
expected_client(lib_a_buf, client_a.id, "editing cart E changed cart A's include attachment")
expected_client(lib_b_buf, client_b.id, "editing cart E changed cart B's include attachment")

-- A .lua path with a tab-like suffix is literal --------------------------------

local literal = tmp .. "/literal"
local literal_cart = literal .. "/cart.p8"
local literal_lib = literal .. "/lib.lua"
write(literal_cart, cart_lines("lib.lua:2"))
write(literal_lib, { "function literal() end" })

local literal_cart_buf = edit(literal_cart)
wait_for(function()
  return #initialized_clients(literal_cart_buf) > 0
end, "pico-lsp did not attach to the literal-suffix cart")

local literal_lib_buf = edit(literal_lib)
if #clients(literal_lib_buf) > 0 then
  fail("the helper treated a .lua:2 include as a tab selector")
end
vim.cmd("Pico8Refresh")
if #clients(literal_lib_buf) > 0 then
  fail("Pico8Refresh treated a .lua:2 include as a tab selector")
end

-- Unrelated Lua files stay untouched ------------------------------------------

local unrelated = tmp .. "/other.lua"
write(unrelated, { "print('unrelated')" })
local unrelated_buf = edit(unrelated)
if #clients(unrelated_buf) > 0 then
  fail("the helper attached an unrelated .lua buffer")
end
vim.cmd("Pico8Refresh")
if #clients(unrelated_buf) > 0 then
  fail("Pico8Refresh attached an unrelated .lua buffer")
end

-- Unloading a cart revalidates against disk ------------------------------------

local project_u = tmp .. "/project-u"
local cart_u = project_u .. "/cart.p8"
local lib_u = project_u .. "/lib.lua"
write(cart_u, cart_lines("lib.lua"))
write(lib_u, { "function lib_u() end" })

local cart_u_buf = edit(cart_u)
wait_for(function()
  return #initialized_clients(cart_u_buf) > 0
end, "pico-lsp did not attach to cart U")
local client_u = initialized_clients(cart_u_buf)[1]

local lib_u_buf = edit(lib_u)
wait_for(function()
  return #initialized_clients(lib_u_buf) > 0
end, "helper did not attach cart U's include")
expected_client(lib_u_buf, client_u.id, "cart U's include did not use cart U's client")

-- An external removal becomes visible once the cart buffer is unloaded. Another
-- BufUnload autocmd yields before the unload finishes, so the revalidation must
-- wait for the buffer to be released.
local yield_group = vim.api.nvim_create_augroup("pico8_correctness_yield_unload", { clear = true })
vim.api.nvim_create_autocmd("BufUnload", {
  group = yield_group,
  pattern = "*.p8",
  callback = function()
    vim.wait(50, function()
      return false
    end)
  end,
})
write(cart_u, cart_lines(nil))
vim.cmd("bunload! " .. cart_u_buf)
wait_for(function()
  return #clients(lib_u_buf) == 0
end, "unloading a cart did not revalidate its includes")
vim.api.nvim_del_augroup_by_id(yield_group)

-- Wiping an unloaded cart buffer revalidates against disk ---------------------

local project_w = tmp .. "/project-w"
local cart_w = project_w .. "/cart.p8"
local lib_w = project_w .. "/lib.lua"
write(cart_w, cart_lines("lib.lua"))
write(lib_w, { "function lib_w() end" })

local cart_w_buf = edit(cart_w)
wait_for(function()
  return #initialized_clients(cart_w_buf) > 0
end, "pico-lsp did not attach to cart W")
local client_w = initialized_clients(cart_w_buf)[1]

local lib_w_buf = edit(lib_w)
wait_for(function()
  return #initialized_clients(lib_w_buf) > 0
end, "helper did not attach cart W's include")
expected_client(lib_w_buf, client_w.id, "cart W's include did not use cart W's client")

-- Unload first while disk still includes the buffer. The unload rescan must
-- keep the attachment, so only BufWipeout can act on the later external change.
vim.cmd("bunload! " .. cart_w_buf)
drain_schedule()
expected_client(lib_w_buf, client_w.id, "unloading a cart detached an include still on disk")

write(cart_w, cart_lines(nil))
vim.cmd("bwipeout! " .. cart_w_buf)
wait_for(function()
  return #clients(lib_w_buf) == 0
end, "wiping an unloaded cart did not detach a removed include")

-- Reloading a cart picks up external include changes ---------------------------

local project_d = tmp .. "/project-d"
local cart_d = project_d .. "/cart.p8"
local lib_d = project_d .. "/lib.lua"
write(cart_d, cart_lines("lib.lua"))
write(lib_d, { "function lib_d() end" })

local cart_d_buf = edit(cart_d)
wait_for(function()
  return #initialized_clients(cart_d_buf) > 0
end, "pico-lsp did not attach to cart D")
local client_d = initialized_clients(cart_d_buf)[1]

local lib_d_buf = edit(lib_d)
wait_for(function()
  return #initialized_clients(lib_d_buf) > 0
end, "helper did not attach cart D's include")
expected_client(lib_d_buf, client_d.id, "cart D's include did not use cart D's client")

-- An external change is not observed while the loaded buffer is authoritative.
write(cart_d, cart_lines(nil))
if #clients(lib_d_buf) == 0 then
  fail("an external disk change was observed without reloading the cart")
end

-- Reloading the cart rescans the new contents and detaches the stale include.
edit(cart_d)
vim.cmd("edit!")
if #clients(lib_d_buf) > 0 then
  fail("reloading a cart did not detach a removed include synchronously")
end

-- Re-adding it externally and reloading reattaches the loaded buffer.
write(cart_d, cart_lines("lib.lua"))
vim.cmd("edit!")
if #clients(lib_d_buf) == 0 then
  fail("reloading a cart did not attach an added include synchronously")
end
expected_client(lib_d_buf, client_d.id, "reloaded include did not reuse cart D's client")

-- A loaded cart buffer remains authoritative when disk disagrees.
write(cart_d, cart_lines(nil))
vim.cmd("Pico8Refresh")
expected_client(lib_d_buf, client_d.id, "Pico8Refresh applied a disk change to a loaded cart buffer")

-- Refresh handles carts that are not loaded ------------------------------------

local project_f = tmp .. "/project-f"
local cart_f = project_f .. "/cart.p8"
local lib_f = project_f .. "/lib.lua"
local lib_f2 = project_f .. "/lib2.lua"
write(cart_f, cart_lines(nil))
write(lib_f, { "function lib_f() end" })
write(lib_f2, { "function lib_f2() end" })

local lib_f_buf = edit(lib_f)
if #clients(lib_f_buf) > 0 then
  fail("the helper attached a buffer with no include")
end

-- An external addition must invalidate the disk include cache. Opening lib2
-- also exercises the helper-started client branch with the cart directory root.
write(cart_f, cart_lines("lib2.lua"))
local lib_f2_buf = edit(lib_f2)
wait_for(function()
  return #initialized_clients(lib_f2_buf) > 0
end, "the disk include cache did not notice an externally added include")
local client_f = initialized_clients(lib_f2_buf)[1]
assert_root(client_f, project_f, "helper-started disk client")

-- The still-unincluded buffer stays untouched.
edit(lib_f)
if #clients(lib_f_buf) > 0 then
  fail("the helper attached a buffer that is not included")
end

-- Refresh attaches a newly included loaded buffer to the existing client.
write(cart_f, cart_lines({ "lib.lua", "lib2.lua" }))
vim.cmd("Pico8Refresh")
wait_for(function()
  return #initialized_clients(lib_f_buf) > 0
end, "Pico8Refresh did not attach a newly included buffer")
expected_client(lib_f_buf, client_f.id, "Pico8Refresh did not reuse the cart F client")

-- Refresh detaches removed includes when the cart is not loaded.
write(cart_f, cart_lines(nil))
vim.cmd("Pico8Refresh")
wait_for(function()
  return #clients(lib_f_buf) == 0 and #clients(lib_f2_buf) == 0
end, "Pico8Refresh did not detach removed includes")

-- Refresh is idempotent and does not duplicate clients.
local refresh_count = #all_clients()
vim.cmd("Pico8Refresh")
vim.cmd("Pico8Refresh")
if vim.wait(500, function()
  return #all_clients() ~= refresh_count
end, 50) then
  fail("Pico8Refresh created duplicate clients")
end

-- A same-size external include swap invalidates by mtime ----------------------

local project_g = tmp .. "/project-g"
local cart_g = project_g .. "/cart.p8"
local aa_g = project_g .. "/aa.lua"
local bb_g = project_g .. "/bb.lua"
write(cart_g, cart_lines("aa.lua"))
write(aa_g, { "function aa() end" })
write(bb_g, { "function bb() end" })

local aa_g_buf = edit(aa_g)
wait_for(function()
  return #initialized_clients(aa_g_buf) > 0
end, "helper did not attach the first same-size include")
local client_g = initialized_clients(aa_g_buf)[1]

-- The cart size stays identical; only its mtime changes.
write(cart_g, cart_lines("bb.lua"))
local bb_g_buf = edit(bb_g)
wait_for(function()
  return #initialized_clients(bb_g_buf) > 0
end, "the disk include cache missed a same-size include swap")
expected_client(bb_g_buf, client_g.id, "same-size swap did not reuse the cart's client")

-- Re-running setup preserves managed attachments -------------------------------

local project_h = tmp .. "/project-h"
local cart_h = project_h .. "/cart.p8"
local lib_h = project_h .. "/lib.lua"
write(cart_h, cart_lines("lib.lua"))
write(lib_h, { "function lib_h() end" })

local cart_h_buf = edit(cart_h)
wait_for(function()
  return #initialized_clients(cart_h_buf) > 0
end, "pico-lsp did not attach to cart H")
local client_h = initialized_clients(cart_h_buf)[1]

local lib_h_buf = edit(lib_h)
wait_for(function()
  return #initialized_clients(lib_h_buf) > 0
end, "helper did not attach cart H's include")
expected_client(lib_h_buf, client_h.id, "cart H's include did not use cart H's client")

require("pico_lsp").setup()
expected_client(fresh_buf, user_client_id, "enabled setup detached a user-managed client")
expected_client(lib_h_buf, client_h.id, "enabled setup detached a managed client")

-- Simulate a plugin module reload: the new module starts with an empty managed
-- map and must re-adopt the marked helper clients.
package.loaded["pico_lsp"] = nil
local reloaded = require("pico_lsp")
reloaded.setup()
expected_client(fresh_buf, user_client_id, "module reload detached a user-managed client")
expected_client(lib_h_buf, client_h.id, "module reload lost a managed client")

set_cart_includes(cart_h_buf, {})
fire_text_changed(cart_h_buf)
wait_for(function()
  return #clients(lib_h_buf) == 0
end, "re-running setup lost the managed attachment")

-- Renaming a managed buffer detaches its helper-owned client -------------------

local project_r = tmp .. "/project-r"
local cart_r = project_r .. "/cart.p8"
local lib_r = project_r .. "/lib.lua"
local renamed_r = project_r .. "/renamed.txt"
write(cart_r, cart_lines("lib.lua"))
write(lib_r, { "function lib_r() end" })

local cart_r_buf = edit(cart_r)
wait_for(function()
  return #initialized_clients(cart_r_buf) > 0
end, "pico-lsp did not attach to cart R")
local client_r = initialized_clients(cart_r_buf)[1]

local lib_r_buf = edit(lib_r)
wait_for(function()
  return #initialized_clients(lib_r_buf) > 0
end, "helper did not attach cart R's include")
expected_client(lib_r_buf, client_r.id, "cart R's include did not use cart R's client")

vim.api.nvim_buf_set_name(lib_r_buf, renamed_r)
vim.cmd("Pico8Refresh")
if #clients(lib_r_buf) > 0 then
  fail("Pico8Refresh kept a managed client after the buffer was renamed away from .lua")
end

-- Buffers that were never included must stay untouched after all rescans.
for _, bufnr in ipairs({ literal_lib_buf, unrelated_buf }) do
  if #clients(bufnr) > 0 then
    fail("a delayed attach reached a buffer that must stay untouched")
  end
end

-- Disabled helper --------------------------------------------------------------

require("pico_lsp").setup({ disable = true })
for _, bufnr in ipairs({ lib_a_buf, lib_b_buf, save_a_buf, save_b_buf, lib_d_buf, shared_e_buf }) do
  if #clients(bufnr) > 0 then
    fail("disabling the helper left a managed attachment")
  end
end
expected_client(fresh_buf, user_client_id, "disabling the helper removed a user-managed client")
if not pcall(vim.cmd, "Pico8Refresh") then
  fail("Pico8Refresh errored when the helper was disabled")
end

local disabled_count = #all_clients()
local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  if not pcall(vim.cmd, "Pico8OpenPng " .. vim.fn.fnameescape(png_fixture)) then
    fail("Pico8OpenPng errored when the helper was disabled")
  end
  if #all_clients() ~= disabled_count then
    fail("Pico8OpenPng started a client when the helper was disabled")
  end
end

edit(fresh)
local before_glyph = vim.api.nvim_buf_get_lines(fresh_buf, 0, -1, false)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
if not pcall(vim.cmd, "Pico8InsertGlyph left") then
  fail("Pico8InsertGlyph errored when the helper was disabled")
end
if vim.inspect(vim.api.nvim_buf_get_lines(fresh_buf, 0, -1, false)) ~= vim.inspect(before_glyph) then
  fail("Pico8InsertGlyph modified a buffer when the helper was disabled")
end
if #all_clients() ~= disabled_count then
  fail("disabled commands changed the client count")
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

print("pico8.nvim correctness: ok")
vim.cmd("qa!")
