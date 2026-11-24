-- Headless test for M28 cart budget statusline and tab picker.
--
-- Covers base-config caching without setup, statusline formatting, includes,
-- standalone .lua carts, decoded .p8.png carts, refresh triggers, stale
-- generations, failure retention, detach cleanup, and the cart commands.
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
  vim.api.nvim_err_writeln("pico8.nvim cart: " .. message)
  vim.cmd("cquit 1")
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function edit(path)
  local normalized = vim.fs.normalize(path)
  local current = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(current)
  if name ~= "" and vim.fs.normalize(name) == normalized then
    return current
  end
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function all_clients()
  return vim.lsp.get_clients({ name = "pico_lsp" })
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
end

local function api()
  return require("pico_lsp")
end

local function cart()
  return require("pico_lsp.cart")
end

local function cart_lines(extra)
  local lines = {
    "pico-8 cartridge // pico-8.com",
    "version 42",
    "__lua__",
    "x = 1",
  }
  for _, line in ipairs(extra or {}) do
    lines[#lines + 1] = line
  end
  return lines
end

local function fire_text_changed(bufnr)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
end

local function assert_same(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
  end
end

-- Temporarily replace client.request so tests can observe or delay requests.
local function patch_request(client, wrapper)
  local original = client.request
  client.request = function(self, method, params, handler, bufnr)
    return wrapper(original, self, method, params, handler, bufnr)
  end
  return function()
    client.request = original
  end
end

-- Keep vim.notify stubbed until the asynchronous callback runs.
local function start_notify_capture()
  local notifications = {}
  local original = vim.notify
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = {
      message = message,
      level = level,
      opts = opts,
    }
  end
  return notifications, function()
    vim.notify = original
  end
end

-- Keep vim.ui.select stubbed until the asynchronous picker runs.
local function start_select_capture(choice)
  local captured = { calls = 0 }
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    captured.calls = captured.calls + 1
    captured.items = items
    captured.opts = opts
    captured.labels = {}
    for index, item in ipairs(items) do
      if opts and type(opts.format_item) == "function" then
        captured.labels[index] = opts.format_item(item)
      else
        captured.labels[index] = tostring(item)
      end
    end
    local selected = choice
    if type(choice) == "function" then
      selected = choice(items)
    end
    if type(selected) == "number" then
      selected = items[selected]
    end
    on_choice(selected)
  end
  return captured, function()
    vim.ui.select = original
  end
end

vim.filetype.add({ extension = { p8 = "pico8", lua = "lua" } })
vim.lsp.config("pico_lsp", { cmd = { binary } })
vim.lsp.enable("pico_lsp")

-- Base configuration: the shipped lsp/pico_lsp.lua registers the cart module
-- and its commands without require("pico_lsp").setup() ------------------------

if package.loaded["pico_lsp.cart"] == nil then
  fail("the shipped config did not load pico_lsp.cart")
end
if package.loaded["pico_lsp"] ~= nil then
  fail("the shipped config loaded require('pico_lsp') before a consumer needed it")
end
if vim.fn.exists(":Pico8CartInfo") ~= 2 or vim.fn.exists(":Pico8Tabs") ~= 2 then
  fail("the shipped config did not register the cart commands")
end

local project_base = tmp .. "/base"
local base_cart = project_base .. "/cart.p8"
write(base_cart, cart_lines())
local base_buf = edit(base_cart)
local before_attach = api().cart_status(base_buf)
if before_attach ~= nil then
  fail("cart_status returned data before the first response")
end

wait_for(function()
  return #clients(base_buf) > 0
end, "pico-lsp did not attach to the base cart")
wait_for(function()
  return api().cart_info(base_buf) ~= nil
end, "the base-config cart cache did not populate")

local base_info = api().cart_info(base_buf)
if base_info.rootUri ~= vim.uri_from_bufnr(base_buf) then
  fail("base cart rootUri is " .. tostring(base_info.rootUri))
end
if base_info.tokenLimit ~= 8192 or base_info.charLimit ~= 65535 then
  fail("base cart limits are " .. vim.inspect({
    tokenLimit = base_info.tokenLimit,
    charLimit = base_info.charLimit,
  }))
end
if
  base_info.tokens ~= base_info.files[1].tokens
  or base_info.chars ~= base_info.files[1].chars
then
  fail("base cart file totals do not match the cart totals")
end

-- Statusline formatting ---------------------------------------------------------

local expected_default = string.format(
  "%d/%d tok · %d/%d ch · %d/%d zip",
  base_info.tokens,
  base_info.tokenLimit,
  base_info.chars,
  base_info.charLimit,
  base_info.compressed,
  base_info.compressedLimit
)
assert_same(api().cart_status(base_buf), expected_default, "default cart_status")
assert_same(
  api().cart_status(base_buf, { fields = { "tokens" } }),
  string.format("%d/%d tok", base_info.tokens, base_info.tokenLimit),
  "tokens-only cart_status"
)
assert_same(
  api().cart_status(base_buf, { fields = { "chars", "tokens" } }),
  string.format(
    "%d/%d ch · %d/%d tok",
    base_info.chars,
    base_info.charLimit,
    base_info.tokens,
    base_info.tokenLimit
  ),
  "ordered cart_status"
)
assert_same(
  api().cart_status(base_buf, { fields = { "bogus" } }),
  "",
  "unknown field cart_status"
)
if api().cart_status(base_buf):find("warning", 1, true) or api().cart_status(base_buf):find("error", 1, true) then
  fail("cart_status added warning text")
end
if base_info.compressedStatus ~= "ok" then
  fail("small cart compressedStatus is " .. tostring(base_info.compressedStatus))
end

-- The public API defaults to the current buffer for statusline use.
if vim.api.nvim_get_current_buf() ~= base_buf then
  edit(base_cart)
end
wait_for(function()
  return api().cart_info(base_buf) ~= nil
end, "the base cart cache did not return before the default-buffer test")
local default_info = api().cart_info()
if not default_info or default_info.rootUri ~= base_info.rootUri then
  fail("cart_info() did not use the current buffer")
end
assert_same(api().cart_status(), api().cart_status(base_buf), "default cart_status")
local no_arg_client = clients(base_buf)[1]
local no_arg_calls = 0
local restore_no_arg = patch_request(no_arg_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" then
    no_arg_calls = no_arg_calls + 1
  end
  return original(self, method, params, handler, bufnr)
end)
api().refresh_cart_info()
wait_for(function()
  return no_arg_calls > 0
end, "refresh_cart_info() did not refresh the current buffer")
restore_no_arg()

-- A client can be attached while the first response is still outstanding; the
-- cache must stay nil rather than showing placeholder zeros.
cart().shutdown()
local delayed_client = clients(base_buf)[1]
local restore_delayed = patch_request(delayed_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  return original(self, method, params, function(err, result)
    vim.defer_fn(function()
      handler(err, result)
    end, 300)
  end, bufnr)
end)
api().refresh_cart_info(base_buf)
if api().cart_status(base_buf) ~= nil then
  fail("cart_status returned placeholder data before the first response")
end
wait_for(function()
  return api().cart_info(base_buf) ~= nil
end, "the delayed first response did not populate the cache")
restore_delayed()

-- The public info table must not be the cache itself.
local mutable = api().cart_info(base_buf)
mutable.tokens = -1
mutable.files[1].tokens = -1
if api().cart_info(base_buf).tokens == -1 or api().cart_info(base_buf).files[1].tokens == -1 then
  fail("cart_info exposed the cache table")
end

-- Statusline access never sends a request.
local base_client = clients(base_buf)[1]
local request_calls = 0
local sync_calls = 0
local restore_request = patch_request(base_client, function(original, self, method, params, handler, bufnr)
  request_calls = request_calls + 1
  return original(self, method, params, handler, bufnr)
end)
local original_sync = base_client.request_sync
base_client.request_sync = function(...)
  sync_calls = sync_calls + 1
  return original_sync(...)
end
for _ = 1, 100 do
  api().cart_status(base_buf)
  api().cart_info(base_buf)
end
restore_request()
base_client.request_sync = original_sync
if request_calls ~= 0 then
  fail("cart_status/cart_info sent " .. request_calls .. " requests")
end
if sync_calls ~= 0 then
  fail("cart_status/cart_info sent " .. sync_calls .. " synchronous requests")
end

-- Enable the included-.lua helper for the remaining cases -----------------------

require("pico_lsp").setup()

-- A real directory named `pico8-cart:...` is not a virtual buffer.
local project_colon = tmp .. "/pico8-cart:demo"
local colon_cart = project_colon .. "/cart.p8"
write(colon_cart, cart_lines())
local colon_buf = edit(colon_cart)
wait_for(function()
  return api().cart_info(colon_buf) ~= nil
end, "a cart in a real pico8-cart: directory did not cache")
local colon_root = api().cart_info(colon_buf).rootUri
local colon_ok, colon_path = pcall(vim.uri_to_fname, colon_root)
if not colon_ok or vim.fs.normalize(colon_path) ~= vim.fs.normalize(colon_cart) then
  fail("the colon-directory rootUri is " .. tostring(colon_root))
end
if api().cart_status(colon_buf) == nil then
  fail("a cart in a real pico8-cart: directory has no statusline text")
end

-- Included .lua buffers resolve to the owning cart -------------------------------

local project_include = tmp .. "/include"
local include_cart = project_include .. "/cart.p8"
local include_lib = project_include .. "/lib.lua"
write(include_cart, cart_lines({ '#include "lib.lua"', "y = 2" }))
write(include_lib, { "function lib() end" })

local include_cart_buf = edit(include_cart)
wait_for(function()
  return api().cart_info(include_cart_buf) ~= nil
end, "the include cart cache did not populate")
local include_cart_info = api().cart_info(include_cart_buf)

-- Change the include on disk before opening it. The helper's first request for
-- an included buffer can start before b:pico8_cart is set, so it re-keys from
-- the include URI to the owning cart. The fresh response must replace the
-- cart's older cache entry.
write(include_lib, { "function lib_with_fresh_content() return 123456 end" })
local include_lib_buf = edit(include_lib)
wait_for(function()
  return #clients(include_lib_buf) > 0
end, "the helper did not attach the included .lua buffer")
wait_for(function()
  return api().cart_info(include_lib_buf) ~= nil
end, "the include buffer did not resolve to cart info")
wait_for(function()
  local info = api().cart_info(include_lib_buf)
  return info ~= nil and info.tokens > include_cart_info.tokens
end, "an include re-key discarded the fresh response")
include_cart_info = api().cart_info(include_cart_buf)
local include_lib_info = api().cart_info(include_lib_buf)
if include_lib_info.rootUri ~= include_cart_info.rootUri then
  fail("include rootUri is " .. tostring(include_lib_info.rootUri))
end
if include_lib_info.tokens ~= include_cart_info.tokens then
  fail("include tokens do not match the owning cart")
end
assert_same(api().cart_status(include_lib_buf), api().cart_status(include_cart_buf), "include status")

-- Editing the include refreshes the owning cart after the debounce.
local lib_tokens_before = api().cart_info(include_lib_buf).tokens
vim.api.nvim_buf_set_lines(include_lib_buf, -1, -1, false, {
  "function lib_with_a_longer_name() return 12345 end",
})
fire_text_changed(include_lib_buf)
assert_same(
  api().cart_info(include_lib_buf).tokens,
  lib_tokens_before,
  "an include edit refreshed synchronously"
)
wait_for(function()
  return api().cart_info(include_lib_buf).tokens > lib_tokens_before
end, "an include edit did not refresh the cache after the debounce")

-- Editing the cart refreshes after the debounce too.
edit(include_cart)
local cart_tokens_before = api().cart_info(include_cart_buf).tokens
vim.api.nvim_buf_set_lines(include_cart_buf, -1, -1, false, {
  "local a_much_longer_cart_expression = 'with some extra characters'",
})
fire_text_changed(include_cart_buf)
assert_same(
  api().cart_info(include_cart_buf).tokens,
  cart_tokens_before,
  "a cart edit refreshed synchronously"
)
wait_for(function()
  return api().cart_info(include_cart_buf).tokens > cart_tokens_before
end, "a cart edit did not refresh the cache after the debounce")
wait_for(function()
  return api().cart_info(include_lib_buf).tokens == api().cart_info(include_cart_buf).tokens
end, "the include cache did not follow the owning cart refresh")

-- Saving a cart refreshes the cache on the next event-loop tick.
edit(include_cart)
local save_tokens_before = api().cart_info(include_cart_buf).tokens
vim.api.nvim_buf_set_lines(include_cart_buf, -1, -1, false, {
  "local saved_expression = 'a saved cart should refresh the statusline'",
})
vim.cmd("silent write")
wait_for(function()
  return api().cart_info(include_cart_buf).tokens > save_tokens_before
end, "saving a cart did not refresh the cache")

-- Saving an included .lua file also refreshes the owning cart immediately.
edit(include_lib)
local include_save_tokens_before = api().cart_info(include_cart_buf).tokens
vim.api.nvim_buf_set_lines(include_lib_buf, -1, -1, false, {
  "function lib_saved_on_disk() return 13579 end",
})
vim.cmd("silent write")
wait_for(function()
  return api().cart_info(include_cart_buf).tokens > include_save_tokens_before
end, "saving an included .lua file did not refresh the cache")

-- InsertLeave refreshes the current attached buffer.
edit(include_lib)
local insert_leave_tokens_before = api().cart_info(include_cart_buf).tokens
vim.api.nvim_buf_set_lines(include_lib_buf, -1, -1, false, {
  "function lib_after_insert_leave() return 98765 end",
})
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = include_lib_buf })
wait_for(function()
  return api().cart_info(include_cart_buf).tokens > insert_leave_tokens_before
end, "InsertLeave did not refresh the cache")

