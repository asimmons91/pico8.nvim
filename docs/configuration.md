# Configuration

## Plugin options

```lua
require("pico_lsp").setup({
  cmd = { "pico-lsp" },       -- optional server command override
  lsp = true,                 -- enable vim.lsp.enable("pico_lsp")
  disable = false,            -- disable the helper and LSP setup
  codelens = true,            -- client-side budget lens display
  inlay_hints = true,         -- client-side inlay-hint display
  glyph_maps = false,         -- install Shift-A..Z P8SCII glyph maps
  settings = {                -- optional pico8 server settings
    pico8 = { typeChecking = "basic" },
  },
})
```

### Options

| Option | Type | Default | Meaning |
|---|---|---|---|
| `cmd` | string, string[], or function | `{ "pico-lsp" }` | Server executable used by the helper and the native client config. |
| `lsp` | boolean | `true` | Call `vim.lsp.enable("pico_lsp")` during setup. |
| `disable` | boolean | `false` | Disable the helper and LSP setup. |
| `codelens` | boolean | `true` | Enable client-side budget lens display for new `pico8` attachments. |
| `inlay_hints` | boolean | `true` | Enable client-side inlay-hint display for new `pico8` attachments. |
| `glyph_maps` | boolean | `false` | Install Shift-A..Z P8SCII glyph maps and prefetch the catalog. `vim.g.pico8_glyph_maps = 1` also enables them. |
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
without it; included `.lua` attachment is the helper's job. Disabling the
helper detaches the `.lua` attachments it created and leaves user-started
clients alone. `:Pico8Refresh` still exists and reports the disabled state
without scanning, and `:Pico8ToggleInlayHints` remains available.

`disable = true` does not turn off the client-side code-lens or inlay-hint
display supplied by the shipped `lsp/pico_lsp.lua`. Use the separate
`codelens` and `inlay_hints` options for that. The cart cache and the
`:Pico8CartInfo`/`:Pico8Tabs` commands also stay available because they work
with any attached `pico_lsp` client; a disabled setup clears cached data.

## Code lens and inlay hints

The shipped config enables both displays for `pico8` buffers:

- the cart budget code lens is returned when `limits.codeLens` is true;
- inferred local type hints are returned when `inlayHints` is true and
  `typeChecking` is not `off`.

The server settings are the feature switches. The client options only control
whether the returned data is displayed. With the default server settings, the
lens appears and inlay hints stay empty because `pico8.inlayHints` defaults to
`false`:

```lua
require("pico_lsp").setup({
  settings = {
    pico8 = { inlayHints = true },
  },
})
```

Options apply to clients started afterwards. `:lsp restart` on Neovim 0.12+ is
enough for `codelens`/`inlay_hints` changes. Server `settings` changes require
re-resolving the client config, so restart Neovim.
`:Pico8ToggleInlayHints` toggles the display for the current buffer without
changing server settings; it warns when `pico8.inlayHints` is false or unset in
the client configuration.

If you use `lsp/pico_lsp.lua` directly without `require("pico_lsp").setup`, the
defaults still apply. If you replace its `on_attach`, enable the display
yourself:

```lua
-- Neovim 0.12+
vim.lsp.codelens.enable(true, { bufnr = bufnr })
-- Neovim 0.11
vim.lsp.codelens.refresh({ bufnr = bufnr })

vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
```

The shipped `on_attach` also runs a wildcard
`vim.lsp.config("*", { on_attach = ... })` callback. A specific config replaces
the wildcard value in Neovim, so the plugin calls it explicitly after its own
enablement. The wildcard callback can disable inlay hints on both versions and
code lens on Neovim 0.12; Neovim 0.11's legacy code-lens engine has no disable
state, and its save hook restores the lens.

The shipped `on_attach` runs after `LspAttach` autocmds. To turn the display off,
use the `codelens`/`inlay_hints` options or a wildcard `on_attach` callback
rather than only disabling it in an `LspAttach` autocmd.

