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
- Complete M27: enable the cart budget code lens and inlay-hint display,
  add `codelens`/`inlay_hints` setup options, and add
  `:Pico8ToggleInlayHints` with Neovim 0.11/0.12 coverage.
- Complete M28: cache `pico8/cartInfo` asynchronously, add `cart_info`,
  `cart_status`, and `refresh_cart_info`, add `:Pico8CartInfo` and
  `:Pico8Tabs`, and document lualine and plain statusline recipes.
- Complete M29: keep stock PICO-8 comment settings on managed includes, expose
  `b:pico8_cart`/`b:pico8_cart_root`, restore settings on managed detach, and
  add `:Pico8OpenCart`.
- Complete M30: add buffer-local `include`/`includeexpr` with cart-scoped
  `path` and cart-relative `gf` navigation, a shared include-target resolver,
  direct `nvim cart.p8.png` auto-open with virtual-buffer reuse and safe failure
  buffers, `:Pico8OpenPng` file completion, and focused include/PNG tests.
- Vendor the editor-only PICO-8 Tree-sitter parser and queries.
- Add plugin documentation and the inherited client milestone roadmap.
