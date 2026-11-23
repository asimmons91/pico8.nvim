# M26 — Neovim Helper Correctness and Performance

**Status:** Done — buffer-aware include discovery, include caching, root-matched
client reuse, managed detach, save/reload and debounced edit rescans,
`:Pico8Refresh`, setup re-entry, tests, and documentation are complete.

**Depends on:** pico-lsp M6 (server features), M25 (drop-in config and cart-aware roots)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

The optional Neovim helper attaches cart-owned `.lua` buffers using the cart's
current buffer contents, never reuses a client rooted at a different cart, and
detaches managed clients when an include disappears. Repeated buffer entry does
not re-read every ancestor directory or start duplicate clients.

An unsaved `#include` is visible immediately when the included file is opened.
With two carts open, saving one cart cannot attach the other cart's client to an
unrelated `.lua` file. Removed includes stop receiving PICO-8 diagnostics and do
not keep a stale client attached.

**Demo:** Open `cart.p8`, add `#include "lib.lua"` without saving, then open
`lib.lua`. The helper attaches `pico_lsp` with the cart directory as its root.
Delete the `#include` line, save or leave insert mode, and the managed client
detaches from `lib.lua`. Open a second cart in a sibling directory and repeat;
the helper never attaches the first cart's client to the second cart's include.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Include source | When a `.p8` buffer is loaded, parse its lines instead of re-reading the file. Fall back to disk only when no loaded buffer exists. |
| D2 | Cache key | Cache each cart's parsed include set by buffer `changedtick` when loaded, otherwise by path plus mtime and size. Invalidate on save and on debounced cart edits. |
| D3 | Client reuse | Reuse an existing `pico_lsp` client only when its normalized root matches the target cart directory. Otherwise start a client for that root. |
| D4 | Ownership | Store helper-managed attachments in a buffer map containing the client ID, root, and owning cart. Explicitly attaching an existing client creates a managed record. Never detach a client that is not recorded as managed for that buffer. |
| D5 | Revalidation | On cart save and debounced cart edits, recompute ownership for loaded managed `.lua` buffers. Detach when the owning cart disappears or changes root, then attach the new owner if one exists. |
| D6 | Rescan triggers | `BufWritePost` and `BufReadPost` for carts, `BufUnload`/`BufWipeout` cache invalidation and revalidation, debounced `TextChanged`/`TextChangedI` for loaded carts, `BufEnter`/`FileType` for Lua buffers, and an explicit `:Pico8Refresh`. |
| D7 | Debounce | Coalesce cart-edit rescans for 250–500 ms. A rescan must not run synchronously on every keystroke. |
| D8 | Missing binary | Keep one warning per session. Do not emit a warning for every `.lua` buffer that cannot attach. |
| D9 | CI | Extend the headless Neovim job from M25 with the correctness cases in this milestone. |
| D10 | Scope | No user-facing commands beyond `:Pico8Refresh`; no change to include semantics or server ownership rules. |

### Resolved decisions

- **D7:** the debounce is 300 ms.
- **D2/D6:** `:Pico8Refresh` is registered even when the helper is disabled and
  reports that state without scanning. A loaded cart buffer remains
  authoritative, so an external change to a loaded cart requires reloading it
  (`:edit!`); `BufReadPost` rescans the new contents, and `BufUnload` drops
  cached data and revalidates.
- **D4:** a buffer that already has a user-started `pico_lsp` client is left
  untouched; the helper never adds a second client or claims that attachment.
- **D4/D5:** a re-`setup()` while `pico_lsp` is already enabled preserves
  managed records without re-running the native enable sweep; disabling the
  helper detaches the records it owns and only those.

## Scope

### In scope

- Buffer-aware include parsing and caching.
- Root-matched client reuse and helper-managed attachment tracking.
- Ownership revalidation and managed detach.
- Debounced cart-edit rescan.
- A `:Pico8Refresh` command.
- Headless tests for unsaved includes, multiple carts, removed includes, and
  duplicate prevention.
- Documentation and troubleshooting updates.

### Out of scope

- Changing faithful PICO-8 include semantics.
- Recursive includes or include reordering.
- Automatically editing cart files.
- Starting a client for unrelated `.lua` files.
- PICO-8 comment options on included buffers (M29).
- `#include` navigation or PNG auto-open (M30).
- LSP server changes.

## Deliverables

1. `lua/pico_lsp/init.lua` — buffer-aware include discovery,
   cache, root matching, and managed detach.
2. `tests/correctness.lua` and `tests/run.sh` — focused headless cases for the
   helper correctness work.
3. `.github/workflows/ci.yml` — the existing Neovim job runs the extended
   `tests/run.sh` coverage; no workflow edit is required for these cases.