## Cart statusline

The cached cart budget has no setup option and is always available with the
client surface. `require("pico_lsp").cart_status()` returns cached text for a
root cart, an included `.lua` buffer, or a decoded `.p8.png` buffer; it never
blocks on a request. `require("pico_lsp").cart_info()` returns the cached
`pico8/cartInfo` table for statusline colors and other integrations.

The cache refreshes asynchronously after an attach, a save, `InsertLeave`, and a
500 ms edit debounce. Use `require("pico_lsp").refresh_cart_info()` for a manual
refresh. See [usage](usage.md#keymaps-and-cart-budget) for the lualine and plain
statusline recipes.

## Server settings

The server reads the `pico8` section through `workspace/configuration`,
`initializationOptions.pico8`, and `workspace/didChangeConfiguration`. When the
client supports `workspace/configuration`, `pico-lsp` pulls the `pico8` section
after initialization. Server defaults remain authoritative; the plugin ships no
duplicate settings table. The authoritative reference is the
[pico-lsp configuration docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md).

The shipped client mirrors `settings.pico8` into
`initializationOptions.pico8` when no explicit `init_options.pico8` is set.
This makes requests sent during attach, such as the glyph catalog prefetch, see
the configured catalog before the asynchronous configuration pull finishes.
The pull remains authoritative for later server settings changes.

Common settings:

| Setting | Default | Meaning |
|---|---|---|
| `apiVersion` | `0.2.7` | PICO-8 API version. |
| `typeChecking` | `basic` | `off`, `basic`, or `strict`. |
| `inlayHints` | `false` | Return inferred local type hints. Also needs client-side `vim.lsp.inlay_hint.enable`; see [code lens and inlay hints](#code-lens-and-inlay-hints). |
| `limits.codeLens` | `true` | Return the cart budget lens. |
| `limits.diagnostics` | `true` | Publish token/character/compressed limit diagnostics. |
| `format.maxBlankLines` | `2` | Maximum consecutive blank lines. |
| `diagnostics.mode` | `auto` | `auto`, `push`, or `pull`. |

## Glyph maps

Enable the maps with either the setup option:

```lua
require("pico_lsp").setup({ glyph_maps = true })
```

or the global, before opening a cart:

```lua
vim.g.pico8_glyph_maps = 1
```

The maps are opt-in because they replace uppercase letters in Lua code. With
either switch, the client prefetches the `pico8/glyphs` catalog after attach and
caches it per client and cart root. Shift presses read the cached
`byte -> text` map; a cold cache makes one bounded request and then falls back
to literal letters.

The cache lasts for the client lifetime. Changing `pico8.glyphs` requires a
client restart so the new catalog is fetched and the old cache is cleared. See
[usage](usage.md#pico-8-shift-shortcuts).

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

## Tree-sitter installer

`:Pico8InstallParser` is independent of the LSP setup and is registered by both
`require("pico_lsp").setup()` and the shipped `lsp/pico_lsp.lua`. It resolves
the grammar directory in this order:

1. `vim.g.pico8_treesitter_source` when it is set to a non-empty path;
2. `PICO_LSP_TREE_SITTER` when it is set to a non-empty path;
3. `vendor/tree-sitter-pico8` in the plugin.

An explicit override is authoritative even when it is invalid, so a typo does
not silently fall back to the vendored grammar. The installer uses `$CC` when
set, otherwise `cc`, then `clang`; `$CC` is one executable path. It installs to
`stdpath("data")/site` and does not write inside the plugin or your config
directory. See [installation](install.md#tree-sitter) for the full behavior.

## Health check

Run `:checkhealth pico_lsp` for a read-only report of the configuration,
resolved binary and version, clients, client feature state, managed includes,
helper commands, and Tree-sitter availability. It never starts clients,
installs parsers, edits buffers, or changes configuration. See
[troubleshooting](troubleshooting.md#using-checkhealth-pico_lsp) for how to
read the report.
