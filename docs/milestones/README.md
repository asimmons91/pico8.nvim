# Client milestones

These are the Neovim-client milestones. Most were inherited from
[`pico-lsp`](https://github.com/asimmons91/pico-lsp), and their milestone IDs
are kept for traceability with the server roadmap and the original PRs. M36 is
a client-local onboarding and release-readiness milestone.

The specifications have been adapted for this repository:

- paths are relative to the plugin root, not `editors/nvim`;
- `pico-lsp M*` references point to server milestones;
- Go test gates belong to `pico-lsp`; this repository runs headless Neovim
  tests;
- M33 is not duplicated here because it adds server capabilities; its client
  smoke tests live in `tests/standard_hooks.lua`.

| Milestone | Spec | Status |
|---|---|---|
| M25 | [Drop-in configuration](M25-nvim-drop-in-config.md) | Done |
| M26 | [Helper correctness](M26-nvim-helper-correctness.md) | Done |
| M27 | [Code lens and inlay hints](M27-nvim-lens-inlay.md) | Done |
| M28 | [Cart budget statusline](M28-nvim-cart-statusline.md) | Done |
| M29 | [Included `.lua` settings](M29-nvim-include-buffers.md) | Done |
| M30 | [Include navigation and PNG](M30-nvim-includes-png.md) | Done |
| M31 | [Glyph input](M31-nvim-glyph-input.md) | Done |
| M32 | [Health check](M32-nvim-health.md) | Done |
| M33 | [Standard LSP Hooks for Neovim](https://github.com/asimmons91/pico-lsp/blob/main/docs/M33-nvim-server-hooks.md) | Done (server) |
| M34 | [Tree-sitter installer](M34-nvim-treesitter-install.md) | Done |
| M36 | [End-user onboarding and release readiness](M36-nvim-onboarding-release.md) | Done |

M33, [Standard LSP Hooks for Neovim](https://github.com/asimmons91/pico-lsp/blob/main/docs/M33-nvim-server-hooks.md),
is implemented in the server repository. The client consumes those capabilities
and falls back to `gf` when document links or range formatting are unavailable.
M35 remains the proposed Mason and LazyVim distribution milestone; M36 is the
manual, tagged-release onboarding path and does not depend on M35.

See the [roadmap](../ROADMAP.md) for the recommended order and release policy.
