# Changelog

## Unreleased

- Extract the existing Neovim client from `pico-lsp/editors/nvim`.
- Add native `lsp/pico_lsp.lua` and lazy.nvim-friendly `setup`.
- Complete M25: cart-directory roots, one-call activation, merged helper
  config, command resolution, config/root tests, and install documentation.
- Complete M26: buffer-aware include discovery and caching, root-matched client
  reuse, managed detach and ownership revalidation, save/reload and 300 ms
  cart-edit rescans, `:Pico8Refresh`, setup re-entry that keeps managed
  attachments, and focused correctness tests.
- Vendor the editor-only PICO-8 Tree-sitter parser and queries.
- Add plugin documentation and the inherited client milestone roadmap.
