# Client milestones

These are the Neovim-client milestones inherited from
[`pico-lsp`](https://github.com/asimmons91/pico-lsp). The milestone IDs are
kept for traceability with the server roadmap and the original PRs.

The specifications have been adapted for this repository:

- paths are relative to the plugin root, not `editors/nvim`;
- `pico-lsp M*` references point to server milestones;
- Go test gates belong to `pico-lsp`; this repository runs headless Neovim
  tests;
- M33 is not duplicated here because it adds server capabilities.

| Milestone | Spec | Status |
|---|---|---|
| M25 | [Drop-in configuration](M25-nvim-drop-in-config.md) | Done |
| M26 | [Helper correctness](M26-nvim-helper-correctness.md) | Done |
| M27 | [Code lens and inlay hints](M27-nvim-lens-inlay.md) | Proposed |
| M28 | [Cart budget statusline](M28-nvim-cart-statusline.md) | Proposed |
| M29 | [Included `.lua` settings](M29-nvim-include-buffers.md) | Proposed |
| M30 | [Include navigation and PNG](M30-nvim-includes-png.md) | Proposed |
| M31 | [Glyph input](M31-nvim-glyph-input.md) | Proposed |
| M32 | [Health check](M32-nvim-health.md) | Proposed |
| M34 | [Tree-sitter installer](M34-nvim-treesitter-install.md) | Proposed |

M33, [Standard LSP Hooks for Neovim](https://github.com/asimmons91/pico-lsp/blob/main/docs/M33-nvim-server-hooks.md),
remains in the server repository. The client consumes those capabilities and
falls back to `gf` when document links or range formatting are unavailable.

See the [roadmap](../ROADMAP.md) for the recommended order and release policy.