-- TextChanged requests are debounced and coalesced.
edit(include_cart)
wait_for(function()
  return api().cart_info(include_cart_buf) ~= nil
end, "the debounce cart cache did not populate")
-- Let any attach/save request settle before counting.
vim.wait(600, function()
  return false
end)
local debounce_client = clients(include_cart_buf)[1]
local debounce_calls = 0
local restore_debounce = patch_request(debounce_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" then
    debounce_calls = debounce_calls + 1
  end
  return original(self, method, params, handler, bufnr)
end)
local debounce_tokens_before = api().cart_info(include_cart_buf).tokens
for index = 1, 5 do
  vim.api.nvim_buf_set_lines(include_cart_buf, -1, -1, false, {
    string.format("local debounce_line_%d = %d", index, index),
  })
  fire_text_changed(include_cart_buf)
end
vim.wait(100, function()
  return false
end)
if debounce_calls ~= 0 then
  fail("TextChanged issued " .. debounce_calls .. " requests before the 500 ms debounce")
end
wait_for(function()
  return debounce_calls == 1
end, "TextChanged did not issue exactly one debounced request", 4000)
restore_debounce()
wait_for(function()
  return api().cart_info(include_cart_buf).tokens > debounce_tokens_before
end, "the debounced request did not update the cache")

