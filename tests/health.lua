-- Headless test for M32 `:checkhealth pico_lsp`.
--
-- Covers the report sections, a real attached cart/include, missing/function/
-- malformed commands, binary and version failures, server log paths,
-- inlay/code-lens warnings, lua_ls conflicts, stale/disabled helper states, and
-- the read-only guarantee.
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
  vim.api.nvim_err_writeln("pico8.nvim health: " .. message)
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

local function clients(bufnr)
  return vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })
end

local function wait_for(predicate, message, timeout)
  if not vim.wait(timeout or 10000, predicate, 25) then
    fail(message)
  end
end

local function assert_contains(text, needle, message)
  if type(text) ~= "string" or text:find(needle, 1, true) == nil then
    fail(message .. ": missing " .. vim.inspect(needle) .. " in\n" .. tostring(text))
  end
end

local function assert_not_contains(text, needle, message)
  if type(text) == "string" and text:find(needle, 1, true) ~= nil then
    fail(message .. ": unexpected " .. vim.inspect(needle) .. " in\n" .. text)
  end
end

-- :checkhealth opens its own buffer before running the module. Capture that
-- buffer, then restore the caller's window/tab so later checks see the cart.
local function capture_health()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_tab = vim.api.nvim_get_current_tabpage()
  local original_win = vim.api.nvim_get_current_win()

  vim.cmd("checkhealth pico_lsp")
  local health_buf = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(health_buf, 0, -1, false), "\n")

  if vim.api.nvim_get_current_tabpage() ~= original_tab then
    pcall(vim.cmd, "tabclose")
  end
  if vim.api.nvim_buf_is_valid(health_buf) then
    pcall(vim.api.nvim_buf_delete, health_buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(original_win) then
    pcall(vim.api.nvim_set_current_win, original_win)
  end
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  return text
end

-- Split reports resolve the cart in the current tab before looking at the
-- previous tab.
local function capture_health_split()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_tab = vim.api.nvim_get_current_tabpage()
  local original_win = vim.api.nvim_get_current_win()

  vim.cmd("vertical checkhealth pico_lsp")
  local health_buf = vim.api.nvim_get_current_buf()
  local health_win = vim.api.nvim_get_current_win()
  local text = table.concat(vim.api.nvim_buf_get_lines(health_buf, 0, -1, false), "\n")

  if vim.api.nvim_get_current_tabpage() ~= original_tab then
    pcall(vim.cmd, "tabclose")
  elseif health_win ~= original_win and vim.api.nvim_win_is_valid(health_win) then
    pcall(vim.cmd, "close")
  end
  if vim.api.nvim_buf_is_valid(health_buf) then
    pcall(vim.api.nvim_buf_delete, health_buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(original_win) then
    pcall(vim.api.nvim_set_current_win, original_win)
  end
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  return text
end

local function section(text, name)
  local header = "pico_lsp: " .. name .. " ~"
  local lines = vim.split(text, "\n", { plain = true })
  local result = {}
  local inside = false
  for _, line in ipairs(lines) do
    if line == header then
      inside = true
    elseif inside and line:match("^pico_lsp: .+ ~$") then
      break
    elseif inside then
      result[#result + 1] = line
    end
  end
  return table.concat(result, "\n")
end

local function assert_section(text, name, needle, message)
  assert_contains(section(text, name), needle, message)
end

local function snapshot_buffers()
  local snapshot = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "health://" then
        snapshot[bufnr] = {
          name = name,
          loaded = vim.api.nvim_buf_is_loaded(bufnr),
          lines = vim.api.nvim_buf_is_loaded(bufnr)
              and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            or nil,
          changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
          modified = vim.bo[bufnr].modified,
        }
      end
    end
  end
  return snapshot
end

local function assert_buffer_snapshot(before, label)
  local after = snapshot_buffers()
  for bufnr, entry in pairs(before) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      fail(label .. ": buffer " .. tostring(bufnr) .. " disappeared")
    end
    if vim.api.nvim_buf_get_name(bufnr) ~= entry.name then
      fail(label .. ": buffer " .. tostring(bufnr) .. " changed name")
    end
    if entry.loaded then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if not vim.deep_equal(lines, entry.lines) then
        fail(label .. ": buffer " .. tostring(bufnr) .. " changed text")
      end
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= entry.changedtick then
      fail(label .. ": buffer " .. tostring(bufnr) .. " changed tick")
    end
    if vim.bo[bufnr].modified ~= entry.modified then
      fail(label .. ": buffer " .. tostring(bufnr) .. " changed modified state")
    end
  end
  for bufnr in pairs(after) do
    if not before[bufnr] then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "health://" then
        fail(label .. ": health created an unexpected buffer: " .. name)
      end
    end
  end
end

local function data_tree()
  local data = vim.fn.stdpath("data")
  local entries = {}
  local function walk(directory, prefix)
    local scan = vim.uv.fs_scandir(directory)
    if not scan then
      return
    end
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      local path = directory .. "/" .. name
      local stat = vim.uv.fs_lstat(path)
      local kind = stat and stat.type or "unknown"
      entries[#entries + 1] = prefix .. name .. ":" .. kind
      if kind == "directory" then
        walk(path, prefix .. name .. "/")
      end
    end
  end
  walk(data, "")
  table.sort(entries)
  return entries
end

local function side_effect_snapshot()
  return {
    commands = {
      Pico8CartInfo = vim.fn.exists(":Pico8CartInfo"),
      Pico8Tabs = vim.fn.exists(":Pico8Tabs"),
      Pico8OpenPng = vim.fn.exists(":Pico8OpenPng"),
    },
    autocmds = {
      cart = vim.fn.exists("#pico_lsp_cart#LspAttach"),
      helper = vim.fn.exists("#pico_lsp_helper#LspAttach"),
    },
  }
end

-- Read-only with no helper and no client --------------------------------------

local before_buffers = snapshot_buffers()
local before_data = data_tree()
local before_side_effects = side_effect_snapshot()
local before_clients = vim.lsp.get_clients({ name = "pico_lsp" })
local text = capture_health()

if #vim.lsp.get_clients({ name = "pico_lsp" }) ~= #before_clients then
  fail("health started or stopped a pico_lsp client")
end
assert_buffer_snapshot(before_buffers, "read-only check")
if not vim.deep_equal(data_tree(), before_data) then
  fail("health changed the stdpath('data') tree")
end
if not vim.deep_equal(side_effect_snapshot(), before_side_effects) then
  fail("health registered commands or autocmds")
end
if package.loaded["pico_lsp.cart"] ~= nil then
  fail("health loaded the pico_lsp.cart module")
end

-- Tree-sitter parser status uses language.add's return value ------------------

local real_language_add = vim.treesitter.language.add
vim.treesitter.language.add = function()
  return nil, "No parser for language pico8"
end
text = capture_health()
local tree = section(text, "Tree-sitter")
assert_contains(tree, "not available", "absent parser was not reported as unavailable")
assert_not_contains(tree, "✅ OK pico8 Tree-sitter parser loads", "absent parser was reported as OK")
assert_contains(tree, "docs/install.md#tree-sitter", "absent parser has no install guidance")

vim.treesitter.language.add = function()
  return true
end
text = capture_health()
tree = section(text, "Tree-sitter")
assert_contains(tree, "✅ OK pico8 Tree-sitter parser loads", "available parser was not reported as OK")
vim.treesitter.language.add = real_language_add

-- A missing shipped config is a warning, not a crash -------------------------

local real_get_runtime_file = vim.api.nvim_get_runtime_file
local saved_user_config = vim.lsp.config._configs["pico_lsp"]
vim.lsp.config._configs["pico_lsp"] = nil
vim.api.nvim_get_runtime_file = function(pattern, all)
  if pattern == "lsp/pico_lsp.lua" then
    return {}
  end
  return real_get_runtime_file(pattern, all)
end
text = capture_health()
assert_section(text, "Configuration", "missing", "missing shipped config was not reported")
assert_section(text, "Configuration", "not on 'runtimepath'", "missing config advice is missing")

vim.lsp.config._configs["pico_lsp"] = { settings = {} }
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "partial config without cmd was not an error")
assert_section(text, "Configuration", "cmd must be a non-empty list", "partial config cmd error is missing")
vim.lsp.config._configs["pico_lsp"] = saved_user_config
vim.api.nvim_get_runtime_file = real_get_runtime_file

-- A malformed shipped config is a compile error, not a crash -----------------

local bad_rtp = tmp .. "/bad-rtp"
write(bad_rtp .. "/lsp/pico_lsp.lua", { "this is not valid lua" })
local saved_rtp = vim.o.runtimepath
vim.opt.runtimepath:prepend(bad_rtp)
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "malformed shipped config was not an error")
assert_section(text, "Configuration", "could not be compiled", "malformed config text is missing")
vim.o.runtimepath = saved_rtp

for _, name in ipairs({
  "Neovim",
  "Configuration",
  "Server binary",
  "Running clients",
  "Client features",
  "Included .lua buffers",
  "Helper",
  "Tree-sitter",
}) do
  assert_contains(text, "pico_lsp: " .. name .. " ~", "missing health section " .. name)
end
assert_section(text, "Neovim", "✅ OK", "Neovim is not reported as supported")
assert_section(text, "Configuration", "vim.lsp.config['pico_lsp']", "config check is missing")
assert_section(text, "Server binary", "server version:", "server version is missing")
assert_section(text, "Running clients", "no running pico_lsp clients", "client check is missing")
assert_section(text, "Client features", "no pico8 cart is active", "feature check did not skip the health buffer")
assert_section(text, "Included .lua buffers", "no helper-managed", "include check is missing")
assert_section(text, "Helper", "setup() has not run", "setup state is missing")
assert_not_contains(section(text, "Helper"), "helper commands are missing", "no-helper run warned about commands")
assert_section(text, "Tree-sitter", "pico8 filetype detection is registered", "filetype detection is missing")
assert_section(text, "Tree-sitter", "pico8 Tree-sitter parser", "parser status is missing")

-- Config resolution failures are errors ----------------------------------------

local real_lsp_config = vim.lsp.config
vim.lsp.config = setmetatable({}, {
  __index = function()
    error("simulated config failure")
  end,
})
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "config resolution failure was not an error")
assert_section(text, "Configuration", "could not be resolved", "config resolution failure text is missing")
vim.lsp.config = real_lsp_config

-- A real cart and managed include --------------------------------------------

local project = tmp .. "/project"
local cart = project .. "/cart.p8"
local lib = project .. "/lib.lua"
write(cart, {
  "pico-8 cartridge // pico-8.com",
  "version 42",
  "__lua__",
  '#include "lib.lua"',
  "function _init()",
  " local x = 1",
  "end",
})
write(lib, { "function lib() end" })

vim.lsp.config("pico_lsp", {
  cmd = { binary },
  settings = { pico8 = { inlayHints = true, limits = { codeLens = true } } },
})
require("pico_lsp").setup()

local cart_buf = edit(cart)
wait_for(function()
  return #clients(cart_buf) > 0
end, "pico-lsp did not attach to the cart")

local lib_buf = edit(lib)
wait_for(function()
  return vim.b[lib_buf].pico8_cart ~= nil and #clients(lib_buf) > 0
end, "the helper did not attach the included .lua buffer")

vim.api.nvim_set_current_buf(cart_buf)
text = capture_health()

if text:find("- ❌ ERROR", 1, true) ~= nil then
  fail("healthy attached run reported an error:\n" .. text)
end
assert_section(text, "Neovim", "✅ OK", "Neovim is not reported as supported")
assert_section(text, "Configuration", "✅ OK", "config check did not pass")
assert_section(text, "Server binary", "server version:", "server version is missing")
assert_section(text, "Server binary", "executable:", "resolved executable is missing")
assert_section(text, "Running clients", "current buffer attached: yes", "current cart is not reported attached")
assert_section(text, "Running clients", "root=" .. vim.fs.normalize(project), "client root is missing")
assert_section(text, "Running clients", "inlayHints=true", "client settings are missing")
assert_section(text, "Running clients", "settings source:", "settings source is missing")
assert_section(text, "Client features", "pico8.inlayHints = true", "inlay setting is missing")
assert_section(text, "Client features", "inlay hints client-side: enabled", "inlay client state is missing")
assert_section(text, "Client features", "pico8.limits.codeLens = true", "code-lens setting is missing")
if is_012 then
  assert_section(text, "Client features", "code lens client-side: enabled", "code-lens client state is missing")
else
  assert_section(text, "Client features", "refresh-based engine", "0.11 code-lens mode is missing")
end
assert_section(text, "Included .lua buffers", vim.fs.normalize(lib), "include path is missing")
assert_section(text, "Included .lua buffers", vim.fs.normalize(cart), "owning cart path is missing")
assert_section(text, "Included .lua buffers", "PICO-8 targets", "include comments are missing")
assert_section(text, "Helper", "require('pico_lsp').setup() has run", "setup state is missing")
assert_section(text, "Helper", "helper is enabled", "helper state is missing")
assert_section(text, "Helper", "all expected helper commands are registered", "helper commands are missing")

-- Missing binary --------------------------------------------------------------

local missing = project .. "/missing-pico-lsp"
vim.lsp.config("pico_lsp", { cmd = { missing } })
text = capture_health()
assert_section(text, "Server binary", "❌ ERROR", "missing binary was not an error")
assert_section(text, "Server binary", "executable not found", "missing binary text is missing")
assert_section(text, "Server binary", "go install", "missing binary has no install step")
assert_section(text, "Server binary", "releases", "missing binary has no release pointer")
local missing_client = clients(cart_buf)[1]
if missing_client then
  assert_section(
    text,
    "Server binary",
    "client " .. missing_client.id .. " server version",
    "missing binary hid the running client version"
  )
end
vim.lsp.config("pico_lsp", { cmd = { binary } })

-- Function-valued command is reported but never called ------------------------

local called = false
vim.lsp.config("pico_lsp", {
  cmd = function()
    called = true
    return { binary }
  end,
})
text = capture_health()
assert_section(text, "Configuration", "user-supplied function", "function cmd source is missing")
assert_section(text, "Server binary", "user-supplied function", "function cmd report is missing")
assert_section(text, "Server binary", "skipping executable", "function cmd probe was not skipped")
assert_not_contains(section(text, "Server binary"), "executable not found", "function cmd produced a missing-binary error")
if called then
  fail("health called the cmd function")
end
vim.lsp.config("pico_lsp", { cmd = { binary } })

-- Malformed command shapes are errors, not crashes --------------------------

vim.lsp.config("pico_lsp", { cmd = binary })
text = capture_health()
assert_section(text, "Configuration", "bare string", "bare-string cmd did not warn")
assert_not_contains(section(text, "Configuration"), "❌ ERROR", "bare-string cmd was treated as an error")
vim.lsp.config("pico_lsp", { cmd = { binary } })

vim.lsp.config("pico_lsp", { cmd = {} })
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "empty cmd was not an error")
assert_section(text, "Configuration", "empty list", "empty cmd text is missing")
vim.lsp.config("pico_lsp", { cmd = { binary } })

