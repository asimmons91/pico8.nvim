# M30 — Neovim Include Navigation and PNG Opening

**Status:** Done — client work complete.

**Depends on:** pico-lsp M6 (server features), pico-lsp M8 (read-only
`.p8.png` carts), M25 (drop-in configuration), M26 (helper correctness)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

Neovim users can put the cursor on an `#include` line and press `gf` to open the
included file, including quoted paths, whitespace, and PICO-8 `:<tab>` suffixes.
Opening a `.p8.png` cart directly with `nvim cart.p8.png` decodes it through the
helper instead of showing a binary buffer.

The commands remain explicit and optional. Include navigation is available
wherever the PICO-8 ftplugin is loaded; PNG auto-open is installed only when the
helper is enabled. Missing includes and decode failures produce clear errors and
never leave a partly initialized virtual buffer.

**Demo:** Open `tests/fixtures/smoke.p8`, place the cursor on
`#include "lib.lua"`, and press `gf`. The included file opens. Repeat with
`#include "other.p8:2"` and confirm the `:2` selector is recognized only for a
cart include and ignored for file opening. `#include "lib.lua:2"` is a literal
`.lua:2` path and is not treated as a tab selector, matching the server. Run
`nvim tests/fixtures/smoke.p8.png` with the helper enabled; a read-only
`pico8-cart:` buffer opens and attaches the client. `:Pico8OpenPng` offers file
completion.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Include options | Set `include`, `includeexpr`, and a cart-scoped `path` buffer-locally in `ftplugin/pico8.vim`. Do not require the helper. |
| D2 | Path parsing | Reuse the helper's include-target parsing rules: optional quotes, leading whitespace after `#include`, forward-slash normalization, and a trailing `:<hex digit>` tab selector only for `.p8`/`.p8.png` includes, matching the server. |
| D3 | Relative paths | Resolve relative paths against the cart's directory, not Neovim's current working directory. Absolute paths stay absolute. |
| D4 | Missing targets | Return the resolved path and let Neovim report `E484`/not-found normally. Do not create files. |
| D5 | `gf` scope | Navigation applies to `.p8` buffers. Included `.lua` files do not gain `gf` include handling. |
| D6 | PNG auto-open | Install a `BufReadCmd` for `*.p8.png` only when `require("pico_lsp").setup()` has run and the helper is not disabled. |
| D7 | Auto-open failure | Show an error and leave the user in an empty scratch buffer; never show binary data and never leave a half-attached virtual buffer. |
| D8 | Virtual buffer | Reuse the existing `pico8-cart:` read-only buffer behavior from pico-lsp M8. Delete the original PNG buffer after a successful auto-open. |
| D9 | Command completion | Add `complete = "file"` to `:Pico8OpenPng`; keep `:Pico8ReloadPng` argument-free. |
| D10 | No new server behavior | Use the existing `pico8/decodeCart` request and file paths. No new LSP request or command. |

## Scope

### In scope

- `include` and `includeexpr` for `.p8` buffers.
- Quoted, unquoted, whitespace-padded, and `:<tab>` include paths.
- `nvim cart.p8.png` auto-decode through the helper.
- `:Pico8OpenPng` file completion.
- Buffer cleanup and error paths for auto-open.
- Headless tests and documentation.

### Out of scope

- Following `#include` paths in included `.lua` files.
- Opening the included file at a specific tab line. PICO-8 tab selection is
  parsed and ignored for `gf`; tab navigation is M28's `:Pico8Tabs`.
- Creating missing include files.
- Changing include resolution, diagnostics, or server ownership.
- Auto-opening `.p8.png` when the helper is disabled.
- Editing or saving decoded PNG carts.
- VS Code or Helix behavior.

## Deliverables

1. `ftplugin/pico8.vim` — `include`/`includeexpr` and undo hooks.
2. `lua/pico_lsp/init.lua` — PNG `BufReadCmd`, command completion,
   and cleanup.
3. A small include-path function, for example
   `lua/pico_lsp/includes.lua`, callable without helper setup.
4. `tests/helper.lua` or a focused test file.
5. `README.md` and `docs/troubleshooting.md`.
6. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Include options

In `ftplugin/pico8.vim`, after the existing comment settings:

- Set `include` to a pattern matching `#include` directives, for example
  `^\s*#include\s\+`.
- Set `includeexpr` to a Lua callable that receives `v:fname` and returns the
  resolved path.
- Scope `path` to the cart directory so Vim's unmodified-name lookup cannot
  fall back to the working directory. Preserve a custom `path`; a virtual PNG
  buffer gets its source directory from the helper.
- Preserve user overrides: if the user has already set `include` or
  `includeexpr`, do not replace it. Use `setlocal` only for empty/default values.
- Add the options to `b:undo_ftplugin` when the ftplugin set them.
- Keep the existing `commentstring`, `comments`, and glyph-map behavior
  unchanged.

`gf` must work when the helper has never been set up, so the path function must
not depend on helper state or the LSP client.