4. `README.md`, `docs/usage.md`, and `docs/troubleshooting.md` — behavior and
   recovery guidance.
5. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Buffer-aware include parsing

- Locate a loaded cart buffer with `vim.fn.bufnr(path)` or an equivalent
  normalized lookup.
- When the buffer is loaded, read `nvim_buf_get_lines` and parse `#include`
  directives from the buffer contents.
- When the buffer is not loaded, read the file from disk as today.
- Preserve the existing directive parser behavior:
  - leading whitespace before `#include`;
  - single or double quotes around the path;
  - optional `:<hex digit>` tab selector only for `.p8` and `.p8.png` include
    paths, matching the server's `splitIncludeTarget`; a `.lua` path keeps the
    suffix as a literal filename;
  - forward-slash normalization;
  - case-insensitive path comparison on Windows and macOS.
- A missing or unreadable cart falls back to the previous behavior without
  throwing an error.

### 2. Include cache

- Keep a module-local cache keyed by normalized cart path.
- For loaded buffers, store the source `changedtick`; a changed tick invalidates
  the entry.
- For disk reads, store mtime and size from `vim.uv.fs_stat` or an equivalent
  call. A missing file invalidates the entry.
- Cache the parsed target set, not the raw lines.
- Clear a cart's entry on `BufWritePost` and on debounced cart edits.
- Bound the cache to loaded carts; clear entries on `BufWipeout` and on helper
  shutdown.
- A cache miss must not block the editor for longer than a normal directory
  scan. Do not walk the entire filesystem.

### 3. Client root matching

- Normalize roots with `vim.fs.normalize` and compare using the existing
  Windows/macOS case rules.
- Read the client root from `client.config.root_dir` first, then
  `client.root_dir` for compatibility.
- Reuse only a client whose root matches the cart directory.
- If a matching client exists but is not attached to the buffer, attach it.
- If no matching client exists, start one with the cart directory as
  `root_dir`.
- Do not attach a client rooted at cart A to a file owned by cart B.
- Handle a nil root explicitly; a nil root does not match a cart directory.

### 4. Managed attachment tracking

- Record an attachment only after `vim.lsp.start` succeeds for a helper-started
  client, or after the helper explicitly attaches an existing matching client
  to a new buffer.
- Store at least `{ client_id, root_dir, cart_uri }` per buffer.
- On `LspDetach`, remove the entry when the detached client matches the managed
  client.
- On `BufWipeout`, remove the entry.
- When detaching for ownership changes, call `vim.lsp.buf_detach_client` and
  then clear the managed entry. Never call detach for a client that is not
  recorded as managed for that buffer.
- A user-started `pico_lsp` client on an included `.lua` buffer must remain
  untouched unless it was started or explicitly attached by the helper.

### 5. Ownership revalidation

- On cart save and debounced cart edits, scan loaded buffers with managed
  attachments.
- Recompute the owning cart using the buffer-aware resolver.
- If the owner is unchanged, do nothing.
- If the owner is removed, detach the managed client and clear the entry.
- If the owner changed to a cart with a different root, detach the old managed
  client, then attach the new owner through the normal path.
- Avoid attaching a buffer twice during one revalidation pass.
- Do not detach a client solely because the buffer is no longer visible; a
  hidden loaded buffer still belongs to its cart.
- The server remains the source of truth for diagnostics and ownership; the
  helper only manages attachment.

### 6. Rescan triggers and debounce

- Keep the existing `BufWritePost` cart rescan.
- Rescan when a cart is reloaded (`BufReadPost`) so `:edit!` sees external
  include changes, and revalidate after a cart is unloaded (`BufUnload`) or
  wiped (`BufWipeout`).
- Add a debounced cart-edit rescan so a new or removed `#include` takes effect
  without saving.
- Use one timer or generation counter per cart; a new edit restarts the
  debounce.
- Do not rescan during `TextChangedI` on every character without debouncing.
- Add `:Pico8Refresh` with no arguments. It clears the include cache, rescans
  loaded `.lua` buffers, and prints a short confirmation. It reads loaded cart
  buffers, so it does not apply external disk changes to an open cart.
- Make `:Pico8Refresh` safe when the helper is disabled or no carts are open.

### 7. Error handling and logging

- A parse error in one cart must not stop the scan of other carts.
- A failed `vim.lsp.start` must not record a managed attachment.
- A missing binary warning is emitted once; subsequent skipped attachments are
  silent.
- Errors from `vim.lsp.buf_detach_client` are ignored after logging at debug
  level, because the client may already have stopped.
- Never write to stdout.

### 8. Documentation

- Explain that unsaved include edits are visible to the helper.
- Document that a loaded cart buffer is authoritative. After an external change
  to an open cart, reload it with `:edit!`; the helper rescans on reload.
  `:Pico8Refresh` does not reload cart buffers.
