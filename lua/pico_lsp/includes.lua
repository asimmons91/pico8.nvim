-- PICO-8 `#include` parsing and `gf`/`includeexpr` path resolution.
--
-- This module is independent of the helper and the LSP client so the PICO-8
-- ftplugin can use it without calling `require("pico_lsp").setup()`. The
-- resolver never reads the target file; a missing path is returned so Neovim
-- can report its normal `gf` error without creating a buffer.

local M = {}

local function normalize(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  local ok, normalized = pcall(vim.fs.normalize, absolute)
  if ok then
    return normalized
  end
  return absolute
end

local function is_absolute(path)
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
    return true
  end
  return path:match("^%a:[/\\]") ~= nil
end

local function is_virtual(name)
  return name:match("^pico8%-cart:") ~= nil
    or name:match("[/\\]pico8%-cart:[/\\]") ~= nil
    or name:match("[/\\]pico8%-cart:$") ~= nil
end

-- Vim globs and upward-searches 'path' entries. A directory containing these
-- characters cannot be represented reliably as a path entry, so use a
-- non-existent sentinel and let includeexpr resolve the target instead.
local PATH_META = "[%[%]*?$]"

local function no_lookup_path()
  if vim.fn.has("win32") == 1 then
    return "C:/pico8-nvim-no-raw-path-lookup"
  end
  return "/pico8-nvim-no-raw-path-lookup"
end

-- Format one directory for the 'path' option. Spaces, commas, semicolons, and
-- backslashes need escaping; glob and environment characters use the sentinel.
function M.path_value(directory)
  if type(directory) ~= "string" or directory == "" then
    return ""
  end
  if directory:find(PATH_META) ~= nil then
    return no_lookup_path()
  end
  return (directory:gsub("([\\, ;])", "\\%1"))
end

-- Match the server's splitIncludeTarget: strip a single hex-digit tab suffix
-- only from cartridge include paths. A `.lua:2` path stays literal.
local function strip_tab_selector(path)
  if #path < 2 then
    return path
  end
  local digit = path:sub(-1)
  if path:sub(-2, -2) ~= ":" or not digit:match("%x") then
    return path
  end
  local name = path:sub(1, -3)
  local lower = name:lower()
  if lower:sub(-7) ~= ".p8.png" and lower:sub(-3) ~= ".p8" then
    return path
  end
  return name
end

-- Parse the raw target from a complete `#include` line. The tab selector is
-- kept so includeexpr can recognize a cursor on the selector digit.
local function parse_target(line)
  if type(line) ~= "string" then
    return nil
  end
  local rest = line:match("^%s*#include%s+(.+)$")
  if not rest then
    return nil
  end
  rest = vim.trim(rest)
  local quoted = rest:match('^"([^"]*)"') or rest:match("^'([^']*)'")
  if quoted ~= nil then
    rest = quoted
  end
  return rest:gsub("\\", "/")
end

-- Parse the target from a complete `#include` line. This is the same parser
-- the include helper uses for ownership, so `gf` and attachment agree.
function M.target(line)
  local rest = parse_target(line)
  if rest == nil then
    return nil
  end
  return strip_tab_selector(rest)
end

-- Resolve one target against a cart directory. `target` may be a bare path,
-- a quoted path, or a complete `#include` line. Relative paths become absolute
-- against `directory`; absolute paths stay absolute. An empty target is
-- returned unchanged so Neovim reports the missing file.
function M.resolve(target, directory)
  if type(target) ~= "string" then
    return target
  end
  local parsed = parse_target(target)
  if parsed == nil and target:match("^%s*#include") then
    -- A directive without a usable path: leave the original text alone so
    -- Neovim reports its normal missing-file error.
    return target
  end
  local value = parsed or target
  value = vim.trim(value)
  local quoted = value:match('^"([^"]*)"') or value:match("^'([^']*)'")
  if quoted ~= nil then
    value = quoted
  end
  value = value:gsub("\\", "/")
  value = strip_tab_selector(value)
  if value == "" then
    return target
  end
  if is_absolute(value) then
    return normalize(value)
  end
  if type(directory) ~= "string" or directory == "" then
    return value
  end
  return normalize(directory .. "/" .. value)
end

-- The directory includes resolve from. A helper-managed include or decoded
-- `.p8.png` virtual buffer carries `b:pico8_cart_root`; a normal `.p8` buffer
-- uses its own directory. A virtual buffer without a tracked root has no
-- usable filesystem directory.
function M.buffer_directory(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local root = vim.b[bufnr].pico8_cart_root
  if type(root) == "string" and root ~= "" then
    return normalize(root)
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or is_virtual(name) then
    return nil
  end
  return vim.fs.dirname(normalize(name))
end

local function current_line()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
end

-- `includeexpr` entry point. Prefer the complete target on the cursor line so
-- quoted paths with spaces and literal `.lua:2` names survive Vim's `gf`
-- tokenization. Fall back to `v:fname` for include searches that are not on an
-- `#include` line.
function M.includeexpr(fname)
  local bufnr = vim.api.nvim_get_current_buf()
  local target = nil
  local raw = parse_target(current_line())
  if raw and raw ~= "" then
    local line_target = strip_tab_selector(raw)
    -- Check both the stripped path and the raw target so a cursor on a
    -- `:2`/`:a` tab-selector digit still matches. The consistency check also
    -- prevents an `[i`/`:checkpath` evaluation on another line from resolving
    -- the wrong directive.
    if
      type(fname) ~= "string"
      or fname == ""
      or line_target:find(fname, 1, true) ~= nil
      or raw:find(fname, 1, true) ~= nil
    then
      target = line_target
    end
  end
  if not target then
    target = fname
  end
  if type(target) ~= "string" then
    return target
  end
  local directory = M.buffer_directory(bufnr)
  if not directory then
    return target
  end
  return M.resolve(target, directory)
end

-- `:saveas` and `:file` change the buffer name without re-running the
-- ftplugin. Update the cart-scoped path when the value is still ours.
local path_group = vim.api.nvim_create_augroup("pico_lsp_includes", { clear = true })
vim.api.nvim_create_autocmd("BufFilePost", {
  group = path_group,
  callback = function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].pico8_path_scoped then
      return
    end
    if vim.bo[bufnr].path ~= vim.b[bufnr].pico8_path_value then
      -- The user replaced the scoped path; leave it alone.
      vim.b[bufnr].pico8_path_scoped = nil
      vim.b[bufnr].pico8_path_value = nil
      return
    end
    local directory = vim.b[bufnr].pico8_cart_root
    if type(directory) ~= "string" or directory == "" then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" or is_virtual(name) then
        return
      end
      directory = vim.fs.dirname(normalize(name))
    end
    vim.bo[bufnr].path = M.path_value(directory)
    vim.b[bufnr].pico8_path_value = vim.bo[bufnr].path
  end,
})

return M
