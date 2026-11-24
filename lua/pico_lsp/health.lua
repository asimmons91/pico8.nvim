-- `:checkhealth pico_lsp` for pico8.nvim.
--
-- Every check is read-only: health never starts or stops a client, enables a
-- config, installs a parser, writes a buffer, or changes a setting. The only
-- process it spawns is the configured binary with `--version`, with a bounded
-- timeout. A function-valued `cmd` is reported but never called.

local M = {}

local PICO8_COMMENTS = ":---,:--,://"
local PICO8_COMMENTSTRING = "-- %s"

local function start_section(name)
  vim.health.start("pico_lsp: " .. name)
end

local function info(message)
  vim.health.info(message)
end

local function ok(message)
  vim.health.ok(message)
end

local function warn(message, ...)
  vim.health.warn(message, ...)
end

local function error(message, ...)
  vim.health.error(message, ...)
end

local function run_section(name, check)
  start_section(name)
  local ran, err = pcall(check)
  if not ran then
    error("health check failed: " .. tostring(err))
  end
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function compact(value)
  value = trim(value)
  value = value:gsub("%s*\r?\n%s*", " | ")
  if #value > 400 then
    value = value:sub(1, 397) .. "..."
  end
  return value
end

local function display(value)
  if value == nil or value == vim.NIL then
    return "unset"
  end
  if type(value) == "string" then
    return value
  end
  local formatted, result = pcall(tostring, value)
  return formatted and result or "<invalid>"
end

local function value_at(table_value, path)
  local current = table_value
  for _, key in ipairs(path) do
    if type(current) ~= "table" then
      return nil
    end
    current = current[key]
  end
  return current
end

local function get_config()
  local fetched, config = pcall(function()
    return vim.lsp.config["pico_lsp"]
  end)
  if not fetched then
    return nil, tostring(config)
  end
  if type(config) == "table" then
    return config, nil
  end
  if config == nil then
    return nil, nil
  end
  return nil, "vim.lsp.config['pico_lsp'] resolved to " .. type(config)
end

local function safe_len(value)
  local ran, length = pcall(function()
    return #value
  end)
  if ran and type(length) == "number" then
    return length
  end
  return 0
end

-- Same precedence as lsp/pico_lsp.lua. Used when the shipped config is not on
-- runtimepath so the binary check can still explain what the helper would run.
local function fallback_command()
  local configured = vim.g.pico_lsp_cmd
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" and safe_len(configured) > 0 and type(configured[1]) == "string" then
    return configured
  end
  if vim.env.PICO_LSP_BIN and vim.env.PICO_LSP_BIN ~= "" then
    return { vim.env.PICO_LSP_BIN }
  end
  return { "pico-lsp" }
end

local function normalize_cmd(cmd)
  local ran, normalized = pcall(function()
    if type(cmd) == "string" and cmd ~= "" then
      return { cmd }
    end
    if type(cmd) == "table" and safe_len(cmd) > 0 and type(cmd[1]) == "string" then
      return cmd
    end
    return nil
  end)
  if ran then
    return normalized
  end
  return nil
end

local function command_source(cmd)
  if type(cmd) == "function" then
    return "user-supplied function"
  end
  local normalized = normalize_cmd(cmd)
  local configured = vim.g.pico_lsp_cmd
  if normalized then
    if type(configured) == "string" and configured ~= "" then
      if #normalized == 1 and normalized[1] == configured then
        return "vim.g.pico_lsp_cmd"
      end
    elseif type(configured) == "table" and safe_len(configured) > 0 then
      if vim.deep_equal(normalized, configured) then
        return "vim.g.pico_lsp_cmd"
      end
    end
    local environment = vim.env.PICO_LSP_BIN
    if type(environment) == "string" and environment ~= "" then
      if #normalized == 1 and normalized[1] == environment then
        return "PICO_LSP_BIN"
      end
    end
    if vim.deep_equal(normalized, { "pico-lsp" }) then
      return "default"
    end
  end
  return "user configuration (setup or vim.lsp.config)"
