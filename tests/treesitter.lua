-- Headless tests for the M34 Tree-sitter installer.
--
-- Run through tests/run.sh, which sets an isolated XDG_DATA_HOME so the user's
-- parser and query directories are never touched.

local root = assert(vim.env.PICO8_NVIM_ROOT, "PICO8_NVIM_ROOT is not set")
vim.opt.runtimepath:append(root)
vim.cmd("filetype plugin on")

local function fail(message)
  vim.api.nvim_err_writeln("pico8.nvim treesitter: " .. message)
  vim.cmd("cquit 1")
end

local function assert_true(value, message)
  if not value then
    fail(message)
  end
end

local function assert_nil(value, message)
  if value ~= nil then
    fail(message .. ": expected nil, got " .. vim.inspect(value))
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

local function read_bytes(path)
  local fd, err = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = ""
  if stat and stat.size and stat.size > 0 then
    data, err = vim.uv.fs_read(fd, stat.size, 0)
  end
  vim.uv.fs_close(fd)
  if not data then
    return nil, err
  end
  return data
end

local function write_script(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
end

local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function count_runtimepath(site)
  local count = 0
  local wanted = normalize(site)
  for _, entry in ipairs(vim.split(vim.o.runtimepath, ",", { plain = true })) do
    local expanded = vim.fn.expand(entry)
    if expanded ~= "" and vim.fs.normalize(expanded) == wanted then
      count = count + 1
    end
  end
  return count
end

local function find_compiler()
  local configured = vim.env.CC
  if configured and configured ~= "" and vim.fn.executable(configured) == 1 then
    return configured
  end
  for _, candidate in ipairs({ "cc", "clang" }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

-- Isolation -------------------------------------------------------------------

local xdg = vim.env.XDG_DATA_HOME
if not xdg or xdg == "" then
  fail("XDG_DATA_HOME must be set to an isolated directory")
end
local data = normalize(vim.fn.stdpath("data"))
if data:find(normalize(xdg), 1, true) ~= 1 then
  fail("stdpath('data') is not under XDG_DATA_HOME: " .. data)
end
local site = data .. "/site"
if vim.fn.isdirectory(site) == 1 then
  vim.fn.delete(site, "rf")
end

if vim.fn.has("win32") == 1 then
  print("SKIP: Tree-sitter installer compilation is not covered on Windows")
  vim.cmd("qall!")
  return
end

local compiler = find_compiler()
if not compiler then
  print("SKIP: no C compiler is available for the Tree-sitter installer test")
  vim.cmd("qall!")
  return
end
vim.env.CC = compiler

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local treesitter = require("pico_lsp.treesitter")
local source = root .. "/vendor/tree-sitter-pico8"
local site_was_present = count_runtimepath(site) > 0

assert_true(vim.fn.exists(":Pico8InstallParser") == 2, ":Pico8InstallParser is not registered")

-- Source discovery ------------------------------------------------------------

local resolved, source_err = treesitter.source()
assert_nil(source_err, "default source discovery failed")
assert_true(
  normalize(resolved) == normalize(source),
  "default source is not the vendored grammar: " .. tostring(resolved)
)

-- Compiler fallback reaches clang when cc is unavailable ----------------------

local saved_path = vim.env.PATH
local compiler_target = vim.fn.exepath(compiler)
if compiler_target ~= "" then
  local bin = tmp .. "/compiler-bin"
  vim.fn.mkdir(bin, "p")
  pcall(vim.uv.fs_symlink, compiler_target, bin .. "/clang")
  if vim.fn.executable(bin .. "/clang") == 1 then
    vim.env.CC = nil
    vim.env.PATH = bin
    local fallback, fallback_err = treesitter.compiler()
    assert_true(fallback == "clang", "compiler fallback did not reach clang: " .. tostring(fallback_err))
  end
end
vim.env.PATH = saved_path
vim.env.CC = compiler

-- Write failures name the destination ----------------------------------------

vim.fn.mkdir(site, "p")
vim.fn.writefile({ "not a directory" }, site .. "/parser")
local result, err = treesitter.install()
assert_nil(result, "install unexpectedly succeeded with a file at the parser directory")
assert_contains(err, site .. "/parser", "write failure does not name the destination")
vim.fn.delete(site .. "/parser")

-- First install ---------------------------------------------------------------

result, err = treesitter.install()
if not result then
  fail("first install failed: " .. tostring(err))
end
assert_true(result.built == true, "first install did not build the parser")
assert_true(result.up_to_date == false, "first install claimed to be up to date")
assert_true(result.reload_required == false, "first install asked for a restart")
assert_true(result.queries_copied == 3, "first install did not copy all three queries")
assert_true(
  result.runtimepath_added == (not site_was_present),
  "runtimepath_added does not match the starting runtimepath"
)
assert_true(vim.fn.filereadable(result.parser_path) == 1, "parser file is missing")
assert_true(count_runtimepath(site) == 1, "site is not on runtimepath exactly once")

for _, name in ipairs({ "highlights.scm", "indents.scm", "textobjects.scm" }) do
  local installed = result.query_dir .. "/" .. name
  assert_true(vim.fn.filereadable(installed) == 1, "query file is missing: " .. installed)
  assert_true(read_bytes(installed) == read_bytes(source .. "/queries/" .. name), "query bytes differ: " .. name)
end

local added, add_err = vim.treesitter.language.add("pico8", { path = result.parser_path })
assert_true(added == true, "the installed parser did not register: " .. tostring(add_err))

-- Start highlighting on a cart -------------------------------------------------

vim.cmd("edit! " .. vim.fn.fnameescape(root .. "/tests/fixtures/smoke.p8"))
assert_true(vim.bo.filetype == "pico8", "smoke fixture did not get filetype=pico8")

local started, start_err = pcall(vim.treesitter.start, 0, "pico8")
assert_true(started, "vim.treesitter.start failed: " .. tostring(start_err))
local parsed, parser_or_err = pcall(vim.treesitter.get_parser, 0, "pico8")
assert_true(parsed and parser_or_err, "the pico8 parser could not be loaded: " .. tostring(parser_or_err))
local tree_ok, tree_or_err = pcall(function()
  return parser_or_err:parse()
end)
assert_true(tree_ok and tree_or_err, "the pico8 parser could not parse the cart: " .. tostring(tree_or_err))
vim.treesitter.stop(0)

-- Idempotence -----------------------------------------------------------------

local messages = capture_notifications(function()
  vim.cmd("Pico8InstallParser")
end)
assert_true(#messages == 1, "the idempotent command did not send exactly one notification")
assert_true(messages[1].level == vim.log.levels.INFO, "the idempotent command did not use INFO")
assert_contains(messages[1].message, "up to date", "the second run did not report up to date")
assert_contains(messages[1].message, result.parser_path, "the second run does not name the parser path")
assert_contains(
  messages[1].message,
  'vim.treesitter.start(0, "pico8")',
  "the second run does not offer the start command on a pico8 buffer"
)
assert_true(count_runtimepath(site) == 1, "repeated installs duplicated site on runtimepath")

-- Query drift is repaired without rebuilding ---------------------------------

local highlight = result.query_dir .. "/highlights.scm"
vim.fn.writefile({ "; drifted" }, highlight)
result, err = treesitter.install()
if not result then
  fail("query repair failed: " .. tostring(err))
end
assert_true(result.built == false, "query repair unexpectedly rebuilt the parser")
assert_true(result.queries_copied == 1, "query repair did not copy the changed query")
assert_true(
  read_bytes(highlight) == read_bytes(source .. "/queries/highlights.scm"),
  "query repair did not restore the source bytes"
)

-- Forced rebuild --------------------------------------------------------------

result, err = treesitter.install({ force = true })
if not result then
  fail("forced rebuild failed: " .. tostring(err))
end
assert_true(result.built == true, "force did not rebuild the parser")
assert_true(result.reload_required == true, "force did not report that a restart is needed")
assert_true(
  vim.treesitter.language.add("pico8", { path = result.parser_path }) == true,
  "the forced parser did not stay loadable"
)

messages = capture_notifications(function()
  vim.cmd("Pico8InstallParser!")
end)
assert_true(#messages == 1, "the forced command did not send exactly one notification")
assert_contains(messages[1].message, "installed pico8 parser", "the forced command did not report a build")
assert_contains(messages[1].message, "restart Neovim", "the forced command did not ask for a restart")

local parser_path = result.parser_path
local parser_dir = vim.fs.dirname(parser_path)
local query_dir = treesitter.destinations().query_dir

-- Invalid source overrides ----------------------------------------------------

local saved_source = vim.g.pico8_treesitter_source
local saved_env = vim.env.PICO_LSP_TREE_SITTER

vim.g.pico8_treesitter_source = tmp .. "/missing-grammar"
messages = capture_notifications(function()
  vim.cmd("Pico8InstallParser")
end)
assert_true(#messages == 1, "the failing command did not send exactly one notification")
assert_true(messages[1].level == vim.log.levels.ERROR, "the failing command did not use ERROR")
assert_contains(messages[1].message, tmp .. "/missing-grammar", "the failing command does not name the source")

result, err = treesitter.install()
assert_nil(result, "install accepted a missing source directory")
assert_contains(err, tmp .. "/missing-grammar", "missing source error does not name the path")
assert_contains(err, "vim.g.pico8_treesitter_source", "missing source error does not name the global")
assert_contains(err, "PICO_LSP_TREE_SITTER", "missing source error does not name the environment")

local partial = tmp .. "/partial-grammar"
for _, relative in ipairs({
  "src/parser.c",
  "src/scanner.c",
  "queries/highlights.scm",
  "queries/textobjects.scm",
}) do
  local path = partial .. "/" .. relative
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "" }, path)
end
vim.g.pico8_treesitter_source = partial
result, err = treesitter.install()
assert_nil(result, "install accepted incomplete sources")
assert_contains(err, partial .. "/queries/indents.scm", "incomplete-source error does not name the missing file")

vim.g.pico8_treesitter_source = true
result, err = treesitter.install()
assert_nil(result, "install accepted a non-string global source")
assert_contains(err, "must be a directory path", "non-string source error is not actionable")

vim.g.pico8_treesitter_source = nil
vim.env.PICO_LSP_TREE_SITTER = tmp .. "/env-missing"
result, err = treesitter.install()
assert_nil(result, "install accepted a missing environment source")
assert_contains(err, tmp .. "/env-missing", "environment source error does not name the path")

vim.g.pico8_treesitter_source = source
vim.env.PICO_LSP_TREE_SITTER = tmp .. "/env-should-lose"
resolved, source_err = treesitter.source()
assert_true(
  normalize(resolved) == normalize(source),
  "the global source override did not win over the environment: " .. tostring(source_err)
)

vim.g.pico8_treesitter_source = saved_source
vim.env.PICO_LSP_TREE_SITTER = saved_env

-- Missing compiler ------------------------------------------------------------

local saved_cc = vim.env.CC
vim.env.CC = tmp .. "/missing-cc"
result, err = treesitter.install({ force = true })
assert_nil(result, "install accepted a missing compiler")
assert_contains(err, tmp .. "/missing-cc", "missing compiler error does not name $CC")
assert_contains(err, "$CC", "missing compiler error does not mention $CC")
assert_contains(err, "docs/install.md#tree-sitter", "missing compiler error has no manual fallback")

-- Failed forced rebuild leaves the previous parser --------------------------

local before = read_bytes(parser_path)
local before_stat = vim.uv.fs_stat(parser_path)
local queries_before = {}
for _, name in ipairs({ "highlights.scm", "indents.scm", "textobjects.scm" }) do
  queries_before[name] = read_bytes(query_dir .. "/" .. name)
end
local fail_cc = tmp .. "/fail-cc.sh"
write_script(fail_cc, {
  "#!/bin/sh",
  "echo 'fake compiler exploded' >&2",
  "exit 1",
})
vim.env.CC = fail_cc

result, err = treesitter.install({ force = true })
assert_nil(result, "a failing compiler produced a successful install")
assert_contains(err, "fake compiler exploded", "compiler stderr is missing from the error")
assert_contains(err, "exit code 1", "compiler failure does not report the exit code")
assert_true(read_bytes(parser_path) == before, "a failed rebuild changed the parser bytes")
local after_stat = vim.uv.fs_stat(parser_path)
assert_true(after_stat ~= nil, "a failed rebuild removed the parser")
assert_true(
  after_stat.mtime.sec == before_stat.mtime.sec and (after_stat.mtime.nsec or 0) == (before_stat.mtime.nsec or 0),
  "a failed rebuild changed the parser mtime"
)
assert_true(#vim.fn.glob(parser_dir .. "/.pico8*", false, true) == 0, "a failed rebuild left a temporary parser")
for _, name in ipairs({ "highlights.scm", "indents.scm", "textobjects.scm" }) do
  assert_true(
    read_bytes(query_dir .. "/" .. name) == queries_before[name],
    "a failed rebuild changed query " .. name
  )
end
assert_true(
  vim.treesitter.language.add("pico8", { path = parser_path }) == true,
  "the previous parser is no longer loadable"
)

-- Compiler output is bounded --------------------------------------------------

local tail_cc = tmp .. "/tail-cc.sh"
local tail_lines = { "#!/bin/sh", "echo 'start-marker' >&2" }
for index = 1, 100 do
  tail_lines[#tail_lines + 1] = string.format("echo 'ERR-%03d' >&2", index)
end
tail_lines[#tail_lines + 1] = "echo 'end-marker' >&2"
tail_lines[#tail_lines + 1] = "exit 1"
write_script(tail_cc, tail_lines)
vim.env.CC = tail_cc

result, err = treesitter.install({ force = true })
assert_nil(result, "the long-output compiler produced a successful install")
assert_contains(err, "end-marker", "the stderr tail did not include the end of the output")
assert_not_contains(err, "start-marker", "the stderr tail was not bounded")

-- Compiler timeout ------------------------------------------------------------

local slow_cc = tmp .. "/slow-cc.sh"
write_script(slow_cc, {
  "#!/bin/sh",
  "exec sleep 5",
})
vim.env.CC = slow_cc

result, err = treesitter.install({ force = true, timeout_ms = 100 })
assert_nil(result, "the slow compiler produced a successful install")
assert_contains(err, "timed out", "compiler timeout is not reported")
assert_contains(err, "100 ms", "compiler timeout does not report the limit")
assert_true(#vim.fn.glob(parser_dir .. "/.pico8*", false, true) == 0, "a timeout left a temporary parser")

-- Registration failure names the parser and Neovim version ------------------

vim.env.CC = saved_cc
local real_add = vim.treesitter.language.add
vim.treesitter.language.add = function()
  return nil, "registration boom"
end
result, err = treesitter.install()
assert_nil(result, "a failed registration produced a successful install")
assert_contains(err, parser_path, "registration failure does not name the parser path")
assert_contains(err, "Neovim", "registration failure does not name Neovim")
assert_contains(err, "registration boom", "registration failure does not include the underlying error")
vim.treesitter.language.add = real_add

-- Recovery after restoring the environment -----------------------------------

result, err = treesitter.install()
if not result then
  fail("install did not recover after the failure cases: " .. tostring(err))
end
assert_true(result.up_to_date == true, "recovery install unexpectedly rebuilt the parser")
assert_true(
  vim.treesitter.language.add("pico8", { path = result.parser_path }) == true,
  "the recovered parser is not loadable"
)

-- A disabled helper still exposes the independent installer command ----------

vim.api.nvim_del_user_command("Pico8InstallParser")
require("pico_lsp").setup({ disable = true })
assert_true(
  vim.fn.exists(":Pico8InstallParser") == 2,
  "a disabled setup did not register :Pico8InstallParser"
)

print("pico8.nvim treesitter installer tests passed")
vim.cmd("qall!")