vim.lsp.config("pico_lsp", { cmd = { 42 } })
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "non-string cmd entry was not an error")
assert_section(text, "Configuration", "cmd[1]", "non-string cmd entry index is missing")
vim.lsp.config("pico_lsp", { cmd = { binary } })

vim.lsp.config("pico_lsp", { cmd = false })
text = capture_health()
assert_section(text, "Configuration", "❌ ERROR", "false cmd was not an error")
assert_section(text, "Configuration", "cmd must be a non-empty list", "false cmd text is missing")
vim.lsp.config("pico_lsp", { cmd = { binary } })

-- A configured server log path is reported -----------------------------------

local server_log = project .. "/pico-lsp.log"
vim.lsp.config("pico_lsp", { cmd = { binary, "--log-file", server_log } })
text = capture_health()
assert_section(text, "Server binary", "server log: " .. server_log, "configured server log is missing")
vim.lsp.config("pico_lsp", { cmd = { binary } })

-- Non-executable configured files are warnings ------------------------------

local not_executable = project .. "/pico-lsp-not-executable"
write(not_executable, { "#!/bin/sh", "exit 0" })
vim.lsp.config("pico_lsp", { cmd = { not_executable } })
text = capture_health()
assert_section(text, "Server binary", "⚠️ WARNING", "non-executable path did not warn")
assert_section(text, "Server binary", "not an executable file", "non-executable path text is missing")
vim.lsp.config("pico_lsp", { cmd = { binary } })