end

local function format_cmd(cmd)
  local formatted, result = pcall(function()
    if type(cmd) == "function" then
      return "user-supplied function"
    end
    if type(cmd) == "string" then
      return vim.inspect(cmd)
    end
    if type(cmd) == "table" then
      local parts = {}
      for _, value in ipairs(cmd) do
        parts[#parts + 1] = vim.inspect(value)
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    end
    return vim.inspect(cmd)
  end)
  if formatted then
    return result
  end
  return "<malformed cmd>"
end

-- Returns "list", "string", or "function" plus an optional problem. A bare
-- string is accepted for probing but warned about separately because Neovim's
-- LSP client rejects it; the shipped config normalizes strings itself.
local function cmd_shape(cmd)
  local ran, shape, problem = pcall(function()
    if type(cmd) == "function" then
      return "function"
    end
    if type(cmd) == "string" then
      if cmd == "" then
        return nil, "cmd is an empty string"
      end
      return "string"
    end
    if type(cmd) ~= "table" then
      return nil, "cmd must be a non-empty list of strings or a function"
    end
    local count = safe_len(cmd)
    if count == 0 then
      return nil, "cmd is an empty list"
    end
    for index = 1, count do
      local value = cmd[index]
      if type(value) ~= "string" or value == "" then
        return nil, string.format("cmd[%d] is not a non-empty string", index)
      end
    end
    return "list"
  end)
  if not ran then
    return nil, "cmd could not be inspected: " .. tostring(shape)
  end
  return shape, problem
end

local function resolve_executable(name)
  local exepath = vim.fn.exepath(name)
  if exepath ~= "" then
    return vim.fs.normalize(exepath)
  end
  if name:find("[/\\]") then
    local absolute = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    if vim.fn.filereadable(absolute) == 1 then
      return absolute
    end
  end
  return nil
end

local function get_clients(filter)
  local ran, clients = pcall(vim.lsp.get_clients, filter or { name = "pico_lsp" })
  if ran and type(clients) == "table" then
    return clients
  end
  return {}
end

local function client_root(client)
  local root = client and (client.root_dir or (client.config and client.config.root_dir))
  if type(root) == "string" and root ~= "" then
    return vim.fs.normalize(root)
  end
  return nil
end

local function attached_count(client)
  if type(client.attached_buffers) == "table" then
    return vim.tbl_count(client.attached_buffers)
  end
  local count = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.lsp.buf_is_attached(bufnr, client.id) then
      count = count + 1
    end
  end
  return count
end

local function pico8_settings(client)
  if not client then
    return nil, nil
  end
  local candidates = {}
  if type(client.settings) == "table" then
    candidates[#candidates + 1] = { value = client.settings, source = "client.settings" }
  end
  if client.config and type(client.config.settings) == "table" then
    candidates[#candidates + 1] = { value = client.config.settings, source = "client.config.settings" }
  end
  if client.config and type(client.config.init_options) == "table" then
    candidates[#candidates + 1] = {
      value = client.config.init_options,
      source = "client.config.init_options",
    }
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate.value.pico8) == "table" then
      return candidate.value.pico8, candidate.source
    end
  end
  return nil, nil
end

local function settings_summary(pico8)
  return table.concat({
    "apiVersion=" .. display(pico8.apiVersion),
    "typeChecking=" .. display(pico8.typeChecking),
    "inlayHints=" .. display(pico8.inlayHints),
    "limits.codeLens=" .. display(value_at(pico8, { "limits", "codeLens" })),
    "diagnostics.mode=" .. display(value_at(pico8, { "diagnostics", "mode" })),
  }, ", ")
end

local function is_pico8_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if vim.bo[bufnr].filetype == "pico8" then
    return true
  end
  if vim.b[bufnr].pico8_virtual_cart == true then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and name:lower():match("%.p8$") ~= nil
end

local function is_health_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end
  if vim.api.nvim_buf_get_name(bufnr) == "health://" then
    return true
  end
  return vim.bo[bufnr].filetype == "checkhealth"
end

-- :checkhealth opens its own buffer before running this module, so the current
-- buffer is not the one the user was editing. Prefer a normal window in the
-- current tab, then the previous tab's active window, then the alternate
-- buffer, to report the cart the user actually had open.
local function context_bufnr()
  local current = vim.api.nvim_get_current_buf()
  if not is_health_buffer(current) then
    return current
  end

  -- `g:health.style = 'float'` keeps the user's tab active and puts the report
  -- in a floating window. Prefer a normal window in this tab before looking at
  -- a different tab.
  local current_win = vim.api.nvim_get_current_win()
  local current_config = vim.api.nvim_win_get_config(current_win)
  if current_config.relative ~= "" then
    local alternate_win = vim.fn.win_getid(vim.fn.winnr("#"))
    if
      alternate_win ~= 0
      and alternate_win ~= current_win
      and vim.api.nvim_win_is_valid(alternate_win)
      and vim.api.nvim_win_get_config(alternate_win).relative == ""
    then
      local bufnr = vim.api.nvim_win_get_buf(alternate_win)
      if not is_health_buffer(bufnr) then
        return bufnr
      end
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= current_win and vim.api.nvim_win_get_config(win).relative == "" then
        local bufnr = vim.api.nvim_win_get_buf(win)
        if not is_health_buffer(bufnr) then
          return bufnr
        end
      end
    end
  end

  local previous = vim.fn.tabpagenr("#")
  if previous > 0 then
    local tabs = vim.api.nvim_list_tabpages()
    local tab = tabs[previous]
    if tab then
      local win = vim.api.nvim_tabpage_get_win(tab)
      local bufnr = vim.api.nvim_win_get_buf(win)
      if not is_health_buffer(bufnr) then
        return bufnr
      end
    end
  end

  local alternate = vim.fn.bufnr("#")
  if alternate ~= -1 and not is_health_buffer(alternate) then
    return alternate
  end

  return nil
end

local function parse_version(output)
  local version = output:match("([vV]?%d+%.%d+%.%d+[%w%.%-%+]*)")
  if version then
    return version
  end
  if output:match("%f[%a]dev%f[%A]") then
    return "dev"
  end
  return nil
end

local function normalize_version(version)
  if type(version) ~= "string" then
    return ""
  end
  return (trim(version):gsub("^[vV]", ""):lower())
end

local function server_log_path(cmd)
  if type(cmd) ~= "table" then
    return nil
  end
  local ran, path = pcall(function()
    for index, argument in ipairs(cmd) do
      if type(argument) == "string" then
        if argument == "--log-file" or argument == "-log-file" then
          local value = cmd[index + 1]
          if type(value) == "string" and value ~= "" then
            return value
          end
        else
          local value = argument:match("^%-%-log%-file=(.+)$") or argument:match("^%-log%-file=(.+)$")
          if value and value ~= "" then
            return value
          end
        end
      end
    end
    return nil
  end)
  if ran then
    return path
  end
  return nil
end

local function check_neovim()
  local version = vim.version()
  local text = string.format("%d.%d.%d", version.major, version.minor, version.patch)
  if version.prerelease and version.prerelease ~= "" then
    text = text .. "-" .. version.prerelease
  end
  if vim.fn.has("nvim-0.11") == 1 then
    ok("Neovim " .. text .. " (0.11 or newer)")
  else
    error(
      "Neovim " .. text .. " is unsupported; pico8.nvim requires Neovim 0.11+",
      "Upgrade Neovim before troubleshooting the plugin."
    )
  end
end

local function check_configuration(config, config_error, cmd)
  if config then
    ok("vim.lsp.config['pico_lsp'] is available")
  elseif config_error then
    error(
      "vim.lsp.config['pico_lsp'] could not be resolved: " .. compact(config_error),
      {
        "Check lsp/pico_lsp.lua for errors and confirm the plugin is on 'runtimepath'.",
        "runtimepath: " .. vim.o.runtimepath,
      }
    )
  else
    warn(
      "vim.lsp.config['pico_lsp'] is missing; the shipped lsp/pico_lsp.lua is not on 'runtimepath'",
      {
        "runtimepath: " .. vim.o.runtimepath,
        "Add the plugin directory to 'runtimepath' or call require('pico_lsp').setup().",
      }
    )
  end

  info("cmd source: " .. command_source(cmd))
  info("cmd: " .. format_cmd(cmd))

  local shape, problem = cmd_shape(cmd)
  if not shape then
    error(problem, "Set cmd to { 'pico-lsp' } or a function that returns a command.")
  elseif shape == "string" then
    warn(
      "cmd is a bare string; Neovim's LSP client rejects it",
      "Use a one-element list such as { 'pico-lsp' }, or set vim.g.pico_lsp_cmd/PICO_LSP_BIN so the shipped config normalizes it."
    )
  else
    ok("cmd shape is valid for the LSP client")
  end

  if type(vim.lsp.config) ~= "table" then
    error("vim.lsp.config is unavailable; this Neovim build cannot use native LSP configuration")
  end
end

local function check_server_binary(cmd)
  if type(cmd) == "function" then
    info("cmd is a user-supplied function; skipping executable resolution and the --version probe")
    local versions = {}
    for _, client in ipairs(get_clients()) do
      local version = client.server_info and client.server_info.version
      if type(version) == "string" and version ~= "" then
        versions[#versions + 1] = version
      end
    end
    if #versions > 0 then
      info("running server version: " .. table.concat(versions, ", "))
    else
      info("server version: unavailable until a client is running")
    end
    return
  end

  local shape, problem = cmd_shape(cmd)
  if not shape then
    error(problem, "Set cmd to { 'pico-lsp' } or a function that returns a command.")
    return
  end

  local executable = shape == "list" and cmd[1] or cmd
  local resolved = resolve_executable(executable)
  if not resolved then
    error(
      "pico-lsp executable not found: " .. executable,
      {
        "Install a release binary from https://github.com/asimmons91/pico-lsp/releases",
        "or run: go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@latest",
        "See docs/install.md for the full installation steps.",
      }
    )
    return
  end

  local readable = vim.fn.filereadable(resolved) == 1
  local executable_bit = vim.fn.executable(resolved) == 1
  if not readable or not executable_bit then
    warn(
      "resolved pico-lsp path is not an executable file: " .. resolved,
      {
        string.format("filereadable=%d, executable=%d", readable and 1 or 0, executable_bit and 1 or 0),
        "Rebuild or reinstall the binary, or update cmd/vim.g.pico_lsp_cmd/PICO_LSP_BIN.",
      }
    )
    return
  end
  info(string.format("executable: %s (executable=%d, readable=%d)", resolved, 1, 1))

  local clients = get_clients()
  local client_versions = {}
  for _, client in ipairs(clients) do
    local version = client.server_info and client.server_info.version
    if type(version) == "string" and version ~= "" then
      client_versions[#client_versions + 1] = { id = client.id, version = version }
    end
  end

  local probe_version = nil
  if type(vim.system) ~= "function" then
    warn("vim.system is unavailable; skipping the server --version probe")
  else
    local ran, result = pcall(function()
      return vim.system({ resolved, "--version" }, { text = true, timeout = 2000 }):wait()
    end)
    if not ran or type(result) ~= "table" then
      warn("could not run " .. resolved .. " --version: " .. tostring(result))
    else
      local stdout = type(result.stdout) == "string" and result.stdout or ""
      local stderr = type(result.stderr) == "string" and result.stderr or ""
      local raw = trim(stdout)
      if raw == "" then
        raw = trim(stderr)
      end
      local status = result.code ~= nil and ("exit code " .. tostring(result.code))
        or ("signal " .. tostring(result.signal))
      if result.code ~= 0 then
        warn(
          string.format("`%s --version` failed with %s", resolved, status),
          "output: " .. (compact(raw) ~= "" and compact(raw) or "<empty>")
        )
      elseif raw == "" then
        info("server version: development build (empty --version output)")
      else
        probe_version = parse_version(raw)
        if probe_version == "dev" then
          info("server version: development build")
        elseif probe_version then
          ok("server version: " .. probe_version)
        else
          warn(
            "could not parse a server version from `--version` output",
            "output: " .. compact(raw)
          )
        end
      end
    end
  end

  if #client_versions > 0 then
    for _, client_version in ipairs(client_versions) do
      info(string.format("client %s server version: %s", tostring(client_version.id), client_version.version))
      if
        probe_version
        and normalize_version(client_version.version) ~= normalize_version(probe_version)
      then
        warn(
          string.format(
            "server version mismatch: binary reports %s, client %s reports %s",
            probe_version,
            tostring(client_version.id),
            client_version.version
          ),
          "Restart the client after changing the binary; the running process keeps its original executable."
        )
      end
    end
  end

  local log_path = server_log_path(cmd)
  if log_path then
    info("server log: " .. log_path)
  else
    info(
      "server log: not configured; add --log-level debug --log-file /tmp/pico-lsp.log to cmd (docs/troubleshooting.md#logs)"
    )
  end
end

local function check_clients()
  local clients = get_clients()
  local bufnr = context_bufnr()
  local current_attached = false

  if #clients == 0 then
    if bufnr and is_pico8_buffer(bufnr) then
      warn(
        "no pico_lsp client is running for the current pico8 buffer",
        {
          "filetype: " .. vim.bo[bufnr].filetype,
          "file exists: " .. (vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)) == 1 and "yes" or "no"),
          "runtimepath: " .. vim.o.runtimepath,
          "Check vim.lsp.config['pico_lsp'] and run :checkhealth vim.lsp.",
        }
      )
    else
      info("no running pico_lsp clients")
    end
    return
  end

  for _, client in ipairs(clients) do
    local root = client_root(client) or "none"
    local count = attached_count(client)
    info(
      string.format(
        "client %s: root=%s, buffers=%d, cmd=%s",
        tostring(client.id),
        root,
        count,
        format_cmd(client.config and client.config.cmd)
      )
    )

    local folders = {}
    if type(client.workspace_folders) == "table" then
      for _, folder in ipairs(client.workspace_folders) do
        if type(folder) == "table" then
          local label = type(folder.name) == "string" and folder.name
            or type(folder.uri) == "string" and folder.uri
            or "<unnamed>"
          folders[#folders + 1] = label
        else
          folders[#folders + 1] = tostring(folder)
        end
      end
    end
    if #folders > 0 then
      info("workspace folders: " .. table.concat(folders, ", "))
    end

    if bufnr then
      local attached = vim.lsp.buf_is_attached(bufnr, client.id)
      current_attached = current_attached or attached
      info("current buffer attached: " .. (attached and "yes" or "no"))
    else
      info("current buffer attached: not applicable (no user buffer beside the health report)")
    end

    local pico8, settings_source = pico8_settings(client)
    if pico8 then
      info("settings source: " .. settings_source)
      info("settings: " .. settings_summary(pico8))
    else
      info("settings: pico8 settings are not available on this client (the server may pull them at runtime)")
    end

    if count == 0 then
      info("client has no attached buffers")
    end
  end

  if bufnr and not current_attached and is_pico8_buffer(bufnr) then
    warn(
      "the current pico8 buffer is not attached to any pico_lsp client",
      {
        "filetype: " .. vim.bo[bufnr].filetype,
        "runtimepath: " .. vim.o.runtimepath,
        "Run :checkhealth vim.lsp and inspect the client log.",
      }
    )
  end
end

local function check_features()
  local bufnr = context_bufnr()
  if not bufnr or not is_pico8_buffer(bufnr) then
    info("no pico8 cart is active outside the health report; open a .p8 file to inspect client feature state")
    return
  end

  local client = get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
  if not client then
    info("no pico_lsp client is attached to the current buffer; feature state is unavailable")
    return
  end

  local pico8, settings_source = pico8_settings(client)
  if not pico8 then
    info("pico8 settings are not available on this client; using unset defaults below")
    pico8 = {}
  else
    info("settings source: " .. settings_source)
  end

  local inlay_setting = pico8.inlayHints
  info("pico8.inlayHints = " .. display(inlay_setting))
  local inlay = vim.lsp and vim.lsp.inlay_hint
  if type(inlay) == "table" and type(inlay.is_enabled) == "function" then
    local ran, enabled = pcall(inlay.is_enabled, { bufnr = bufnr })
    enabled = ran and enabled == true
    info("inlay hints client-side: " .. (enabled and "enabled" or "disabled"))
    if inlay_setting == true and not enabled then
      warn(
        "pico8.inlayHints is true but client-side inlay hints are disabled for this buffer",
        "Enable with require('pico_lsp').setup({ inlay_hints = true }) or vim.lsp.inlay_hint.enable(true, { bufnr = ... })."
      )
    elseif inlay_setting == false then
      info("inlay hints are intentionally off in the server settings")
    elseif inlay_setting == nil or inlay_setting == vim.NIL then
      info("pico8.inlayHints is unset; the server default is false")
    end
  else
    info("this Neovim build has no inlay hint API")
  end

  local codelens_setting = value_at(pico8, { "limits", "codeLens" })
  info("pico8.limits.codeLens = " .. display(codelens_setting))
  local codelens = vim.lsp and vim.lsp.codelens
  if type(codelens) ~= "table" then
    info("this Neovim build has no code lens API")
  elseif type(codelens.is_enabled) == "function" then
    local ran, enabled = pcall(codelens.is_enabled, { bufnr = bufnr })
    enabled = ran and enabled == true
    info("code lens client-side: " .. (enabled and "enabled" or "disabled"))
    -- The server defaults limits.codeLens to true, so an unset value still
    -- returns the lens and deserves the same warning as an explicit true.
    if codelens_setting ~= false and not enabled then
      warn(
        "pico8.limits.codeLens is enabled (or unset and defaults to true) but client-side code lens is disabled",
        "Enable with require('pico_lsp').setup({ codelens = true }) or vim.lsp.codelens.enable(true, { bufnr = ... })."
      )
    elseif codelens_setting == false then
      info("code lens is intentionally off in the server settings")
    end
  elseif type(codelens.refresh) == "function" then
    local count = 0
    if type(codelens.get) == "function" then
      local ran, lenses = pcall(codelens.get, bufnr)
      if ran and type(lenses) == "table" then
        count = #lenses
      end
    end
    info(
      string.format(
        "code lens client-side: refresh-based engine with %d cached lens(es); this Neovim version has no per-buffer toggle",
        count
      )
    )
    if codelens_setting == false then
      info("code lens is intentionally off in the server settings")
    end
  else
    info("this Neovim build has no code lens API")
  end

  local type_checking = pico8.typeChecking
  if type_checking ~= nil and type_checking ~= vim.NIL then
    if
      type(type_checking) ~= "string"
      or not vim.tbl_contains({ "off", "basic", "strict" }, type_checking)
    then
      warn(
        "pico8.typeChecking has an invalid value: " .. display(type_checking),
        "Expected off, basic, or strict."
      )
    else
      info("pico8.typeChecking = " .. type_checking)
    end
  else
    info("pico8.typeChecking = unset (server default basic)")
  end

  local diagnostics_mode = value_at(pico8, { "diagnostics", "mode" })
  if diagnostics_mode ~= nil and diagnostics_mode ~= vim.NIL then
    if
      type(diagnostics_mode) ~= "string"
      or not vim.tbl_contains({ "auto", "push", "pull" }, diagnostics_mode)
    then
      warn(
        "pico8.diagnostics.mode has an invalid value: " .. display(diagnostics_mode),
        "Expected auto, push, or pull."
      )
    else
      info("pico8.diagnostics.mode = " .. diagnostics_mode)
    end
  else
    info("pico8.diagnostics.mode = unset (server default auto)")
  end
end

local function report_include(bufnr, cart_uri)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    name = "<unnamed>"
  end
  local converted, cart_path = pcall(vim.uri_to_fname, cart_uri)
  info(string.format("include %s: cart=%s", name, converted and cart_path or cart_uri))

  local clients = get_clients({ bufnr = bufnr })
  local attached = {}
  local has_pico8 = false
  local has_lua_ls = false
  for _, client in ipairs(clients) do
    attached[#attached + 1] = string.format(
      "%s (id %s, root %s)",
      tostring(client.name),
      tostring(client.id),
      client_root(client) or "none"
    )
    if client.name == "pico_lsp" then
      has_pico8 = true
    elseif client.name == "lua_ls" then
      has_lua_ls = true
    end
  end
  if #attached > 0 then
    info("attached clients: " .. table.concat(attached, ", "))
  else
    info("attached clients: none")
  end

  local comments = vim.bo[bufnr].comments
  local commentstring = vim.bo[bufnr].commentstring
  info(
    string.format(
      "comments=%s, commentstring=%s%s",
      comments,
      commentstring,
      comments == PICO8_COMMENTS and commentstring == PICO8_COMMENTSTRING and " (PICO-8 targets)" or ""
    )
  )

  if has_pico8 and has_lua_ls then
    warn(
      "lua_ls and pico_lsp are both attached to " .. name .. "; this combination is unsupported",
      "Stop one client or exclude this file from the lua_ls project."
    )
  elseif not has_pico8 then
    info(
      "no pico_lsp client is attached to this managed include; run :Pico8Refresh or confirm require('pico_lsp').setup() is active"
    )
  end
end

local function check_includes()
  local found = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local read, cart_uri = pcall(function()
        return vim.b[bufnr].pico8_cart
      end)
      if read and type(cart_uri) == "string" and cart_uri ~= "" then
        found = true
        local reported, err = pcall(report_include, bufnr, cart_uri)
        if not reported then
          info("skipped an include buffer that disappeared during the check: " .. compact(tostring(err)))
        end
      end
    end
  end
  if not found then
    info("no helper-managed .lua buffers are loaded")
  end
end

local function check_helper(cmd)
  local loaded = package.loaded["pico_lsp"]
  local setup_ran = type(loaded) == "table" and loaded.did_setup == true
  local setup_disabled = type(loaded) == "table" and loaded.disabled == true
  local disabled_global = vim.g.pico_lsp_helper_disabled == 1
  -- The global is read by setup(), not watched at runtime. Report the effective
  -- state and flag a global that was set after the last setup.
  local disabled = setup_disabled or (not setup_ran and disabled_global)

  if setup_ran then
    info("require('pico_lsp').setup() has run")
  else
    info(
      "require('pico_lsp').setup() has not run; base-config users can still use .p8 carts through lsp/pico_lsp.lua"
    )
  end

  if disabled then
    info(
      "helper is disabled"
        .. (setup_disabled and " by setup({ disable = true })" or " by vim.g.pico_lsp_helper_disabled")
    )
  elseif setup_ran and disabled_global then
    warn(
      "vim.g.pico_lsp_helper_disabled is set, but the helper is still active because setup has not run since the change",
      "Re-run require('pico_lsp').setup() to apply the disable."
    )
  elseif setup_ran then
    ok("helper is enabled")
  else
    info("helper is not active; included .lua attachment requires require('pico_lsp').setup()")
  end

  local commands = {
    "Pico8OpenPng",
    "Pico8ReloadPng",
    "Pico8InsertGlyph",
    "Pico8CartInfo",
    "Pico8Tabs",
    "Pico8Refresh",
    "Pico8ToggleInlayHints",
    "Pico8OpenCart",
  }
  local present = {}
  local missing = {}
  for _, name in ipairs(commands) do
    if vim.fn.exists(":" .. name) == 2 then
      present[#present + 1] = name
    else
      missing[#missing + 1] = name
    end
  end
  if #present > 0 then
    info("commands present: " .. table.concat(present, ", "))
  end
  if #missing == 0 then
    ok("all expected helper commands are registered")
  elseif setup_ran and not disabled then
    warn(
      "helper commands are missing: " .. table.concat(missing, ", "),
      {
        "Check that the plugin is on 'runtimepath' and call require('pico_lsp').setup().",
        "runtimepath: " .. vim.o.runtimepath,
      }
    )
  else
    info("commands not registered: " .. table.concat(missing, ", ") .. " (helper is not enabled)")
  end

  local logged, log_path = pcall(function()
    return vim.lsp.log.get_filename()
  end)
  if logged and type(log_path) == "string" and log_path ~= "" then
    info("Neovim LSP client log: " .. log_path)
  else
    info("Neovim LSP client log: unavailable (vim.lsp.log.get_filename() failed)")
  end

  local server_log = server_log_path(cmd)
  if server_log then
    info("server log: " .. server_log)
  else
    info(
      "server log: not configured; add --log-level debug --log-file /tmp/pico-lsp.log to cmd (docs/troubleshooting.md#logs)"
    )
  end
end

local function detects_pico8_filetype()
  local matched, filetype = pcall(vim.filetype.match, { filename = "pico8-health-check.p8" })
  if matched and filetype == "pico8" then
    return true, "vim.filetype.match"
  end

  -- The shipped ftdetect uses a BufRead/BufNewFile autocmd, which
  -- vim.filetype.match() does not consult. Fall back to the registered autocmd
  -- so a healthy runtime does not produce a false warning.
  local listed, autocmds = pcall(vim.api.nvim_get_autocmds, {
    event = { "BufNewFile", "BufRead", "BufReadPost" },
    pattern = "*.p8",
  })
  if listed then
    for _, autocmd in ipairs(autocmds) do
      if type(autocmd.command) == "string" and autocmd.command:match("setfiletype%s+pico8") then
        return true, "ftdetect autocmd"
      end
    end
  end
  return false, nil
end

local function check_treesitter()
  local language = vim.treesitter and vim.treesitter.language
  if not language or type(language.add) ~= "function" then
    info("Tree-sitter API is unavailable; Vim syntax highlighting still works")
  else
    local loaded = pcall(language.add, "pico8")
    if loaded then
      ok("pico8 Tree-sitter parser loads")
    else
      info("pico8 Tree-sitter parser is not available; Vim syntax highlighting still works")
      info("Build it from vendor/tree-sitter-pico8 as described in docs/install.md#tree-sitter.")
      info("Automatic installation is proposed in M34 (:Pico8InstallParser).")
    end
  end

  local detected, how = detects_pico8_filetype()
  if detected then
    ok("pico8 filetype detection is registered (" .. how .. ")")
  else
    warn(
      "pico8 filetype detection is not registered",
      {
        "Add the plugin to 'runtimepath' and enable filetype detection (`:filetype plugin on`).",
        "runtimepath: " .. vim.o.runtimepath,
      }
    )
  end
end

function M.check()
  if type(vim.health) ~= "table" or type(vim.health.start) ~= "function" then
    return
  end

  vim.health.start("pico_lsp")

  local config, config_error = get_config()
  local cmd = config and config.cmd or fallback_command()

  run_section("Neovim", check_neovim)
  run_section("Configuration", function()
    check_configuration(config, config_error, cmd)
  end)
  run_section("Server binary", function()
    check_server_binary(cmd)
  end)
  run_section("Running clients", check_clients)
  run_section("Client features", check_features)
  run_section("Included .lua buffers", check_includes)
  run_section("Helper", function()
    check_helper(cmd)
  end)
  run_section("Tree-sitter", check_treesitter)
end

return M
