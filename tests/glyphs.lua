-- Headless tests for M31 glyph caching, byte insertion, picker filtering, and
-- completion.
--
-- Run with tests/run.sh after installing pico-lsp:
--   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh

local root = vim.env.PICO8_NVIM_ROOT or vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local binary = vim.env.PICO_LSP_BIN or "pico-lsp"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local cart = tmp .. "/cart.p8"
local included = tmp .. "/lib.lua"
vim.fn.writefile({
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "function _init()",
  "end",
}, cart)
vim.fn.writefile({ "function lib() end" }, included)

vim.filetype.add({ extension = { p8 = "pico8" } })
vim.lsp.config("pico_lsp", {
  cmd = { binary },
  filetypes = { "pico8" },
  root_dir = tmp,
  settings = {
    pico8 = {
      glyphs = {
        { name = "logo", byte = 128, description = "custom font slot 0x80" },
      },
    },
  },
})
vim.lsp.enable("pico_lsp")
-- Exercise the setup option instead of the global switch.
vim.g.pico8_glyph_maps = nil
require("pico_lsp").setup({ glyph_maps = true })
local glyphs = require("pico_lsp.glyphs")

local function fail(message)
  vim.api.nvim_err_writeln("nvim glyphs: " .. message)
  vim.cmd("cquit 1")
end

local function assert_true(value, message)
  if not value then
    fail(message)
  end
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 5000, predicate, 20) then
    fail(message)
  end
end

local function current_line(lnum)
  return vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
end

local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
local function feed(keys)
  vim.api.nvim_feedkeys(keys .. esc, "xt", false)
end

local function new_code_line(text)
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { text or "" })
  local lnum = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return lnum
end

local function count_requests(client, method)
  local counts = { sync = 0, async = 0 }
  local original_sync = client.request_sync
  local original_request = client.request
  client.request_sync = function(self, name, ...)
    if name == method then
      counts.sync = counts.sync + 1
    end
    return original_sync(self, name, ...)
  end
  client.request = function(self, name, ...)
    if name == method then
      counts.async = counts.async + 1
    end
    return original_request(self, name, ...)
  end
  return counts, function()
    client.request_sync = original_sync
    client.request = original_request
  end
end

local function capture_notifications(fn)
  local messages = {}
  local original = vim.notify
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err)
  end
  return messages
end

local function wait_cache(bufnr)
  wait_for(function()
    local entry = glyphs.cache_for(bufnr)
    return entry ~= nil and entry.entries ~= nil
  end, "glyph catalog was not prefetched")
end

vim.cmd.edit(vim.fn.fnameescape(cart))
wait_for(function()
  return #vim.lsp.get_clients({ name = "pico_lsp", bufnr = 0 }) > 0
end, "pico-lsp did not attach to the cart")

local bufnr = vim.api.nvim_get_current_buf()
local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]

-- The setup option installs maps without g:pico8_glyph_maps.
local mapping = vim.fn.maparg("L", "i", false, true)
assert_true(type(mapping.callback) == "function", "glyph_maps option did not install Shift maps")

-- Attach prefetch fills the full catalog without a Shift press.
wait_cache(bufnr)
local cache = glyphs.cache_for(bufnr)
local expected_left = cache.by_byte[0x8b]
assert_true(type(expected_left) == "string" and expected_left ~= "", "cached catalog has no 0x8b glyph")
local logo = cache.names.logo
assert_true(logo ~= nil, "cached catalog has no custom logo name")
assert_true(logo.custom == true and logo.byte == 128, "custom logo entry was not preserved")
assert_true(cache.by_byte[128] == logo.text, "later custom entry did not win byte 0x80")

-- A cold cache makes one synchronous request; the next Shift press uses it.
glyphs.reset()
local sync_counts, restore_sync = count_requests(client, "pico8/glyphs")
local first = new_code_line()
feed("iL")
wait_for(function()
  return current_line(first) == expected_left
end, "first Shift-L insertion did not use the synchronous fallback")
wait_cache(bufnr)
assert_true(sync_counts.sync == 1, "first Shift insertion made " .. sync_counts.sync .. " glyph requests")
cache = glyphs.cache_for(bufnr)

local second = new_code_line()
feed("iL")
wait_for(function()
  return current_line(second) == expected_left
end, "second Shift-L insertion did not use the cache")
vim.wait(100, function()
  return true
end)
assert_true(sync_counts.sync == 1, "second Shift insertion requested the catalog again")
restore_sync()

