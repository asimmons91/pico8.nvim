# pico8.nvim

[![CI](https://github.com/asimmons91/pico8.nvim/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/asimmons91/pico8.nvim/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/asimmons91/pico8.nvim)](https://github.com/asimmons91/pico8.nvim/releases)

Neovim client for [`pico-lsp`](https://github.com/asimmons91/pico-lsp), a
PICO-8 language server built in Go. The plugin provides PICO-8 filetype
detection, LSP setup, cart-owned `.lua` attachment, `pico8/cartInfo` status
helpers, a P8SCII glyph picker, read-only `.p8.png` opening, and the
Neovim-specific client surface.

New here? Start with the [five-minute quickstart](docs/getting-started.md) or
open the [demo cart](examples/hello.p8).

![A Neovim terminal session editing examples/hello.p8 with the cart budget code lens, statusline, and #include line](docs/assets/onboarding.svg)

**Status:** v0.1.0. The plugin ships native LSP configuration, cart-aware
roots, one-call activation, a buffer-aware cart-owned `.lua` helper with
managed attachment and `:Pico8Refresh`, client-side enabling for the cart
budget code lens and inlay hints, a cached cart budget statusline with
`:Pico8CartInfo` and `:Pico8Tabs`, PICO-8 comment settings, cart variables, and
`:Pico8OpenCart` for included `.lua` buffers, `gf` navigation for `#include`
targets, direct `nvim cart.p8.png` decoding, cached P8SCII glyph input with byte
forms and a filtered picker, `gq` range formatting and Neovim 0.12 `gx` include
links, `:checkhealth pico_lsp`, and `:Pico8InstallParser` for the vendored
Tree-sitter grammar.

| `pico8.nvim` | `pico-lsp` | Tested Neovim |
|---|---|---|
| v0.1.0 | v1.8.1 (minimum) | 0.11.4, 0.12.6 |

`pico-lsp` v1.8.1 predates the standard range-formatting and document-link
capabilities added in M33. Core editing, cart budget, includes, glyphs, PNG,
health, and Tree-sitter work with v1.8.1; `gq` and Neovim 0.12 `gx` require a
newer server build. The client falls back to `gf` when those capabilities are
absent.

## Requirements

- Neovim 0.11.4 or newer. CI covers 0.11.4 and 0.12.6; newer patch releases
  are not individually claimed as tested.
- A `pico-lsp` v1.8.1 or newer binary on `PATH`, or a configured command.
- Optional: a C compiler for `:Pico8InstallParser` or manual Tree-sitter
  parsing. The Vim syntax file works without one.
- PICO-8 0.2.7 if you want to run carts. PICO-8 is not required to edit them,
  and this plugin does not run carts.

## Install

### Install the server

Download the archive for your OS and architecture from the
[`pico-lsp` v1.8.1 release](https://github.com/asimmons91/pico-lsp/releases/tag/v1.8.1),
or install with Go 1.27.4 or newer:

```sh
go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@v1.8.1
```

Verify it with `pico-lsp --version`. See the
[`pico-lsp` installation guide](https://github.com/asimmons91/pico-lsp/blob/main/docs/install.md)
for per-OS archives, checksums, Windows `.zip`, macOS Gatekeeper, offline use,
upgrade, uninstall, and `GOBIN`/`PATH` guidance.

Mason packaging is not available yet; it remains distribution work in
[the roadmap](docs/ROADMAP.md).

### lazy.nvim / LazyVim

Put this in `lua/plugins/pico8.lua`:

```lua
return {
  {
    "asimmons91/pico8.nvim",
    tag = "v0.1.0",
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

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  { src = "https://github.com/asimmons91/pico8.nvim", version = "v0.1.0" },
})
require("pico_lsp").setup()
```

`vim.pack.add` installs and loads the plugin; the explicit `setup()` is still
required for commands, the include helper, and PNG auto-open.

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
runtime files are available, and keep `filetype plugin on` enabled for the
`ftplugin` options.

There is no `plugin/` entry: installing the plugin alone does not register the
commands, start the helper, or install PNG auto-open. Call `setup()` once.

For local development before a tagged release:

```lua
{
  dir = vim.fn.expand("~/projects/pico8.nvim"),
  name = "pico8.nvim",
  main = "pico_lsp",
  lazy = false,
  opts = {},
}
```

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

### Tree-sitter parser

The Vim syntax file works without a compiler. To build and install the optional
editor-only Tree-sitter parser from the vendored grammar:

```vim
:Pico8InstallParser
```

The command compiles `vendor/tree-sitter-pico8`, installs
`stdpath("data")/site/parser/pico8.so` (`.dll` on Windows), copies the three
query files to `stdpath("data")/site/queries/pico8/`, adds `site` to
`runtimepath` once, and registers the language for the current session. Re-run
it to repair missing or changed queries; the parser build is skipped when the
installed parser is up to date. Use `:Pico8InstallParser!` to force a rebuild.

The installer reads `vim.g.pico8_treesitter_source`, then
`PICO_LSP_TREE_SITTER`, then the plugin's `vendor/tree-sitter-pico8` directory.
It uses `$CC` when set, otherwise `cc`, then `clang`, with a 60-second timeout.
MSVC's `cl` is not supported; Windows builds are best-effort and not covered by
CI.

`nvim-treesitter` does not install this grammar, and `:TSInstall pico8` is not
supported. Use `:Pico8InstallParser` instead.

Tree-sitter highlighting is opt-in. Start it for `.p8` buffers with:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "pico8",
  callback = function()
    pcall(vim.treesitter.start, 0, "pico8")
  end,
})
```

The grammar is editor highlighting only. It never replaces LSP diagnostics,
completion, or semantic tokens. The committed parser targets ABI 14 for Neovim
0.11+. See [installation](docs/install.md#tree-sitter) for the manual build and
fallback.

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
  glyph maps work for `.p8` carts. Glyph maps prefetch and cache the server
  catalog, so only the first insertion can wait on a request.
- Cart-owned `.lua` files stay `lua` buffers but use PICO-8's comment leaders,
  expose their owning cart through buffer variables, and can open it with
  `:Pico8OpenCart`.
- `gf` opens `#include` targets relative to the cart, including quoted paths,
  spaces, nested and absolute paths, and `.p8`/`.p8.png` tab selectors (the
  selector is stripped for `gf`).
- `gq` formats the selected lines through the server's range formatting.
  Neovim 0.12 `gx` opens the resolved `#include` target through the document
  link and `vim.ui.open`; `gf` remains the in-editor path. These require a
  server build with M33; `pico-lsp` v1.8.1 predates it and leaves `gf` as the
  fallback.
- Read-only `.p8.png` carts open directly with `nvim cart.p8.png`, and through
  `:Pico8OpenPng` and `:Pico8ReloadPng`.
- `:Pico8InsertGlyph` inserts a glyph by name, decimal byte, or `0x` byte; a
  search term opens a filtered picker, and command-line completion lists cached
  names.
- `pico8/cartInfo` is cached asynchronously and powers a statusline API,
  `:Pico8CartInfo`, and `:Pico8Tabs`. Root carts, cart-owned includes, and
  decoded `.p8.png` virtual buffers all show their owning cart's budget.
- `:checkhealth pico_lsp` reports the Neovim version, configuration, resolved
  binary and version, running clients, client feature state, managed includes,
  helper commands, and Tree-sitter availability without changing anything.
- `:Pico8InstallParser` builds the vendored Tree-sitter parser and queries under
  `stdpath("data")/site`; repeated runs are idempotent and `!` rebuilds safely.

### Health check

Run `:checkhealth pico_lsp` before deeper troubleshooting. It reports:

- the Neovim version and whether `vim.lsp.config["pico_lsp"]` is available;
- the resolved `cmd`, its source, the executable path, the `--version` probe,
  and the configured server log path;
- each running `pico_lsp` client with its root, attached buffer count, and
  selected `pico8` settings;
- the code-lens and inlay-hint state for the active cart, including mismatches
  between the server settings and the client display;
- helper-managed `.lua` buffers, their owning carts, comment settings, and
  `lua_ls` conflicts;
- whether `require("pico_lsp").setup()` ran, whether the helper is disabled,
  and which optional commands exist;
- whether the `pico8` Tree-sitter parser and filetype detection are available.

Health is read-only. It never starts a client, downloads a binary, installs a
parser, edits a buffer, or changes configuration. The only process it runs is
the configured binary with `--version`, with a 2-second timeout. A
function-valued `cmd` is reported but never called. Missing binaries and
malformed configuration are errors; failed probes and optional features such as
the Tree-sitter parser and disabled capabilities are warnings or infos.

### Included `.lua` files

The helper keeps `filetype=lua` and fills in PICO-8 comment defaults only when
the buffer still has stock Lua settings:

- `comments` becomes `:---,:--,://`, so comment-aware formatting recognizes
  `//` comments;
- `commentstring` becomes `-- %s`, so `gcc`/`gc` use `--`.

A custom `comments` or `commentstring` value is never overwritten on attach. On
managed detach, including helper shutdown, the helper restores only the values
it changed and only if they are still in place. A later change to a different
value is kept; setting an option to exactly the PICO-8 target is
indistinguishable from the helper's value and is restored.

Restore records are module-local. After a plugin reload, a later detach leaves
exact PICO-8 values in place rather than guessing the original Lua values.

Managed include buffers also expose these compatibility variables; treat them
as read-only:

- `b:pico8_cart` — the owning cart URI;
- `b:pico8_cart_root` — the normalized cart directory.

`:Pico8OpenCart` opens the owning cart in the current window. On a cart or a
decoded `.p8.png` buffer it reports that the buffer is already a cart; on an
unrelated buffer it reports that no owner was found. Glyph maps remain
`.p8`-only, and the helper does not change `syntax`, indentation, or filetype.

### Navigating includes

The `pico8` ftplugin sets buffer-local `include` and `includeexpr` options, so
`gf`, `Ctrl-W f`, and `Ctrl-W gf` open an `#include` target even when the helper
has never been set up. Paths resolve relative to the cart's directory, not
Neovim's current directory. Absolute paths stay absolute. The ftplugin also
scopes the buffer-local `path` option to the cart, so a plain relative name
cannot fall back to the working directory. A custom `path`, including one set
by an after-ftplugin or `FileType` handler, is left alone, and the scoped path
follows `:saveas`/`:file` renames. Names starting with `./` or
`../` are resolved by Vim relative to the working directory before
`includeexpr`; use an absolute or cart-relative path if that matters. Cart
directories containing glob characters (`[`, `]`, `*`, `?`, or `$`) are
resolved through `includeexpr` instead of Vim's raw lookup.

Supported forms include:

```pico8
#include "lib.lua"
#include 'lib.lua'
#include   lib.lua
#include "sub dir/lib.lua"   -- spaces in a quoted path
#include "other.p8:2"        -- opens other.p8; the tab selector is stripped
```

A `:<hex digit>` suffix is stripped only for `.p8` and `.p8.png` targets,
matching the server. A `.lua:2` path stays a literal filename. `gf` opens the
file, not a specific tab; use `:Pico8Tabs` to jump to a tab in a cart. Missing
targets report Neovim's normal `E447`/`E484` error and never create a file.

The ftplugin fills in a default only when the value is empty. A non-empty
`includeexpr` is preserved as a user value. `include` is global-local, so a
global value is treated as a default and is overridden locally; changing the
filetype restores it. `path` is scoped only when it is empty or the default,
and a custom value is preserved.

### Opening `.p8.png` carts

With the helper enabled, opening a PNG cart directly decodes it into a
read-only `pico8-cart:` buffer and attaches the client:

```sh
nvim path/to/cart.p8.png
```

The original binary PNG buffer is removed after a successful decode. On a
decode or client-start failure, the buffer becomes an empty, read-only
`nofile` buffer with the source name; no binary data is shown. Retry with:

```vim
:Pico8OpenPng path/to/cart.p8.png
```

`:Pico8OpenPng` offers file completion, and `:Pico8ReloadPng` re-decodes the
current virtual cart after the PNG changes. Reopening the same PNG with `:edit`,
`:split`, or `:Pico8OpenPng` reuses the existing virtual buffer instead of
creating a duplicate and preserves buffer-local include/expression/path values.
A `:bdelete`d or unloaded virtual cart restores its virtual options when loaded
again; a stale restore lists the cart. `:Pico8ReloadPng` restores its text and
client and keeps a deliberately unlisted cart unlisted. Auto-open is installed
only by
`require("pico_lsp").setup()` when the helper is not disabled; a fresh
`setup({ disable = true })` installs no PNG autocmd. The shipped
`lsp/pico_lsp.lua` config alone does not auto-open PNGs.

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

Restart Neovim after changing server `settings`. The client display options are
read at the next attach, so `:lsp restart` on Neovim 0.12+ is enough for
`codelens`/`inlay_hints` changes.
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

## Cart budget statusline

The helper caches the server's `pico8/cartInfo` response and refreshes it after
an attach, a save, `InsertLeave`, and a 500 ms debounce after cart or include
edits. Root carts, cart-owned `.lua` includes, and decoded `.p8.png` virtual
buffers all use the owning cart's entry.

```lua
local api = require("pico_lsp")

api.cart_status()
-- "4210/8192 tok · 27433/65535 ch · 12000/15616 zip"

api.cart_status(0, { fields = { "tokens", "chars" } })
-- "4210/8192 tok · 27433/65535 ch"

api.cart_info()         -- full cartInfo table, or nil before the first response
api.refresh_cart_info() -- asynchronous manual refresh; returns immediately
```

`cart_status` reads the cache only. It never sends a request or waits for the
server, so it is safe on every redraw. It returns `nil` until the first
response. Segments use exactly the server's integers; the compressed segment is
omitted when `compressedStatus` is `unavailable`, as it is for standalone
`.lua` carts. `cart_info` returns a copy of the server data; inspect
`compressedStatus` there when a statusline plugin needs to color `warning` or
`error` states.

The statusline updates after the debounce, on `InsertLeave`, and on saves, not
on every keystroke.

### lualine

Lualine is optional. This component colors the compressed budget through the
normal diagnostic highlights:

```lua
local function pico8_cart()
  return require("pico_lsp").cart_status() or ""
end

local function pico8_cart_color()
  local info = require("pico_lsp").cart_info()
  local status = info and info.compressedStatus
  if status == "error" then
    return "DiagnosticError"
  elseif status == "warning" then
    return "DiagnosticWarn"
  end
end

require("lualine").setup({
  sections = {
    lualine_x = {
      {
        pico8_cart,
        color = pico8_cart_color,
        cond = function()
          return require("pico_lsp").cart_status() ~= nil
        end,
      },
      "filetype",
    },
  },
})
```

### Plain statusline

No statusline plugin is required. Use a global function so `v:lua` can call it:

```lua
function _G.Pico8CartStatus()
  return require("pico_lsp").cart_status() or ""
end

vim.o.statusline = "%f %m %{%v:lua.Pico8CartStatus()%} %= %l:%c"
```

## Commands

| Command | Purpose |
|---|---|
| `:Pico8OpenPng [path]` | Decode a `.p8.png` cart into a read-only virtual buffer; offers file completion. |
| `:Pico8ReloadPng` | Re-decode the current virtual `.p8.png` cart. |
| `:Pico8InsertGlyph [name\|byte\|search]` | Insert a glyph by name or byte, or open a filtered picker; completes cached names. |
| `:Pico8Refresh` | Clear the include cache and rescan loaded buffers. |
| `:Pico8ToggleInlayHints` | Toggle client-side inlay hints for the current buffer. |
| `:Pico8CartInfo` | Show the cart budget with per-file and per-include detail. |
| `:Pico8Tabs` | Pick a code tab and place the cursor on its start line. |
| `:Pico8OpenCart` | Open the cart that owns the current included `.lua` buffer. |
| `:Pico8InstallParser[!]` | Build and install the vendored Tree-sitter parser and queries; `!` forces a rebuild. |
| `:checkhealth pico_lsp` | Report configuration, binary, clients, features, includes, helper commands, and Tree-sitter state. |

`:Pico8CartInfo` requests a fresh value asynchronously and notifies the same
summary plus compact file detail. `:Pico8Tabs` fetches fresh tab lines, opens
`vim.ui.select`, and jumps within the current buffer. On an included `.lua`
buffer it names the owning cart and does not switch buffers; on a decoded
`.p8.png` buffer it jumps inside the virtual buffer.

`:Pico8InsertGlyph left` inserts by name, `:Pico8InsertGlyph 139` and
`:Pico8InsertGlyph 0x8b` insert by byte, and any other term opens the picker
filtered by name, description, or byte spelling. Command-line completion lists
cached canonical names without making a request. See
[usage](docs/usage.md#p8scii-glyph-input).

## Configuration

```lua
require("pico_lsp").setup({
  cmd = { "pico-lsp" },       -- optional command override
  lsp = true,                 -- enable the pico_lsp client on setup
  disable = false,            -- disable the helper and LSP setup
  codelens = true,            -- client-side budget lens display
  inlay_hints = true,         -- client-side inlay-hint display
  glyph_maps = false,         -- install Shift-A..Z P8SCII glyph maps
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

`:Pico8InstallParser` reads `vim.g.pico8_treesitter_source`, then
`PICO_LSP_TREE_SITTER`, then the vendored grammar directory. It uses `$CC` when
set, otherwise `cc`, then `clang`. See [configuration](docs/configuration.md)
for root overrides and the server settings reference.

## Known limitations

- `.p8.png` carts are read-only. Edit and save an exported text `.p8` when you
  need to change the cart; the plugin never writes PNG carts.
- The plugin does not run, compile, or emulate carts. It edits the same `.p8`
  and `.lua` files that PICO-8 loads.
- Only the PICO-8 0.2.7 API is modeled. The Lua standard library is not
  available.
- PICO-8's `CTRL-J` (Hiragana), `CTRL-K` (Katakana), and `CTRL-P` (puny font)
  input modes are not implemented because they conflict with Neovim's built-in
  insert-mode keys.
- Neovim 0.11 has no document-link `gx` handling; use `gf` or upgrade to
  Neovim 0.12.
- Mason and the LazyVim extra are not available yet. The manual install path in
  this README and [installation](docs/install.md) is the supported path.
- Windows Tree-sitter builds are best-effort with `cc` or `clang`; MSVC's `cl`
  is not supported and Windows is not covered by CI.
- Standalone `.lua` carts use a manual filetype switch; see
  [usage](docs/usage.md#standalone-lua-carts).
- P8SCII glyphs are Unicode characters. The terminal font must render them; see
  [glyph input](docs/usage.md#p8scii-glyph-input).

## Support and privacy

- Start with [Getting started](docs/getting-started.md) and
  [Troubleshooting](docs/troubleshooting.md).
- Report bugs with the [bug report form](https://github.com/asimmons91/pico8.nvim/issues/new?template=bug.yml).
  Include a minimal cart, `:checkhealth pico_lsp` output, and your Neovim and
  `pico-lsp` versions.
- Report vulnerabilities privately through [SECURITY.md](SECURITY.md), not the
  public issue tracker.
- Contribution guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).

The plugin has no telemetry or analytics. Carts are parsed by `pico-lsp`, never
executed. Logs may contain source excerpts when verbose logging is enabled;
review a log before sharing it.

## Documentation

- [Getting started](docs/getting-started.md)
- [Installation](docs/install.md)
- [Usage](docs/usage.md)
- [Configuration](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Roadmap](docs/ROADMAP.md)
- [Client milestones](docs/milestones/README.md)
- [Changelog](CHANGELOG.md)
- `:help pico8` for the in-editor command summary

## Development

```sh
# Run the headless config and helper tests against an installed server.
PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
```

The tests create temporary carts and exercise config resolution, command-line
overrides, cart and include roots, attachment without a shipped config, unsaved
includes, managed detach, multiple carts, PNG opening and auto-open, glyph
cache and prefetch behavior, byte insertion, filtered picker and completion,
cached cart info and statusline text, include and PNG cart
resolution, `gf` include navigation, `gq` range formatting and `gx` document
links, refresh debouncing and coalescing, included-buffer comment settings and
variables, `:Pico8OpenCart`, the cart commands, health-check sections and
read-only behavior, Tree-sitter installation, idempotence, query repair, and
failure paths, and fallback behavior. CI runs the suite on Neovim 0.11.4 and
0.12.6 against a built `pico-lsp` binary, then runs the installer test with the
system compiler on macOS. The release checklist adds a run against the pinned
`pico-lsp` release.

Documentation checks run with:

```sh
nvim --headless --clean -u NONE -l tests/docs.lua
```

The release process and manual verification matrix are in
[docs/release-checklist.md](docs/release-checklist.md).

## Relationship to pico-lsp

`pico-lsp` owns the Go server, parser, analysis, formatter, and standard LSP
capabilities. `pico8.nvim` owns the Neovim plugin, filetype runtime files,
commands, statusline helpers, health checks, and Neovim-specific tests.

The M25–M32 and M34 specs are inherited from `pico-lsp` for traceability. M33
is implemented in the server and consumed by Neovim's standard `formatexpr`,
`gx`, and code-lens-refresh handling. M34 and M36 are implemented in this
repository. M35 remains the proposed Mason and LazyVim distribution milestone.

## License

[MIT](LICENSE). The Tree-sitter parser sources are derived from tree-sitter-lua;
see `vendor/tree-sitter-pico8/LICENSE.tree-sitter-lua`.