-- Failed version probes warn with the raw output ------------------------------

local real_system = vim.system
vim.system = function()
  return {
    wait = function()
      return { code = 1, signal = 0, stdout = "", stderr = "probe failed" }
    end,
  }
end
text = capture_health()
assert_section(text, "Server binary", "⚠️ WARNING", "non-zero version probe did not warn")
assert_section(text, "Server binary", "exit code 1", "non-zero version probe status is missing")
assert_section(text, "Server binary", "probe failed", "non-zero version probe output is missing")

vim.system = function()
  return {
    wait = function()
      return { code = nil, signal = 15, stdout = "", stderr = "" }
    end,
  }
end
text = capture_health()
assert_section(text, "Server binary", "⚠️ WARNING", "timed-out version probe did not warn")
assert_section(text, "Server binary", "signal 15", "timed-out version probe status is missing")
vim.system = real_system

-- A running client with a different version warns ----------------------------

local version_client = clients(cart_buf)[1]
if not version_client or not version_client.server_info then
  fail("no client for the version-mismatch check")
end
local saved_server_version = version_client.server_info.version
version_client.server_info.version = "v0.0.1-health-test"
text = capture_health()
assert_section(text, "Server binary", "⚠️ WARNING", "version mismatch did not warn")
assert_section(text, "Server binary", "server version mismatch", "version mismatch text is missing")
version_client.server_info.version = saved_server_version

