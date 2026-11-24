# M29 — PICO-8 Buffer Settings for Cart-Owned Lua Files

**Status:** Done — client work complete.

**Depends on:** M26 (helper correctness)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

An included `.lua` file behaves like PICO-8 code for comment editing while
remaining a normal Lua buffer. Comment-aware formatting recognizes `//` as a
PICO-8 comment, `gcc` uses `--`, and the buffer exposes its owning cart to other
Neovim plugins. Users can jump from an include back to the cart without
guessing.

The helper does not change the filetype, install glyph maps, override
`syntax`, or replace a user's comment configuration. It only fills in PICO-8
defaults when the buffer still has stock Lua comment settings.

**Demo:** Open an included `lib.lua` through the helper and run `:setlocal
comments? commentstring?`. The values are `:---,:--,://` and `-- %s`. `:gcc`
comments a line with `--`, and `gq` wrapping recognizes a `//` comment block.
`:echo b:pico8_cart` prints the owning cart URI. `:Pico8OpenCart` opens the cart
in the current window.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Filetype | Keep `filetype=lua`. Do not switch cart-owned includes to `pico8`; that would break Lua tooling, syntax, and the user's expectations. |
| D2 | Comment defaults | Set `comments=:---,:--,://` and `commentstring=--\ %s` when the current values are empty or match the stock Lua ftplugin defaults. |
| D3 | User overrides | Do not overwrite a value that differs from the stock Lua defaults. Record what the helper changed so it can restore it later. |
| D4 | Restore | On managed detach, restore the previous `comments`/`commentstring` only if the buffer still has the values the helper set. Do not clobber later user changes. |
| D5 | Buffer variables | Set `vim.b.pico8_cart` to the owning cart URI and `vim.b.pico8_cart_root` to its directory. Clear them on managed detach or when ownership disappears. |
| D6 | Open-cart command | Add `:Pico8OpenCart` for managed include buffers. It opens the owning cart in the current window and does not modify files. |
| D7 | Glyph maps | Do not install PICO-8 Shift glyph mappings on included `.lua` buffers. The existing exclusion stays. |
| D8 | Formatting | Rely on Neovim's LSP `formatexpr` support when available. Do not force `formatexpr`; range formatting is M33. |
| D9 | Scope | Only helper-managed cart-owned `.lua` buffers. `.p8` buffers keep their existing ftplugin behavior. |

Confirmed 2026-11-23: D2/D3 apply per option, so a custom `comments` does not
prevent a stock/empty `commentstring` from being filled in; exact PICO-8 values
count as user values and are not claimed or restored; D6 is limited to managed
includes, and the command stays registered after a later disabled setup where it
reports the disabled helper. Restore records are module-local, so a plugin
reload before detach leaves exact PICO-8 values in place. Setting an option to
exactly the target after attach is restored, because detach cannot distinguish
it from the helper's value.

## Scope

### In scope

- Buffer-local `comments` and `commentstring` for managed includes.
- Stock-default detection and safe restore.
- `vim.b.pico8_cart` and `vim.b.pico8_cart_root`.
- `:Pico8OpenCart`.
- Headless tests for comment editing, variables, overrides, and restore.
- Documentation and troubleshooting.

### Out of scope

- Changing `ftplugin/pico8.vim` comment behavior for carts.
- Changing filetype, `syntax`, `indentexpr`, `formatoptions`, or `formatexpr`.
- Installing glyph maps or `pico8` keymaps on included files.
- Automatic formatting on save.
- Changing include ownership or server analysis.
- Multi-owner selection when a file is included by more than one cart; the
  existing nearest-ancestor ownership rule applies.
- VS Code or Helix behavior.

## Deliverables

1. `lua/pico_lsp/init.lua` — comment and buffer-variable setup in
   the managed attach/detach path.
2. `tests/helper.lua` or a focused include-settings test.
3. `README.md` — include-buffer behavior and variables.
4. `docs/troubleshooting.md` — comment or variable troubleshooting.
5. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Stock Lua defaults

Before changing a buffer, read:

- `vim.bo[bufnr].comments`
- `vim.bo[bufnr].commentstring`

Treat these as stock/default values:

- `comments` equal to `:---,:--` (the built-in Lua ftplugin value);
- `commentstring` equal to `-- %s`;
- empty strings.

If the buffer has any other value, leave both options untouched and do not
record a change for restore.

The PICO-8 target values are:

- `comments = ":---,:--,://"`
- `commentstring = "-- %s"`

`://` is included because PICO-8 accepts `//` comments, and comment-aware
formatting should continue that leader.

### 2. Apply and restore

- Apply the target values after the helper attaches a managed client.
- Record `{ comments = previous, commentstring = previous }` for the buffer.
- On managed detach:
  - restore `comments` only if the current value still equals the target;
  - restore `commentstring` only if the current value still equals the target;
  - remove the saved record either way.
- On `BufWipeout`, remove the saved record.
- If the helper is disabled while buffers remain open, restore managed values
  for loaded buffers.
- Do not restore values for a buffer that has been reattached by a different
  managed client with the same settings; keep one record per buffer.

### 3. Buffer variables

Set on managed attach:

- `vim.b[bufnr].pico8_cart` = owning cart URI, for example
  `file:///path/to/cart.p8`.
