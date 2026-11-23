# pico8.nvim — Roadmap

**Status:** Skeleton extracted from `pico-lsp`. The existing Neovim client
surface is present; the inherited client milestones are proposed and
unimplemented except for the M25 skeleton.

**Last updated:** 2026-11-23

**Server:** [`pico-lsp`](https://github.com/asimmons91/pico-lsp)

**Target:** Neovim 0.11+; PICO-8 0.2.7 through `pico-lsp`

## Vision

Make PICO-8 the best-supported non-standard Lua dialect in Neovim:

- correct `.p8` carts, includes, code tabs, and PICO-8 shorthand;
- native Neovim LSP setup without requiring `nvim-lspconfig`;
- cartridge-aware attachment for included `.lua` files;
- visible token, character, and compressed-size budgets;
- P8SCII input that matches the PICO-8 editor without fighting Neovim;
- read-only `.p8.png` carts and editor-only Tree-sitter highlighting;
- installation through a normal lazy.nvim plugin spec.

The plugin stays a **thin client**. Language analysis, diagnostics, types,
formatting, and standard LSP capabilities belong to `pico-lsp`.

## Relationship to pico-lsp

| Repository | Owns |
|---|---|
| [`pico-lsp`](https://github.com/asimmons91/pico-lsp) | Go server, parser, analysis, formatter, diagnostics, public Go packages, standard LSP capabilities |
| `pico8.nvim` | Lua client, filetype runtime files, commands, statusline helpers, health checks, Neovim tests, editor-only Tree-sitter grammar |

M25–M32 and M34 are inherited milestone IDs from `pico-lsp` for traceability.
M33 is server-owned and remains in `pico-lsp`. The `pico-lsp`
`editors/nvim` copy is historical until the migration is complete; this
repository is the canonical client source.

## Current state

- P0 skeleton is complete: helper, `ftdetect`, `ftplugin`, syntax, tests,
  glyph picker, PNG commands, native `lsp/pico_lsp.lua`, lazy.nvim-friendly
  `setup`, vendored Tree-sitter parser sources, and the test fixture.
- M25 is partially implemented: the shipped `lsp/pico_lsp.lua`, cart-aware
  roots, setup activation, and command normalization are present. Config
  tests, full documentation, and the final CI matrix remain.
- M26–M32 and M34 are proposed.
- M33 is an external server dependency.
- M35 (Mason and LazyVim extra) is proposed after the client surface is stable.

## Milestones

| ID | Milestone | Outcome | Depends on | Status |
|---|---|---|---|---|
| P0 | Skeleton extraction | Plugin layout, existing helper features, tests, grammar vendor, docs | — | Done |
| M25 | Drop-in configuration | `lsp/pico_lsp.lua`, cart-aware roots, setup activation | pico-lsp M6 | Skeleton |
| M26 | Helper correctness | Buffer-aware includes, root-matched clients, managed detach | pico-lsp M6, M25 | Proposed |
| M27 | Code lens and inlay hints | Existing server features visible in stock Neovim | M25, M26 | Proposed |
| M28 | Cart budget statusline | Cached cart info, `:Pico8CartInfo`, `:Pico8Tabs` | M25–M27 | Proposed |
| M29 | Included `.lua` settings | PICO-8 comments, buffer variables, `:Pico8OpenCart` | M26 | Proposed |
| M30 | Include navigation and PNG | `gf` for includes and direct `.p8.png` opening | pico-lsp M8, M25, M26 | Proposed |
| M31 | Glyph input polish | Cached catalog, byte insertion, filtered picker | pico-lsp M16, M26 | Proposed |
| M32 | Health check | `:checkhealth pico_lsp` | M25–M31 | Proposed |
| M33 | Standard LSP hooks | Range formatting, document links, code-lens refresh | pico-lsp M7, M8, M11, M14 | External (pico-lsp) |
| M34 | Tree-sitter installer | Build and install the vendored parser and queries | pico-lsp M12, M25 | Proposed |
| M35 | Mason and LazyVim extra | Mason package, LazyVim extra, plugin release automation | M25–M32, M34 | Proposed |

## Recommended order

1. **P0** — keep the skeleton green.
2. **M25–M26** — finish the config and harden the include helper.
3. **M27–M31** — visible and ergonomic client features.
4. **M32** — health checks.
5. **M33** — server-owned; ship in `pico-lsp` when ready.
6. **M34** — parser installer.
7. **M35** — Mason and LazyVim distribution.

M33 can ship before or after the client milestones; the client gracefully
falls back to `gf` when document links and range formatting are unavailable.

## Release and compatibility

- The plugin follows its own semver. A plugin release documents a minimum
  `pico-lsp` version and can run against newer servers.
- M32's health check reports the server binary, version, root, and settings;
  it warns rather than refusing to start on a version mismatch.
- The server remains editor-agnostic. The plugin must not require changes to
  the LSP protocol for client-only features.
- A `pico8.nvim` tag should be cut only after the corresponding client tests
  pass against a released `pico-lsp` binary.

## Testing

- Headless Neovim tests under `tests/` use a real `pico-lsp` binary through
  `PICO_LSP_BIN`.
- CI checks out or installs the server, then runs the suite on Neovim 0.11 and
  0.12.
- Tests cover attachment, includes, PNG carts, glyph input, commands, and
  failure paths.
- Server tests, Go fuzz tests, and LSP e2e tests remain in `pico-lsp`.
- Manual checks for LazyVim, lazy.nvim, and vanilla `runtimepath` are recorded
  in the milestone checklist.

## Documentation map

- [`README.md`](../README.md) — install and feature overview.
- [`docs/install.md`](install.md) — plugin and server installation.
- [`docs/usage.md`](usage.md) — carts, includes, PNG, glyphs, keymaps.
- [`docs/configuration.md`](configuration.md) — plugin options and server
  settings.
- [`docs/troubleshooting.md`](troubleshooting.md) — health, logs, and common
  failures.
- [`docs/milestones/README.md`](milestones/README.md) — inherited client
  milestone index.
- [`doc/pico8.txt`](../doc/pico8.txt) — `:help pico8`.

## Open decisions

1. **M25 root strategy:** cart directory (recommended) versus repository root.
2. **Server distribution:** Mason package versus PATH/installation docs;
   plugin-managed downloads are deferred.
3. **Parser distribution:** vendored sources (current) versus prebuilt parser
   assets per OS/architecture.
4. **LazyVim extra:** contribute upstream after the plugin and Mason package
   are stable, rather than treating a plugin as an extra.
5. **Statusline surface:** a plain cached function first; optional lualine
   recipe, not a hard dependency.