-- Inlay hints warning ---------------------------------------------------------

require("pico_lsp.client").setup({ inlay_hints = false, codelens = true })
local inlay_ok, inlay_err = pcall(vim.lsp.inlay_hint.enable, false, { bufnr = cart_buf })
if not inlay_ok then
  fail("could not disable inlay hints: " .. tostring(inlay_err))
end
text = capture_health()
assert_section(text, "Client features", "pico8.inlayHints = true", "inlay setting disappeared")
assert_section(text, "Client features", "inlay hints client-side: disabled", "inlay state is not disabled")
assert_section(text, "Client features", "⚠️ WARNING", "disabled inlay hints did not warn")
assert_section(text, "Client features", "setup({ inlay_hints = true })", "inlay advice is missing")
pcall(vim.lsp.inlay_hint.enable, true, { bufnr = cart_buf })
require("pico_lsp.client").setup({ inlay_hints = true, codelens = true })

-- Code lens: 0.12 has an enable state; 0.11 must not claim one ----------------

if is_012 then
  local client = clients(cart_buf)[1]
  if not client then
    fail("no client for the code lens check")
  end
  local saved_settings = client.settings

  -- Unset limits.codeLens still means the server default (true).
  client.settings = { pico8 = { inlayHints = true } }
  require("pico_lsp.client").setup({ codelens = false, inlay_hints = true })
  local lens_ok, lens_err = pcall(vim.lsp.codelens.enable, false, { bufnr = cart_buf })
  if not lens_ok then
    fail("could not disable code lens: " .. tostring(lens_err))
  end
  text = capture_health()
  assert_section(text, "Client features", "pico8.limits.codeLens = unset", "unset code-lens value is missing")
  assert_section(text, "Client features", "code lens client-side: disabled", "code lens is not disabled")
  assert_section(text, "Client features", "⚠️ WARNING", "unset code lens did not warn")
  assert_section(text, "Client features", "setup({ codelens = true })", "code-lens advice is missing")

  -- Explicit true must warn the same way.
  client.settings = { pico8 = { inlayHints = true, limits = { codeLens = true } } }
  text = capture_health()
  assert_section(text, "Client features", "pico8.limits.codeLens = true", "explicit code-lens value is missing")
  assert_section(text, "Client features", "code lens client-side: disabled", "explicit code lens is not disabled")
  assert_section(text, "Client features", "⚠️ WARNING", "explicit code lens did not warn")
  assert_section(text, "Client features", "setup({ codelens = true })", "explicit code-lens advice is missing")

  client.settings = saved_settings
  pcall(vim.lsp.codelens.enable, true, { bufnr = cart_buf })
  require("pico_lsp.client").setup({ codelens = true, inlay_hints = true })