### 2. Include target parsing

The resolver must handle:

```text
#include "lib.lua"
#include 'lib.lua'
#include   lib.lua
#include "other.p8:2"
#include other.p8:a
#include "lib.lua:2"   -- literal filename, not a tab selector
```

Rules:

- Strip one pair of matching single or double quotes.
- Trim leading and trailing whitespace.
- Convert backslashes to forward slashes.
- Strip a trailing `:<hex digit>` tab selector only when the remaining path
  ends in `.p8` or `.p8.png`. This matches the server's
  `splitIncludeTarget`; a `.lua:2` path stays literal.
- Resolve relative paths against the cart's directory.
- Keep absolute paths absolute.
- Return a normalized path that Neovim can use with `:find`/`:edit`.
- If the directive has no path, return the original `v:fname` so Neovim reports
  a normal missing-file error.
- Do not read the target file to validate it.

### 3. `gf` behavior

- With the cursor on an include line, `gf` opens the resolved file in the
  current window.
- `Ctrl-W f`, `Ctrl-W gf`, and other Vim commands that use `includeexpr` work
  without special handling.
- The search is relative to the cart, even when Neovim's current directory is
  different.
- A missing target produces Neovim's normal error and does not create a buffer
  with an invented name.
- The first matching include on the line is used; multiple directives on one
  line are not a supported PICO-8 shape.
- Do not change the cursor or add mappings.

### 4. PNG auto-open

When `require("pico_lsp").setup()` enables the helper:

- Create a `BufReadCmd` autocmd for `*.p8.png` in the helper augroup.
- The callback reads the file path from the event, calls `M.open_png(path)`,
  and on success deletes the original unread PNG buffer with
  `nvim_buf_delete(..., { force = true })`.
- On failure, show a `vim.notify` error and leave an empty scratch buffer. Do
  not leave the binary file loaded.
- Do not install the autocmd when `disable = true`.
- Do not auto-open PNGs from `:Pico8OpenPng`; that command already opens the
  virtual buffer explicitly.
- Ensure the existing `Pico8ReloadPng` state map is updated for auto-opened
  buffers.
- Reuse the existing virtual buffer when the same PNG is opened again with
  `:edit`, `:split`, or `:Pico8OpenPng`; update its text and version instead of
  creating a duplicate. If a new virtual buffer cannot be named, delete it
  rather than leaking an unnamed buffer.
- A second `BufReadCmd` must not fire for the `pico8-cart:` virtual buffer.

### 5. Command completion

- Change `:Pico8OpenPng` to:

  ```lua
  vim.api.nvim_create_user_command("Pico8OpenPng", function(args) ... end, {
    nargs = "?",
    complete = "file",
  })
  ```

- Keep `:Pico8ReloadPng` with `nargs = 0`.
- Do not add completion to `:Pico8ReloadPng`.

### 6. Virtual buffer lifecycle

- Reuse `open_virtual` from the existing helper.
- The virtual buffer remains `nofile`, `bufhidden=hide`, `swapfile=false`,
  `modifiable=false`, and `filetype=pico8`.
- The source PNG URI and virtual URI are tracked as today.
- Deleting the original PNG buffer must not delete the virtual buffer.
- A failed decode must not leave an entry in `M.png_buffers`.
- `BufWipeout` cleanup continues to remove tracking state.

### 7. Documentation

- Add a "Navigating includes" subsection to `README.md` with the
  `gf` behavior, supported path forms, and the tab-selector limitation.
- Add a "Opening `.p8.png` carts" subsection showing both `nvim cart.p8.png`
  and `:Pico8OpenPng`, including the helper requirement.
- Update the troubleshooting guide:
  - `gf` fails: check `:setlocal include? includeexpr?`, the cart path, and the
    include's file extension.
  - auto-open fails: check the helper is enabled, the binary is on `PATH`, and
    the PNG is a valid PICO-8 cart.
- Note that include navigation does not change include order or ownership.

## Interfaces and state

- New buffer-local options in `.p8` buffers: `include`, `includeexpr`, and a
  cart-scoped `path`; decoded PNG virtual buffers get the same `path` scoping
  from the helper.
- New autocmd: `BufReadCmd` for `*.p8.png` when the helper is enabled.
- `:Pico8OpenPng` gains file completion.
- New include-path module or function callable without `setup`.
- No new LSP request, response, command, or setting.
- No change to `pico8/decodeCart` or virtual-document semantics.

## Error handling

- Missing cart path: `gf` returns the original match and Neovim reports the
  error.
- Invalid UTF-8 or spaces in paths: use `fnameescape` where required.
- Decode timeout or RPC error: notify and leave a usable empty buffer.
- Client start failure: do not create the virtual buffer.
- Auto-open when helper is disabled: no autocmd, no behavior change.
- Deleting the source buffer fails: keep the virtual buffer and log at debug
  level; do not undo a successful decode.

## Testing and CI

