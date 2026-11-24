# M31 — Neovim Glyph Input Polish

**Status:** Done — cached catalog, attach-time prefetch, byte forms, filtered
picker, completion, tests, and documentation are complete.

**Depends on:** pico-lsp M16 (glyph catalog and picker), M26 (helper correctness)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-24.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

PICO-8 glyph input in Neovim no longer performs a synchronous catalog request
on every Shift-key press. The helper caches the server's catalog per cart,
prefetches it when glyph maps are enabled, and keeps the existing literal
uppercase fallback when the client or catalog is unavailable.

`:Pico8InsertGlyph` accepts glyph names, decimal bytes, and `0x` bytes; offers
name completion; and can filter the picker with a search term. Custom
`pico8.glyphs` entries continue to override built-in bytes.

**Demo:** With `g:pico8_glyph_maps = 1`, type `Shift-L` repeatedly in a string.
The first insertion loads the catalog; subsequent insertions read the cache and
do not block on a request. Run `:Pico8InsertGlyph left`, `:Pico8InsertGlyph 139`,
or `:Pico8InsertGlyph 0x8b` to insert the same glyph directly. Run
`:Pico8InsertGlyph butt` to open a picker filtered to matching names and
descriptions. A custom `logo` entry at byte `128` still wins over the built-in
`0x80` entry.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Cache scope | Cache the catalog per `pico_lsp` client and cart root. Store the full entry list plus a final `byte -> text` map where later entries override earlier ones. |
| D2 | Prefetch | When glyph maps are enabled, request the catalog asynchronously on `LspAttach`. Do not block attachment. |
| D3 | Synchronous fallback | On a cache miss inside an expression mapping, make one bounded synchronous request (500–1000 ms). On failure, fall back to the literal key and warn once. |
| D4 | Invalidation | Clear a client's cache on `LspDetach`, when the helper is re-setup, and when the client restarts. Do not cache across different roots. |
| D5 | Argument parsing | `:Pico8InsertGlyph` accepts an exact name, a decimal byte (`139`), a hex byte (`0x8b`), or a search term. Exact name/byte inserts immediately; any other term opens a filtered picker. |
| D6 | Completion | Command-line completion lists catalog names when a client and cache are available. Do not trigger a synchronous request from completion. |
| D7 | Picker | Keep `vim.ui.select`; filter by case-insensitive substring across name, description, and byte. Do not add a Telescope/fzf dependency. |
| D8 | Context rules | Keep the server's context validation: control entries are offered only inside strings, include paths are rejected, and unknown names/bytes error. |
| D9 | Replace mode | Preserve the existing replace-mode and non-modifiable-buffer fallbacks. |
| D10 | Scope | `.p8` buffers only; included `.lua` buffers do not receive glyph maps. |

### Resolved decisions

- **D1/D4:** `lua/pico_lsp/glyphs.lua` owns the cache, keyed by client ID and
  normalized cart root. It stores server-order entries plus `by_byte` and
  case-insensitive `names`. The cache clears when the client's last attached
  buffer detaches, on helper re-setup, and on a module reload. The glyph module
  installs its own detach cleanup so base-config users get the same
  invalidation.
- **D2:** Attach-time prefetch sends one asynchronous, position-independent
  `pico8/glyphs` request. `install_glyph_maps` also asks for a prefetch when a
  client is already attached; in-flight and filled caches coalesce. Read-only
  `.p8.png` virtual buffers never prefetch.
- **D2/settings:** The shipped and fallback configs mirror `settings.pico8`
  into `initializationOptions.pico8` when no explicit `init_options.pico8` is
  set. This prevents the attach-time prefetch from caching server defaults
  while the asynchronous `workspace/configuration` pull is still in flight.
- **D3:** The synchronous fallback timeout is 750 ms. It warns once per cache,
  returns the literal key, and does not retry until an explicit prefetch.
- **D4/activation:** `require("pico_lsp").setup({ glyph_maps = true })` installs
  the maps through the ftplugin and enables prefetch. The existing
  `vim.g.pico8_glyph_maps = 1` switch remains supported.
- **D5:** Numeric-looking out-of-range values error instead of becoming search
  terms. Exact names resolve against the full catalog first, so control entries
  receive the server's context error instead of opening the picker. A cold
  command cache makes one bounded full-catalog request before the picker's
  position request.
- **D6:** Completion lists canonical cached names only, deduplicated
  case-insensitively and sorted case-insensitively. It never starts a request.
- **D7:** The picker keeps `vim.ui.select`. The position-filtered response is
  local to the picker and never replaces the full catalog.
