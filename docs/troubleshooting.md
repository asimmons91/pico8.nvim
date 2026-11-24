# Troubleshooting

## First checks

- `:checkhealth pico_lsp` is the first diagnostic step. It reports the
  configuration, binary and version, clients, client feature state, managed
  includes, helper commands, and Tree-sitter availability.
- `:checkhealth pico_lsp` shows which `pico-lsp` binary Neovim resolves.
  `pico-lsp --version` in a shell can resolve a different binary when Neovim
  was launched from a GUI.
- `:checkhealth vim.lsp` shows Neovim's LSP health and attached clients.
- `:lua =vim.lsp.get_clients({ bufnr = 0 })` shows the current buffer's clients.
- `:set filetype?` should report `pico8` in a cart.
- `:lua =vim.fn.stdpath("data")` shows the data directory used by
  `:Pico8InstallParser`.

## Server binary is not found or is the wrong version

- Run `:checkhealth pico_lsp` and read the Server binary section. It shows the
  resolved executable, its source, and the `--version` result.
- If `go install` succeeded but `pico-lsp` is not found, add `$(go env GOPATH)/bin`
  to `PATH`, reinstall with `GOBIN` set to a directory on `PATH`, or set an
  absolute `cmd` in `setup()` or `vim.lsp.config`.
- If Neovim resolves a different binary than your shell, set
  `PICO_LSP_BIN`/`vim.g.pico_lsp_cmd` or an absolute `cmd`.
