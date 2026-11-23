# pico8.nvim

Neovim client for [`pico-lsp`](https://github.com/asimmons91/pico-lsp), a
PICO-8 language server built in Go. The plugin provides PICO-8 filetype
detection, LSP setup, cart-owned `.lua` attachment, `pico8/cartInfo` status
helpers, a P8SCII glyph picker, read-only `.p8.png` opening, and a home for the
Neovim-specific milestones inherited from the server repository.

**Status:** Skeleton extraction. The existing helper, ftplugin, syntax,
ftdetect, PNG support, glyph input, and tests are in place. The M25 client
skeleton (native config, cart-aware roots, and setup activation) is present; the
remaining M25 work and M26–M32/M34 are proposed and unimplemented. M33 (range
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

### Server binary

Install `pico-lsp` from a [GitHub release](https://github.com/asimmons91/pico-lsp/releases)
or with:

```sh
go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@latest
```

Verify it with `pico-lsp --version`. A Mason package is planned but not part of
the skeleton.

## What works now

- `pico-lsp` attaches to `.p8` carts through the native `lsp/pico_lsp.lua`
  config.
- Cart-owned `.lua` files attach through the helper. Buffer-aware unsaved
  `#include` discovery is proposed in M26.
- PICO-8 comments, syntax highlighting, and the optional `Shift-A`–`Shift-Z`
  glyph maps work for `.p8` carts.
- Read-only `.p8.png` carts open through `:Pico8OpenPng` and `:Pico8ReloadPng`.
- The P8SCII glyph picker is available through `:Pico8InsertGlyph`.
- `pico8/cartInfo` is available through the documented request; the cached
  statusline API is proposed in M28.

## Commands

| Command | Purpose |
|---|---|
| `:Pico8OpenPng [path]` | Decode a `.p8.png` cart into a read-only virtual buffer. |
| `:Pico8ReloadPng` | Re-decode the current virtual `.p8.png` cart. |
| `:Pico8InsertGlyph [name]` | Insert a P8SCII glyph or open the picker. |
| `:Pico8Refresh` | Proposed in M26. |
| `:Pico8CartInfo`, `:Pico8Tabs` | Proposed in M28. |
| `:checkhealth pico_lsp` | Proposed in M32. |

## Configuration

```lua
require("pico_lsp").setup({
  cmd = { "pico-lsp" },       -- optional command override
  lsp = true,                 -- enable the native client on setup
  disable = false,            -- disable the helper and LSP setup
  settings = {                -- optional pico8 server settings
    pico8 = { typeChecking = "basic" },
  },
})
```

`vim.g.pico_lsp_cmd` and `PICO_LSP_BIN` are also accepted. The server settings
reference is in the [pico-lsp configuration docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md).

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
# Run the headless helper tests against an installed server.
PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
```

The tests create temporary carts and exercise attachment, PNG opening, glyph
insertion, and fallback behavior. The CI workflow checks out the server and
builds a test binary.

## Relationship to pico-lsp

`pico-lsp` owns the Go server, parser, analysis, formatter, and standard LSP
capabilities. `pico8.nvim` owns the Neovim plugin, filetype runtime files,
commands, statusline helpers, health checks, and Neovim-specific tests.

The M25–M32 and M34 specs are inherited from `pico-lsp` for traceability. M33
stays in the server repository because it adds server capabilities.

## License

MIT. The Tree-sitter parser sources are derived from tree-sitter-lua; see
`vendor/tree-sitter-pico8/LICENSE.tree-sitter-lua`.
