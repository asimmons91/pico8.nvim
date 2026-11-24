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
  vim.cmd.edit(vim.fn.fnameescape(path))
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
local restore_request = patch_request(base_client, function(original, self, method, params, handler, bufnr)
  request_calls = request_calls + 1
  return original(self, method, params, handler, bufnr)
end)
for _ = 1, 100 do
  api().cart_status(base_buf)
  api().cart_info(base_buf)
end
restore_request()
if request_calls ~= 0 then
  fail("cart_status/cart_info sent " .. request_calls .. " requests")
end

-- Enable the included-.lua helper for the remaining cases -----------------------

require("pico_lsp").setup()

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

local include_lib_buf = edit(include_lib)
wait_for(function()
  return #clients(include_lib_buf) > 0
end, "the helper did not attach the included .lua buffer")
wait_for(function()
  return api().cart_info(include_lib_buf) ~= nil
end, "the include buffer did not resolve to cart info")
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

-- A standalone .lua cart omits the compressed segment ----------------------------

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

-- Rapid refreshes keep one request in flight and one pending ----------------------

local burst_client = clients(failure_buf)[1]
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
  return original(self, method, params, function(err, result)
    vim.defer_fn(function()
      burst_in_flight = burst_in_flight - 1
      handler(err, result)
    end, 100)
  end, bufnr)
end)
for _ = 1, 10 do
  api().refresh_cart_info(failure_buf)
end
wait_for(function()
  return burst_calls >= 2 and burst_in_flight == 0
end, "the burst refreshes did not settle", 5000)
restore_burst()
if burst_max > 1 then
  fail("rapid refreshes reached " .. burst_max .. " in-flight requests")
end
if burst_calls > 2 then
  fail("rapid refreshes sent " .. burst_calls .. " requests instead of one plus one pending")
end
wait_for(function()
  return api().cart_info(failure_buf) ~= nil
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

local wipe_buf = edit(tabs_cart)
wait_for(function()
  return api().cart_info(wipe_buf) ~= nil
end, "the wipe cart cache did not populate")
vim.cmd("bwipeout! " .. wipe_buf)
if api().cart_info(wipe_buf) ~= nil then
  fail("wiping the cart buffer kept the cart cache")
end

-- Commands stay available when the helper is disabled -----------------------------

require("pico_lsp").setup({ disable = true })
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
