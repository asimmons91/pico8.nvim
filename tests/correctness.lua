-- Headless test for the M26 helper correctness work.
--
-- Covers unsaved includes, debounced ownership changes, per-root client reuse,
-- managed detach, user-started clients, and :Pico8Refresh.
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

local function cart_lines(include)
  local lines = {
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
  }
  if include then
    lines[#lines + 1] = '#include "' .. include .. '"'
  end
  lines[#lines + 1] = "x = 1"
  return lines
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

local function assert_root(client, directory, message)
  if root_of(client) ~= vim.fs.normalize(directory) then
    fail(message .. ": root is " .. root_of(client) .. " instead of " .. directory)
  end
end

local function count_by_root()
  local seen = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp" })) do
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
write(cart_1, cart_lines(nil))
write(fresh, { "function fresh() end" })

local cart_1_buf = edit(cart_1)
wait_for(function()
  return #initialized_clients(cart_1_buf) > 0
end, "pico-lsp did not attach to the first cart")
local cart_1_client = initialized_clients(cart_1_buf)[1]
assert_root(cart_1_client, project_1, "first cart")

-- Add the include without saving. The cart buffer is the source of truth.
vim.api.nvim_buf_set_lines(cart_1_buf, 3, 3, false, { '#include "fresh.lua"' })
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

-- Removing the include without saving detaches the managed client.
vim.api.nvim_buf_set_lines(cart_1_buf, 3, 4, false, {})
fire_text_changed(cart_1_buf)
wait_for(function()
  return #clients(fresh_buf) == 0
end, "removing an unsaved include did not detach the managed client")

-- Adding it back without saving reattaches after the debounce.
vim.api.nvim_buf_set_lines(cart_1_buf, 3, 3, false, { '#include "fresh.lua"' })
fire_text_changed(cart_1_buf)
wait_for(function()
  return #initialized_clients(fresh_buf) > 0
end, "re-adding an unsaved include did not reattach the managed client")

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
local before = #vim.lsp.get_clients({ name = "pico_lsp" })
for _ = 1, 5 do
  edit(cart_a)
  edit(lib_a)
  edit(cart_b)
  edit(lib_b)
end
wait_for(function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) == before
end, "repeated buffer entry changed the client count")
for root_path, count in pairs(count_by_root()) do
  if count > 1 then
    fail("found " .. count .. " clients for root " .. root_path)
  end
end

-- User-started clients are never detached -------------------------------------

-- Remove the include from project 1 without saving, then attach a client to the
-- Lua buffer directly. The helper must not claim that attachment.
vim.api.nvim_buf_set_lines(cart_1_buf, 3, 4, false, {})
fire_text_changed(cart_1_buf)
wait_for(function()
  return #clients(fresh_buf) == 0
end, "removing the include before the user-client case did not detach")

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

-- Re-adding and removing the include must leave the user client alone, even
-- after the debounce would have rescanned. The helper must not add the cart's
-- client alongside it.
vim.api.nvim_buf_set_lines(cart_1_buf, 3, 3, false, { '#include "fresh.lua"' })
fire_text_changed(cart_1_buf)
if vim.wait(1200, function()
  return #clients(fresh_buf) ~= 1
end, 50) then
  fail("the helper changed a user-managed attachment when the include was added")
end

vim.api.nvim_buf_set_lines(cart_1_buf, 3, 4, false, {})
fire_text_changed(cart_1_buf)
if vim.wait(1200, function()
  return #clients(fresh_buf) == 0
end, 50) then
  fail("the helper detached a user-managed client when the include was removed")
end
if #clients(fresh_buf) ~= 1 or clients(fresh_buf)[1].id ~= user_client_id then
  fail("the user-managed client was replaced")
end
assert_root(clients(fresh_buf)[1], user_root, "user-managed client after removal")

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
if vim.wait(1200, function()
  return #clients(literal_lib_buf) > 0
end, 50) then
  fail("the helper treated a .lua:2 include as a tab selector")
end

-- Unrelated Lua files stay untouched ------------------------------------------

local unrelated = tmp .. "/other.lua"
write(unrelated, { "print('unrelated')" })
local unrelated_buf = edit(unrelated)
if vim.wait(1200, function()
  return #clients(unrelated_buf) > 0
end, 50) then
  fail("the helper attached an unrelated .lua buffer")
end

-- Refresh handles an external cart change and stays idempotent -----------------

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
if initialized_clients(lib_d_buf)[1].id ~= client_d.id then
  fail("cart D's include did not use cart D's client")
end

-- An external tool removes the include. Dropping the loaded cart buffer makes
-- the helper read the file from disk; refresh then detaches the stale include.
write(cart_d, cart_lines(nil))
vim.api.nvim_buf_delete(cart_d_buf, { force = true })
if not pcall(vim.cmd, "Pico8Refresh") then
  fail("Pico8Refresh errored after an external cart change")
end
wait_for(function()
  return #clients(lib_d_buf) == 0
end, "Pico8Refresh did not detach a stale include")

-- Refresh is idempotent and does not duplicate clients.
local refresh_count = #vim.lsp.get_clients({ name = "pico_lsp" })
vim.cmd("Pico8Refresh")
vim.cmd("Pico8Refresh")
if vim.wait(500, function()
  return #vim.lsp.get_clients({ name = "pico_lsp" }) ~= refresh_count
end, 50) then
  fail("Pico8Refresh created duplicate clients")
end

-- Disabled helper --------------------------------------------------------------

require("pico_lsp").setup({ disable = true })
if not pcall(vim.cmd, "Pico8Refresh") then
  fail("Pico8Refresh errored when the helper was disabled")
end

-- Cleanup ----------------------------------------------------------------------

vim.lsp.enable("pico_lsp", false)
for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })) do
  client:stop(true)
end
if not vim.wait(3000, function()
  return #vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true }) == 0
end, 25) then
  local remaining = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = "pico_lsp", _uninitialized = true })) do
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
