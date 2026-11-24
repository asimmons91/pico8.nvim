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
still registers `:Pico8Refresh` (which reports the disabled state) and the
client-only `:Pico8ToggleInlayHints`, `:Pico8CartInfo`, and `:Pico8Tabs`
commands. It clears cached cart data but does not suppress the shipped config's
client-side display. Re-running setup while `pico_lsp` is already enabled keeps
existing helper-managed and user-started clients attached.

The `.p8` ftplugin sets PICO-8 comment options for carts:

```vim
setlocal comments=:---,:--,://
setlocal commentstring=--\ %s
```

A helper-managed include keeps `filetype=lua` and gets the same comment leaders
when it still has stock Lua settings. `comments` gains `://` so comment-aware
formatting recognizes PICO-8 `//` comments, while `gcc` still uses `--`. A
custom `comments` or `commentstring` value is never overwritten on attach. On
managed detach, including helper shutdown, the helper restores only the values
it changed and only if they are still in place. A later change to a different
value is kept; setting an option to exactly the PICO-8 target is restored
because it is indistinguishable from the helper's value.

Restore records are module-local. After a plugin reload, a later detach leaves
exact PICO-8 values in place rather than guessing the original Lua values.

Managed includes expose `b:pico8_cart` (the owning cart URI) and
`b:pico8_cart_root` (the normalized cart directory) for other plugins.
`:Pico8OpenCart` opens the owner in the current window. It reports that the
buffer is already a cart on a `.p8` or `.p8.png` buffer, and reports no owner on
an unrelated buffer.

## Navigating includes

The `pico8` ftplugin sets buffer-local `include` and `includeexpr` options, so
`gf`, `Ctrl-W f`, and `Ctrl-W gf` open `#include` targets without requiring the
helper or an initialized client. A relative target resolves against the cart's
directory, not Neovim's current directory. The ftplugin also scopes the
buffer-local `path` option to the cart, so a plain relative name cannot fall
back to the working directory. A custom `path`, including one set by an
after-ftplugin or `FileType` handler, is preserved, and the scoped path follows
`:saveas`/`:file` renames. Names starting with `./` or `../` are
handled by Vim relative to the working directory before `includeexpr`; use an
absolute or cart-relative path if that matters. Cart directories containing
glob characters (`[`, `]`, `*`, `?`, or `$`) use `includeexpr` instead of Vim's
raw lookup.

```pico8
#include "lib.lua"
#include 'lib.lua'
#include   lib.lua
#include "sub dir/lib.lua"
#include "other.p8:2"
```

Quoted, unquoted, whitespace-padded, nested, absolute, and space-containing
paths work. A trailing `:<hex digit>` is stripped only for `.p8` and
`.p8.png` targets; `.lua:2` stays a literal filename. `gf` opens the file at its
start, not at a code tab. Use `:Pico8Tabs` for tab navigation. Missing targets
report Neovim's normal `E447`/`E484` error, and no file is created.

The ftplugin fills in defaults only when the options are empty. A non-empty
`includeexpr` is preserved as a user value. `include` is global-local: a global
value is a default and is overridden locally, then restored by the ftplugin
undo hook. `path` is scoped only when it is empty or the default; a custom
value, including one set by an after-ftplugin or `FileType` handler, is
preserved. If you set a global `includeexpr`, `gf` uses your expression.

## Read-only `.p8.png` carts

With the helper enabled, opening a PNG cart directly decodes it:

```sh
nvim path/to/cart.p8.png
```

The command and replacement forms are also available:

```vim
:Pico8OpenPng path/to/cart.p8.png
:Pico8ReloadPng
```

`:Pico8OpenPng` offers file completion. It requests `pico8/decodeCart`, opens a
`pico8-cart:` virtual buffer, marks it `nomodifiable`, and attaches the
`pico_lsp` client. The original PNG buffer is deleted after a successful
auto-open. Reopening the same PNG with `:edit`, `:split`, or `:Pico8OpenPng`
reuses the existing virtual buffer and preserves buffer-local
include/expression/path values. A `:bdelete`d or unloaded virtual cart restores
its virtual options when loaded again; a stale restore lists the cart.
`:Pico8ReloadPng` restores its text and client and keeps a deliberately
unlisted cart unlisted.

If decoding or client startup fails, the source buffer becomes an empty,
read-only `nofile` buffer with its name intact; raw binary data is never
shown. Retry with `:Pico8OpenPng <path>`. Auto-open is installed only when
`require("pico_lsp").setup()` runs with the helper enabled. A disabled setup
installs no PNG autocmd, and the shipped `lsp/pico_lsp.lua` config alone does
not auto-open PNGs.

Navigation, diagnostics, completion, hover, and `pico8/cartInfo` work on the
virtual buffer; formatting and edits are refused because the PNG is read-only.
The virtual buffer also carries `b:pico8_cart_root`, so `gf` resolves includes
against the source PNG's directory.

For a static fallback:

```sh
pico-lsp decode --output /tmp/cart.p8 path/to/cart.p8.png
```

## P8SCII glyph input

Type `p8_left` in code or a string and accept completion to insert `⬅️`. The
`p8-` form is accepted for `pico8-ls` compatibility. Control entries such as
`p8_font_custom` (`\14`) are offered only inside strings.

The helper adds a picker and direct insertion:

```vim
:Pico8InsertGlyph            " unfiltered picker
:Pico8InsertGlyph left       " exact name
:Pico8InsertGlyph 139        " decimal P8SCII byte
:Pico8InsertGlyph 0x8b       " hex P8SCII byte
:Pico8InsertGlyph butt       " picker filtered by the search term
```

