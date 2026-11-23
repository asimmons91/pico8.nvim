-- Client-side enablement for pico-lsp code lenses and inlay hints.
--
-- The shipped `lsp/pico_lsp.lua` calls `M.attach` from its `on_attach` hook, so
-- the display works without `require("pico_lsp").setup`. The setup options are
-- read at attach time and affect clients started after they change.
--
-- The server remains the feature switch: `pico8.limits.codeLens` and
-- `pico8.inlayHints` decide what it returns. This module only enables the
-- client-side display for a `pico8` buffer.

local M = {}

M.options = {
  codelens = true,
  inlay_hints = true,
}

local function notify(message, level)
  vim.notify("pico-lsp: " .. message, level or vim.log.levels.WARN)
end

local function log_debug(message)
  local ok, logger = pcall(function()
    return vim.lsp.log
  end)
  if ok and logger and type(logger.debug) == "function" then
    pcall(logger.debug, message)
  end
end

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function is_pico8_buffer(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
    and vim.bo[bufnr].filetype == "pico8"
end

-- Neovim 0.12 replaced the legacy code-lens engine with an enable/disable
-- capability. Feature-detect instead of comparing versions so a patched or
-- nightly build behaves like the API it exposes.
function M.codelens_mode()
  local codelens = vim.lsp and vim.lsp.codelens
  if type(codelens) ~= "table" then
    return nil
  end
  if type(codelens.enable) == "function" then
    return "enable"
  end
  if type(codelens.refresh) == "function" then
    return "refresh"
  end
  return nil
end

-- Neovim 0.11 has no codelens enable state, so refresh again after a cart save.
-- The budget lens is allowed to be one save behind while typing.
local function ensure_save_refresh(bufnr)
  if vim.b[bufnr].pico8_codelens_save_refresh then
    return
  end
  vim.b[bufnr].pico8_codelens_save_refresh = true
  local ok = pcall(vim.api.nvim_create_autocmd, "BufWritePost", {
    buffer = bufnr,
    desc = "Refresh pico-lsp code lenses",
    callback = function(args)
      if type(vim.lsp.codelens.refresh) ~= "function" then
        return
      end
      if #vim.lsp.get_clients({ name = "pico_lsp", bufnr = args.buf }) == 0 then
        return
      end
      local refreshed, err = pcall(vim.lsp.codelens.refresh, { bufnr = args.buf })
      if not refreshed then
        log_debug("pico-lsp: code lens refresh failed: " .. tostring(err))
      end
    end,
  })
  if not ok then
    vim.b[bufnr].pico8_codelens_save_refresh = nil
  end
end

function M.enable_codelens(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local mode = M.codelens_mode()
  if mode == "enable" then
    local ok, err = pcall(vim.lsp.codelens.enable, true, { bufnr = bufnr })
    if not ok then
      log_debug("pico-lsp: could not enable code lens: " .. tostring(err))
    end
    return ok
  end
  if mode == "refresh" then
    local ok, err = pcall(vim.lsp.codelens.refresh, { bufnr = bufnr })
    if not ok then
      log_debug("pico-lsp: could not refresh code lens: " .. tostring(err))
      return false
    end
    ensure_save_refresh(bufnr)
    return true
  end
  log_debug("pico-lsp: this Neovim build has no code lens API")
  return false
end

-- Report the per-buffer display state the same way on both Neovim versions.
-- Neovim 0.11 has no `is_enabled`, so use its cached lenses instead.
function M.codelens_enabled(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local codelens = vim.lsp and vim.lsp.codelens
  if type(codelens) ~= "table" then
    return false
  end
  if type(codelens.is_enabled) == "function" then
    local ok, enabled = pcall(codelens.is_enabled, { bufnr = bufnr })
    return ok and enabled == true
  end
  if type(codelens.get) == "function" then
    local ok, lenses = pcall(codelens.get, bufnr)
    return ok and type(lenses) == "table" and #lenses > 0
  end
  return false
end

function M.enable_inlay_hints(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local inlay_hint = vim.lsp and vim.lsp.inlay_hint
  if type(inlay_hint) ~= "table" or type(inlay_hint.enable) ~= "function" then
    log_debug("pico-lsp: this Neovim build has no inlay hint API")
    return false
  end
  local ok, err = pcall(inlay_hint.enable, true, { bufnr = bufnr })
  if not ok then
    log_debug("pico-lsp: could not enable inlay hints: " .. tostring(err))
  end
  return ok
end

function M.inlay_hints_enabled(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local inlay_hint = vim.lsp and vim.lsp.inlay_hint
  if type(inlay_hint) ~= "table" or type(inlay_hint.is_enabled) ~= "function" then
    return false
  end
  local ok, enabled = pcall(inlay_hint.is_enabled, { bufnr = bufnr })
  return ok and enabled == true
end

-- Read the client-visible `pico8.inlayHints` value. Returns true, false, or
-- nil when the client does not carry the setting. The server also accepts the
-- same section through `settings` or `init_options`.
function M.server_inlay_hints(client)
  if not client then
    return nil
  end
  local candidates = {}
  if type(client.settings) == "table" then
    candidates[#candidates + 1] = client.settings
  end
  if client.config and type(client.config.settings) == "table" then
    candidates[#candidates + 1] = client.config.settings
  end
  if client.config and type(client.config.init_options) == "table" then
    candidates[#candidates + 1] = client.config.init_options
  end
  for _, candidate in ipairs(candidates) do
    local pico8 = nil
    if type(candidate) == "table" then
      pico8 = candidate.pico8
    end
    local value = nil
    if type(pico8) == "table" then
      value = pico8.inlayHints
    end
    if type(value) == "boolean" then
      return value
    end
  end
  return nil
end

function M.toggle_inlay_hints(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not is_pico8_buffer(bufnr) then
    notify("Pico8ToggleInlayHints only works in pico8 buffers", vim.log.levels.INFO)
    return nil
  end

  local client = vim.lsp.get_clients({ name = "pico_lsp", bufnr = bufnr })[1]
  if not client then
    notify("no pico_lsp client attached to this buffer")
    return nil
  end

  local inlay_hint = vim.lsp and vim.lsp.inlay_hint
  if
    type(inlay_hint) ~= "table"
    or type(inlay_hint.enable) ~= "function"
    or type(inlay_hint.is_enabled) ~= "function"
  then
    notify("this Neovim build has no inlay hint API", vim.log.levels.ERROR)
    return nil
  end

  local enable = not M.inlay_hints_enabled(bufnr)
  local ok, err = pcall(inlay_hint.enable, enable, { bufnr = bufnr })
  if not ok then
    log_debug("pico-lsp: could not toggle inlay hints: " .. tostring(err))
    notify("could not toggle inlay hints: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  -- The server defaults the setting to false. An absent client value therefore
  -- means hints will stay empty just like an explicit false.
  if enable and M.server_inlay_hints(client) ~= true then
    notify(
      "pico8.inlayHints is not enabled in the server settings; hints will stay empty. "
        .. "Set it to true in your pico-lsp configuration (see docs/configuration.md)."
    )
  end
  return enable
end

-- Called from the shipped config's `on_attach` and from the helper's fallback
-- config. Only `pico8` buffers get the client-side display.
function M.attach(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not is_pico8_buffer(bufnr) then
    return
  end
  if M.options.codelens ~= false then
    M.enable_codelens(bufnr)
  end
  if M.options.inlay_hints ~= false then
    M.enable_inlay_hints(bufnr)
  end
end

function M.setup(opts)
  opts = opts or {}
  M.options = {
    codelens = opts.codelens ~= false,
    inlay_hints = opts.inlay_hints ~= false,
  }
end

return M
