# Installation

For the shortest install-to-first-cart path, use
[Getting started](getting-started.md). This page is the full reference.

## Requirements

- Neovim 0.11.4 or newer. This release is tested with 0.11.4 and 0.12.6;
  newer patch releases are not individually claimed as tested.
- `pico-lsp` v1.8.1 or newer, installed and executable.
- Optional: a C compiler for `:Pico8InstallParser` or manual Tree-sitter
  parsing. The Vim syntax file works without one.
- PICO-8 0.2.7 if you want to run carts. PICO-8 is not required to edit carts,
  and this plugin does not run them.

## Compatibility

| `pico8.nvim` | `pico-lsp` | Tested Neovim |
|---|---|---|
| v0.1.0 | v1.8.1 (minimum) | 0.11.4, 0.12.6 |

A plugin release documents the minimum `pico-lsp` release it was tested
against. The client may work with newer server versions, but the pinned pair
above is the supported launch combination.

`pico-lsp` v1.8.1 predates the standard range-formatting and document-link
capabilities added in M33. Core editing, cart budget, includes, glyphs, PNG,
health, and Tree-sitter work with v1.8.1; `gq` and Neovim 0.12 `gx` require a
newer server build. `gf` remains the fallback when those capabilities are
absent.

## Install the server

Download the archive for your OS and architecture from the
[`pico-lsp` v1.8.1 release](https://github.com/asimmons91/pico-lsp/releases/tag/v1.8.1),
or install with Go 1.27.4 or newer:

```sh
go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@v1.8.1
```

Verify it:

```sh
pico-lsp --version
```

The [`pico-lsp` installation guide](https://github.com/asimmons91/pico-lsp/blob/main/docs/install.md)
is authoritative for:

- Linux, macOS, and Windows release archives;
- `checksums.txt` verification;
- the Windows `.zip` and `%LOCALAPPDATA%` layout;
- macOS Gatekeeper notes for unsigned binaries;
- offline and air-gapped installs;
- `GOBIN`/`PATH` setup after `go install`;
- server upgrade and uninstall.

The plugin looks for `pico-lsp` on `PATH`. To use another binary, set `cmd` in
the plugin setup, `vim.g.pico_lsp_cmd`, or `PICO_LSP_BIN`. The shipped config
checks `vim.g.pico_lsp_cmd`, then `PICO_LSP_BIN`, then `pico-lsp`; a `setup`
`cmd` or a later user `vim.lsp.config` call overrides that value.

The shell and Neovim can resolve different binaries when Neovim is launched
from a GUI. Run `:checkhealth pico_lsp` to see the executable Neovim will use.
The health probe is authoritative; `pico-lsp --version` in a shell is not.

Mason packaging is not available yet. It remains distribution work in the
[roadmap](ROADMAP.md).

## Install the plugin

### lazy.nvim / LazyVim

Add `lua/plugins/pico8.lua`:

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

`lazy = false` ensures `ftdetect`, `ftplugin`, and `syntax` are available
before the first `.p8` buffer opens. `opts = {}` runs
`require("pico_lsp").setup({})`, which enables the client by default.

Set `opts = { lsp = false }` if you manage `vim.lsp.enable` yourself. There is no
`plugin/` entry: commands, the include helper, and PNG auto-open are installed
by `setup()`, not by loading the plugin alone.

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  { src = "https://github.com/asimmons91/pico8.nvim", version = "v0.1.0" },
})
require("pico_lsp").setup()
```

### Vanilla Neovim

```lua
vim.opt.runtimepath:append("/path/to/pico8.nvim")
require("pico_lsp").setup()
```

Keep `filetype plugin on` enabled for the `ftplugin` options. If `:help pico8`
reports `E149` after installing from an older tag, run
`:helptags /path/to/pico8.nvim/doc` once.

### Local development

```lua
{
  dir = vim.fn.expand("~/projects/pico8.nvim"),
  name = "pico8.nvim",
  main = "pico_lsp",
  lazy = false,
  opts = {},
}
```

### Base LSP setup

`lsp/pico_lsp.lua` is the only LSP configuration file, and it attaches to
buffers whose filetype is `pico8`. Neovim 0.11+ loads it from `runtimepath`,
and `require("pico_lsp").setup()` enables it. The plugin also ships `ftdetect`,
which assigns that filetype to `.p8` files, plus `ftplugin`, `syntax`, the
cart-owned `.lua` helper, and commands. Keep the plugin on `runtimepath` or
lazy-load it before the first cart opens so those runtime files are available.

`setup({ lsp = false })` skips `vim.lsp.enable("pico_lsp")` so you can call it
yourself. Loading the shipped config also registers the cached cart statusline
module and its commands; it does not start a client or request cart data until a
`pico_lsp` client attaches.

### Workspace root

A `.p8` buffer uses the cart's directory as its workspace root. This applies
even when the directory has no `.git` marker. Includes resolve from the cart
directory, and workspace symbols scan that directory. Two carts in different
directories start separate clients; two carts in the same directory share one
client.

Unnamed buffers and `pico8-cart:` virtual buffers are not auto-activated by the
shipped config. The `.p8.png` helper starts its virtual document explicitly with
the source directory, including when `nvim cart.p8.png` auto-opens it.

To use a repository-wide root instead, override `root_dir` before opening the
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
directory otherwise. The override replaces the shipped callback; it is not
merged. Existing clients keep their root until they restart, so configure this
before opening carts.

## Tree-sitter

The Vim syntax file works without a compiler. To build and install the optional
editor-only Tree-sitter grammar from the vendored sources:

```vim
:Pico8InstallParser
```

The command:

- compiles `vendor/tree-sitter-pico8/src/parser.c` and `src/scanner.c`;
- installs `stdpath("data")/site/parser/pico8.so` (`.dll` on Windows);
- copies `highlights.scm`, `indents.scm`, and `textobjects.scm` to
  `stdpath("data")/site/queries/pico8/`;
- adds `stdpath("data")/site` to `runtimepath` once, if needed;
- registers the language in the current session.

Re-running the command repairs missing or changed query files and skips an
up-to-date parser. `:Pico8InstallParser!` forces a rebuild. A failed compiler
run leaves the previous parser and queries in place. After a forced rebuild in
a session that already loaded the parser, restart Neovim to load the new
binary; a first install is usable immediately.

`nvim-treesitter` does not install this grammar, and `:TSInstall pico8` is not
supported. Use `:Pico8InstallParser` instead.

The installer reads the grammar directory from
`vim.g.pico8_treesitter_source`, then `PICO_LSP_TREE_SITTER`, then the plugin's
`vendor/tree-sitter-pico8` directory. An explicit override must contain:

```text
src/parser.c
src/scanner.c
queries/highlights.scm
queries/indents.scm
queries/textobjects.scm
```

It uses `$CC` when set, otherwise `cc`, then `clang`; `$CC` is a single
executable path, not a shell command. Compilation is bounded to 60 seconds and
uses an atomic rename so a partial `.so` is never installed. The installer does
not use the network or require the `tree-sitter` CLI. MSVC's `cl` is not
supported; Windows builds are best-effort and are not covered by CI.

Start it for `.p8` buffers (the installer does not start it automatically):

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "pico8",
  callback = function()
    pcall(vim.treesitter.start, 0, "pico8")
  end,
})
```

