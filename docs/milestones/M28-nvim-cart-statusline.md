# M28 — Neovim Cart Budget Statusline and Tab Picker

**Status:** Done — cached cart state, statusline formatting, refresh
autocmds, `:Pico8CartInfo`, `:Pico8Tabs`, tests, and documentation are complete.

**Depends on:** M25 (drop-in configuration), M26 (helper correctness), M27
(client capability wiring)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

Neovim users can see the assembled cart's token, character, and compressed-size
budget in the statusline without opening the code lens or invoking a command.
The helper caches `pico8/cartInfo` and refreshes it asynchronously, so statusline
rendering never makes a blocking LSP request. The same data powers
`:Pico8CartInfo` and a searchable `:Pico8Tabs` picker for carts with multiple
code tabs.

Included `.lua` buffers and read-only `.p8.png` virtual buffers show their
owning cart's budget. A lualine recipe is documented, but no statusline plugin
is required.

**Demo:** Add the documented lualine component. Opening `tests/fixtures/smoke.p8`
shows `4210/8192 tok · 27433/65535 ch · 12000/15616 zip` (values vary by cart).
Editing an include updates the numbers after a short debounce. Running
`:Pico8CartInfo` prints the same summary with per-file and per-include detail.
`:Pico8Tabs` lists the cart's tabs and jumps to the chosen one. The component
uses a cached value and does not block the statusline.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Module | Put cache and commands in `lua/pico_lsp/cart.lua` and re-export the public functions from `require("pico_lsp")`. |
| D2 | Never block rendering | Statusline functions return cached data only. They never call `request_sync` or wait for the server. |
| D3 | Refresh transport | Use asynchronous `client:request` for `pico8/cartInfo`. Ignore responses that no longer match the current refresh generation. |
| D4 | Cache key | Cache by the response's `rootUri`: the owning cart for includes, and the `pico8-cart:` virtual URI for a virtual-buffer request. Map each buffer to that key. Source-PNG and virtual requests are separate keys; do not assume they share an entry. |
| D5 | Refresh triggers | `LspAttach`, `BufWritePost` for carts and includes, `InsertLeave`, and a debounced `TextChanged` on attached buffers. A manual refresh is available. |
| D6 | Debounce | Coalesce edit-triggered refreshes for 400–600 ms. Do not request on every keystroke. |
| D7 | Default text | `tokens/tokenLimit tok · chars/charLimit ch · compressed/compressedLimit zip`, omitting the compressed segment when `compressedStatus` is `unavailable`. |
| D8 | Formatting | Expose raw numbers through `cart_info`; `cart_status` formats them. Do not abbreviate with `k` unless the caller opts in. |
| D9 | Warning state | Return the raw `compressedStatus` in `cart_info`. The documented lualine recipe colors the component for `warning` and `error`; `cart_status` does not add terminal escape sequences. |
| D10 | Commands | Add `:Pico8CartInfo` and `:Pico8Tabs`. No `:Pico8NextTab`/`:Pico8PrevTab` in the first version. |
| D11 | Tabs scope | `:Pico8Tabs` works on the root cart and on `.p8.png` virtual documents. On an included `.lua` buffer it explains that tabs belong to the owning cart. |
| D12 | Server changes | None. Use the existing `pico8/cartInfo` response fields. |

### Resolved decisions

- **D1/D2:** `lua/pico_lsp/cart.lua` owns the cache and commands. The shipped
  `lsp/pico_lsp.lua` requires it so base-config users who never call
  `require("pico_lsp").setup()` still get automatic caching and the commands.
- **D5/D6:** the debounce is 500 ms. Attaches, saves, `InsertLeave`, and a
  successful PNG reload refresh immediately; `TextChanged` refreshes after the
  debounce. Read-only virtual buffers are never edit-refreshed.
- **D4:** helper-managed includes carry the owning cart URI in
  `b:pico8_cart`. Other Lua buffers start under their own URI and re-key the
  cache to the response's `rootUri` after the first success.
- **D7/D8:** `cart_status` uses exactly the server's integers and the
  `tok`/`ch`/`zip` labels. It returns `nil` without a cached value and `""`
  when the requested fields produce no segments.
