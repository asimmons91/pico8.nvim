# Troubleshooting

## First checks

- `pico-lsp --version` verifies which binary Neovim would run.
- `:checkhealth vim.lsp` shows Neovim's LSP health and attached clients.
- `:lua =vim.lsp.get_clients({ bufnr = 0 })` shows the current buffer's clients.
- `:set filetype?` should report `pico8` in a cart.
- `:lua =vim.fn.stdpath("data")` shows the data directory used by a future
  parser installer.

`:checkhealth pico_lsp` is proposed in M32. Until then, use the Neovim checks
above.

## Client does not attach

1. Confirm the plugin is on `runtimepath`:
   `:lua =vim.o.runtimepath`.
2. Confirm `lsp/pico_lsp.lua` is readable and `vim.lsp.config["pico_lsp"]`
   exists.
3. Confirm `require("pico_lsp").setup()` ran. With lazy.nvim, use `opts = {}`
   or add `config = function() require("pico_lsp").setup() end`.
4. Check the server command: `vim.g.pico_lsp_cmd`, `PICO_LSP_BIN`, or the
   configured `cmd`.
5. Open `:checkhealth vim.lsp` and inspect the client log.

## Included `.lua` file does not attach

- Confirm the include is a line beginning with `#include`.
- Confirm the path resolves relative to the cart directory.
- Unsaved includes work: the helper reads a loaded cart buffer instead of the
  file on disk. An unloaded cart is read from disk.
- If an external tool changed a cart while Neovim has the old buffer loaded,
  reload it with `:edit!` so Neovim reads the new contents. The helper rescans
  on reload. `:Pico8Refresh` clears cached include data and rescans loaded
  `.lua` buffers, but it does not reload a cart buffer.
- If the cart is not loaded and changed outside Neovim, run `:Pico8Refresh`.
- Check that `lua_ls` and `pico_lsp` are not both attached to the same buffer.
- The helper ignores unrelated `.lua` files by design.

## An include stays attached after removal

- Wait for the debounce (300 ms) after an unsaved cart edit, or save the cart.
- If the cart changed outside Neovim, reload it with `:edit!`; the helper
  rescans on reload. If the cart is not loaded, run `:Pico8Refresh`.
- The helper only detaches clients it recorded as helper-managed. A `pico_lsp`
  client you started yourself remains attached until you stop it.

## Lens or hints are missing

- The budget lens requires the server to return a lens and the client to display
  it.
- On Neovim 0.11, the legacy code-lens engine uses `vim.lsp.codelens.refresh`;
  on 0.12, the client uses `vim.lsp.codelens.enable`.
- Inlay hints require both `pico8.inlayHints = true` and client-side
  `vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })`.
- The exact enablement and toggle command are proposed in M27.

## PNG cart fails

- Confirm the file is a valid PICO-8 `.p8.png` cart.
- Confirm `pico-lsp` is executable and the client is attached.
- Use `pico-lsp decode --output /tmp/cart.p8 cart.p8.png` to test the server
  independently.
- A failed decode should leave an empty buffer, not binary contents. Auto-open
  failure handling is proposed in M30.

## Glyph insertion falls back to uppercase

- The Shift maps need an attached `pico_lsp` client and the server glyph
  catalog.
- Outside Lua code, in include paths, in read-only buffers, or with no client,
  the mapping intentionally inserts a literal letter.
- Use `:Pico8InsertGlyph` or `p8_` completion for the remaining glyphs.
- Catalog caching is proposed in M31.

## Tree-sitter parser does not load

- Confirm the parser exists at `stdpath("data")/site/parser/pico8.so`.
- Confirm the queries are under `stdpath("data")/site/queries/pico8/`.
- Run `:lua =pcall(vim.treesitter.language.add, "pico8")` and inspect the error.
- Rebuild with the command in [installation](install.md#tree-sitter).
- The committed parser targets ABI 14 for Neovim 0.11+.

## Logs

Neovim's client log path:

```vim
:lua =vim.lsp.log.get_filename()
```

Server logs go to stderr or `--log-file`. Add flags to `cmd`:

```lua
cmd = { "pico-lsp", "--log-level", "debug", "--log-file", "/tmp/pico-lsp.log" },
```

Routine logs never go to stdout, so they cannot corrupt the protocol stream.