-- Moving an include to another cart in the same root must not corrupt either
-- cart's cache or leave the include on the old owner.
do
local project_owner = tmp .. "/owner"
local owner_a = project_owner .. "/a.p8"
local owner_b = project_owner .. "/b.p8"
local owner_lib = project_owner .. "/lib.lua"
write(owner_a, cart_lines({ '#include "lib.lua"', "a_value = 1" }))
write(owner_b, cart_lines({ '#include "lib.lua"', "b_value = 2" }))
write(owner_lib, { "function owner_lib() end" })

local owner_a_buf = edit(owner_a)
wait_for(function()
  return api().cart_info(owner_a_buf) ~= nil
end, "owner cart A cache did not populate")
local owner_a_uri = vim.uri_from_fname(owner_a)
local owner_b_uri = vim.uri_from_fname(owner_b)

local owner_lib_buf = edit(owner_lib)
wait_for(function()
  return api().cart_info(owner_lib_buf) ~= nil
end, "owner include cache did not populate")
if api().cart_info(owner_lib_buf).rootUri ~= owner_a_uri then
  fail("the initial include owner is " .. tostring(api().cart_info(owner_lib_buf).rootUri))
end

-- Start a delayed request under A. Cart A then drops the include, so B becomes
-- the owner. The old A response must not move the include back to A.
local owner_lib_client = clients(owner_lib_buf)[1]
local owner_calls = 0
local owner_stale_done = false
local restore_owner = patch_request(owner_lib_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  owner_calls = owner_calls + 1
  local call = owner_calls
  local delay = call == 1 and 500 or 50
  return original(self, method, params, function(err, result)
    vim.defer_fn(function()
      handler(err, result)
      if call == 1 then
        owner_stale_done = true
      end
    end, delay)
  end, bufnr)
end)
api().refresh_cart_info(owner_lib_buf)

-- Remove the include from A and save. B still includes it, so ownership moves.
edit(owner_a)
vim.api.nvim_buf_set_lines(owner_a_buf, 0, -1, false, cart_lines({ "a_value = 1" }))
vim.cmd("silent write")
wait_for(function()
  return vim.b[owner_lib_buf].pico8_cart == owner_b_uri
end, "the helper did not move the include to cart B")
wait_for(function()
  local info = api().cart_info(owner_lib_buf)
  return info ~= nil and info.rootUri == owner_b_uri
end, "the cart cache did not follow the new owner")
-- Let the delayed old-owner response arrive.
wait_for(function()
  return owner_stale_done
end, "the delayed old-owner response did not run", 4000)
vim.wait(200, function()
  return false
end)
restore_owner()
local owner_b_after = api().cart_info(owner_lib_buf)
if not owner_b_after or owner_b_after.rootUri ~= owner_b_uri then
  fail("a late old-owner response moved the include back to cart A")
end
local owner_a_after = api().cart_info(owner_a_buf)
if not owner_a_after or owner_a_after.rootUri ~= owner_a_uri then
  fail("cart A's cache was corrupted by the include ownership change: "
    .. vim.inspect(owner_a_after and owner_a_after.rootUri))
end
if owner_b_after.rootUri == owner_a_uri then
  fail("the include still reports the old owner")
end

-- A response from the old owner under the new owner's key is rejected.
local owner_fake_client = clients(owner_lib_buf)[1]
local fake_old = vim.deepcopy(owner_b_after)
fake_old.rootUri = owner_a_uri
fake_old.tokens = 777777
local fake_injected = false
local restore_fake = patch_request(owner_fake_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  return original(self, method, params, function(err, result)
    if not fake_injected then
      fake_injected = true
      handler(nil, fake_old)
    else
      handler(err, result)
    end
  end, bufnr)
end)
api().refresh_cart_info(owner_lib_buf)
wait_for(function()
  return fake_injected
end, "the fake old-owner response did not run", 4000)
vim.wait(200, function()
  return false
end)
restore_fake()
local owner_fake_after = api().cart_info(owner_lib_buf)
if not owner_fake_after or owner_fake_after.rootUri ~= owner_b_uri then
  fail("an old-owner response was accepted under the new owner")
end
end

-- A user-started client on an include has no b:pico8_cart. The first response
-- re-keys to the cart; later responses must keep updating the same cache entry.
do
local project_user = tmp .. "/user-include"
local user_cart = project_user .. "/cart.p8"
local user_lib = project_user .. "/lib.lua"
write(user_cart, cart_lines({ '#include "lib.lua"', "user_value = 1" }))
write(user_lib, { "function user_lib() end" })
local user_cart_buf = edit(user_cart)
wait_for(function()
  return api().cart_info(user_cart_buf) ~= nil
end, "the user-include cart cache did not populate")
local user_cart_uri = vim.uri_from_fname(user_cart)
local user_lib_buf = edit(user_lib)
wait_for(function()
  return #clients(user_lib_buf) > 0 and api().cart_info(user_lib_buf) ~= nil
end, "the user-include buffer did not cache")
local user_client = clients(user_lib_buf)[1]
vim.b[user_lib_buf].pico8_cart = nil
cart().detach(user_client.id, user_lib_buf)
wait_for(function()
  return api().cart_info(user_lib_buf) == nil
end, "the user-include detach did not clear the mapping")
api().refresh_cart_info(user_lib_buf)
wait_for(function()
  local info = api().cart_info(user_lib_buf)
  return info ~= nil and info.rootUri == user_cart_uri
end, "the user-include first response did not re-key to the cart")
local user_tokens_before = api().cart_info(user_lib_buf).tokens
vim.api.nvim_buf_set_lines(user_lib_buf, -1, -1, false, {
  "function user_lib_with_more_tokens() return 24680 end",
})
fire_text_changed(user_lib_buf)
wait_for(function()
  return api().cart_info(user_lib_buf).tokens > user_tokens_before
end, "a user-started include refresh was rejected after re-keying")
end