- **D10:** `:Pico8CartInfo` requests fresh data and notifies a capped
  per-file/per-include breakdown; full data stays available through
  `cart_info()`. `:Pico8Tabs` always shows `vim.ui.select`, including a
  single-tab cart, fetches fresh tab lines, and falls back to the last cached
  value on error. On a standalone `.lua` cart with no parsed tabs it offers the
  whole buffer as a single `main` tab.
- **D11:** `:Pico8Tabs` names the owning cart on a helper-managed include and
  does not switch buffers. On a decoded `.p8.png` buffer it jumps within the
  virtual buffer.
- **D4/D3:** `cart_info` returns a deep copy of the server table. Requests are
  coalesced to one in flight plus one pending per root, stale generations never
  update the cache, and a failed refresh keeps the last good value.
- **D10:** the cart commands remain registered when the included-Lua helper is
  disabled because they work with any attached `pico_lsp` client. A disabled
  setup clears cached state and timers.

## Scope

### In scope

- Cached `pico8/cartInfo` client state.
- Public `cart_info`, `cart_status`, and `refresh_cart_info` functions.
- `:Pico8CartInfo` summary using `vim.notify`.
- `:Pico8Tabs` picker using `vim.ui.select`.
- Refresh autocmds and debounce.
- Support for cart-owned `.lua` and `.p8.png` virtual buffers.
- A documented lualine component and a dependency-free statusline expression.
- Headless tests and CI coverage.

### Out of scope

- Changing `pico8/cartInfo`, the budget lens, or budget diagnostics.
- Per-file or per-tab token accounting beyond what the server returns.
- A new statusline plugin, Lualine dependency, or Heirline dependency.
- Background polling while Neovim is idle.
- Caching cart data to disk.
- Changing tab navigation in the server or adding new tab commands.
- VS Code status bar behavior.

## Deliverables

1. `lua/pico_lsp/cart.lua` — cache, formatting, refresh, and
   commands.
2. `lua/pico_lsp/init.lua` — public exports and command
   registration.
3. `tests/cart.lua` or an extension to `helper.lua`.
4. `README.md` — statusline and tab-picker recipes.
5. [pico-lsp API docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/api.md) — link the Neovim consumer example from `pico8/cartInfo`.
6. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Public API

Export from `require("pico_lsp")`:

```lua
--- @param bufnr integer?
--- @return table? info CartInfo, or nil when no cached value exists
function M.cart_info(bufnr) end

--- @param bufnr integer?
--- @param opts? { fields?: string[] }
--- @return string? text
function M.cart_status(bufnr, opts) end

--- @param bufnr integer?
function M.refresh_cart_info(bufnr) end
```

- `bufnr` defaults to the current buffer.
- `cart_info` returns the server's decoded table unchanged, including
  `rootUri`, `files`, `includes`, and `tabs`.
- `cart_status` returns `nil` when there is no cached value. It must not fall
  back to a synchronous request.
- `fields` accepts `tokens`, `chars`, and `compressed`; the default is all
  three in that order.
- `refresh_cart_info` is asynchronous and safe to call repeatedly. It returns
  immediately.
- Do not expose the cache table itself; return a shallow copy or treat the
  cached table as read-only.

### 2. Cache and refresh lifecycle

- On `LspAttach` for a `pico_lsp` client, request cart info for the buffer.
- After a successful response, store the table under `rootUri` and record the
  buffer's owner root.
- For an included `.lua` buffer, the response's `rootUri` is the owning cart;
  use that for the cache key.
- For a `.p8.png` virtual buffer, the response's `rootUri` is the
  `pico8-cart:` virtual URI because the snapshot is loaded under that virtual
  root. Use the virtual URI as the cache key. A direct request for the source
  PNG URI is a different key and is not required by the Neovim statusline.
- Before a response arrives, `cart_info` may return `nil`. Do not substitute
  placeholder zeros.
- Increment a generation counter per root for each request. Ignore a response
  whose generation is stale.
- On `BufWritePost` for a `.p8` or `.lua` buffer attached to `pico_lsp`,
  refresh the owner root.
- After the helper's `Pico8ReloadPng` path refreshes a virtual document,
  refresh its cached cart info when the cart module is loaded.
