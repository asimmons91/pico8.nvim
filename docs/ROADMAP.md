# pico8.nvim — Roadmap

**Status:** M32 and M33 are complete. The existing Neovim client surface is
present and M34 remains proposed.

**Last updated:** 2026-11-24

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
M33 is server-owned in `pico-lsp`; this client consumes its standard LSP
capabilities and tests them here. The `pico-lsp` `editors/nvim` copy is
historical until the migration is complete; this repository is the canonical
client source.

## Current state

- P0 skeleton is complete: helper, `ftdetect`, `ftplugin`, syntax, tests,
  glyph picker, PNG commands, native `lsp/pico_lsp.lua`, lazy.nvim-friendly
  `setup`, vendored Tree-sitter parser sources, and the test fixture.
- M25 is complete: shipped `lsp/pico_lsp.lua`, cart-aware roots, setup
  activation, merged helper config, config/root tests, CI matrix, and install
  documentation.
- M26 is complete: buffer-aware include discovery and caching, root-matched
  client reuse, managed detach and ownership revalidation, save/reload and
  debounced cart-edit rescans, `:Pico8Refresh`, and setup re-entry that keeps
  managed attachments.
- M27 is complete: shipped `on_attach` enablement, per-buffer code lens and
  inlay-hint display, `codelens`/`inlay_hints` setup options, a
  `:Pico8ToggleInlayHints` command, and version-aware Neovim 0.11/0.12
  behavior.
- M28 is complete: asynchronous `pico8/cartInfo` cache keyed by the server's
  `rootUri`, cached statusline functions, `:Pico8CartInfo`, `:Pico8Tabs`,
  refresh autocmds with a 500 ms debounce, and include/PNG support.
- M29 is complete: stock-aware PICO-8 comment defaults for managed includes,
  safe restore, `b:pico8_cart`/`b:pico8_cart_root`, and `:Pico8OpenCart`.
- M30 is complete: buffer-local `include`/`includeexpr` with a cart-scoped
  `path`, cart-relative `gf` navigation for quoted/unquoted/nested/absolute
  includes and `.p8` tab selectors, direct `nvim cart.p8.png` decoding with
  virtual-buffer reuse, safe failure buffers, and `:Pico8OpenPng` file
  completion.
- M31 is complete: cached P8SCII glyph input with attach-time prefetch, byte
  and name insertion, a filtered picker, and cached-name completion.
- M32 is complete: `:checkhealth pico_lsp` reports the Neovim version,
  configuration, binary and version, running clients, client feature state,
  managed includes, helper commands, and Tree-sitter availability without
  changing state.
- M33 is complete: the server's range formatting, document links, and
  code-lens refresh are consumed through Neovim's standard `formatexpr`, `gx`,
  and refresh support. `tests/standard_hooks.lua` covers `gq`, `gx` on Neovim
  0.12, and the unchanged-buffer refusal path.
- M34 is proposed.
- M35 (Mason and LazyVim extra) is proposed after the client surface is stable.

## Milestones

| ID | Milestone | Outcome | Depends on | Status |
|---|---|---|---|---|
| P0 | Skeleton extraction | Plugin layout, existing helper features, tests, grammar vendor, docs | — | Done |
| M25 | Drop-in configuration | `lsp/pico_lsp.lua`, cart-aware roots, setup activation | pico-lsp M6 | Done |
| M26 | Helper correctness | Buffer-aware includes, root-matched clients, managed detach | pico-lsp M6, M25 | Done |
| M27 | Code lens and inlay hints | Existing server features visible in stock Neovim | M25, M26 | Done |
| M28 | Cart budget statusline | Cached cart info, `:Pico8CartInfo`, `:Pico8Tabs` | M25–M27 | Done |
| M29 | Included `.lua` settings | PICO-8 comments, buffer variables, `:Pico8OpenCart` | M26 | Done |
| M30 | Include navigation and PNG | `gf` for includes and direct `.p8.png` opening | pico-lsp M8, M25, M26 | Done |
| M31 | Glyph input polish | Cached catalog, byte insertion, filtered picker | pico-lsp M16, M26 | Done |
| M32 | Health check | `:checkhealth pico_lsp` | M25–M31 | Done |
| M33 | Standard LSP hooks | Range formatting, document links, code-lens refresh | pico-lsp M7, M8, M11, M14 | Done |
| M34 | Tree-sitter installer | Build and install the vendored parser and queries | pico-lsp M12, M25 | Proposed |
| M35 | Mason and LazyVim extra | Mason package, LazyVim extra, plugin release automation | M25–M32, M34 | Proposed |

## Recommended order

1. **P0** — keep the skeleton green.
2. **M25** — configuration foundation (complete). **M26** — harden the include
   helper (complete). **M27** — show the server's lens and hints (complete).
   **M28** — cached cart statusline and tab picker (complete). **M29** —
   included `.lua` settings and `:Pico8OpenCart` (complete). **M30** — include
   navigation and direct PNG opening (complete). **M31** — cached glyph input,
   byte forms, and filtered picker (complete). **M32** — `:checkhealth
   pico_lsp` (complete). **M33** — standard range formatting, document links,
   and code-lens refresh (complete).
3. **M34** — parser installer.
4. **M35** — Mason and LazyVim distribution.

The client falls back to `gf` when an older server does not advertise document
links or range formatting.

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
- Tests cover attachment, includes, `gf` navigation, PNG carts and auto-open,
  glyph cache and prefetch behavior, byte insertion, picker filtering,
  completion, commands, health checks, and failure paths.
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