### Remove the parser

Run `:lua =vim.fn.stdpath("data")` to find the data directory, then delete:

```text
<data>/site/parser/pico8.so      (.dll on Windows)
<data>/site/queries/pico8/
```

Removing the plugin does not remove these files.

### Manual build fallback

If a compiler is unavailable, or you prefer to manage the parser yourself:

```sh
mkdir -p ~/.local/share/nvim/site/parser
cc -shared -fPIC -I vendor/tree-sitter-pico8/src \
  vendor/tree-sitter-pico8/src/parser.c \
  vendor/tree-sitter-pico8/src/scanner.c \
  -o ~/.local/share/nvim/site/parser/pico8.so

mkdir -p ~/.local/share/nvim/site/queries/pico8
cp vendor/tree-sitter-pico8/queries/*.scm ~/.local/share/nvim/site/queries/pico8/
```

Use the same parser and query directories as the installer so Neovim finds
them through the default `runtimepath`. The committed parser targets ABI 14 for
Neovim 0.11+.

`:checkhealth pico_lsp` reports whether the parser loads and whether `pico8`
filetype detection is registered. It never installs or starts the parser.

## Verify

1. Run the plugin health check:

   ```vim
   :checkhealth pico_lsp
   ```

   It reports the resolved binary, server version, configuration, clients,
   client features, helper commands, managed includes, and Tree-sitter status.
   It never starts clients or changes configuration.

2. Open the demo cart:

   ```sh
   nvim examples/hello.p8
   ```

3. Check the filetype and client:

   ```vim
   :set filetype?
   :checkhealth vim.lsp
   :lua =vim.lsp.get_clients({ bufnr = 0 })
   ```

4. Open `examples/hello_lib.lua` with `gf` and confirm the helper attaches.

If the cart does not attach, read
[troubleshooting](troubleshooting.md#client-does-not-attach).

## Upgrade and uninstall

### Upgrade

1. Change the plugin tag to the newer release and update it with your plugin
   manager.
2. Install the matching `pico-lsp` release and verify it with
   `:checkhealth pico_lsp`.
3. Restart Neovim, or use `:lsp restart` on Neovim 0.12+.
4. Re-run `:Pico8InstallParser` after a plugin update that changes the vendored
   grammar.

### Uninstall

1. Remove the plugin from your plugin manager.
2. Remove the parser and queries if you installed them:
   `stdpath("data")/site/parser/pico8.*` and
   `stdpath("data")/site/queries/pico8/`.
3. Remove the `pico-lsp` binary separately. Uninstalling the plugin does not
   remove the server.

## Development checks

The end-user verification path is `:checkhealth pico_lsp` plus the demo cart.
The headless test suite is a contributor check and needs an installed server:

```sh
PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
```

The release process is in [release-checklist](release-checklist.md). The
documentation checks run with:

```sh
nvim --headless --clean -u NONE -l tests/docs.lua
```