- On `InsertLeave`, refresh the current attached buffer.
- On `TextChanged`, debounce a refresh for the current attached buffer.
- Do not refresh when the client is not attached or the buffer is not
  modifiable (except for an explicit command or PNG reload).
- On `LspDetach`, clear entries for that client's buffers and roots when no
  other buffer uses them.
- On `BufWipeout`, remove the buffer-to-root mapping.
- Clear all state when the helper is disabled or `setup` is called again.

### 3. Status text

Default output for a compressed-capable cart:

```text
4210/8192 tok · 27433/65535 ch · 12000/15616 zip
```

Rules:

- Separate segments with ` · `.
- Use the raw integers from `CartInfo`; do not round or abbreviate by default.
- When `compressedStatus` is `unavailable`, omit the compressed segment rather
  than printing `0/15616`.
- When a field is selected but the limit is zero or missing, omit that segment.
- Do not append warning text. Callers that want color can inspect
  `cart_info(bufnr).compressedStatus`.
- Do not include the cart name; the statusline already identifies the buffer.
- `cart_status` must be cheap enough to call on every redraw.

### 4. `:Pico8CartInfo`

- Request a fresh value asynchronously, then show a `vim.notify` summary.
- The summary includes tokens, characters, compressed size and status, and the
  owning cart URI/path.
- If the server returns per-file or per-include data, include a compact
  breakdown in the notification or make it available through
  `cart_info(bufnr)`; do not dump the entire table into a single message.
- If no cart is found, show a clear notification rather than a generic RPC
  error.
- The command must work on include and PNG virtual buffers.
- The command must not change the cursor, buffer contents, or server settings.

### 5. `:Pico8Tabs`

- Fetch or use cached cart info, then call `vim.ui.select` with tab labels such
  as `0: main (lines 4-120)`.
- Tab `index`, `name`, `startLine`, and `endLine` come from `pico8/cartInfo`.
  The server reports cart lines zero-based; convert to a 1-based Neovim cursor
  line and clamp to the buffer line count.
- Place the cursor on the selected tab's start line. Do not modify the buffer.
- On a root cart, operate on the current buffer.
- On an included `.lua` buffer, notify that tabs belong to the owning cart and
  do not open a different buffer automatically.
- On a `.p8.png` virtual buffer, jump within the virtual buffer.
- If there are no tabs or only the implicit first tab, still show the picker or
  a short "only one tab" notification; choose one behavior and test it.
- Respect an overridden `vim.ui.select`.

### 6. Refresh stability

- A failed request keeps the previous cached value and records the error for
  health checks; it does not clear the statusline.
- A request for a buffer that closes before the response arrives is discarded.
- Rapid saves and edits must not produce an unbounded request queue. Keep at
  most one in-flight request per root, plus one pending generation.
- Do not refresh during `InsertLeave` if the buffer has no `pico_lsp` client.
- Do not trigger a refresh from `cart_status`.
- Stop timers and clear callbacks when the helper is disabled or Neovim exits.

### 7. Documentation

- Replace the README's copy-paste `pico8/cartInfo` keymap with the command and
  cached API.
- Include a lualine component recipe that reads `require("pico_lsp").cart_status()`
  and colors `warning`/`error` using `cart_info().compressedStatus`.
- Include a dependency-free `statusline` example using a Lua function.
- Document that the statusline updates after a debounce, not on every keystroke.
- Document `:Pico8Tabs` and its behavior on includes and PNG carts.
- Link the example from [pico-lsp API docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/api.md) under `pico8/cartInfo`.

### 8. Tests

- Headless Neovim tests with the real server assert:
  - `cart_info` becomes available after attach;
  - `cart_status` returns the expected token/character/compressed segments;
  - the compressed segment is omitted for a standalone `.lua` cart;
  - an included `.lua` buffer resolves to the owning cart's info;
  - a `.p8.png` virtual buffer resolves using the virtual `rootUri` returned by
    the server, not a fabricated source-PNG key;
  - editing a cart or include changes the cached values after the debounce;
  - `:Pico8CartInfo` notifies with a summary;
  - `:Pico8Tabs` uses `vim.ui.select` and jumps to the chosen tab;
  - a failed refresh after a successful fetch keeps the previous cached value;
  - rapid saves/edits leave at most one in-flight request per root and discard
    stale generations;
  - `cart_status` returns `nil` before the first response and never blocks.