- **D8/D10:** `:Pico8InsertGlyph` remains available on included `.lua` buffers;
  only the Shift maps are `.p8`-only. The cached Shift mapping preserves the old
  context fallback locally by allowing only the `__lua__` section and rejecting
  `#include` lines.
- **D9:** Replace mode and non-modifiable buffers return before any cache or
  request work, preserving the existing behavior.

## Scope

### In scope

- Per-client/cart glyph catalog cache.
- Async prefetch after attach when glyph maps are enabled.
- Bounded synchronous cache-miss fallback.
- `:Pico8InsertGlyph` name/byte/search argument handling.
- Command-line name completion.
- Filtered `vim.ui.select` picker.
- Tests for request counts, byte insertion, custom overrides, fallbacks, and
  completion.
- Documentation updates.

### Out of scope

- Changing the server catalog, `pico8/glyphs`, or `pico8.insertGlyph`.
- PICO-8 `CTRL-J`/`CTRL-K`/`CTRL-P` input modes.
- Installing glyph maps on included `.lua` files.
- Replacing `vim.ui.select` with Telescope, fzf-lua, or snacks.
- A floating preview or graphical glyph browser.
- Automatic uppercase-to-glyph conversion outside the existing mappings.
- VS Code or Helix behavior.

## Deliverables

1. `lua/pico_lsp/glyphs.lua` — catalog cache, prefetch, insertion, picker,
   and completion.
2. `lua/pico_lsp/init.lua` — command parsing, completion, prefetch wiring, and
   `glyph_maps` activation.
3. `tests/glyphs.lua` — focused headless cache, insertion, picker, completion,
   and fallback tests.
4. `README.md`, `docs/usage.md`, `docs/configuration.md`, and
   `docs/troubleshooting.md` — new argument forms, filtering, cache, and
   restart behavior.
5. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Catalog cache

Store per client ID and root:

```lua
{
  entries = { ... },       -- server order, including duplicates
  by_byte = { [0x80] = "..." },
  names = { left = entry, ... },
  fetched_at = ...,
}
```

- `by_byte` applies the existing "later entries win" rule so a custom glyph
  overrides a built-in byte.
- `names` is case-insensitive for lookup but preserves the server's spelling for
  display.
- Keep the raw entries for the picker and completion.
- A cache entry is valid for the lifetime of the client attachment. Server
  settings changes require a client restart, which clears the cache.
- Cap memory by clearing entries on detach; the catalog is small.

### 2. Prefetch

- On `LspAttach` for a `pico8` buffer, if `vim.g.pico8_glyph_maps` is truthy or
  the helper option enables it, send an asynchronous `pico8/glyphs` request.
- Fill the cache in the callback. Log failures at debug level; do not notify on
  a prefetch failure.
- Do not prefetch for `.p8.png` read-only buffers unless glyph maps are
  installed there; the current mappings are insert-mode only and the buffer is
  not modifiable.
- Do not prefetch from `install_glyph_maps` itself if a request is already in
  flight.

### 3. Synchronous fallback

The expression mapping must return a string synchronously. If the cache is
empty:

- Send one `request_sync` with a 500–1000 ms timeout.
- On success, fill the cache and return the glyph text.
- On failure, set a per-client warned flag, notify once, and return the literal
  key.
- Do not repeat the failed request on every keypress; retry only after a client
  restart or an explicit prefetch.
- In replace mode, return the literal key without a request, preserving today's
  behavior.
- In a non-modifiable buffer, return an empty string, preserving today's
  behavior.

### 4. `:Pico8InsertGlyph` arguments

Parse the argument in this order:

1. Empty: open the unfiltered picker.
2. Decimal integer in `0..255`: insert by byte.
3. `0x` or `0X` followed by one or two hex digits: insert by byte.
4. Exact name match, case-insensitive: insert by name.
5. Anything else: open the picker filtered by the argument.

Requirements:

- Byte insertion sends `{ byte = value }` to `pico8.insertGlyph`; name insertion
  sends `{ name = name }`.
- Both forms include the current document URI and position.
- An out-of-range byte (`256`, `-1`, `0x100`) produces a clear error and does
  not call the server.
- A search term that matches nothing shows a notification and does not open an
  empty picker.
- A direct insert still respects the server's context validation, including
  "only valid inside a string" and "cannot insert in an include path".
- Insertion applies the returned `WorkspaceEdit` with the client's offset
  encoding.
- If the server returns `applied = true` with no edit, do not apply an empty
  edit; the buffer is already up to date.