-- Completion reads the cache and never starts a request.
local complete_counts, restore_complete = count_requests(client, "pico8/glyphs")
local names = glyphs.complete("le")
assert_true(vim.tbl_contains(names, "left"), "completion did not return left")
local sorted = vim.deepcopy(names)
table.sort(sorted, function(a, b)
  return a:lower() < b:lower()
end)
for i = 1, #names do
  assert_true(names[i] == sorted[i], "completion names were not sorted")
end
local logo_names = glyphs.complete("log")
assert_true(vim.tbl_contains(logo_names, "logo"), "completion did not include the custom name")
local cmdline = vim.fn.getcompletion("Pico8InsertGlyph le", "cmdline")
assert_true(vim.tbl_contains(cmdline, "left"), "command completion did not return left")
assert_true(
  complete_counts.sync == 0 and complete_counts.async == 0,
  "completion triggered a catalog request"
)
restore_complete()

-- Exact names insert directly without opening the picker.
local select_calls = 0
local original_select = vim.ui.select
vim.ui.select = function()
  select_calls = select_calls + 1
end
local exact_line = new_code_line()
vim.cmd("Pico8InsertGlyph left")
wait_for(function()
  return current_line(exact_line) == expected_left
end, "exact name insertion did not insert left")
vim.ui.select = original_select
assert_true(select_calls == 0, "exact name insertion opened the picker")

local logo_line = new_code_line()
vim.cmd("Pico8InsertGlyph logo")
wait_for(function()
  return current_line(logo_line) == logo.text
end, "custom glyph name insertion did not insert the custom text")

-- Decimal and hex byte forms send the byte directly.
for _, form in ipairs({ "139", "0x8b", "0X8B" }) do
  local lnum = new_code_line()
  vim.cmd("Pico8InsertGlyph " .. form)
  wait_for(function()
    return current_line(lnum) == expected_left
  end, "byte form " .. form .. " did not insert 0x8b")
end