M25's cart-directory root strategy was confirmed on 2026-11-23. The shipped
config does not walk to `.git`; users can override `root_dir` for
repository-wide symbols.

M26's implementation choices were confirmed on 2026-11-23: a 300 ms debounce,
`:Pico8Refresh` registered even when the helper is disabled, existing
user-started `pico_lsp` clients left untouched, and a loaded cart buffer kept
authoritative so external changes require a cart reload.

M27's implementation choices were confirmed on 2026-11-23: the inlay toggle
warns when `pico8.inlayHints` is false **or unset** because the server default is
false, and `:Pico8ToggleInlayHints` is registered even when the helper is
disabled because it only controls client-side display. Display enablement is
limited to `pico8` buffers; included `.lua` files are untouched. Re-attach
reconciles stale display state with the current options, a bounded post-attach
hint refresh handles the server `didOpen` race, and the shipped `on_attach`
preserves a wildcard `vim.lsp.config("*")` callback.

M28's implementation choices were confirmed on 2026-11-23: the shipped
`lsp/pico_lsp.lua` loads the cart module so base-config users get the cache and
commands without `setup`; edit-triggered refreshes use a 500 ms debounce;
`:Pico8Tabs` always shows the picker, fetches fresh tab lines, and falls back to
the cache on error; `:Pico8CartInfo` includes a capped per-file breakdown; and
the cart commands stay available when the included-Lua helper is disabled. The
pico-lsp API docs link is [asimmons91/pico-lsp#71](https://github.com/asimmons91/pico-lsp/pull/71);
merge it before a release that claims the external link.

M29's implementation choices were confirmed on 2026-11-23: comment defaults are
applied per option, so a custom `comments` does not prevent a stock/empty
`commentstring` from being filled in; exact PICO-8 values are treated as user
values and are neither claimed nor restored; `:Pico8OpenCart` works only for
helper-managed includes (a user-started `pico_lsp` attachment reports no owner);
and the command stays registered after a later disabled setup, where it reports
the disabled helper. A fresh disabled setup does not register it. Restore
records are module-local, so a plugin reload before detach leaves exact PICO-8
values in place; this follows the exact-target rule rather than guessing a
previous value. Setting an option to exactly the target after attach is also
restored, because it is indistinguishable from the helper's value.

M30's implementation choices were confirmed on 2026-11-23: `include` is
buffer-local when empty, so a global value is treated as a default and
overridden locally; `includeexpr` is local to the buffer, so any non-empty
value is preserved as a user value; and `path` is scoped to the cart when it is
empty or the default, with a custom value preserved. The scoped path follows
`:saveas`/`:file`, and directories with path glob characters use `includeexpr`
instead of Vim's raw lookup. `includeexpr` prefers the complete target on the
cursor's `#include` line, so quoted paths with spaces, literal `.lua:2` names,
and selector digits survive Neovim's `gf` tokenization, then falls back to
`v:fname`. Failed PNG auto-open leaves the named source buffer as an empty,
read-only `nofile` buffer. Reopening a PNG reuses its virtual buffer, preserves
custom include/expression/path values (including after-ftplugin/`FileType`
values) and a custom global path, restores virtual options after `:bdelete` or
a direct `:buffer` load and lists the restored cart, keeps a deliberately
unlisted buffer unlisted on reload, and reload reattaches the client. Decoded
`.p8.png` virtual buffers carry `b:pico8_cart_root` and a scoped `path`, so
include navigation resolves against the source PNG's directory. Vim's first
unmodified-name lookup can still match the first word of a quoted spaced path
when that word is a file in the cart; troubleshooting documents the workaround.
The PNG autocmd is installed only by an enabled `require("pico_lsp").setup()`,
never by the shipped config alone.

M32's implementation choices were confirmed on 2026-11-24: an unset
`pico8.limits.codeLens` is treated as the server default `true`, so health warns
when the client display is disabled; missing helper commands warn only after an
enabled `require("pico_lsp").setup()`, while base-config users get info; and
the settings report shows selected keys (`apiVersion`, `typeChecking`,
`inlayHints`, `limits.codeLens`, `diagnostics.mode`) instead of the full
table. Health inspects a fresh session without executing `lsp/pico_lsp.lua`
(it compiles the runtime file only), and it recovers the pre-`:checkhealth`
cart from a non-health window in the current tab before falling back to the
previous tab. The Tree-sitter check uses the return value from
`vim.treesitter.language.add`, because a missing parser returns `nil` rather
than raising.

M33's implementation choices were confirmed on 2026-11-24: document links use a
parser-owned path span (quotes included) rather than the whole directive; range
formatting mirrors document formatting and only refuses missing includes for the
cart root; the server skips code-lens refresh when `pico8.limits.codeLens` is
false; and the headless client test uses `gq` on Neovim 0.11+ and `gx` with a
stubbed `vim.ui.open` only on Neovim 0.12+.

1. **Server distribution:** Mason package versus PATH/installation docs;
   plugin-managed downloads are deferred.
2. **Parser distribution:** vendored sources (current) versus prebuilt parser
   assets per OS/architecture.
3. **LazyVim extra:** contribute upstream after the plugin and Mason package
   are stable, rather than treating a plugin as an extra.
4. **Statusline surface:** resolved in M28 — cached `cart_info`/`cart_status`
   functions with documented lualine and plain statusline recipes; no
   statusline dependency.
