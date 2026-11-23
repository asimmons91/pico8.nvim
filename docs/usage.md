# Usage

## LSP setup

Installing the plugin and calling `require("pico_lsp").setup()` enables
`pico_lsp` for `pico8` buffers. The shipped `lsp/pico_lsp.lua` provides:

- `cmd = { "pico-lsp" }` unless overridden;
- `filetypes = { "pico8" }`;
- the cart directory as `root_dir`;
- client-side display for the cart budget code lens and inlay hints.

Users can override it:

```lua
vim.lsp.config("pico_lsp", {
  cmd = { "/absolute/path/to/pico-lsp" },
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
```

A user override replaces the shipped callback. Configure it before opening a
cart; existing clients keep their root until they restart.

Set `opts = { lsp = false }` to manage `vim.lsp.enable("pico_lsp")` yourself.

The shipped config carries no server settings; `pico-lsp` owns the defaults.
The same settings can be passed as `init_options = { pico8 = { ... } }` instead
of `settings`. If the client supports `workspace/configuration`, the server
pulls the `pico8` section after `initialized` and prefers pulled values per
field.

Avoid running `lua_ls` and `pico_lsp` on the same cart-owned `.lua` buffer.

## Included `.lua` files

The helper walks up from a `.lua` buffer to find the nearest `.p8` cart that
includes it, then starts or reuses the `pico_lsp` client with that cart's
directory as `root_dir`.

It:

- reads a loaded cart buffer, so an unsaved `#include` is visible as soon as the
  included file is opened;
- reads an unloaded cart from disk and caches its include set by mtime and size;
- ignores unrelated `.lua` buffers;
- reuses a client only when its root matches the cart directory, so carts in
  sibling directories never cross-attach;
- rescans loaded `.lua` buffers after a cart save or reload and 300 ms after
  cart edits;
- records the attachments it creates and detaches only those when an include
  disappears or moves to a cart with a different root.

If a `.lua` buffer already has a `pico_lsp` client, the helper leaves it alone.
That includes clients you start yourself. The helper never detaches an
attachment it did not record.

Use `:Pico8Refresh` to clear cached include data and rescan loaded `.lua`
buffers:

```vim
:Pico8Refresh
```

A loaded cart buffer is authoritative. After an external tool changes an open
cart, reload it with `:edit!`; the helper rescans on reload. `:Pico8Refresh`
does not reload cart buffers, so use it for carts that are not loaded.

The command is safe with no carts open and when the helper is disabled; in the
disabled case it reports that state and does no scanning.

Enable the helper with `require("pico_lsp").setup()` (the default when the
plugin is installed through lazy.nvim). Disable it with:

```lua
require("pico_lsp").setup({ disable = true })
```

or `vim.g.pico_lsp_helper_disabled = 1`.

Disabling detaches the cart-owned `.lua` attachments the helper created. A
`pico_lsp` client you started yourself remains attached. A fresh disabled setup
registers only `:Pico8Refresh`, which reports the disabled state; commands
already registered by an earlier enabled setup also report it. Re-running setup
while `pico_lsp` is already enabled keeps existing helper-managed and
user-started clients attached.

The `.p8` ftplugin sets PICO-8 comment options for carts:

```vim
setlocal comments=:---,:--,://
setlocal commentstring=--\ %s
```

PICO-8 comment settings for cart-owned `.lua` buffers, including `//`
recognition and `b:pico8_cart`, are proposed in M29.

## Read-only `.p8.png` carts

```vim
:Pico8OpenPng path/to/cart.p8.png
:Pico8ReloadPng
```

`:Pico8OpenPng` requests `pico8/decodeCart`, opens a `pico8-cart:` virtual
buffer, marks it `nomodifiable`, and attaches the existing `pico_lsp` client.
Use `:Pico8ReloadPng` after replacing the PNG file.

Navigation, diagnostics, completion, hover, and `pico8/cartInfo` work on the
virtual buffer; formatting and edits are refused because the PNG is read-only.
Auto-opening `nvim cart.p8.png` is proposed in M30.

For a static fallback:

```sh
pico-lsp decode --output /tmp/cart.p8 path/to/cart.p8.png
```

## P8SCII glyph input

Type `p8_left` in code or a string and accept completion to insert `⬅️`. The
`p8-` form is accepted for `pico8-ls` compatibility. Control entries such as
`p8_font_custom` (`\14`) are offered only inside strings.

The helper adds a picker:

```vim
:Pico8InsertGlyph
```

Pass a name to insert directly:

```vim
:Pico8InsertGlyph left
```