- Headless tests assert:
  - `gf` opens quoted, unquoted, whitespace-padded, nested, and absolute
    include targets, including a cursor on a `:<tab>` selector digit;
  - `gf` resolves a relative include against the cart even when Neovim's
    working directory is a sibling or repository root;
  - a same-named file in the working directory does not win over a missing
    include or a decoded PNG's source directory;
  - a `:tab` suffix on a `.p8` include opens the file and strips the suffix;
  - a `.lua:2` path is treated as a literal filename, not a tab selector;
  - a missing target reports an error and creates no file;
  - the include options and cart-scoped `path` are restored when the filetype
    changes, and a custom `path` is preserved;
  - `nvim cart.p8.png` auto-opens a read-only `pico8-cart:` buffer with an
    attached client;
  - reopening or splitting the same PNG reuses the virtual buffer and leaks no
    unnamed buffer;
  - an invalid `.p8.png` and a client-start failure produce an error, no
    `pico8-cart:` virtual buffer, no binary line content, and no
    `M.png_buffers` entry;
  - the original PNG buffer is removed after success;
  - auto-open does not run when `disable = true`;
  - `:Pico8OpenPng` completion includes files;
  - `:Pico8ReloadPng` still works after auto-open.
- Use `tests/fixtures/smoke.p8.png` for the PNG case.
- Run on Neovim 0.11 and 0.12 in CI.

## Exit criteria

- [x] `gf` opens quoted, unquoted, relative, and `:<tab>` include targets.
- [x] Missing includes fail without creating files.
- [x] `gf` does not fall back to a same-named file in the working directory.
- [x] `nvim cart.p8.png` opens a read-only virtual cart when the helper is
      enabled.
- [x] Reopening or splitting the same PNG reuses the virtual buffer.
- [x] Auto-open is absent when the helper is disabled.
- [x] `:Pico8OpenPng` offers file completion.
- [x] The original PNG buffer is cleaned up and reload still works.
- [x] README and troubleshooting document the behavior.
- [x] Headless tests run in CI.

## Verification

- `tests/includes.lua`, run by `tests/run.sh`, covers `include`/`includeexpr`
  and cart-scoped `path` installation without helper setup, `gf` for quoted,
  unquoted, whitespace-padded, nested, absolute, space-containing, backslash,
  `.p8:2`, and selector-digit targets with Neovim's working directory outside
  the cart, working-directory decoys, literal `.lua:2` names, missing targets
  that create no file, option undo and user overrides, virtual-buffer root
  resolution, direct `.p8.png` auto-open, source-buffer deletion, reopening and
  splitting an existing PNG, reload, command completion, invalid PNGs,
  client-start failure, the post-decode attach failure path, and the
  disabled-helper path. It passed on Neovim 0.11.4 and 0.12.5 against a
  pico-lsp development build, and the full suite passes in CI on Neovim 0.11
  and 0.12.
- The existing config, helper, correctness, include-buffer, features, cart, and
  fallback suites pass on the same setup.
- Confirmed choices: `include` is buffer-local when empty, so a global value is
  treated as a default and overridden locally; `includeexpr` is local to the
  buffer, so any non-empty value is preserved. `path` is scoped to the cart
  only when it is empty or the default, and a custom value is preserved.
  `includeexpr` prefers the complete target on the cursor's `#include` line to
  recover spaces, literal `.lua:2` names, and selector digits, then falls back
  to `v:fname`. A failed auto-open leaves the named source buffer as an empty
  read-only `nofile` buffer. Decoded PNG virtual buffers carry
  `b:pico8_cart_root` and a scoped `path` for include navigation. Reopening a
  PNG reuses its virtual buffer.
- Known behavior: Neovim's `gf` strips a trailing `:2` before calling
  `includeexpr`; the resolver recovers the original target from the include
  line. Vim also tries its unmodified-name lookup before `includeexpr`, so a
  quoted path whose first word is an existing file in the cart can open that
  file. The cart-scoped `path` prevents the same shadowing from the working
  directory; the first-word case is documented in troubleshooting. Names
  starting with `./` or `../` are handled by Vim relative to the working
  directory before `includeexpr`; use an absolute or cart-relative path if a
  same-named file there would win.

## Risks

| Risk | Mitigation |
|---|---|
| `includeexpr` parsing differs from the server's include rules | Reuse the same quote/tab-suffix rules and add fixtures for both forms. |
| Auto-open leaves an empty or duplicate buffer | Delete the source buffer only after a successful virtual-buffer attach; reuse an existing virtual buffer and test both paths. |
| `gf` resolves relative to the wrong directory | Scope `path` to the cart and resolve against it, not `getcwd()`; test from a different working directory with decoys. |
| Vim's first unmodified-name lookup shadows a quoted spaced path | Scope `path` to the cart, document the remaining first-word case, and point to `:edit` for that rare input. |
| Users expect tab-specific opening | Document the limitation and point to `:Pico8Tabs`. |