- Use a stubbed `vim.ui.select` to choose a tab deterministically.
- Keep the test independent of real cart token counts where possible; assert
  relationships and limits rather than magic totals.
- Run on Neovim 0.11 and 0.12 in CI.

## Interfaces and state

- New public functions: `cart_info`, `cart_status`, `refresh_cart_info`.
- New commands: `:Pico8CartInfo`, `:Pico8Tabs`.
- New module: `lua/pico_lsp/cart.lua`.
- Cache state is module-local and keyed by cart root URI.
- No new server request, response, command, or setting.
- No statusline dependency; lualine support is documentation only.

## Error handling

- No attached client: `cart_status` returns `nil`; commands notify.
- `cart-not-found`: notify once and keep the previous cache.
- Malformed response: discard it, keep the previous cache, and log at debug
  level.
- Timed-out or cancelled requests: ignore stale generations.
- Read-only PNG virtual buffers: no edits, only cache and navigation.
- A tab start line outside the buffer is clamped; never throw.
- `vim.ui.select` cancellation is a no-op.

## Testing and CI

- Extend the headless Neovim suite from M25/M26.
- Server tests remain in `pico-lsp`; add an LSP e2e test there only if a
  response shape is found to be unstable.
- The Neovim CI job runs on 0.11 and 0.12.
- Manual check: add the lualine recipe to a real config and confirm the
  component updates after edits and saves.
- No network access in tests.

## Exit criteria

- [x] `require("pico_lsp").cart_status()` returns a cached summary in a real
      statusline without blocking.
- [x] `cart_info()` returns the raw server data for carts, includes, and PNG
      virtual buffers.
- [x] Editing a cart or include refreshes the cache after the debounce.
- [x] `:Pico8CartInfo` shows a useful summary.
- [x] `:Pico8Tabs` jumps to the selected tab and handles includes/PNG carts.
- [x] A failed request does not erase the last good value.
- [x] README and [pico-lsp API docs](https://github.com/asimmons91/pico-lsp/blob/main/docs/api.md) document the API and lualine recipe.
- [x] Headless tests and CI cover the cache and commands.

## Verification

- `tests/cart.lua`, run by `tests/run.sh`, covers the shipped config without
  `setup`, cache timing before the first response, statusline segments and
  field selection, deep-copy isolation, include and standalone `.lua` carts,
  debounced cart/include edits, `:Pico8CartInfo` detail and no-client paths,
  `:Pico8Tabs` for multi-tab, single-tab, include, cancellation, and PNG
  cases, failed-refresh retention, one-in-flight/one-pending coalescing, and
  detach/wipe cleanup. It passed on Neovim 0.11.4 and 0.12.6 against a
  pico-lsp development build.
- `tests/run.sh` also runs the existing config, helper, correctness, features,
  and fallback suites on both Neovim versions.
- The plain statusline expression was checked with
  `nvim_eval_statusline`; the `luaeval` and `_G` function forms both render the
  cached text with no statusline plugin.

## Known limitations

- `:Pico8Tabs` does not open the owning cart from an included `.lua` buffer;
  opening the cart is M29's `:Pico8OpenCart`.
- Tab navigation commands (`:Pico8NextTab`/`:Pico8PrevTab`) are intentionally
  absent from this milestone.
- The cache is in memory only and is not persisted to disk. Requests are not
  polled while Neovim is idle.
- The lualine component is a documented recipe, not a bundled statusline
  plugin.

## Risks

| Risk | Mitigation |
|---|---|
| Statusline redraws could accidentally call the server | Keep requests out of `cart_info`/`cart_status`; assert this in tests. |
| Debounce timers outlive buffers | Clear timers and generations on detach/wipeout. |
| Tab lines are zero-based and can be stale | Convert and clamp; refetch before opening the picker. |
| Duplicate cache entries for includes | Key by the server's `rootUri` after the first response. |
| A large notification for per-file data | Keep the notification compact and expose detail through the API. |