Custom font slots are declared in `pico8.glyphs`; see the
[pico-lsp configuration reference](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md#p8scii-glyph-snippets).
The server inserts the canonical Unicode spelling for the chosen byte because
it cannot inspect custom font pixels.

Byte insertion, search filtering, and catalog caching are proposed in M31.

### PICO-8 Shift shortcuts

The optional ftplugin installs PICO-8's `Shift-A` through `Shift-Z` insert-mode
glyph shortcuts. Enable them before opening a cart:

```lua
vim.g.pico8_glyph_maps = 1
```

In Lua code sections (but not `#include` paths), the mappings fetch the
canonical glyph text from the server's `pico8/glyphs` catalog by byte. Outside
Lua code, in include paths, without a client, or for a byte with no catalog
entry, the key inserts the literal uppercase letter. Use `CTRL-V u<hex>` to
insert a literal uppercase letter in code, for example `CTRL-V u0055` for `U`.

The maps are buffer-local to `pico8` buffers; included `.lua` files do not
receive them. Read-only `.p8.png` buffers do not accept insertions.

The remaining printable P8SCII characters are available through `p8_`
completion or `:Pico8InsertGlyph`. PICO-8's `CTRL-J` (Hiragana), `CTRL-K`
(Katakana), and `CTRL-P` (puny font) input modes are not implemented because
they conflict with Neovim's built-in insert-mode keys.

## Syntax highlighting

The plugin ships `syntax/pico8.vim` and the editor-oriented Tree-sitter grammar
under `vendor/tree-sitter-pico8`. The grammar highlights cart headers, sections,
tab markers, dialect syntax, and non-code payloads.

See [installation](install.md#tree-sitter) for the manual parser build. The
`:Pico8InstallParser` command is proposed in M34.

The Vim syntax file remains the no-compiler fallback. LSP semantic tokens cover
Lua code, while the syntax file also highlights non-code `.p8` sections.

## Comments

`ftplugin/pico8.vim` sets buffer-local comment options for carts:

```vim
setlocal commentstring=--\ %s
setlocal comments=:---,:--,://
```

This makes `gcc`/`gc` use `--`, while comment-aware formatting recognizes both
PICO-8 line-comment leaders. Neovim configs normally enable ftplugins with
`filetype plugin on`; LazyVim and most distributions do this by default.

## Keymaps and cart budget

The plugin does not install keymaps. Recommended mappings:

```lua
vim.keymap.set("n", "gd", vim.lsp.buf.definition)
vim.keymap.set("n", "K", vim.lsp.buf.hover)
vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename)
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action)
```

The server publishes a budget code lens on the root cart. The shipped config
enables its client-side display, so it appears without extra setup. The lens
marks compressed budgets with `(warning)` from 90% of the limit and
`(over limit)` above it.

Inferred local type hints appear when the server setting is on:

```lua
require("pico_lsp").setup({
  settings = { pico8 = { inlayHints = true } },
})
```

The client display is enabled by default. Turn either display off for clients
started afterwards:

```lua
require("pico_lsp").setup({
  codelens = false,
  inlay_hints = false,
})
```

`:LspRestart` after changing setup options. `:Pico8ToggleInlayHints` toggles the
display for the current buffer without changing server settings; it warns when
`pico8.inlayHints` is false or unset. If you replace the shipped `on_attach`,
call `vim.lsp.codelens.enable(true, { bufnr = bufnr })` on Neovim 0.12+ (or
`vim.lsp.codelens.refresh({ bufnr = bufnr })` on 0.11) and
`vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })` yourself.

A cached statusline API, `:Pico8CartInfo`, and `:Pico8Tabs` are proposed in
M28. The current request is:

```lua
vim.lsp.buf_request(0, "pico8/cartInfo", {
  textDocument = { uri = vim.uri_from_bufnr(0) },
}, function(err, result)
  if err or not result then return end
  print(("%d / %d tokens"):format(result.tokens, result.tokenLimit))
end)
```

## Commands

| Command | Status |
|---|---|
| `:Pico8OpenPng [path]` | Available |
| `:Pico8ReloadPng` | Available |
| `:Pico8InsertGlyph [name]` | Available |
| `:Pico8Refresh` | Available |
| `:Pico8ToggleInlayHints` | Available |
| `:Pico8CartInfo`, `:Pico8Tabs` | Proposed (M28) |
| `:Pico8OpenCart` | Proposed (M29) |
| `:checkhealth pico_lsp` | Proposed (M32) |
| `:Pico8InstallParser` | Proposed (M34) |