An exact name or byte inserts immediately. Any other term opens the picker
filtered by a case-insensitive substring across the glyph name, description,
`0x` byte, and decimal byte. A term with no matches reports that result instead
of showing an empty picker. Byte values outside `0..255`, including `256`,
`-1`, and `0x100`, are rejected before any server request.

Command-line completion lists the cached canonical glyph names, sorted by name.
It includes custom names, deduplicates case-insensitively, and never starts a
request; if the cache is empty, run the command once or enable the Shift maps to
prefetch it.

Control entries remain context-restricted. The server rejects insertion outside
Lua code, in an `#include` path, or for a string-only control glyph outside a
string, and the client shows the server's error. Cancelling the picker is a
no-op.

Custom font slots are declared in `pico8.glyphs`; see the
[pico-lsp configuration reference](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md#p8scii-glyph-snippets).
The server inserts the canonical Unicode spelling for the chosen byte because
it cannot inspect custom font pixels. A custom entry uses its configured name
and overrides a built-in entry that shares the same byte.

### Catalog cache and prefetch

The client caches the full `pico8/glyphs` catalog per `pico_lsp` client and
cart root. When glyph maps are enabled it prefetches asynchronously after
attach, so the first Shift press normally does not wait for the server. A cold
cache makes one bounded synchronous request (750 ms) and then falls back to the
literal uppercase key. A failed request warns once per client; later presses
use the literal key without repeating the request. A later explicit prefetch,
such as reinstalling the maps, can retry.

The picker asks for a position-filtered catalog so string-only control entries
are not offered outside a string. That filtered response never replaces the
full cache used by the Shift mappings. Included `.lua` buffers can use
`:Pico8InsertGlyph`, but they do not receive Shift maps.

Changing `pico8.glyphs` requires a client restart, which clears the cache and
fetches the new catalog. Prefetch failures are silent unless a later insertion
needs the catalog.

### PICO-8 Shift shortcuts

The optional ftplugin installs PICO-8's `Shift-A` through `Shift-Z` insert-mode
glyph shortcuts. Enable them before opening a cart with either:

```lua
require("pico_lsp").setup({ glyph_maps = true })
```

```lua
vim.g.pico8_glyph_maps = 1
```

In Lua code sections (but not `#include` paths), the mappings read the cached
canonical glyph text from the `pico8/glyphs` catalog by byte. Outside Lua code,
in include paths, without a client, for a byte with no catalog entry, or after
a failed catalog request, the key inserts the literal uppercase letter. Use
`CTRL-V u<hex>` to insert a literal uppercase letter in code, for example
`CTRL-V u0055` for `U`.

The maps are buffer-local to `pico8` buffers; included `.lua` files do not
receive them. Read-only `.p8.png` buffers do not accept insertions and do not
prefetch the catalog.

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

Inferred local type hints appear when the server setting is on and type
checking is not `off`:

```lua
require("pico_lsp").setup({
  settings = { pico8 = { inlayHints = true } },
})
```

See the
[pico-lsp configuration reference](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md)
for server defaults.

The client display is enabled by default. Turn either display off for clients
started afterwards:

```lua
require("pico_lsp").setup({
  codelens = false,
  inlay_hints = false,
})
```

Restart Neovim after changing server settings. The client display options apply
at the next attach; `:lsp restart` on Neovim 0.12+ is enough for those.
`:Pico8ToggleInlayHints` toggles the display for the current buffer without
changing server settings; it warns when `pico8.inlayHints` is false or unset.

If you replace the shipped `on_attach`, enable the display yourself:

```lua
-- Neovim 0.12+
vim.lsp.codelens.enable(true, { bufnr = bufnr })
-- Neovim 0.11
vim.lsp.codelens.refresh({ bufnr = bufnr })

vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
```

A cached statusline API, `:Pico8CartInfo`, and `:Pico8Tabs` use the same data:

```lua
local api = require("pico_lsp")

api.cart_status()
-- "4210/8192 tok · 27433/65535 ch · 12000/15616 zip"

api.cart_status(0, { fields = { "tokens", "chars" } })
api.cart_info()         -- full cached cartInfo table, or nil
api.refresh_cart_info() -- asynchronous manual refresh
```

The helper caches `pico8/cartInfo` after an attach, a save, `InsertLeave`, and a
500 ms debounce after edits. Statusline functions only read the cache and never
block on the server. The cache covers root carts, included `.lua` files, and
decoded `.p8.png` virtual buffers. The compressed segment is omitted when
`compressedStatus` is `unavailable`, as it is for standalone `.lua` carts.

For lualine and dependency-free statusline recipes, see the
[README](../README.md#cart-budget-statusline). The lualine recipe colors
`compressedStatus` with `DiagnosticWarn`/`DiagnosticError`.

`:Pico8CartInfo` requests a fresh value and notifies the budget plus compact
per-file and per-include detail. `:Pico8Tabs` fetches fresh tab lines, opens
`vim.ui.select`, and jumps within the current buffer. On an included `.lua`
buffer it explains that tabs belong to the owning cart; on a decoded `.p8.png`
buffer it jumps inside the virtual buffer.

## Commands

| Command | Status |
|---|---|
| `:Pico8OpenPng [path]` | Available |
| `:Pico8ReloadPng` | Available |
| `:Pico8InsertGlyph [name\|byte\|search]` | Available |
| `:Pico8Refresh` | Available |
| `:Pico8ToggleInlayHints` | Available |
| `:Pico8CartInfo`, `:Pico8Tabs` | Available |
| `:Pico8OpenCart` | Available |
| `:checkhealth pico_lsp` | Proposed (M32) |
| `:Pico8InstallParser` | Proposed (M34) |
