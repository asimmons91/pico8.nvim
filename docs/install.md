# Installation

## Requirements

- Neovim 0.11 or newer.
- `pico-lsp` installed and executable.
- Optional: a C compiler for manual Tree-sitter parsing.

## Install the server

Use a release binary from the
[`pico-lsp` releases](https://github.com/asimmons91/pico-lsp/releases), or:

```sh
go install github.com/asimmons91/pico-lsp/cmd/pico-lsp@latest
```

Verify it:

```sh
pico-lsp --version
```

The plugin looks for `pico-lsp` on `PATH`. To use another binary, set `cmd` in
the plugin setup, `vim.g.pico_lsp_cmd`, or `PICO_LSP_BIN`. The shipped config
checks `vim.g.pico_lsp_cmd`, then `PICO_LSP_BIN`, then `pico-lsp`; a `setup`
`cmd` or a later user `vim.lsp.config` call overrides that value.

## Install the plugin

### lazy.nvim / LazyVim

Add `lua/plugins/pico8.lua`:

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

`lazy = false` ensures `ftdetect`, `ftplugin`, and `syntax` are available
before the first `.p8` buffer opens. `opts = {}` runs
`require("pico_lsp").setup({})`, which enables the client by default.

Set `opts = { lsp = false }` if you manage `vim.lsp.enable` yourself.

### Vanilla Neovim

```lua
vim.opt.runtimepath:append("/path/to/pico8.nvim")
require("pico_lsp").setup()
```

The shipped `lsp/pico_lsp.lua` requests `pico8` buffers and uses the cart
directory as the workspace root.

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
yourself. The shipped config returns a plain table and has no side effects.

### Workspace root

A `.p8` buffer uses the cart's directory as its workspace root. This applies
even when the directory has no `.git` marker. Includes resolve from the cart
directory, and workspace symbols scan that directory. Two carts in different
directories start separate clients; two carts in the same directory share one
client.

Unnamed buffers and `pico8-cart:` virtual buffers are not auto-activated by the
shipped config. The `.p8.png` helper starts its virtual document explicitly with
the source directory.

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

The Vim syntax file works without a compiler. To use the editor-only
Tree-sitter grammar manually:

```sh
mkdir -p ~/.local/share/nvim/site/parser
cc -shared -fPIC -I vendor/tree-sitter-pico8/src \
  vendor/tree-sitter-pico8/src/parser.c \
  vendor/tree-sitter-pico8/src/scanner.c \
  -o ~/.local/share/nvim/site/parser/pico8.so

mkdir -p ~/.local/share/nvim/site/queries/pico8
cp vendor/tree-sitter-pico8/queries/*.scm ~/.local/share/nvim/site/queries/pico8/
```

Start it for `.p8` buffers:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "pico8",
  callback = function()
    pcall(vim.treesitter.start, 0, "pico8")
  end,
})
```

`:Pico8InstallParser` is proposed in
[M34](milestones/M34-nvim-treesitter-install.md).

## Verify

1. Open a cart:

   ```sh
   nvim tests/fixtures/smoke.p8
   ```

2. Check the filetype and client:

   ```vim
   :set filetype?
   :checkhealth vim.lsp
   :lua =vim.lsp.get_clients({ bufnr = 0 })
   ```

3. Open an included `.lua` file and confirm the helper attaches.

4. Run the headless test suite:

   ```sh
   PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
   ```