-- A queued command callback must survive an ownership sweep while the first
-- include response is still in flight.
do
local project_pending = tmp .. "/pending"
local pending_cart = project_pending .. "/cart.p8"
local pending_lib = project_pending .. "/lib.lua"
write(pending_cart, cart_lines({ '#include "lib.lua"', "pending_value = 1" }))
write(pending_lib, { "function pending_lib() end" })
local pending_cart_buf = edit(pending_cart)
wait_for(function()
  return api().cart_info(pending_cart_buf) ~= nil
end, "the pending-callback cart cache did not populate")
local pending_client = clients(pending_cart_buf)[1]
local restore_pending = patch_request(pending_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  return original(self, method, params, function(err, result)
    vim.defer_fn(function()
      handler(err, result)
    end, 300)
  end, bufnr)
end)
local pending_lib_buf = edit(pending_lib)
wait_for(function()
  return #clients(pending_lib_buf) > 0
end, "the pending-callback include did not attach")
local pending_notifications, restore_pending_notify = start_notify_capture()
vim.cmd("Pico8CartInfo")
vim.cmd("Pico8Refresh")
local pending_summary
wait_for(function()
  for _, notification in ipairs(pending_notifications) do
    if notification.message:find("tokens", 1, true) then
      pending_summary = notification.message
      return true
    end
  end
  return false
end, "an ownership sweep dropped a queued cart command", 6000)
restore_pending_notify()
restore_pending()
if not pending_summary:find(pending_cart, 1, true) then
  fail("the surviving command summary is missing the cart path: " .. pending_summary)
end
end

-- A slow, older include response must not overwrite a newer cart cache after
-- both buffers re-key into the same root.
do
local project_order = tmp .. "/order"
local order_cart = project_order .. "/cart.p8"
local order_lib = project_order .. "/lib.lua"
write(order_cart, cart_lines({ '#include "lib.lua"', "order_value = 1" }))
write(order_lib, { "function order_lib() end" })
local order_cart_buf = edit(order_cart)
wait_for(function()
  return api().cart_info(order_cart_buf) ~= nil
end, "the ordering cart cache did not populate")
local order_baseline = api().cart_info(order_cart_buf)
local order_client = clients(order_cart_buf)[1]
local order_calls = 0
local order_stale_done = false
local restore_order = patch_request(order_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  order_calls = order_calls + 1
  local call = order_calls
  if call == 1 then
    return original(self, method, params, function(err, result)
      vim.defer_fn(function()
        handler(err, result)
        order_stale_done = true
      end, 1200)
    end, bufnr)
  end
  return original(self, method, params, handler, bufnr)
end)
local order_lib_buf = edit(order_lib)
wait_for(function()
  return #clients(order_lib_buf) > 0
end, "the ordering include did not attach")
edit(order_cart)
vim.api.nvim_buf_set_lines(order_cart_buf, -1, -1, false, {
  "local order_newer_expression = 'a newer cart value that must survive'",
})
-- Let the didChange reach the server, then refresh the cart directly. Do not
-- fire TextChanged: a helper rescan would create a newer include request and
-- hide the older-response ordering case.
vim.wait(100, function()
  return false
end)
api().refresh_cart_info(order_cart_buf)
wait_for(function()
  local info = api().cart_info(order_cart_buf)
  return info ~= nil and info.tokens > order_baseline.tokens
end, "the newer cart refresh did not apply")
local order_newer_tokens = api().cart_info(order_cart_buf).tokens
wait_for(function()
  return order_stale_done
end, "the slow include response did not run", 4000)
vim.wait(200, function()
  return false
end)
restore_order()
if api().cart_info(order_cart_buf).tokens ~= order_newer_tokens then
  fail("an older include response overwrote the newer cart cache")
end
wait_for(function()
  local info = api().cart_info(order_lib_buf)
  return info ~= nil and info.tokens == order_newer_tokens
end, "the include did not read the newer cart cache")
end

-- A standalone .lua cart omits the compressed segment ----------------------------
do
local project_lua = tmp .. "/standalone"
local standalone = project_lua .. "/main.lua"
write(standalone, { "print('standalone')" })
local standalone_buf = edit(standalone)
local standalone_config = vim.deepcopy(vim.lsp.config["pico_lsp"])
standalone_config.root_dir = vim.fs.normalize(project_lua)
if not vim.lsp.start(standalone_config, { bufnr = standalone_buf }) then
  fail("could not start a client for the standalone .lua cart")
end
wait_for(function()
  return api().cart_info(standalone_buf) ~= nil
end, "the standalone .lua cart cache did not populate")
local standalone_info = api().cart_info(standalone_buf)
if standalone_info.rootUri ~= vim.uri_from_bufnr(standalone_buf) then
  fail("standalone rootUri is " .. tostring(standalone_info.rootUri))
end
if standalone_info.compressedStatus ~= "unavailable" then
  fail("standalone compressedStatus is " .. tostring(standalone_info.compressedStatus))
end
local standalone_status = api().cart_status(standalone_buf)
if standalone_status:find(" zip", 1, true) then
  fail("standalone cart_status includes a compressed segment: " .. standalone_status)
end
if standalone_status:find(" tok", 1, true) == nil or standalone_status:find(" ch", 1, true) == nil then
  fail("standalone cart_status is missing token or character segments: " .. standalone_status)
end
assert_same(
  api().cart_status(standalone_buf, { fields = { "compressed" } }),
  "",
  "standalone compressed-only status"
)

-- A standalone .lua cart has no parsed tabs; the picker offers the whole buffer.
local standalone_count = vim.api.nvim_buf_line_count(standalone_buf)
vim.api.nvim_win_set_cursor(0, { standalone_count, 0 })
local standalone_captured, restore_standalone_select = start_select_capture(1)
vim.cmd("Pico8Tabs")
wait_for(function()
  return standalone_captured.calls > 0
end, "Pico8Tabs did not offer a standalone .lua tab")
restore_standalone_select()
if #standalone_captured.items ~= 1 then
  fail("the standalone .lua picker offered " .. #standalone_captured.items .. " items")
end
local standalone_label = string.format("0: main (lines 1-%d)", standalone_count)
if standalone_captured.labels[1] ~= standalone_label then
  fail("the standalone .lua tab label is " .. standalone_captured.labels[1])
end
wait_for(function()
  return vim.api.nvim_win_get_cursor(0)[1] == 1
end, "Pico8Tabs did not jump to the standalone .lua tab")
end

-- :Pico8CartInfo ---------------------------------------------------------------

edit(base_cart)
local notifications, restore_notify = start_notify_capture()
vim.cmd("Pico8CartInfo")
wait_for(function()
  return #notifications > 0
end, "Pico8CartInfo did not notify")
restore_notify()
local summary = notifications[1].message
if summary:find("tokens", 1, true) == nil or summary:find("chars", 1, true) == nil then
  fail("Pico8CartInfo summary is missing a budget: " .. summary)
end
if summary:find("compressed", 1, true) == nil then
  fail("Pico8CartInfo summary is missing the compressed budget: " .. summary)
end
if summary:find(base_cart, 1, true) == nil then
  fail("Pico8CartInfo summary is missing the cart path: " .. summary)
end
if summary:find("base") == nil or summary:find("tok", 1, true) == nil then
  fail("Pico8CartInfo summary is missing per-file detail: " .. summary)
end

-- The command works on an include and names the owning cart.
notifications, restore_notify = start_notify_capture()
edit(include_lib)
vim.cmd("Pico8CartInfo")
wait_for(function()
  return #notifications > 0
end, "Pico8CartInfo did not notify on an include")
restore_notify()
if notifications[1].message:find(include_cart, 1, true) == nil then
  fail("the include summary does not name the owning cart: " .. notifications[1].message)
end
if notifications[1].message:find("lib.lua", 1, true) == nil then
  fail("the include summary does not include the include file: " .. notifications[1].message)
end

-- The no-client path is clear.
local idle_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(idle_buf, project_base .. "/idle.p8")
notifications, restore_notify = start_notify_capture()
vim.api.nvim_buf_call(idle_buf, function()
  vim.cmd("Pico8CartInfo")
end)
wait_for(function()
  return #notifications > 0
end, "Pico8CartInfo without a client did not notify")
restore_notify()
if notifications[1].message:find("no pico_lsp client", 1, true) == nil then
  fail("the no-client message is " .. notifications[1].message)
end
notifications, restore_notify = start_notify_capture()
vim.api.nvim_buf_call(idle_buf, function()
  vim.cmd("Pico8Tabs")
end)
wait_for(function()
  return #notifications > 0
end, "Pico8Tabs without a client did not notify")
restore_notify()
if notifications[1].message:find("no pico_lsp client", 1, true) == nil then
  fail("the no-client Pico8Tabs message is " .. notifications[1].message)
end
vim.api.nvim_buf_delete(idle_buf, { force = true })

-- :Pico8Tabs --------------------------------------------------------------------

local project_tabs = tmp .. "/tabs"
local tabs_cart = project_tabs .. "/cart.p8"
write(tabs_cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  "first = 1",
  "-->8",
  "second = 2",
})
local tabs_buf = edit(tabs_cart)
wait_for(function()
  return api().cart_info(tabs_buf) ~= nil
end, "the tabs cart cache did not populate")
local tabs_info = api().cart_info(tabs_buf)
if type(tabs_info.tabs) ~= "table" or #tabs_info.tabs < 2 then
  fail("the tabs fixture returned " .. vim.inspect(tabs_info.tabs))