- `vim.b[bufnr].pico8_cart_root` = normalized cart directory path.

Requirements:

- Use the same normalized URI form as the helper's `find_cart` result.
- Set the variables after the owning cart is confirmed, not before.
- Clear them on managed detach when no managed client remains.
- Do not set them on unrelated `.lua` files or on `.p8` carts.
- Treat them as read-only compatibility surface for other plugins; document the
  names.
- If ownership changes to another cart, update both values after the new
  attachment succeeds.

### 4. `:Pico8OpenCart`

- Available when the helper is enabled.
- On a managed include buffer, open `vim.b.pico8_cart` in the current window
  with `:edit`.
- On a root cart or PNG virtual buffer, notify that the current buffer is
  already a cart.
- On an unrelated buffer, notify that no owning cart was found.
- Do not save, modify, or reload the include buffer.
- Accept an optional path argument? No; keep the command argument-free in this
  milestone.
- Use `vim.fn.fnameescape` and handle spaces in paths.

### 5. Interaction with other milestones

- M26 owns attachment, root matching, and ownership revalidation. This
  milestone hooks into the managed attach/detach points.
- M28 may use `pico8_cart` to map a buffer to its root; the variable is not a
  substitute for the cache.
- M30 adds include navigation and PNG auto-open; it must not reset these
  comment settings.
- M33 may add server range formatting; it must respect the comment leaders set
  here.

### 6. Documentation

- Add an "Included `.lua` files" subsection to `README.md`
  explaining:
  - the filetype stays `lua`;
  - `//` is accepted by comment-aware formatting;
  - glyph maps remain `.p8`-only;
  - `b:pico8_cart` and `b:pico8_cart_root` are available;
  - `:Pico8OpenCart` jumps to the owner;
  - custom comment settings are preserved.
- Add a troubleshooting entry for `//` not being recognized: confirm the buffer
  is helper-managed, check `:setlocal comments?`, and check `:Pico8Refresh`.
- Mention the restore behavior when the helper is disabled.

## Interfaces and state

- New command: `:Pico8OpenCart`.
- New buffer variables: `b:pico8_cart`, `b:pico8_cart_root`.
- New module-local restore records keyed by buffer number.
- No new LSP request, response, server command, or setting.
- No change to helper setup options.

## Error handling

- A nil or malformed cart URI leaves the buffer untouched and logs at debug
  level.
- A failed `:edit` in `:Pico8OpenCart` shows a normal Neovim error; the include
  buffer remains current.
- A buffer that becomes unloaded before restore is skipped.
- A user-changed comment value is never overwritten on restore.
- Setting buffer variables on a read-only buffer is safe; no text is changed.

## Testing and CI

- Headless tests assert:
  - a managed include receives the PICO-8 `comments` and `commentstring`;
  - `:gcc` uses `--`;
  - `gq` recognizes and continues a `//` comment block;
  - an unrelated `.lua` file keeps stock Lua settings;
  - a buffer with custom comment settings is not overwritten;
  - managed detach restores stock values;
  - a user change after attach is preserved on detach;
  - `b:pico8_cart` and `b:pico8_cart_root` are set and cleared;
  - `:Pico8OpenCart` opens the cart and handles spaces in paths;
  - glyph maps remain absent from the include buffer.
- Reuse the existing comment-wrapping test pattern in
  `tests/helper.lua`.
- Run on Neovim 0.11 and 0.12 in CI.

## Exit criteria

- [x] Managed includes use `:---,:--,://` and `-- %s` when they had stock Lua
      settings.
- [x] Custom comment settings are preserved.
- [x] Managed detach restores the previous values only when safe.
- [x] `b:pico8_cart` and `b:pico8_cart_root` are available and cleared.
- [x] `:Pico8OpenCart` opens the owning cart.
- [x] Glyph maps and filetype remain unchanged for includes.
- [x] Headless tests cover the behavior in CI.

## Verification

- `tests/include_buffers.lua`, run by `tests/run.sh`, covers stock PICO-8
  comment application, `gcc`, `gq` continuation of `//` blocks, buffer
  variables, glyph-map exclusion, `:Pico8OpenCart` on includes/carts/PNG/
  unrelated buffers with spaces in paths, stock and empty restore, per-option
  custom values, already-PICO-8 values, user changes after attach, same-root
  ownership changes, and the disabled helper path. It passed on Neovim 0.12.5
  against a pico-lsp development build.
- The existing config, helper, correctness, features, cart, and fallback
  suites pass on the same setup.
- Confirmed choices: comment defaults apply per option; exact PICO-8 values are
  treated as user values and are not claimed or restored; `:Pico8OpenCart` is
  limited to managed includes and remains registered after a disabled setup.
- Known limitation: restore records are module-local. A plugin reload before
  detach loses them, so exact PICO-8 values stay in place rather than reverting
  to a guessed previous value.

## Risks

| Risk | Mitigation |
|---|---|
| Overwriting a user's comment configuration | Only change stock/empty values and never restore over later edits. |
| `//` is not a Lua comment to other tools | Keep `filetype=lua`; the setting is buffer-local and scoped to cart-owned files. |
| Stale buffer variables after ownership changes | Clear and reset through M26's managed revalidation. |
| `:Pico8OpenCart` surprises users by replacing the window | Document the current-window behavior; a split variant can be added later. |
