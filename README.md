# pico8.nvim

Neovim client for [`pico-lsp`](https://github.com/asimmons91/pico-lsp), a
PICO-8 language server built in Go. The plugin provides PICO-8 filetype
detection, LSP setup, cart-owned `.lua` attachment, `pico8/cartInfo` status
helpers, a P8SCII glyph picker, read-only `.p8.png` opening, and a home for the
Neovim-specific milestones inherited from the server repository.

**Status:** M27 is complete. The plugin ships native LSP configuration,
cart-aware roots, one-call activation, a buffer-aware cart-owned `.lua` helper
with managed attachment and `:Pico8Refresh`, and client-side enabling for the
cart budget code lens and inlay hints. M28–M32 and M34 are proposed; M33 (range
formatting, document links, and code-lens refresh) remains server work in
`pico-lsp`.

## Requirements

- Neovim 0.11 or newer.
- A `pico-lsp` binary on `PATH`, or a configured command.
- Optional: a C compiler for manual Tree-sitter parsing. The parser installer
  is a proposed milestone.

## Install

### lazy.nvim / LazyVim

Put this in `lua/plugins/pico8.lua`:

```lua
return {
  {
    "asimmons91/pico8.nvim",
    main = "pico_lsp",
    lazy = false,
    opts = {},
  },
}
```

`lazy = false` is intentional. The plugin ships `ftdetect`, `ftplugin`, and
`syntax` files; those runtime files must be available before the first `.p8`
buffer is opened. `opts = {}` runs `require("pico_lsp").setup({})` and enables
the `pico_lsp` client by default. Set `opts = { lsp = false }` if you want to
manage `vim.lsp.enable` yourself.

For local development before the plugin is tagged:

```lua
{
  dir = vim.fn.expand("~/projects/pico8.nvim"),
  name = "pico8.nvim",
  main = "pico_lsp",
  lazy = false,
  opts = {},
}
```

### Vanilla Neovim

```lua
vim.opt.runtimepath:append("/path/to/pico8.nvim")
require("pico_lsp").setup()
```

`lsp/pico_lsp.lua` is the only LSP configuration file, and it attaches to
buffers whose filetype is `pico8`. Neovim 0.11+ loads it from `runtimepath`.
The plugin also ships `ftdetect` (which assigns that filetype to `.p8` files),
`ftplugin`, `syntax`, the cart-owned `.lua` helper, and commands. Keep the
plugin on `runtimepath` or lazy-load it before the first cart opens so those
runtime files are available.

### Workspace root

The shipped config uses the directory containing the cart as `root_dir`. A cart
in a plain directory with no `.git` still has a workspace root, `#include`
paths resolve from that directory, and workspace symbols scan the cart's
directory rather than an unrelated repository root. Carts in different
directories start separate clients.

To use a repository-wide root instead, override `root_dir` before opening a
cart:

```lua
vim.lsp.config("pico_lsp", {
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return
    end
    local git = vim.fs.root(bufnr, { ".git" })
    on_dir(git or vim.fs.dirname(vim.fs.normalize(name)))
  end,
})
```

The example uses the git root when one exists and falls back to the cart
directory otherwise. There is no default `.git` fallback in the shipped
config. A user override replaces the shipped callback; the two roots are not
merged.

### Server binary

Install `pico-lsp` from a [GitHub release](https://github.com/asimmons91/pico-lsp/releases)
or with:

```sh
go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@latest
```

Verify it with `pico-lsp --version`. A Mason package is planned.

## What works now

- `pico-lsp` attaches to `.p8` carts through the shipped `lsp/pico_lsp.lua`
  config after `require("pico_lsp").setup()` (or `opts = {}` with lazy.nvim).
- Carts in plain, non-git directories use the cart directory as the client
  root; carts in different directories get separate roots.
- Cart-owned `.lua` files attach through the helper. An unsaved `#include` is
  visible immediately, cart saves and edits are rescanned, and the helper only
  detaches clients it manages.
- The shipped config enables the cart budget code lens and inlay-hint display
  for `pico8` buffers. `pico8.limits.codeLens` and `pico8.inlayHints` on the
  server decide what appears; the latter defaults to off.
- PICO-8 comments, syntax highlighting, and the optional `Shift-A`–`Shift-Z`
  glyph maps work for `.p8` carts.
- Read-only `.p8.png` carts open through `:Pico8OpenPng` and `:Pico8ReloadPng`.
- The P8SCII glyph picker is available through `:Pico8InsertGlyph`.
- `pico8/cartInfo` is available through the documented request; the cached
  statusline API is proposed in M28.

### Opt-in LSP features

The shipped config enables client-side display for the cart budget code lens
and inferred-type inlay hints on `pico8` buffers. The server settings remain the
feature switches:

- `pico8.limits.codeLens` returns the budget lens.
- `pico8.inlayHints` returns local type hints when enabled and `typeChecking`
  is not `off`. It defaults to `false`, so set it to `true` in `settings` to see
  hints. The authoritative defaults and full settings table are in the
  [pico-lsp configuration reference](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md).

Turn the client-side display off for clients started afterwards:

```lua
require("pico_lsp").setup({ codelens = false, inlay_hints = false })
```

Restart the client for setup changes to take effect: `:lsp restart` on Neovim
0.12+, or
`:lua vim.lsp.enable("pico_lsp", false); vim.lsp.enable("pico_lsp")` on 0.11.
`:Pico8ToggleInlayHints` flips the display for the current buffer and warns when
`pico8.inlayHints` is false or unset.

The display is also enabled when you use the shipped `lsp/pico_lsp.lua` without
calling setup. If you replace its `on_attach`, add the enablement yourself:

```lua
-- Neovim 0.12+
vim.lsp.codelens.enable(true, { bufnr = bufnr })
-- Neovim 0.11
vim.lsp.codelens.refresh({ bufnr = bufnr })

vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
```

## Commands

| Command | Purpose |
|---|---|
| `:Pico8OpenPng [path]` | Decode a `.p8.png` cart into a read-only virtual buffer. |
| `:Pico8ReloadPng` | Re-decode the current virtual `.p8.png` cart. |
| `:Pico8InsertGlyph [name]` | Insert a P8SCII glyph or open the picker. |
| `:Pico8Refresh` | Clear the include cache and rescan loaded buffers. |
| `:Pico8ToggleInlayHints` | Toggle client-side inlay hints for the current buffer. |
| `:Pico8CartInfo`, `:Pico8Tabs` | Proposed in M28. |
| `:checkhealth pico_lsp` | Proposed in M32. |

## Configuration

```lua
require("pico_lsp").setup({
  cmd = { "pico-lsp" },       -- optional command override
  lsp = true,                 -- enable the pico_lsp client on setup
  disable = false,            -- disable the helper and LSP setup
  codelens = true,            -- client-side budget lens display
  inlay_hints = true,         -- client-side inlay-hint display
  settings = {                -- optional pico8 server settings
    pico8 = { typeChecking = "basic" },
  },
})
```

The shipped config does not repeat server defaults. `settings` is merged into
`vim.lsp.config("pico_lsp", ...)` and the helper reads the same merged config.

Command resolution checks `vim.g.pico_lsp_cmd`, then `PICO_LSP_BIN`, then
`pico-lsp` on `PATH`; `setup({ cmd = ... })` and a later
`vim.lsp.config("pico_lsp", { cmd = ... })` override the shipped value.
`setup` and the shipped config normalize string commands to a one-element list;
a value passed directly to `vim.lsp.config` must already be a list or function.
See [configuration](docs/configuration.md) for root overrides and the server
settings reference.

## Documentation

- [Installation](docs/install.md)
- [Usage](docs/usage.md)
- [Configuration](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Roadmap](docs/ROADMAP.md)
- [Client milestones](docs/milestones/README.md)
- `:help pico8` for the in-editor command summary

## Development

```sh
# Run the headless config and helper tests against an installed server.
PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
```

The tests create temporary carts and exercise config resolution, command-line
overrides, cart and include roots, attachment without a shipped config, unsaved
includes, managed detach, multiple carts, PNG opening, glyph insertion, and
fallback behavior. The CI workflow checks out the server and builds a test
binary on Neovim 0.11 and 0.12.

## Relationship to pico-lsp

`pico-lsp` owns the Go server, parser, analysis, formatter, and standard LSP
capabilities. `pico8.nvim` owns the Neovim plugin, filetype runtime files,
commands, statusline helpers, health checks, and Neovim-specific tests.

The M25–M32 and M34 specs are inherited from `pico-lsp` for traceability. M33
stays in the server repository because it adds server capabilities.

## License

MIT. The Tree-sitter parser sources are derived from tree-sitter-lua; see
`vendor/tree-sitter-pico8/LICENSE.tree-sitter-lua`.