else
  text = capture_health()
  assert_section(text, "Client features", "refresh-based engine", "0.11 code-lens mode is missing")
  assert_not_contains(
    section(text, "Client features"),
    "client-side code lens is disabled",
    "0.11 reported a toggle warning"
  )
end

-- Invalid setting values warn -------------------------------------------------

local settings_client = clients(cart_buf)[1]
if not settings_client then
  fail("no client for the invalid-settings check")
end
local saved_client_settings = settings_client.settings
settings_client.settings = {
  pico8 = {
    typeChecking = "loud",
    diagnostics = { mode = "sometimes" },
  },
}
text = capture_health()
assert_section(text, "Client features", "pico8.typeChecking has an invalid value", "invalid typeChecking did not warn")
assert_section(text, "Client features", "pico8.diagnostics.mode has an invalid value", "invalid diagnostics mode did not warn")
settings_client.settings = saved_client_settings

-- lua_ls conflict on a managed include ---------------------------------------

local original_get_clients = vim.lsp.get_clients
local fake_lua_ls = { name = "lua_ls", id = 987654, root_dir = project }
vim.lsp.get_clients = function(filter)
  local result = original_get_clients(filter)
  if filter and filter.bufnr == lib_buf then
    result = vim.list_extend({}, result)
    result[#result + 1] = fake_lua_ls
  end
  return result
end
local conflict_ok, conflict_err = pcall(function()
  local conflict_text = capture_health()
  local includes = section(conflict_text, "Included .lua buffers")
  assert_contains(includes, "lua_ls", "lua_ls is missing from the include report")
  assert_contains(includes, "pico_lsp", "pico_lsp is missing from the include report")
  assert_contains(includes, "unsupported", "the lua_ls conflict did not warn")
end)
vim.lsp.get_clients = original_get_clients
if not conflict_ok then
  fail(tostring(conflict_err))
end
if vim.lsp.get_client_by_id(987654) ~= nil then
  fail("the mocked lua_ls client was started")
end

-- A split report uses the cart in the current tab, not the previous tab ------

local other = tmp .. "/other.txt"
write(other, { "not a cart" })
vim.cmd("tabnew " .. vim.fn.fnameescape(other))
vim.cmd("tabprevious")
local split_text = capture_health_split()
assert_section(split_text, "Running clients", "current buffer attached: yes", "split report lost the current cart")
assert_section(split_text, "Client features", "pico8.inlayHints = true", "split report lost the cart features")
assert_not_contains(
  section(split_text, "Client features"),
  "no pico8 cart is active",
  "split report used the previous tab"
)
pcall(vim.cmd, "tabclose 2")

-- Missing helper commands warn while the helper is enabled --------------------

vim.api.nvim_del_user_command("Pico8OpenPng")
text = capture_health()
helper = section(text, "Helper")
assert_contains(helper, "helper commands are missing", "missing helper command did not warn")
assert_contains(helper, "Pico8OpenPng", "missing helper command name is absent")
assert_contains(helper, "⚠️ WARNING", "missing helper command did not produce a warning")
vim.api.nvim_create_user_command("Pico8OpenPng", function() end, {
  nargs = "?",
  complete = "file",
  desc = "test stub",
})

-- A global set after setup warns instead of claiming the helper is disabled ----

vim.g.pico_lsp_helper_disabled = 1
text = capture_health()
local stale_helper = section(text, "Helper")
assert_contains(stale_helper, "still active", "stale helper-disabled global is not reported")
assert_contains(stale_helper, "⚠️ WARNING", "stale helper-disabled global did not warn")
assert_not_contains(stale_helper, "helper is disabled", "stale global claimed the helper was disabled")
vim.g.pico_lsp_helper_disabled = nil

-- Disabled helper does not warn about missing commands -----------------------

require("pico_lsp").setup({ disable = true })
text = capture_health()
local helper = section(text, "Helper")
assert_contains(helper, "helper is disabled", "disabled helper is not reported")
assert_contains(helper, "setup({ disable = true })", "disabled helper source is missing")
assert_not_contains(helper, "helper commands are missing", "disabled helper warned about missing commands")
assert_not_contains(helper, "⚠️ WARNING", "disabled helper produced a warning")

-- A global read during setup is attributed to the global ----------------------

vim.g.pico_lsp_helper_disabled = 1
require("pico_lsp").setup()
text = capture_health()
helper = section(text, "Helper")
assert_contains(
  helper,
  "helper is disabled by vim.g.pico_lsp_helper_disabled",
  "global-before-setup disable source is missing"
)
vim.g.pico_lsp_helper_disabled = nil

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

print("pico8.nvim health: ok")
vim.cmd("qa!")
