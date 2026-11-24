# Changelog

## Unreleased

## [0.1.0](https://github.com/asimmons91/pico8.nvim/releases/tag/v0.1.0) - 2026-11-24

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
- Complete M31: cache the P8SCII catalog per client and cart root, prefetch it
  after attach, add `glyph_maps` setup activation, accept names, decimal bytes,
  and `0x` bytes in `:Pico8InsertGlyph`, filter the picker by name,
  description, or byte, and add cached-name command completion.
- Complete M32: add `:checkhealth pico_lsp` with read-only Neovim,
  configuration, binary/version, client, feature, include, helper, and
  Tree-sitter checks, plus headless coverage for the healthy, missing-binary,
  function-command, disabled-helper, feature-warning, lua_ls-conflict, and
  no-side-effect paths.
- Complete M33: consume the server's standard range formatting, document links,
  and code-lens refresh through Neovim, and add headless `gq` and Neovim 0.12
  `gx` coverage including the line-count refusal path.
- Complete M34: add `:Pico8InstallParser` with atomic builds from the vendored
  grammar, idempotent parser/query installation, `!` rebuilds, source and
  compiler overrides, current-session registration, isolated headless tests,
  and macOS CI coverage.
- Vendor the editor-only PICO-8 Tree-sitter parser and queries.
- Add plugin documentation and the inherited client milestone roadmap.
- Complete M36: add the pinned v0.1.0 install path, five-minute quickstart,
  demo cart, real terminal capture, LuaLS coexistence recipe, standalone
  `.lua` guidance, known limitations, help tags, support/security/contribution
  files, release checklist, and documentation link/tag checks. Mason and the
  LazyVim extra remain M35.
