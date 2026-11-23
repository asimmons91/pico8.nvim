-- Default pico-lsp client configuration for pico8.nvim.
--
-- Loaded by Neovim 0.11+ from `lsp/pico_lsp.lua` on `runtimepath`.
-- Users can override this table with:
--   vim.lsp.config("pico_lsp", { cmd = { "/path/to/pico-lsp" } })
-- The server owns setting defaults; do not duplicate them here.

local function command()
  local configured = vim.g.pico_lsp_cmd
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" and #configured > 0 and type(configured[1]) == "string" then
    return configured
  end
  if vim.env.PICO_LSP_BIN and vim.env.PICO_LSP_BIN ~= "" then
    return { vim.env.PICO_LSP_BIN }
  end
  return { "pico-lsp" }
end

-- Neovim 0.11 expands URI-like buffer names to absolute paths, so the helper
-- marks its virtual PNG buffers with `pico8_virtual_cart`. A scheme-prefixed
-- name covers Neovim 0.12 and buffers created without the marker.
local function is_virtual(bufnr, name)
  return vim.b[bufnr].pico8_virtual_cart == true or name:match("^pico8%-cart:") ~= nil
end

return {
  cmd = command(),
  filetypes = { "pico8" },
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" or is_virtual(bufnr, name) then
      return
    end
    on_dir(vim.fs.dirname(vim.fs.normalize(name)))
  end,
}