- Install the matching `pico-lsp` release and restart Neovim. The tested pair is
  `pico8.nvim` v0.1.0 with `pico-lsp` v1.8.1; see
  [compatibility](install.md#compatibility).
- On macOS, Gatekeeper may block an unsigned downloaded binary. On Windows,
  SmartScreen may warn. See the
  [`pico-lsp` installation guide](https://github.com/asimmons91/pico-lsp/blob/main/docs/install.md)
  for the platform steps.
- For offline or air-gapped installs, download the release archive and set
  `cmd` or `PICO_LSP_BIN` to the local executable.

## Using `:checkhealth pico_lsp`

The health report is read-only. It never starts or stops a client, downloads a
binary, installs a parser, edits a buffer, or changes configuration. The only
process it runs is the configured binary with `--version`, with a 2-second
timeout. A function-valued `cmd` is reported as user-supplied but is never
called.

Read the report from the top:

1. **Neovim** — 0.11.4 or newer is required; 0.11.4 and 0.12.6 are tested.
2. **Configuration** — confirms `vim.lsp.config["pico_lsp"]` is present and
   validates the command shape. A bare-string `cmd` is rejected by Neovim even
   if the health probe can still resolve it. In a fresh session the report says
   the runtime config compiles but has not loaded yet; open a cart to validate
   its runtime behavior.
3. **Server binary** — resolves the executable, probes `--version`, and
   compares it with a running client's `server_info.version`. Missing binaries
   include install steps.
4. **Running clients** — shows each client's root, attached buffer count, and
   selected `pico8` settings. If a cart is active but unattached, the report
   points to the runtime path and `:checkhealth vim.lsp`.
5. **Client features** — compares `pico8.inlayHints` and
   `pico8.limits.codeLens` with the client display state. An unset
   `limits.codeLens` counts as the server default `true`; on Neovim 0.11 the
   report describes the refresh-based code-lens engine instead of claiming a
   per-buffer toggle.
6. **Included `.lua` buffers** — lists helper-managed buffers, their owning
   carts, attached clients, and comment settings. A `lua_ls` + `pico_lsp`
   attachment is reported as unsupported.
7. **Helper** — reports whether `require("pico_lsp").setup()` ran, whether the
   helper is disabled, which optional commands exist, and the LSP/server log
   paths.
8. **Tree-sitter** — reports whether the `pico8` parser loads and whether
   filetype detection is registered. Neither is required for the Vim syntax
   fallback.

Missing optional pieces are infos or warnings; broken configuration and missing
executables are errors.

## Client does not attach

1. Run `:checkhealth pico_lsp` and read the Configuration, Server binary,
   Running clients, and Helper sections.
2. Confirm the plugin is on `runtimepath`:
   `:lua =vim.o.runtimepath`.
3. Confirm `lsp/pico_lsp.lua` is readable and `vim.lsp.config["pico_lsp"]`
   exists.
4. Confirm `require("pico_lsp").setup()` ran. With lazy.nvim, use `opts = {}`
   or add `config = function() require("pico_lsp").setup() end`.
5. Check the server command: `vim.g.pico_lsp_cmd`, `PICO_LSP_BIN`, or the
   configured `cmd`.
6. Open `:checkhealth vim.lsp` and inspect the client log.

## Included `.lua` file does not attach

- Run `:checkhealth pico_lsp` and read the Helper and Included `.lua` buffers
  sections.
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

## LuaLS also attaches to a cart-owned include

- Run `:checkhealth pico_lsp`; the Included `.lua` buffers section warns when
  `lua_ls` and `pico_lsp` are both attached.
- Confirm with `:lua =vim.lsp.get_clients({ bufnr = 0 })`.
- Scope `lua_ls` away from files included by a nearby `.p8` cart with the
  [include-aware recipe](usage.md#coexisting-with-luals). Do not disable
  `lua_ls` for unrelated Lua files.
- The `pico8.attachLua` setting is a VS Code extension setting; it does not
  control the Neovim helper.

## An include stays attached after removal

- Wait for the debounce (300 ms) after an unsaved cart edit, or save the cart.
- If the cart changed outside Neovim, reload it with `:edit!`; the helper
  rescans on reload. If the cart is not loaded, run `:Pico8Refresh`.
- The helper only detaches clients it recorded as helper-managed. A `pico_lsp`
  client you started yourself remains attached until you stop it.

## `//` comments are not recognized in an include

- Confirm the buffer is helper-managed: `:echo b:pico8_cart` should print the
  owning cart URI. A user-started client on a `.lua` file is not managed and
  does not receive PICO-8 comment settings.
- Check `:setlocal comments?`. A managed include that had stock Lua settings
  shows `:---,:--,://`. `:gcc` still uses `--` from `commentstring`.
- If you changed `comments` yourself, the helper leaves your value alone. Add
  `://` manually, for example `:setlocal comments+=://`, if you want
  comment-aware formatting to continue `//` blocks.
- Run `:Pico8Refresh` after an ownership change, or reload the cart after an
  external edit.
- `:Pico8OpenCart` opens the owner from a managed include and reports
  `no owning cart` on unmanaged buffers.
- Disabling the helper restores the comment values it changed and leaves a
  later change to a different value in place. Setting an option to exactly the
  PICO-8 target is restored because it is indistinguishable from the helper's
  value. Restore records are module-local: after a plugin reload, disabling or
  detaching leaves exact PICO-8 values in place. `b:pico8_cart` and
  `b:pico8_cart_root` are cleared.

## Lens or hints are missing

- Run `:checkhealth pico_lsp` and read the Client features section. It compares
  the server settings with the client display and warns about a mismatch.
- Confirm a `pico_lsp` client is attached: `:lua =vim.lsp.get_clients({ bufnr = 0 })`.
- The shipped config enables the client-side display for `pico8` buffers. If
  you replaced its `on_attach`, enable the display yourself; see
  [configuration](configuration.md#code-lens-and-inlay-hints).
- Check the client-side state. On Neovim 0.12:
  `:lua =vim.lsp.codelens.is_enabled({ bufnr = 0 })` and
  `:lua =vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })`. On Neovim 0.11, use
  `:lua =vim.lsp.codelens.get(0)` and the same inlay-hint call.
- For hints, enable `pico8.inlayHints` in `settings` and keep `typeChecking`
  other than `off`. The server default is off; see
  [configuration](configuration.md#code-lens-and-inlay-hints).
- `:Pico8ToggleInlayHints` toggles the client display for the current buffer.
  It warns when the setting is false or absent and does not change server
  configuration.
- The budget lens also requires `pico8.limits.codeLens = true` and a root cart
  with available counts.
- Client-side options apply to clients started after `setup`. Restart Neovim
  after changing server settings; `:lsp restart` on Neovim 0.12+ is enough for
  the `codelens`/`inlay_hints` options.
- Inspect the client log if the requests fail.

## Cart lens or hints are stale after editing an include

- A current server refreshes capable clients after a cart analysis, including
  edits to a cart-owned `.lua` file. Check that the client is attached and that
  `pico8.limits.codeLens` is true. The refresh is throttled, so allow a moment
  after a burst of edits.
- Neovim 0.11 refreshes the lens on cart saves through the client module.
  Neovim 0.12 uses its code-lens enable state plus the server refresh.
- If the lens is still stale, change and save the cart buffer or restart
  Neovim.

## `gq` does not format or reports an error

- `gq` uses Neovim's LSP `formatexpr`, which is set only when the server
  advertises `textDocument/rangeFormatting`. Check the attached client:
  `:lua =vim.lsp.get_clients({ bufnr = 0 })`.
- `pico-lsp` v1.8.1 predates M33 and does not advertise range formatting or
  document links. Use a newer server build for `gq` and Neovim 0.12 `gx`; `gf`
  remains the fallback.
- A custom `formatexpr` is preserved; clear it or call
  `:lua vim.lsp.buf.format()` to format the whole document.
- Range formatting refuses a change that would alter the line count. The
  buffer is intentionally left unchanged; format the whole document instead.
- A cart with missing or unreadable includes is refused when formatting the
  cart root. Fix the include or use the included `.lua` buffer directly.

## `gx` does not open an include

- Neovim 0.11 has no document-link `gx` handling; use `gf` or upgrade to
  Neovim 0.12.
- `pico-lsp` v1.8.1 predates the M33 document-link capability. Use a newer
  server build or `gf`.
- On Neovim 0.12, put the cursor on the include target and check that the
  server advertises `textDocument/documentLink`:
  `:lua =vim.lsp.get_clients({ bufnr = 0 })[1].server_capabilities.documentLinkProvider`.
- `gx` passes the target to `vim.ui.open` and the system opener. It does not
  open an editor buffer; use `gf` for in-editor navigation.
- Missing, unreadable, and nested includes intentionally have no link.

## Cart statusline is empty or stale

- `require("pico_lsp").cart_status()` returns `nil` until the first
  `pico8/cartInfo` response. It never blocks, so an empty component right after
  attach is expected.
- Confirm a `pico_lsp` client is attached to the cart or include buffer.
- The cache refreshes after attach, saves, `InsertLeave`, and a 500 ms debounce
  after edits. `require("pico_lsp").refresh_cart_info()` forces a refresh for an
  attached buffer. `:Pico8Refresh` also refreshes the cart cache while the
  helper is enabled; a disabled helper reports its state instead.
- A standalone `.lua` cart omits the compressed segment because the server
  reports `compressedStatus = "unavailable"`.
- Lualine and plain statusline recipes are documentation only; the plugin does
  not install a statusline plugin.
- If `:Pico8CartInfo` reports `no cart found for this buffer`, check the cart
  or `#include` ownership and the client root.

## `gf` does not open an include

- Check the buffer-local options: `:setlocal include? includeexpr? path?`. In a
  `.p8` buffer, `include` should be `^\s*#include\s\+`, `includeexpr` should
  call `pico_lsp.includes.includeexpr`, and `path` should name the cart
  directory (or a non-existent sentinel for a directory with glob characters).
  After `:saveas` or `:file`, the scoped `path` follows the new buffer name; a
  custom `path` is left alone.
- The ftplugin fills in defaults only when the value is empty. A global
  `includeexpr` is preserved as a user value; clear it or set a buffer-local
  expression if you want PICO-8 navigation. A custom `path` is preserved too;
  set it to the cart directory if you want the scoped lookup.
- Relative paths resolve against the cart's directory, not Neovim's current
  directory. Absolute paths stay absolute. The cart-scoped `path` prevents a
  plain same-named file in the working directory from winning.
- Vim tries the name it detects before `includeexpr`. For a quoted path such as
  `"space dir/lib.lua"`, if the first word (`space`) is itself a file in the
  cart, `gf` can open that file instead. Rename the file or use `:edit` with
  the full path in that rare case. Names starting with `./` or `../` are also
  handled by Vim relative to the working directory; use an absolute or
  cart-relative path if a same-named file there would win.
- Cart directories containing glob characters (`[`, `]`, `*`, `?`, or `$`) are
  resolved through `includeexpr` rather than Vim's raw lookup. `:find` does not
  search those directories, but `gf` still opens include targets. Semicolons,
  spaces, and commas in the cart directory are escaped normally.
- Quoted, unquoted, whitespace-padded, nested, and space-containing paths work.
  A `:<hex digit>` suffix is stripped for `.p8`/`.p8.png` targets; a `.lua:2`
  filename is literal.
- `gf` opens the file, not a code tab. Use `:Pico8Tabs` to jump within a cart.
- A missing target reports `E447`/`E484` and creates neither a buffer nor a
  file. Check the spelling and the cart directory.
- `gf` works without the helper. `:Pico8Refresh` rescans LSP ownership; it does
  not change include navigation.

## PNG cart fails

- Confirm the file is a valid PICO-8 `.p8.png` cart.
- Confirm `pico-lsp` is executable and the client can start.
- Auto-open is installed by `require("pico_lsp").setup()` only when the helper
  is enabled. A disabled setup installs no PNG autocmd, and the shipped
  `lsp/pico_lsp.lua` config alone does not auto-open PNGs.
- A failed auto-open leaves an empty, read-only `nofile` buffer with the PNG
  name; raw binary data is never shown. Retry with
  `:Pico8OpenPng path/to/cart.p8.png`, which offers file completion.
- Reopening the same PNG with `:edit`, `:split`, or `:Pico8OpenPng` reuses the
  existing virtual buffer and preserves buffer-local include/expression/path
  values, including a `path` set by an after-ftplugin or `FileType` handler. A
  custom global `path` is also preserved through restore and reload. Loading a
  `:bdelete`d or `:bunload`ed virtual cart with `:buffer` restores its virtual
  options; a stale restore lists the cart. `:Pico8ReloadPng` refreshes its text
  and client and keeps a deliberately unlisted buffer unlisted.
  `:Pico8ReloadPng` re-decodes the cart after the PNG changes.
- Use `pico-lsp decode --output /tmp/cart.p8 cart.p8.png` to test the server
  independently.

## Glyph insertion falls back to uppercase

- The Shift maps need an attached `pico_lsp` client and the server glyph
  catalog. The catalog is prefetched when the maps are enabled and cached for
  the client lifetime.
- Outside Lua code, in include paths, in read-only buffers, or with no client,
  the mapping intentionally inserts a literal letter.
- The first cold-cache insertion makes one bounded request. If it fails, the
  client warns once and keeps using literal letters. Restart the client or
  reinstall the maps to retry.
- Use `:Pico8InsertGlyph` or `p8_` completion for the remaining glyphs. The
  command accepts names, decimal bytes, and `0x` bytes; other terms open a
  filtered picker.
- Custom `pico8.glyphs` changes need a client restart because the catalog is
  cached per client and cart root.

## Glyphs render as boxes or blank cells

- Inserted P8SCII glyphs are Unicode characters. The terminal font must contain
  them; this is a font limitation, not an insertion failure.
- Use `:Pico8InsertGlyph` to inspect the inserted character, or type the literal
  uppercase letter when a glyph is unavailable.
- The Shift maps intentionally fall back to the literal key outside Lua code,
  in `#include` paths, without a client, or after a failed catalog request.
- Changing the terminal font or fallback font is outside the plugin.

## Tree-sitter parser does not load

- Run `:checkhealth pico_lsp` and read the Tree-sitter section.
- Confirm the parser exists at `stdpath("data")/site/parser/pico8.so`
  (`.dll` on Windows).
- Confirm the queries are under `stdpath("data")/site/queries/pico8/`.
- Run `:lua =pcall(vim.treesitter.language.add, "pico8")` and inspect the error.
- Rebuild with `:Pico8InstallParser!`, or with the manual command in
  [installation](install.md#tree-sitter).
- If the command reports a missing compiler, install `cc`/`clang` or set `$CC`
  to one executable. Point `g:pico8_treesitter_source` or
  `PICO_LSP_TREE_SITTER` at the grammar directory if the vendored sources are
  not beside the plugin.
- After a forced rebuild, restart Neovim to load the new binary. The committed
  parser targets ABI 14 for Neovim 0.11+.
- The installer writes only under `stdpath("data")/site`; a write failure names
  the destination path and usually means that directory is not writable.

## Upgrade or uninstall

- Upgrade the plugin tag and the `pico-lsp` binary together, then restart
  Neovim or use `:lsp restart` on Neovim 0.12+.
- Re-run `:Pico8InstallParser` after a plugin update that changes the vendored
  grammar. A rebuild in a session that already loaded the parser needs a
  restart.
- Uninstalling the plugin does not remove `pico-lsp`. Remove the binary
  separately.
- Remove parser files from `stdpath("data")/site/parser/pico8.*` and
  `stdpath("data")/site/queries/pico8/` if you installed them.
- See [installation](install.md#upgrade-and-uninstall) for the full sequence.

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
