-- Install the vendored PICO-8 Tree-sitter parser and queries.
--
-- The installer builds the committed grammar sources with a local C compiler
-- and writes them under stdpath("data")/site, which Neovim reads from
-- 'runtimepath'. It never downloads anything or inspects cart contents.
--
-- Use :Pico8InstallParser, or:
--   require("pico_lsp.treesitter").install({ force = true })

local M = {}

local LANGUAGE = "pico8"
local COMPILE_TIMEOUT_MS = 60000
local STDERR_TAIL_LINES = 20
local STDERR_TAIL_BYTES = 2000

-- Keep this list in the same order as the milestone and documentation.
local QUERY_FILES = { "highlights.scm", "indents.scm", "textobjects.scm" }
local SOURCE_FILES = { "src/parser.c", "src/scanner.c" }
local REQUIRED_FILES = {
  "src/parser.c",
  "src/scanner.c",
  "queries/highlights.scm",
  "queries/indents.scm",
  "queries/textobjects.scm",
}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notify_user(message, level)
  vim.notify("pico-lsp: " .. message, level or vim.log.levels.INFO)
end

local function is_windows()
  return vim.fn.has("win32") == 1
end

local function normalize(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  local ok, normalized = pcall(vim.fs.normalize, absolute)
  if ok then
    return normalized
  end
  return absolute
end

local function same_path(a, b)
  if is_windows() or vim.fn.has("mac") == 1 then
    return a:lower() == b:lower()
  end
  return a == b
end

local function is_directory(path)
  return type(path) == "string" and path ~= "" and vim.fn.isdirectory(path) == 1
end

local function neovim_version()
  local version = vim.version()
  local text = string.format("%d.%d.%d", version.major, version.minor, version.patch)
  if version.prerelease and version.prerelease ~= "" then
    text = text .. "-" .. version.prerelease
  end
  return text
end

local function tail(text, max_lines, max_bytes)
  text = tostring(text or ""):gsub("\r\n", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  if #lines > max_lines then
    local keep = {}
    for index = #lines - max_lines + 1, #lines do
      keep[#keep + 1] = lines[index]
    end
    lines = keep
    table.insert(lines, 1, "...")
  end
  local result = table.concat(lines, "\n")
  if #result > max_bytes then
    result = "..." .. result:sub(#result - max_bytes + 1)
  end
  return result
end

local function unique_path(destination, tag)
  local directory = vim.fs.dirname(destination)
  local basename = vim.fs.basename(destination)
  local pid = type(vim.uv.os_getpid) == "function" and vim.uv.os_getpid() or 0
  local stamp = tostring(vim.uv.hrtime()):gsub("%D", "")
  return string.format("%s/.%s.%s.%s.%s", directory, basename, tag, tostring(pid), stamp)
end

local function ensure_directory(path)
  if is_directory(path) then
    return true
  end
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then
    return nil, string.format("could not create %s: %s", path, tostring(err))
  end
  if not is_directory(path) then
    return nil, string.format("could not create %s (check write permissions)", path)
  end
  return true
end

local function read_bytes(path)
  local fd, open_err = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil, open_err
  end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil, stat_err
  end
  local data = ""
  if stat.size and stat.size > 0 then
    data, stat_err = vim.uv.fs_read(fd, stat.size, 0)
  end
  vim.uv.fs_close(fd)
  if not data then
    return nil, stat_err
  end
  return data
end

local function write_bytes(path, data)
  local fd, open_err = vim.uv.fs_open(path, "w", 420)
  if not fd then
    return nil, open_err
  end
  local offset = 0
  while offset < #data do
    local written, write_err = vim.uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written == 0 then
      vim.uv.fs_close(fd)
      return nil, write_err or "the write made no progress"
    end
    offset = offset + written
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if not closed and close_err then
    return nil, close_err
  end
  return true
end

-- Rename over an existing destination. POSIX rename replaces it atomically;
-- Windows may reject that, so move the old file aside and restore it if the
-- new file cannot be put in place.
local function replace_file(temp, destination)
  local renamed, rename_err = vim.uv.fs_rename(temp, destination)
  if renamed then
    return true
  end

  local existing = vim.uv.fs_stat(destination) ~= nil
  if not existing then
    return nil, rename_err
  end

  local backup = unique_path(destination, "backup")
  local moved, move_err = vim.uv.fs_rename(destination, backup)
  if not moved then
    return nil, move_err
  end
  local replaced, replace_err = vim.uv.fs_rename(temp, destination)
  if replaced then
    pcall(vim.uv.fs_unlink, backup)
    return true
  end
  pcall(vim.uv.fs_rename, backup, destination)
  return nil, replace_err
end

local function runtime_source()
  local found = vim.api.nvim_get_runtime_file("vendor/tree-sitter-pico8/src/parser.c", false)
  if found and found[1] then
    return normalize(vim.fs.dirname(vim.fs.dirname(found[1])))
  end
  return nil
end

local function default_source()
  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source ~= "" then
    local module_dir = vim.fs.dirname(normalize(source))
    local root = module_dir and vim.fs.dirname(vim.fs.dirname(module_dir))
    if root then
      local candidate = normalize(root .. "/vendor/tree-sitter-pico8")
      if is_directory(candidate) then
        return candidate
      end
      local from_runtime = runtime_source()
      if from_runtime then
        return from_runtime
      end
      -- Keep the expected default so the error names the path the user should
      -- populate or override.
      return candidate
    end
  end
  local from_runtime = runtime_source()
  if from_runtime then
    return from_runtime
  end
  return nil
end

-- Resolve the grammar directory. An explicit override is authoritative even when
-- it is invalid: falling through would hide a typo behind the vendored default.
function M.source()
  local configured = vim.g.pico8_treesitter_source
  if configured ~= nil and configured ~= "" then
    if type(configured) ~= "string" then
      return nil, "vim.g.pico8_treesitter_source must be a directory path"
    end
    return normalize(configured), nil
  end

  local environment = vim.env.PICO_LSP_TREE_SITTER
  if type(environment) == "string" and environment ~= "" then
    return normalize(environment), nil
  end

  local source = default_source()
  if not source then
    return nil,
      "could not locate vendor/tree-sitter-pico8; set vim.g.pico8_treesitter_source "
      .. "or PICO_LSP_TREE_SITTER to the grammar directory"
  end
  return source, nil
end

function M.destinations()
  local data = normalize(vim.fn.stdpath("data"))
  local site = data .. "/site"
  local extension = is_windows() and "dll" or "so"
  return {
    data = data,
    site = site,
    parser_dir = site .. "/parser",
    parser_path = site .. "/parser/" .. LANGUAGE .. "." .. extension,
    query_dir = site .. "/queries/" .. LANGUAGE,
  }
end

local function compiler_hint()
  if is_windows() then
    return "install LLVM/clang or MinGW and put cc or clang on PATH"
  end
  if vim.fn.has("mac") == 1 then
    return "install the Xcode command line tools with: xcode-select --install"
  end
  return "install build-essential (Debian/Ubuntu), gcc/clang (Fedora), "
    .. "or your distribution's C toolchain"
end

function M.compiler()
  local configured = vim.env.CC
  if configured ~= nil and configured ~= "" then
    if vim.fn.executable(configured) == 1 then
      return configured
    end
    return nil, string.format(
      "$CC is set to %q but is not executable; fix or unset it.\n%s\n"
        .. "See docs/install.md#tree-sitter for the manual build.",
      configured,
      compiler_hint()
    )
  end

  local tried = {}
  for _, candidate in ipairs({ "cc", "clang" }) do
    tried[#tried + 1] = candidate
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil,
    "no C compiler found (tried " .. table.concat(tried, ", ") .. ").\n"
    .. compiler_hint()
    .. "\nSee docs/install.md#tree-sitter for the manual build"
end

local function validate_source(source)
  if not is_directory(source) then
    return nil,
      "PICO-8 Tree-sitter source directory not found: " .. source .. "\n"
      .. "Set vim.g.pico8_treesitter_source or PICO_LSP_TREE_SITTER to the grammar directory."
  end
  local missing = {}
  for _, relative in ipairs(REQUIRED_FILES) do
    if vim.fn.filereadable(source .. "/" .. relative) ~= 1 then
      missing[#missing + 1] = source .. "/" .. relative
    end
  end
  if #missing > 0 then
    return nil,
      "PICO-8 Tree-sitter sources are incomplete; missing:\n  " .. table.concat(missing, "\n  ") .. "\n"
      .. "Set vim.g.pico8_treesitter_source or PICO_LSP_TREE_SITTER to a complete grammar directory."
  end
  return true
end

local function latest_source_mtime(source)
  local latest = nil
  for _, relative in ipairs(SOURCE_FILES) do
    local stat = vim.uv.fs_stat(source .. "/" .. relative)
    if not stat then
      return nil, "could not stat " .. source .. "/" .. relative
    end
    local newer = not latest
      or stat.mtime.sec > latest.sec
      or (stat.mtime.sec == latest.sec and (stat.mtime.nsec or 0) > (latest.nsec or 0))
    if newer then
      latest = stat.mtime
    end
  end
  return latest
end

local function parser_is_current(parser_path, source)
  local parser_stat = vim.uv.fs_stat(parser_path)
  if not parser_stat then
    return false
  end
  local source_mtime, err = latest_source_mtime(source)
  if not source_mtime then
    return nil, err
  end
  if source_mtime.sec ~= parser_stat.mtime.sec then
    return source_mtime.sec < parser_stat.mtime.sec
  end
  return (source_mtime.nsec or 0) <= (parser_stat.mtime.nsec or 0)
end

local function compile_command(compiler, source, output)
  local command = { compiler, "-shared" }
  if not is_windows() then
    command[#command + 1] = "-fPIC"
  end
  vim.list_extend(command, {
    "-O2",
    "-I",
    source .. "/src",
    source .. "/src/parser.c",
    source .. "/src/scanner.c",
    "-o",
    output,
  })
  return command
end

local function compiler_output(result)
  local output = tail(result.stderr or "", STDERR_TAIL_LINES, STDERR_TAIL_BYTES)
  if output == "" then
    output = tail(result.stdout or "", STDERR_TAIL_LINES, STDERR_TAIL_BYTES)
  end
  if output == "" then
    output = "<no compiler output>"
  end
  return output
end

local function compiler_timeout(timeout_ms)
  return string.format(
    "compiling the pico8 parser timed out after %d ms; "
      .. "raise the timeout or build it manually (docs/install.md#tree-sitter)",
    timeout_ms
  )
end

local function build_parser(source, parser_path, compiler, timeout_ms)
  local parser_dir = vim.fs.dirname(parser_path)
  local made, make_err = ensure_directory(parser_dir)
  if not made then
    return nil, make_err
  end

  local temp = unique_path(parser_path, "build")
  -- Fail with the destination path before spawning a compiler when the parser
  -- directory is read-only. The compiler overwrites this empty file.
  local prepared, prepare_err = write_bytes(temp, "")
  if not prepared then
    pcall(vim.uv.fs_unlink, temp)
    return nil, string.format("could not write the parser to %s: %s", parser_path, tostring(prepare_err))
  end

  local started = vim.uv.now()
  local ran, result = pcall(function()
    return vim.system(compile_command(compiler, source, temp), {
      text = true,
      timeout = timeout_ms,
    }):wait()
  end)
  if not ran then
    pcall(vim.uv.fs_unlink, temp)
    return nil, "could not run the C compiler: " .. tostring(result)
  end
  if type(result) ~= "table" then
    pcall(vim.uv.fs_unlink, temp)
    -- A compiler that leaves a child holding stdout/stderr open can make
    -- vim.system:wait() return nil after its timeout has elapsed.
    if vim.uv.now() - started >= timeout_ms then
      return nil, compiler_timeout(timeout_ms)
    end
    return nil, "could not run the C compiler: the process returned no result"
  end

  if result.code == 124 or (result.code == nil and vim.uv.now() - started >= timeout_ms) then
    pcall(vim.uv.fs_unlink, temp)
    return nil, compiler_timeout(timeout_ms)
  end

  if result.code ~= 0 then
    pcall(vim.uv.fs_unlink, temp)
    local status = result.code ~= nil and ("exit code " .. tostring(result.code))
      or (result.signal ~= nil and ("signal " .. tostring(result.signal)) or "unknown status")
    return nil,
      string.format("compiling the pico8 parser failed (%s):\n%s", status, compiler_output(result))
  end

  local stat = vim.uv.fs_stat(temp)
  if not stat or stat.size == 0 then
    pcall(vim.uv.fs_unlink, temp)
    return nil, "the C compiler reported success but produced no parser at " .. temp
  end

  local replaced, replace_err = replace_file(temp, parser_path)
  if not replaced then
    pcall(vim.uv.fs_unlink, temp)
    return nil, string.format("could not install the parser at %s: %s", parser_path, tostring(replace_err))
  end
  return true
end

local function install_queries(source, query_dir)
  local made, make_err = ensure_directory(query_dir)
  if not made then
    return nil, make_err
  end

  local copied = 0
  for _, name in ipairs(QUERY_FILES) do
    local source_path = source .. "/queries/" .. name
    local destination = query_dir .. "/" .. name
    local source_data, read_err = read_bytes(source_path)
    if not source_data then
      return nil, string.format("could not read query %s: %s", source_path, tostring(read_err))
    end

    local destination_data = nil
    if vim.uv.fs_stat(destination) then
      local installed_err
      destination_data, installed_err = read_bytes(destination)
      if not destination_data then
        return nil, string.format("could not read installed query %s: %s", destination, tostring(installed_err))
      end
    end

    if destination_data ~= source_data then
      local temp = unique_path(destination, "query")
      local wrote, write_err = write_bytes(temp, source_data)
      if not wrote then
        pcall(vim.uv.fs_unlink, temp)
        return nil, string.format("could not write query %s: %s", destination, tostring(write_err))
      end
      local replaced, replace_err = replace_file(temp, destination)
      if not replaced then
        pcall(vim.uv.fs_unlink, temp)
        return nil, string.format("could not install query %s: %s", destination, tostring(replace_err))
      end
      copied = copied + 1
    end
  end
  return copied
end

local function runtimepath_has(site)
  for _, entry in ipairs(vim.split(vim.o.runtimepath, ",", { plain = true })) do
    -- Runtimepath entries may keep `~` or environment variables unexpanded.
    local expanded = vim.fn.expand(entry)
    if expanded ~= "" and same_path(normalize(expanded), site) then
      return true
    end
  end
  return false
end

local function ensure_runtimepath(site)
  if runtimepath_has(site) then
    return false
  end
  vim.o.runtimepath = site .. "," .. vim.o.runtimepath
  return true
end

local function language_loaded()
  return type(vim._ts_has_language) == "function" and vim._ts_has_language(LANGUAGE) == true
end

local function register_parser(parser_path)
  local language = vim.treesitter and vim.treesitter.language
  if not language or type(language.add) ~= "function" then
    return nil,
      string.format(
        "installed the pico8 parser at %s, but Neovim %s has no vim.treesitter.language.add",
        parser_path,
        neovim_version()
      )
  end

  local called, loaded, load_err = pcall(language.add, LANGUAGE, { path = parser_path })
  if not called then
    return nil,
      string.format(
        "installed the pico8 parser at %s, but Neovim %s could not register it: %s\n"
          .. "The committed parser targets ABI 14; restart Neovim or check the platform build.",
        parser_path,
        neovim_version(),
        tostring(loaded)
      )
  end
  if not loaded then
    return nil,
      string.format(
        "installed the pico8 parser at %s, but Neovim %s could not load it: %s\n"
          .. "The committed parser targets ABI 14; restart Neovim or check the platform build.",
        parser_path,
        neovim_version(),
        tostring(load_err)
      )
  end
  return true
end

-- Build and install the parser and queries. Returns a result table, or nil and
-- an actionable error. This function does not notify; the command reports the
-- result so scripts and tests can use the same path without duplicate messages.
function M.install(opts)
  if type(opts) ~= "table" then
    opts = {}
  end
  local force = opts.force == true
  local timeout_ms = tonumber(opts.timeout_ms) or COMPILE_TIMEOUT_MS
  if timeout_ms <= 0 then
    timeout_ms = COMPILE_TIMEOUT_MS
  end

  local source, source_err = M.source()
  if not source then
    return nil, source_err
  end
  local valid, validation_err = validate_source(source)
  if not valid then
    return nil, validation_err
  end

  local destinations = M.destinations()
  local current, current_err = parser_is_current(destinations.parser_path, source)
  if current == nil then
    return nil, current_err
  end
  local needs_build = force or not current
  local compiler = nil
  if needs_build then
    local compiler_err
    compiler, compiler_err = M.compiler()
    if not compiler then
      return nil, compiler_err
    end
  end

  local already_loaded = language_loaded()
  local built = false
  if needs_build then
    local compiled, build_err = build_parser(source, destinations.parser_path, compiler, timeout_ms)
    if not compiled then
      return nil, build_err
    end
    built = true
  end

  local copied, query_err = install_queries(source, destinations.query_dir)
  if not copied then
    return nil, query_err
  end

  local registered, register_err = register_parser(destinations.parser_path)
  if not registered then
    return nil, register_err
  end

  local runtimepath_added = ensure_runtimepath(destinations.site)
  return {
    source = source,
    site = destinations.site,
    parser_path = destinations.parser_path,
    query_dir = destinations.query_dir,
    built = built,
    up_to_date = not built,
    queries_copied = copied,
    runtimepath_added = runtimepath_added,
    reload_required = built and already_loaded,
  },
  nil
end

local function success_message(result)
  local parts = {}
  if result.built then
    parts[#parts + 1] = "installed pico8 parser: " .. result.parser_path
  else
    parts[#parts + 1] = "pico8 parser is up to date: " .. result.parser_path
  end
  if result.queries_copied > 0 then
    parts[#parts + 1] = string.format(
      "updated %d query file%s in %s",
      result.queries_copied,
      result.queries_copied == 1 and "" or "s",
      result.query_dir
    )
  else
    parts[#parts + 1] = "queries: " .. result.query_dir
  end
  if result.runtimepath_added then
    parts[#parts + 1] = "added " .. result.site .. " to 'runtimepath'"
  end
  if result.reload_required then
    parts[#parts + 1] = "restart Neovim to load the rebuilt parser"
  elseif vim.bo[vim.api.nvim_get_current_buf()].filetype == "pico8" then
    parts[#parts + 1] = 'start it with :lua vim.treesitter.start(0, "pico8")'
  end
  return table.concat(parts, "; ")
end

function M.install_command()
  vim.api.nvim_create_user_command("Pico8InstallParser", function(args)
    local result, err = M.install({ force = args.bang })
    if not result then
      notify_user(err, vim.log.levels.ERROR)
      return
    end
    notify_user(success_message(result), vim.log.levels.INFO)
  end, {
    bang = true,
    nargs = 0,
    desc = "Build and install the vendored pico8 Tree-sitter parser and queries",
  })
end

-- Requiring the module is enough to expose the command. lsp/pico_lsp.lua uses
-- this for base-config users who never call require("pico_lsp").setup().
M.install_command()

return M