- Document `:Pico8Refresh` for carts that are not loaded.
- Document that the helper only detaches clients it manages.
- Add a troubleshooting entry for a stale include attachment and the refresh
  command.
- Note that unrelated `.lua` files remain untouched.

## Interfaces and state

- `require("pico_lsp").setup(opts)` keeps its existing options.
- New command: `:Pico8Refresh`.
- Module-local cache and managed-attachment state; helper-managed attachments
  carry a private per-buffer marker on the client so a module reload can
  re-adopt them without claiming a user-started attachment on another buffer;
  no new global variables.
- No new LSP request, response, server command, or setting.
- `vim.b.pico8_cart` and comment settings are added by M29, not this milestone.

## Error handling

- A failed attachment, detach, or ownership revalidation must not throw out of
  the `BufEnter`/`FileType`/`TextChanged` callback.
- A missing binary produces one warning per session; later skipped attachments
  are silent.
- A malformed or unreadable cart is skipped without stopping the scan of other
  carts.
- Cache and timer failures reset the affected cart's entry and fall back to the
  next bounded scan.
- User-managed clients are never detached by the helper.

## Testing and CI

- `tests/correctness.lua`, run by `tests/run.sh`, covers:
  - opening a cart and appending an unsaved `#include`, then opening the target
    and asserting attachment;
  - modifying a loaded cart's include list without saving and asserting the
    target attaches or detaches after the debounce;
  - opening two carts with the same include basename in sibling directories and
    asserting each buffer uses the matching root;
  - moving ownership between a parent cart and a nearer cart root;
  - removing one include while keeping another managed buffer and the cart's
    own client attached;
  - saving a cart and asserting a removed include detaches and an added include
    reattaches;
  - reloading a cart with `:edit!` and asserting external include changes take
    effect immediately;
  - unloading or wiping a cart and asserting its includes are revalidated
    against disk;
  - externally changing a cart that is not loaded and asserting the disk include
    cache notices the change, including a same-size include swap;
  - asserting a loaded cart buffer stays authoritative for `:Pico8Refresh` when
    disk disagrees;
  - renaming a managed `.lua` buffer and asserting the helper client detaches;
  - re-running setup while `pico_lsp` is already enabled and asserting managed
    attachments and user-started clients survive;
  - simulating a plugin module reload and asserting marked helper clients are
    re-adopted while user-started clients remain;
  - disabling the helper and asserting managed attachments detach while a
    user-started client remains;
  - invoking disabled commands and asserting they do not start clients or edit
    buffers;
  - removing an include and asserting the managed client detaches;
  - starting a `pico_lsp` client directly on an included `.lua` buffer,
    removing the include, and asserting the user-started client remains
    attached even after `:Pico8Refresh`;
  - entering and leaving the same `.lua` buffer repeatedly and asserting one
    client per root;
  - calling `:Pico8Refresh` and asserting no duplicate clients;
  - verifying an unrelated `.lua` file still does not attach;
  - verifying a `.lua:2` include path is treated literally, matching the
    server, and does not attach a `lib.lua` buffer.
- Tests must wait on conditions with a bounded `vim.wait`, not fixed sleeps.
- Run the suite on Neovim 0.11 and 0.12 in CI.
- The test must clean up temporary directories and stop clients before exiting.

## Exit criteria

- [x] An unsaved `#include` attaches the included `.lua` buffer.
- [x] Editing or removing an include updates managed attachments after the
      debounce.
- [x] Saving or reloading a cart applies its new include list immediately, and
      unloading or wiping it revalidates against disk.
- [x] Renaming a managed `.lua` buffer detaches its helper-owned client.
- [x] Re-running setup while `pico_lsp` is already enabled preserves managed
      attachments and user-started clients, and disabling the helper detaches
      only its managed attachments.
- [x] A plugin module reload re-adopts helper-managed clients without claiming
      user-started clients.
- [x] Clients are reused only for the matching cart root.
- [x] Multiple carts in sibling directories do not cross-attach.
- [x] Repeated buffer entry does not create duplicate clients.
- [x] The helper never detaches a client it did not manage.
- [x] `:Pico8Refresh` rescans safely and is idempotent.
- [x] Headless Neovim tests cover the cases above and run in CI.

## Risks

| Risk | Mitigation |
|---|---|
| Reading a loaded cart buffer could differ from the saved file | That is intentional: the editor's current include list is what the user sees. A save refreshes the cache. |
| Debounced rescans add complexity | Keep one timer per cart and test idempotence. |
| Root matching can start more clients in multi-cart projects | This is the intended isolation; document the behavior and keep clients per cart directory. |
| Detaching could interfere with user-managed clients | Only detach clients recorded in the helper's managed map. |
