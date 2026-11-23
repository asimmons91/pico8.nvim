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
the plugin setup, `vim.g.pico_lsp_cmd`, or `PICO_LSP_BIN`.

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
