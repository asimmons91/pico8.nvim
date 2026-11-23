# Configuration

## Plugin options

```lua
require("pico_lsp").setup({
  cmd = { "pico-lsp" },       -- optional server command override
  lsp = true,                 -- enable vim.lsp.enable("pico_lsp")
  disable = false,            -- disable the helper and LSP setup
  settings = {                -- optional pico8 server settings
    pico8 = { typeChecking = "basic" },
  },
})
```

### Options

| Option | Type | Default | Meaning |
|---|---|---|---|
| `cmd` | string or string[] | `{ "pico-lsp" }` | Server executable used by the helper and the native client config. |
| `lsp` | boolean | `true` | Call `vim.lsp.enable("pico_lsp")` during setup. |
| `disable` | boolean | `false` | Disable the helper and LSP setup. |
| `settings` | table | unset | `pico8` settings passed to the client config. |

`vim.g.pico_lsp_cmd` and `PICO_LSP_BIN` are also accepted. A `cmd` string is
normalized to a one-element list because Neovim's LSP client rejects a bare
string.

Command resolution:

- The shipped `lsp/pico_lsp.lua` checks `vim.g.pico_lsp_cmd`, then
  `PICO_LSP_BIN`, then `pico-lsp` on `PATH`.
- `cmd` in `require("pico_lsp").setup()` and a user
  `vim.lsp.config("pico_lsp", { cmd = ... })` call override the shipped value;
  whichever runs last wins.
- `setup` normalizes a `cmd` string to a one-element list and preserves a table
  or function. The shipped config normalizes string values from
  `vim.g.pico_lsp_cmd` and `PICO_LSP_BIN`. A value passed directly to
  `vim.lsp.config` must already be a list or function; Neovim does not normalize
  it.

`cmd` and `settings` are merged into `vim.lsp.config("pico_lsp", ...)` during
setup, including when `lsp = false`; that option only controls
`vim.lsp.enable`. The shipped `lsp/pico_lsp.lua` contains no `settings` table;
`pico-lsp` owns the defaults. The helper reads the same merged config.

### Workspace root

The shipped config uses the cart directory as `root_dir`. There is no default
`.git` walk, so a cart outside a repository still gets a workspace root. Carts
in sibling directories start separate clients.

Override the root before opening carts if you want repository-wide symbols:

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
directory otherwise. The override replaces the shipped callback; it is not
merged. An existing client keeps its root until it restarts.

### Disable the helper

```lua
require("pico_lsp").setup({ disable = true })
```

or:

```lua
vim.g.pico_lsp_helper_disabled = 1
```

The helper is optional. Opening `.p8` carts works through the native LSP config
without it; included `.lua` attachment is the helper's job.

## Server settings

The server reads the `pico8` section through `workspace/configuration`,
`initializationOptions.pico8`, and `workspace/didChangeConfiguration`. When the
client supports `workspace/configuration`, `pico-lsp` pulls the `pico8` section
after initialization. Server defaults remain authoritative; the plugin ships no
duplicate settings table. The authoritative reference is the
[pico-lsp configuration docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md).

Common settings:

| Setting | Default | Meaning |
|---|---|---|
| `apiVersion` | `0.2.7` | PICO-8 API version. |
| `typeChecking` | `basic` | `off`, `basic`, or `strict`. |
| `inlayHints` | `false` | Show inferred local type hints. |
| `limits.codeLens` | `true` | Show the cart budget lens. |
| `limits.diagnostics` | `true` | Publish token/character/compressed limit diagnostics. |
| `format.maxBlankLines` | `2` | Maximum consecutive blank lines. |
| `diagnostics.mode` | `auto` | `auto`, `push`, or `pull`. |

## Glyph maps

```lua
vim.g.pico8_glyph_maps = 1
```

Set before opening a cart. The maps are opt-in because they replace uppercase
letters in Lua code. See [usage](usage.md#pico-8-shift-shortcuts).

## Standalone native config

If you prefer not to use the plugin's `lsp` activation, this complete starting
point does not depend on the shipped defaults:

```lua
require("pico_lsp").setup({ lsp = false })

vim.lsp.config("pico_lsp", {
  cmd = { "pico-lsp" },
  filetypes = { "pico8" },
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return
    end
    local git = vim.fs.root(bufnr, { ".git" })
    on_dir(git or vim.fs.dirname(vim.fs.normalize(name)))
  end,
  settings = {
    pico8 = { typeChecking = "strict" },
  },
})

vim.lsp.enable("pico_lsp")
```

The helper reads the merged `vim.lsp.config["pico_lsp"]` value.

## Future options

The following are proposed and not available yet:

- `codelens`, `inlay_hints` (M27);
- cached cart info/statusline (M28);
- `:checkhealth pico_lsp` (M32);
- `:Pico8InstallParser` (M34).