-- Invalid bytes are rejected before workspace/executeCommand.
local exec_counts, restore_exec = count_requests(client, "workspace/executeCommand")
local invalid_messages = capture_notifications(function()
  vim.cmd("Pico8InsertGlyph 256")
  vim.cmd("Pico8InsertGlyph -1")
  vim.cmd("Pico8InsertGlyph 0x100")
end)
restore_exec()
assert_true(exec_counts.sync == 0, "an invalid byte reached workspace/executeCommand")
assert_true(#invalid_messages == 3, "invalid byte forms did not each report an error")
for _, message in ipairs(invalid_messages) do
  assert_true(
    message.message:find("between 0 and 255", 1, true) ~= nil,
    "invalid byte error was not clear: " .. tostring(message.message)
  )
end

-- A search term opens a filtered picker. The position-filtered response must
-- not replace the full cached catalog used by Shift maps.
local function entry_matches(item, term)
  term = term:lower()
  local fields = {
    item.name,
    item.description,
    item.byte and string.format("0x%02x", item.byte) or nil,
    item.byte and tostring(item.byte) or nil,
  }
  for i = 1, 4 do
    local field = fields[i]
    if type(field) == "string" and field:lower():find(term, 1, true) then
      return true
    end
  end
  return false
end

local before_entries = cache.entries
local before_control = cache.by_byte[0x0e]
assert_true(before_control ~= nil, "full cache has no control entry before the picker")
local picked
select_calls = 0
vim.ui.select = function(items, options, _)
  select_calls = select_calls + 1
  picked = { items = items, prompt = options.prompt }
end
exec_counts, restore_exec = count_requests(client, "workspace/executeCommand")
vim.cmd("Pico8InsertGlyph butt")
restore_exec()
vim.ui.select = original_select
assert_true(select_calls == 1, "search term did not open the picker")
assert_true(#picked.items > 0, "search picker was empty")
for _, item in ipairs(picked.items) do
  assert_true(entry_matches(item, "butt"), "picker item did not match the search term: " .. vim.inspect(item))
end
assert_true(exec_counts.sync == 0, "search picker inserted a glyph before selection")
assert_true(cache.entries == before_entries, "picker replaced the full cached catalog")
assert_true(cache.by_byte[0x0e] == before_control, "picker removed a control entry from the cache")

-- Byte representations are searchable too ("0x8b" contains "8b").
picked = nil
vim.ui.select = function(items)
  picked = items
end
vim.cmd("Pico8InsertGlyph 8b")
vim.ui.select = original_select
assert_true(picked ~= nil and #picked > 0, "hex substring did not open a filtered picker")
local has_left = false
for _, item in ipairs(picked) do
  if item.name == "left" then
    has_left = true
  end
end
assert_true(has_left, "hex substring filter did not include left")

-- A search with no matches reports and does not open an empty picker.
select_calls = 0
vim.ui.select = function()
  select_calls = select_calls + 1
end
local no_match_messages = capture_notifications(function()
  vim.cmd("Pico8InsertGlyph zzzzz")
end)
vim.ui.select = original_select
assert_true(select_calls == 0, "no-match search opened a picker")
assert_true(#no_match_messages == 1, "no-match search did not report once")
assert_true(
  no_match_messages[1].message:find("no P8SCII glyphs match", 1, true) ~= nil,
  "no-match search did not explain the failure"
)

-- A failed cold lookup falls back to the literal key, warns once, and does not
-- retry on the next keypress. An explicit prefetch can recover.
glyphs.reset()
local original_sync = client.request_sync
local glyph_requests = 0
client.request_sync = function(self, method, ...)
  if method == "pico8/glyphs" then
    glyph_requests = glyph_requests + 1
    return nil, "test timeout"
  end
  return original_sync(self, method, ...)
end
local fallback_line = new_code_line()
local fallback_messages = capture_notifications(function()
  feed("iL")
  feed("iL")
end)
client.request_sync = original_sync
assert_true(current_line(fallback_line) == "LL", "failed lookup did not fall back to literal letters")
assert_true(glyph_requests == 1, "failed lookup retried on every keypress")
assert_true(#fallback_messages == 1, "failed lookup did not warn exactly once")
assert_true(
  fallback_messages[1].message:find("fall back", 1, true) ~= nil,
  "failed lookup warning did not mention the fallback"
)
glyphs.prefetch(client, bufnr)
wait_cache(bufnr)

-- Replace mode returns the literal key without a request.
glyphs.reset()
local replace_counts, restore_replace = count_requests(client, "pico8/glyphs")
local replace_line = new_code_line("abcdef")
vim.api.nvim_win_set_cursor(0, { replace_line, 0 })
feed("RL")
wait_for(function()
  return current_line(replace_line) == "Lbcdef"
end, "replace mode did not keep a literal key")
assert_true(replace_counts.sync == 0, "replace mode requested the catalog")
restore_replace()

-- A non-modifiable buffer returns an empty string without a request.
glyphs.reset()
local readonly_counts, restore_readonly = count_requests(client, "pico8/glyphs")
vim.bo[bufnr].modifiable = false
local readonly_mapping = vim.fn.maparg("L", "i", false, true)
local readonly_result
vim.api.nvim_buf_call(bufnr, function()
  readonly_result = readonly_mapping.callback()
end)
vim.bo[bufnr].modifiable = true
assert_true(readonly_result == "", "read-only buffer did not return an empty string")
assert_true(readonly_counts.sync == 0, "read-only buffer requested the catalog")
restore_readonly()

-- Without a client the mapping warns once and inserts literal letters.
glyphs.reset()
local probe = vim.api.nvim_create_buf(false, true)
vim.bo[probe].filetype = "pico8"
vim.api.nvim_buf_set_lines(probe, 0, -1, false, { "" })
require("pico_lsp").install_glyph_maps(probe)
local missing_messages = capture_notifications(function()
  vim.api.nvim_buf_call(probe, function()
    feed("iA")
    feed("iA")
  end)
end)
assert_true(vim.api.nvim_buf_get_lines(probe, 0, -1, false)[1] == "AA", "missing client did not fall back")
assert_true(#missing_messages == 1, "missing client did not warn exactly once")
assert_true(
  missing_messages[1].message:find("no pico_lsp client", 1, true) ~= nil,
  "missing client warning was not clear"
)
vim.api.nvim_buf_delete(probe, { force = true })

-- A decoded PNG is read-only and must not prefetch the catalog.
glyphs.reset()
local png_fixture = root .. "/tests/fixtures/smoke.p8.png"
if vim.fn.filereadable(png_fixture) == 1 then
  vim.cmd("Pico8OpenPng " .. vim.fn.fnameescape(png_fixture))
  wait_for(function()
    local png_buf = vim.api.nvim_get_current_buf()
    return vim.b[png_buf].pico8_virtual_cart == true
      and #vim.lsp.get_clients({ name = "pico_lsp", bufnr = png_buf }) > 0
  end, "PNG cart did not open with a client")
  local png_buf = vim.api.nvim_get_current_buf()
  vim.wait(300, function()
    return false
  end)
  assert_true(glyphs.cache_for(png_buf) == nil, "read-only PNG prefetched the glyph catalog")
  vim.api.nvim_set_current_buf(bufnr)
end

print("nvim glyphs: ok")
vim.cmd("qa!")