end

local expected_line = tabs_info.tabs[2].startLine + 1
local captured, restore_select = start_select_capture(2)
local lines_before_tabs = vim.api.nvim_buf_get_lines(tabs_buf, 0, -1, false)
vim.cmd("Pico8Tabs")
wait_for(function()
  return captured.calls > 0
end, "Pico8Tabs did not call vim.ui.select")
restore_select()
if #captured.items ~= #tabs_info.tabs then
  fail("Pico8Tabs offered " .. #captured.items .. " tabs instead of " .. #tabs_info.tabs)
end
if captured.labels[1]:find("0:", 1, true) == nil or captured.labels[1]:find("lines", 1, true) == nil then
  fail("the first tab label is " .. captured.labels[1])
end
local expected_label = string.format(
  "%d: %s (lines %d-%d)",
  tabs_info.tabs[2].index,
  tabs_info.tabs[2].name,
  math.min(tabs_info.tabs[2].startLine + 1, vim.api.nvim_buf_line_count(tabs_buf)),
  math.min(tabs_info.tabs[2].endLine + 1, vim.api.nvim_buf_line_count(tabs_buf))
)
if captured.labels[2] ~= expected_label then
  fail("the second tab label is " .. captured.labels[2] .. " instead of " .. expected_label)
end
wait_for(function()
  return vim.api.nvim_win_get_cursor(0)[1] == expected_line
end, "Pico8Tabs did not jump to the selected tab")
assert_same(
  vim.api.nvim_buf_get_lines(tabs_buf, 0, -1, false),
  lines_before_tabs,
  "Pico8Tabs modified the buffer"
)

-- Cancelling the picker is a no-op.
local cursor_before_cancel = vim.api.nvim_win_get_cursor(0)
captured, restore_select = start_select_capture(nil)
vim.cmd("Pico8Tabs")
wait_for(function()
  return captured.calls > 0
end, "Pico8Tabs did not call vim.ui.select for cancellation")
restore_select()
assert_same(vim.api.nvim_win_get_cursor(0), cursor_before_cancel, "cancelled Pico8Tabs moved the cursor")

-- A transient fresh-request failure falls back to the cached tab list.
local tabs_client = clients(tabs_buf)[1]
local tabs_failure_sent = false
local restore_tabs_failure = patch_request(tabs_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" and not tabs_failure_sent then
    tabs_failure_sent = true
    vim.schedule(function()
      handler({ code = -32001, message = "cart-not-found: test" }, nil)
    end)
    return true, 1
  end
  return original(self, method, params, handler, bufnr)
end)
captured, restore_select = start_select_capture(1)
vim.cmd("Pico8Tabs")
wait_for(function()
  return captured.calls > 0
end, "Pico8Tabs did not fall back to cached tabs")
restore_select()
restore_tabs_failure()
if #captured.items ~= #tabs_info.tabs then
  fail("the failed Pico8Tabs request offered " .. #captured.items .. " cached tabs")
end
api().refresh_cart_info(tabs_buf)
wait_for(function()
  return cart().last_error() == nil
end, "the Pico8Tabs fallback error was not cleared")

-- Out-of-range tab lines and zero/missing limits are handled without throwing.
local clamp_client = clients(tabs_buf)[1]
local clamp_info = vim.deepcopy(api().cart_info(tabs_buf))
clamp_info.tabs = { { index = 0, name = "huge", startLine = 999, endLine = 1000 } }
clamp_info.tokenLimit = 0
clamp_info.charLimit = nil
local clamp_calls = 0
local restore_clamp = patch_request(clamp_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" then
    clamp_calls = clamp_calls + 1
    vim.schedule(function()
      handler(nil, clamp_info)
    end)
    return true, 1
  end
  return original(self, method, params, handler, bufnr)
end)
api().refresh_cart_info(tabs_buf)
wait_for(function()
  local info = api().cart_info(tabs_buf)
  return info ~= nil and info.tabs[1] ~= nil and info.tabs[1].name == "huge"
end, "the out-of-range tab fixture did not cache")
local expected_clamped = string.format("%d/%d zip", clamp_info.compressed, clamp_info.compressedLimit)
assert_same(api().cart_status(tabs_buf), expected_clamped, "zero-limit cart_status")
captured, restore_select = start_select_capture(1)
vim.cmd("Pico8Tabs")
wait_for(function()
  return captured.calls > 0
end, "Pico8Tabs did not show the out-of-range tab")
restore_select()
local clamp_count = vim.api.nvim_buf_line_count(tabs_buf)
if captured.labels[1] ~= string.format("0: huge (lines %d-%d)", clamp_count, clamp_count) then
  fail("the clamped tab label is " .. captured.labels[1])
end
wait_for(function()
  return vim.api.nvim_win_get_cursor(0)[1] == clamp_count
end, "Pico8Tabs did not clamp the out-of-range tab line")
restore_clamp()
api().refresh_cart_info(tabs_buf)
wait_for(function()
  local info = api().cart_info(tabs_buf)
  return info ~= nil and info.tabs[1] ~= nil and info.tabs[1].name ~= "huge"
end, "the real tab data did not return after the clamp test")

-- A cart with one tab still shows the picker.
local project_one = tmp .. "/one-tab"
local one_cart = project_one .. "/cart.p8"
write(one_cart, cart_lines())
local one_buf = edit(one_cart)
wait_for(function()
  return api().cart_info(one_buf) ~= nil
end, "the one-tab cart cache did not populate")
local one_info = api().cart_info(one_buf)
captured, restore_select = start_select_capture(1)
vim.cmd("Pico8Tabs")
wait_for(function()
  return captured.calls > 0
end, "Pico8Tabs did not show a one-tab picker")
restore_select()
if #captured.items ~= #one_info.tabs or #captured.items ~= 1 then
  fail("the one-tab picker offered " .. #captured.items .. " items")
end
wait_for(function()
  return vim.api.nvim_win_get_cursor(0)[1] == one_info.tabs[1].startLine + 1
end, "the one-tab picker did not jump")

-- An include explains that tabs belong to the owning cart.
edit(include_lib)
local include_cursor = vim.api.nvim_win_get_cursor(0)
captured, restore_select = start_select_capture(1)
notifications, restore_notify = start_notify_capture()
vim.cmd("Pico8Tabs")
wait_for(function()
  return #notifications > 0
end, "Pico8Tabs did not explain the include case")
restore_notify()
restore_select()
if captured.calls ~= 0 then
  fail("Pico8Tabs opened a picker on an included .lua buffer")
end
if notifications[1].message:find("owning cart", 1, true) == nil then
  fail("the include Pico8Tabs message is " .. notifications[1].message)
end
if notifications[1].message:find(include_cart, 1, true) == nil then
  fail("the include Pico8Tabs message does not name the cart: " .. notifications[1].message)
end
assert_same(vim.api.nvim_win_get_cursor(0), include_cursor, "Pico8Tabs moved the include cursor")

-- A .p8.png virtual buffer uses the server's virtual rootUri ---------------------

local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
  local png_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.b[png_buf].pico8_virtual_cart == true and api().cart_info(png_buf) ~= nil
  end, "the decoded PNG cart cache did not populate")
  local png_info = api().cart_info(png_buf)
  local png_virtual = api().png_buffers[png_buf] and api().png_buffers[png_buf].virtual
  if not png_virtual then
    fail("the decoded PNG buffer has no tracked virtual URI")
  end
  if png_info.rootUri ~= png_virtual then
    fail("PNG rootUri is " .. tostring(png_info.rootUri) .. " instead of " .. png_virtual)
  end
  local png_status = api().cart_status(png_buf)
  if png_status:find(" zip", 1, true) == nil then
    fail("PNG cart_status is missing the compressed segment: " .. png_status)
  end

  notifications, restore_notify = start_notify_capture()
  vim.cmd("Pico8CartInfo")
  wait_for(function()
    return #notifications > 0
  end, "Pico8CartInfo did not notify on a PNG cart")
  restore_notify()
  if notifications[1].message:find("pico8-cart:", 1, true) == nil then
    fail("the PNG summary does not name the virtual cart: " .. notifications[1].message)
  end

  local png_tabs = png_info.tabs
  if type(png_tabs) ~= "table" or #png_tabs == 0 then
    fail("the PNG cart reported no tabs")
  end
  local png_lines_before = vim.api.nvim_buf_get_lines(png_buf, 0, -1, false)
  captured, restore_select = start_select_capture(1)
  vim.cmd("Pico8Tabs")
  wait_for(function()
    return captured.calls > 0
  end, "Pico8Tabs did not show the PNG picker")
  restore_select()
  wait_for(function()
    return vim.api.nvim_win_get_cursor(0)[1] == png_tabs[1].startLine + 1
  end, "Pico8Tabs did not jump inside the PNG buffer")
  assert_same(
    vim.api.nvim_buf_get_lines(png_buf, 0, -1, false),
    png_lines_before,
    "Pico8Tabs modified the PNG buffer"
  )

  -- Pico8ReloadPng refreshes the cached cart info after it reopens the virtual
  -- document. The request must come after the didOpen notification.
  local png_client = clients(png_buf)[1]
  local reload_requests = 0
  local reload_open_seen = false
  local reload_request_after_open = false
  local original_png_notify = png_client.notify
  png_client.notify = function(self, method, params)
    if method == "textDocument/didOpen" then
      reload_open_seen = true
    end
    return original_png_notify(self, method, params)
  end
  local restore_reload = patch_request(png_client, function(original, self, method, params, handler, bufnr)
    if method == "pico8/cartInfo" then
      reload_requests = reload_requests + 1
      reload_request_after_open = reload_open_seen
    end
    return original(self, method, params, handler, bufnr)
  end)
  vim.cmd("Pico8ReloadPng")
  wait_for(function()
    return reload_requests > 0
  end, "Pico8ReloadPng did not refresh the cart info cache")
  restore_reload()
  png_client.notify = original_png_notify
  if not reload_request_after_open then
    fail("Pico8ReloadPng refreshed the cart info before didOpen")
  end
  wait_for(function()
    return api().cart_info(png_buf) ~= nil
  end, "the reloaded PNG cart cache did not repopulate")
end

-- A failed refresh keeps the last good value -------------------------------------

local failure_buf = edit(tabs_cart)
wait_for(function()
  return api().cart_info(failure_buf) ~= nil
end, "the failure cart cache did not populate")
local failure_client = clients(failure_buf)[1]
local failure_info = api().cart_info(failure_buf)
local failure_status = api().cart_status(failure_buf)
local failure_sent = false
local restore_failure = patch_request(failure_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" and not failure_sent then
    failure_sent = true
    vim.schedule(function()
      handler({ code = -32001, message = "cart-not-found: test" }, nil)
    end)
    return true, 1
  end
  return original(self, method, params, handler, bufnr)
end)
api().refresh_cart_info(failure_buf)
wait_for(function()
  local last = cart().last_error()
  return last ~= nil and last.message == "no cart found for this buffer"
end, "the failed refresh was not recorded")
restore_failure()
assert_same(api().cart_info(failure_buf), failure_info, "a failed refresh changed the cached info")
assert_same(api().cart_status(failure_buf), failure_status, "a failed refresh changed the statusline")
api().refresh_cart_info(failure_buf)
wait_for(function()
  return cart().last_error() == nil
end, "a successful refresh did not clear the recorded error")

-- :Pico8CartInfo reports a failed fresh request and keeps the last good value.
local command_failure_sent = false
local command_failure_client = clients(failure_buf)[1]
local restore_command_failure = patch_request(
  command_failure_client,
  function(original, self, method, params, handler, bufnr)
    if method == "pico8/cartInfo" and not command_failure_sent then
      command_failure_sent = true
      vim.schedule(function()
        handler({ code = -32001, message = "cart-not-found: test" }, nil)
      end)
      return true, 1
    end
    return original(self, method, params, handler, bufnr)
  end
)
notifications, restore_notify = start_notify_capture()
vim.cmd("Pico8CartInfo")
wait_for(function()
  return #notifications > 0
end, "Pico8CartInfo did not notify on a failed request")
restore_notify()
restore_command_failure()
if notifications[1].message:find("could not read cart info", 1, true) == nil then
  fail("the failed Pico8CartInfo message is " .. notifications[1].message)
end
if notifications[1].message:find("no cart found", 1, true) == nil then
  fail("the failed Pico8CartInfo did not map cart-not-found: " .. notifications[1].message)
end
assert_same(api().cart_info(failure_buf), failure_info, "a failed Pico8CartInfo changed the cache")

-- A malformed successful response is discarded and keeps the last good value.
local malformed_client = clients(failure_buf)[1]
local malformed_sent = false
local restore_malformed = patch_request(malformed_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" and not malformed_sent then
    malformed_sent = true
    vim.schedule(function()
      handler(nil, { tokens = 1 })
    end)
    return true, 1
  end
  return original(self, method, params, handler, bufnr)
end)
local malformed_before = api().cart_info(failure_buf)
api().refresh_cart_info(failure_buf)
wait_for(function()
  local last = cart().last_error()
  return last ~= nil and last.message == "invalid pico8/cartInfo response"
end, "the malformed response was not recorded")
restore_malformed()
assert_same(api().cart_info(failure_buf), malformed_before, "a malformed response changed the cache")
api().refresh_cart_info(failure_buf)
wait_for(function()
  return cart().last_error() == nil
end, "a successful refresh did not clear the malformed-response error")

-- Rapid refreshes keep one request in flight and one pending ----------------------

local burst_client = clients(failure_buf)[1]
local burst_baseline = api().cart_info(failure_buf)
local burst_stale = vim.deepcopy(burst_baseline)
burst_stale.tokens = 999999
local burst_calls = 0
local burst_in_flight = 0
local burst_max = 0
local restore_burst = patch_request(burst_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  burst_calls = burst_calls + 1
  burst_in_flight = burst_in_flight + 1
  burst_max = math.max(burst_max, burst_in_flight)
  local call = burst_calls
  return original(self, method, params, function(err, result)
    -- The first response is stale and must be discarded. Delay the follow-up so
    -- the test can sample the cache before the real response overwrites it.
    local delay = call == 1 and 50 or 400
    vim.defer_fn(function()
      burst_in_flight = burst_in_flight - 1
      if call == 1 then
        handler(nil, burst_stale)
      else
        handler(err, result)
      end
    end, delay)
  end, bufnr)
end)
for _ = 1, 10 do
  api().refresh_cart_info(failure_buf)
end
wait_for(function()
  return burst_calls >= 2
end, "the burst refreshes did not start the pending request", 5000)
if api().cart_info(failure_buf).tokens == 999999 then
  fail("a stale generation overwrote the cache")
end
wait_for(function()
  return burst_in_flight == 0
end, "the burst refreshes did not settle", 5000)
restore_burst()
if burst_max > 1 then
  fail("rapid refreshes reached " .. burst_max .. " in-flight requests")
end
if burst_calls > 2 then
  fail("rapid refreshes sent " .. burst_calls .. " requests instead of one plus one pending")
end
wait_for(function()
  local info = api().cart_info(failure_buf)
  return info ~= nil and info.tokens == burst_baseline.tokens
end, "the burst refresh lost the cached value")

-- Detach and wipe remove the cache -----------------------------------------------

local detach_buf = edit(one_cart)
wait_for(function()
  return api().cart_info(detach_buf) ~= nil
end, "the detach cart cache did not populate")
local detach_client = clients(detach_buf)[1]
vim.lsp.buf_detach_client(detach_buf, detach_client.id)
wait_for(function()
  return api().cart_info(detach_buf) == nil and api().cart_status(detach_buf) == nil
end, "detaching the client did not clear the cart cache")

-- A response that arrives after LspDetach must not resurrect the mapping.
edit(include_cart)
edit(include_lib)
wait_for(function()
  return #clients(include_lib_buf) > 0 and api().cart_info(include_lib_buf) ~= nil
end, "the include did not reattach before the late-response test")
local late_client = clients(include_lib_buf)[1]
local late_response_done = false
local restore_late = patch_request(late_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" then
    return original(self, method, params, function(err, result)
      vim.defer_fn(function()
        handler(err, result)
        late_response_done = true
      end, 300)
    end, bufnr)
  end
  return original(self, method, params, handler, bufnr)
end)
api().refresh_cart_info(include_lib_buf)
vim.lsp.buf_detach_client(include_lib_buf, late_client.id)
wait_for(function()
  return vim.b[include_lib_buf].pico8_cart == nil
end, "the helper did not clear b:pico8_cart on detach")
if api().cart_info(include_cart_buf) == nil then
  fail("detaching the include cleared the owning cart cache")
end
wait_for(function()
  return late_response_done
end, "the delayed late response did not run", 4000)
vim.wait(200, function()
  return false
end)
restore_late()
if api().cart_info(include_lib_buf) ~= nil then
  fail("a late response resurrected a detached include cache")
end
if api().cart_info(include_cart_buf) == nil then
  fail("the late response cleared the owning cart cache")
end
if #clients(include_lib_buf) ~= 0 then
  fail("the late-response test left the include client attached")
end
edit(include_cart)
edit(include_lib)
wait_for(function()
  return #clients(include_lib_buf) > 0 and api().cart_info(include_lib_buf) ~= nil
end, "the include did not reattach after the late-response test")

-- A response for a wiped buffer must be discarded without touching vim.b.
local wipe_errmsg_before = vim.v.errmsg
local wipe_late_client = clients(include_lib_buf)[1]
local wipe_late_done = false
local restore_wipe_late = patch_request(wipe_late_client, function(original, self, method, params, handler, bufnr)
  if method == "pico8/cartInfo" then
    return original(self, method, params, function(err, result)
      vim.defer_fn(function()
        handler(err, result)
        wipe_late_done = true
      end, 300)
    end, bufnr)
  end
  return original(self, method, params, handler, bufnr)
end)
api().refresh_cart_info(include_lib_buf)
vim.cmd("bwipeout! " .. include_lib_buf)
wait_for(function()
  return wipe_late_done
end, "the wiped-buffer late response did not run", 4000)
vim.wait(200, function()
  return false
end)
restore_wipe_late()
if vim.v.errmsg ~= wipe_errmsg_before and vim.v.errmsg:find("Invalid buffer id", 1, true) then
  fail("a wiped-buffer response raised Invalid buffer id")
end
if api().cart_info(include_cart_buf) == nil then
  fail("wiping an include cleared the owning cart cache")
end

local wipe_buf = edit(tabs_cart)
wait_for(function()
  return api().cart_info(wipe_buf) ~= nil
end, "the wipe cart cache did not populate")
vim.cmd("bwipeout! " .. wipe_buf)
if api().cart_info(wipe_buf) ~= nil then
  fail("wiping the cart buffer kept the cart cache")
end

-- Commands stay available when the helper is disabled -----------------------------

-- A user-started include that becomes standalone must not move the former
-- cart's shared cache to the standalone root.
require("pico_lsp").setup({ disable = true })
local project_orphan = tmp .. "/orphan"
local orphan_cart = project_orphan .. "/cart.p8"
local orphan_lib = project_orphan .. "/lib.lua"
write(orphan_cart, cart_lines({ '#include "lib.lua"', "orphan_value = 1" }))
write(orphan_lib, { "function orphan_lib() end" })
local orphan_cfg = vim.deepcopy(vim.lsp.config["pico_lsp"])
orphan_cfg.root_dir = vim.fs.normalize(project_orphan)
local orphan_cart_buf = edit(orphan_cart)
if not vim.lsp.start(orphan_cfg, { bufnr = orphan_cart_buf }) then
  fail("could not start the orphan cart client")
end
wait_for(function()
  return api().cart_info(orphan_cart_buf) ~= nil
end, "the orphan cart cache did not populate")
local orphan_cart_uri = vim.uri_from_fname(orphan_cart)
local orphan_tokens_before = api().cart_info(orphan_cart_buf).tokens
local orphan_lib_buf = edit(orphan_lib)
if not vim.lsp.start(orphan_cfg, { bufnr = orphan_lib_buf }) then
  fail("could not start the orphan include client")
end
wait_for(function()
  local info = api().cart_info(orphan_lib_buf)
  return info ~= nil and info.rootUri == orphan_cart_uri
end, "the orphan include did not cache under the cart")
edit(orphan_cart)
vim.api.nvim_buf_set_lines(orphan_cart_buf, 0, -1, false, cart_lines({ "orphan_value = 1" }))
vim.cmd("silent write")
wait_for(function()
  local info = api().cart_info(orphan_cart_buf)
  return info ~= nil and info.tokens ~= orphan_tokens_before
end, "the orphan cart cache did not process the include removal")
api().refresh_cart_info(orphan_lib_buf)
wait_for(function()
  local info = api().cart_info(orphan_lib_buf)
  return info ~= nil and info.rootUri == vim.uri_from_fname(orphan_lib)
end, "the removed include did not become a standalone cart")
local orphan_cart_after = api().cart_info(orphan_cart_buf)
if not orphan_cart_after or orphan_cart_after.rootUri ~= orphan_cart_uri then
  fail("the standalone re-key cleared the former cart cache")
end

-- A real user-started include is picked up by the helper's ownership sweep.
local project_user_owner = tmp .. "/user-owner"
local uo_a = project_user_owner .. "/a.p8"
local uo_b = project_user_owner .. "/b.p8"
local uo_lib = project_user_owner .. "/lib.lua"
write(uo_a, cart_lines({ '#include "lib.lua"', "uo_a = 1" }))
write(uo_b, cart_lines({ '#include "lib.lua"', "uo_b = 2" }))
write(uo_lib, { "function uo_lib() end" })
local uo_cfg = vim.deepcopy(vim.lsp.config["pico_lsp"])
uo_cfg.root_dir = vim.fs.normalize(project_user_owner)
local uo_lib_buf = edit(uo_lib)
if not vim.lsp.start(uo_cfg, { bufnr = uo_lib_buf }) then
  fail("could not start the user-owned include client")
end
wait_for(function()
  return #clients(uo_lib_buf) > 0 and api().cart_info(uo_lib_buf) ~= nil
end, "the user-owned include cache did not populate")
local uo_a_uri = vim.uri_from_fname(uo_a)
if api().cart_info(uo_lib_buf).rootUri ~= uo_a_uri then
  fail("the initial user-owned include owner is " .. tostring(api().cart_info(uo_lib_buf).rootUri))
end
local uo_a_buf = edit(uo_a)
wait_for(function()
  return api().cart_info(uo_a_buf) ~= nil
end, "user-owner cart A cache did not populate")
local uo_b_buf = edit(uo_b)
wait_for(function()
  return api().cart_info(uo_b_buf) ~= nil
end, "user-owner cart B cache did not populate")
require("pico_lsp").setup()
wait_for(function()
  return api().cart_info(uo_lib_buf) ~= nil and vim.b[uo_lib_buf].pico8_cart == nil
end, "the enabled helper claimed or lost the user-owned include")
edit(uo_a)
local uo_client = clients(uo_a_buf)[1]
local restore_uo_patch = patch_request(uo_client, function(original, self, method, params, handler, bufnr)
  if method ~= "pico8/cartInfo" then
    return original(self, method, params, handler, bufnr)
  end
  return original(self, method, params, function(err, result)
    vim.defer_fn(function()
      handler(err, result)
    end, 400)
  end, bufnr)
end)
local uo_notifications, restore_uo_notify = start_notify_capture()
vim.cmd("Pico8CartInfo")
vim.api.nvim_buf_set_lines(uo_a_buf, 0, -1, false, cart_lines({ "uo_a = 1" }))
vim.cmd("silent write")
local uo_summary
wait_for(function()
  for _, notification in ipairs(uo_notifications) do
    if notification.message:find("tokens", 1, true) then
      uo_summary = notification.message
      return true
    end
  end
  return false
end, "the user-owner cart command was dropped or misrouted", 8000)
restore_uo_notify()
restore_uo_patch()
if not uo_summary:find(uo_a, 1, true) then
  fail("the user-owner command reported the wrong cart: " .. uo_summary)
end
wait_for(function()
  local info = api().cart_info(uo_lib_buf)
  return info ~= nil and info.rootUri == vim.uri_from_fname(uo_b)
end, "the user-owned include did not follow the ownership change")
local uo_a_after = api().cart_info(uo_a_buf)
if not uo_a_after or uo_a_after.rootUri ~= uo_a_uri then
  fail("syncing a user-owned include cleared cart A's cache")
end
-- Remove the include from B too; the helper-enabled sweep must make the user
-- buffer standalone without clearing B's cache.
edit(uo_b)
vim.api.nvim_buf_set_lines(uo_b_buf, 0, -1, false, cart_lines({ "uo_b = 2" }))
vim.cmd("silent write")
wait_for(function()
  local info = api().cart_info(uo_lib_buf)
  return info ~= nil and info.rootUri == vim.uri_from_fname(uo_lib)
end, "the user-owned include did not become standalone after removal")
local uo_b_after = api().cart_info(uo_b_buf)
if not uo_b_after or uo_b_after.rootUri ~= vim.uri_from_fname(uo_b) then
  fail("removing the user-owned include cleared cart B's cache")
end

-- A deferred save refresh must not repopulate the cache after disabling.
local project_epoch = tmp .. "/epoch"
local epoch_cart = project_epoch .. "/cart.p8"
write(epoch_cart, cart_lines())
local epoch_buf = edit(epoch_cart)
wait_for(function()
  return api().cart_info(epoch_buf) ~= nil
end, "the epoch cart cache did not populate")
vim.api.nvim_buf_set_lines(epoch_buf, -1, -1, false, { "epoch_value = 2" })
vim.cmd("silent write")
require("pico_lsp").setup({ disable = true })
vim.wait(300, function()
  return false
end)
if api().cart_info(epoch_buf) ~= nil then
  fail("a deferred refresh repopulated the cache after disable")
end
if vim.fn.exists(":Pico8CartInfo") ~= 2 or vim.fn.exists(":Pico8Tabs") ~= 2 then
  fail("a disabled helper removed the cart commands")
end
edit(base_cart)
wait_for(function()
  return api().cart_info(base_buf) == nil
end, "a disabled setup did not clear the cart cache")

-- Cleanup ------------------------------------------------------------------------

vim.lsp.enable("pico_lsp", false)
for _, client in ipairs(all_clients()) do
  client:stop(true)
end
if not vim.wait(3000, function()
  return #all_clients() == 0
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

print("pico8.nvim cart: ok")
vim.cmd("qa!")