### 5. Command completion

- Add a `complete` callback to `:Pico8InsertGlyph`.
- The callback returns cached glyph names matching the argument prefix, sorted
  by name.
- If no cache exists but a client is attached, do not trigger a synchronous
  request; return an empty list. The user can run the command once to populate
  the cache.
- Include custom names.
- Do not complete decimal/hex forms; users type those directly.
- Deduplicate names case-insensitively.

### 6. Picker

- Keep `vim.ui.select` and the existing `format_item` layout:
  glyph text, `p8_name`, and description/byte.
- When a search term is supplied, filter entries by case-insensitive substring
  across:
  - name;
  - description;
  - `string.format("0x%02x", byte)`;
  - decimal byte string.
- Preserve server order within the filtered list.
- The picker request includes the current position so the server can filter
  string-only entries correctly; alternatively use the cached full catalog and
  rely on `pico8.insertGlyph` to reject invalid context. Prefer the existing
  position request so the picker does not offer invalid entries.
- Do not overwrite the full `entries`/`by_byte` cache with a position-filtered
  picker result. Keep the filtered list local to the picker, or merge only
  entries that are valid for the current context.
- Selection calls the same insert path as an exact name.
- Cancellation is a no-op.

### 7. Documentation

- Document all argument forms and completion.
- Explain that a search term filters the picker.
- Explain the cache and prefetch behavior, and that changing `pico8.glyphs`
  requires a client restart.
- Keep the existing Shift mapping and fallback documentation, updating the
  performance note.
- Note that control entries are still context-restricted.

### 8. Tests

- Headless tests assert:
  - the first Shift insertion populates the cache;
  - a second Shift insertion does not call `request_sync` again (wrap or count
    the client request method);
  - custom byte overrides still win;
  - decimal and hex byte insertion work;
  - an invalid byte is rejected before the RPC;
  - exact name insertion works;
  - a search term opens a filtered picker (stub `vim.ui.select` and assert the
    item list);
  - a position-filtered picker request does not clobber the full catalog used
    by Shift mappings;
  - command completion returns cached names without a request;
  - missing-client and failed-request fallbacks return literal letters and warn
    once;
  - replace mode and read-only buffers do not request.
- Use the existing custom `logo` glyph fixture in the helper test.
- Run on Neovim 0.11 and 0.12 in CI.

## Interfaces and state

- New module-local glyph cache keyed by client/root.
- `:Pico8InsertGlyph` gains byte and search forms plus completion.
- No new LSP request, response, command, or setting.
- No change to the server's glyph catalog or insertion rules.
- No new plugin dependency.

## Error handling

- Unknown name, byte out of range, invalid context, and stale analysis all show
  a clear notification from the server response.
- A prefetch failure is silent unless the user later requests a glyph.
- A synchronous fallback failure warns once per client and falls back to the
  literal key.
- A picker request failure falls back to the cached catalog if one exists;
  otherwise notify and stop.
- A closed buffer or detached client cancels the insertion without throwing.

## Testing and CI

- Extend the headless Neovim suite from M25/M26.
- The request-count test must be deterministic and must not depend on server
  timing; wrap `client.request_sync` in the test or inspect a cache counter.
- Server tests remain in `pico-lsp`; add an LSP e2e test there only if a
  response shape is found to be unstable.
- Run on Neovim 0.11 and 0.12 in CI.
- Manual check: enable glyph maps, type a full Shift-letter sequence, and
  confirm no visible blocking after the first insertion.

## Exit criteria

- [x] Glyph maps use the cached catalog and do not request on every keypress.
- [x] Prefetch runs asynchronously after attach when maps are enabled.
- [x] Failed lookups still fall back to literal uppercase letters.
- [x] `:Pico8InsertGlyph` accepts names, decimal bytes, and `0x` bytes.
- [x] A search term filters the picker.
- [x] Command completion lists cached names without a request.
- [x] Custom glyph overrides, context rules, and replace-mode behavior are
      preserved.
- [x] Headless tests and CI cover the cache and argument forms.

## Risks

| Risk | Mitigation |
|---|---|
| A synchronous cache miss can still block | Prefetch on attach, keep the timeout bounded, and test that only the first request occurs. |
| Cache invalidation is missed after settings changes | Key by client and clear on detach; document that settings changes need a restart. |
| Filtering hides the expected glyph | Match name, description, and byte representations; show a clear "no matches" message. |
| Byte insertion bypasses context safety | The server remains authoritative and rejects invalid contexts. |
