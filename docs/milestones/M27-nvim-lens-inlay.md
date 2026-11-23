# M27 — Neovim Code Lens and Inlay Hint Enablement

**Status:** Done — shipped `on_attach` enablement, per-buffer display, setup
options, `:Pico8ToggleInlayHints`, Neovim 0.11/0.12 compatibility, tests, and
documentation are complete.

**Depends on:** M25 (drop-in configuration), M26 (helper correctness)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

The cart-budget code lens and inferred-type inlay hints work in a stock Neovim
installation. Advertising the server features is no longer enough: the client
enables code lens and inlay hints per `pico8` buffer, then lets the server
settings decide what is actually returned.

The README no longer claims that a lens or hints simply appear. Users can turn
the client-side display off, and users who configure Neovim without the helper
still get the same behavior through the shipped `lsp/pico_lsp.lua` config.

**Demo:** Open `tests/fixtures/smoke.p8` with the helper enabled. The root cart shows
the budget lens on line 0, and `grx` (or the configured code-lens action) runs
`pico8.showCartInfo`. Set `pico8.inlayHints = true`, restart the client, and
local type hints appear. `require("pico_lsp").setup({ codelens = false,
inlay_hints = false })` suppresses both client-side displays without changing
server settings.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Default behavior | Enable code lens and inlay-hint display for `pico8` buffers by default. The server's `pico8.limits.codeLens` and `pico8.inlayHints` settings remain the actual feature switches. |
| D2 | Wiring point | Add an `on_attach` function to `lsp/pico_lsp.lua` that delegates to a helper module. This covers both the optional helper and base config users. |
| D3 | Scope | Enable per buffer, not globally. Do not change other filetypes or other LSP clients. |
| D4 | Setup options | Add `codelens` and `inlay_hints` booleans to `require("pico_lsp").setup`, defaulting to `true`. |
| D5 | Neovim API floor | Use a compatibility helper: Neovim 0.12+ has `vim.lsp.codelens.enable`/`is_enabled`; Neovim 0.11 has `vim.lsp.codelens.refresh` and its legacy display path. Inlay hints expose `enable`/`is_enabled` on both. Wrap calls in `pcall` so a stripped or patched build cannot break attachment. |
| D6 | Code-lens refresh | Enable or refresh the lens on attach. On Neovim 0.12+ the client refreshes automatically after changes; on 0.11 refresh on `BufWritePost`. Do not run a refresh on every keystroke. |
| D7 | Inlay toggle | Add `:Pico8ToggleInlayHints` to toggle the client display for the current buffer. It does not rewrite server configuration; it warns when `pico8.inlayHints` is false. |
| D8 | Server changes | None. The server already advertises both capabilities and honors its settings. |
| D9 | Non-helper users | Users who replace the shipped config's `on_attach` are responsible for enabling the features; document the one-line calls. |
| D10 | Tests | Extend the headless Neovim suite to assert client capability state and server responses. |

### Resolved decisions

- **D7:** the toggle warns when `pico8.inlayHints` is explicit `false` **or
  unset**. `pico-lsp` defaults the setting to `false`, so an absent client value
  has the same visible result. The warning points at
  `docs/configuration.md` and does not change server configuration.
- **D4:** `:Pico8ToggleInlayHints` is registered even when the helper is
  disabled because it only controls client-side display. `:Pico8Refresh` keeps
  the M26 behavior.
- **D5:** enablement uses feature detection: `vim.lsp.codelens.enable` when
  present, otherwise `vim.lsp.codelens.refresh`. All calls are wrapped in
  `pcall`; a missing API only writes a debug log.
- **D6:** Neovim 0.11 gets one buffer-local `BufWritePost` refresh per cart.
  Neovim 0.12 relies on its automatic refresh. The refresh is skipped when no
  `pico_lsp` client is attached. The attach-time inlay request can race the
  server's `didOpen` analysis, so the client retries the hint refresh twice
  after attach and stops as soon as hints are visible.
- **D4/D5:** a re-attach reconciles the current options with persisted display
  state: Neovim 0.12 code-lens enablement is explicitly disabled when the
  option is off, and the Neovim 0.11 save-refresh autocmd is removed. The same
  attach path disables inlay hints when `inlay_hints = false`.
- **D3:** enablement is limited to buffers whose filetype is `pico8`. Included
  `.lua` buffers and other clients are untouched.
- **D9:** the shipped `lsp/pico_lsp.lua` `on_attach` reads the current helper
  options. Base-config users get the defaults without calling
  `require("pico_lsp").setup`; replacing `on_attach` opts out and is documented.
  The shipped hook calls a wildcard `vim.lsp.config("*")` `on_attach`
  explicitly, because a specific config replaces the wildcard value in Neovim.
  The wildcard callback runs last and can disable inlay hints on both versions
  and code lens on Neovim 0.12; the 0.11 code-lens engine has no disable state.

## Scope

### In scope

- `on_attach` wiring in `lsp/pico_lsp.lua`.
- A small `lua/pico_lsp/client.lua` module or equivalent for testable
  enablement logic.
- `setup({ codelens = ..., inlay_hints = ... })` options.
- Per-buffer code-lens and inlay-hint enabling.
- Save-time code-lens refresh where needed.
- `:Pico8ToggleInlayHints`.
- README and troubleshooting updates.
- Headless tests and CI coverage.

### Out of scope

- Changing the budget lens text, thresholds, or `pico8/cartInfo`.
- Changing inferred type hints or server analysis.
- Enabling code lens or inlay hints for other filetypes.
- Changing global Neovim settings or other clients' capabilities.
- Toggling server settings through `workspace/didChangeConfiguration`.
- Semantic-token, completion, or folding setup.
- VS Code behavior.

## Deliverables

1. `lsp/pico_lsp.lua` — `on_attach` hook.
2. `lua/pico_lsp/client.lua` — enablement, refresh, and toggle
   helpers.
3. `lua/pico_lsp/init.lua` — setup options and command
   registration.
4. `tests/helper.lua` or a focused test file.
5. `README.md`, `docs/usage.md`, and `docs/troubleshooting.md`.
6. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Client capability enablement

On `LspAttach` for a `pico_lsp` client:

- When `M.opts.codelens ~= false`, call a compatibility helper that:
  - uses `vim.lsp.codelens.enable(true, { bufnr = bufnr })` on Neovim 0.12+;
  - otherwise uses `vim.lsp.codelens.refresh({ bufnr = bufnr })` on Neovim
    0.11, whose legacy code-lens engine displays the returned lenses.
- Call `vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })` when
  `M.opts.inlay_hints ~= false`.
- Do not check the server's current settings before enabling. The server
  returns an empty result when the setting is off, and this keeps a later
  configuration change from requiring a different client-side state.
- Wrap each call in `pcall` and log a debug message if the API is unavailable.
- Do not call either function for buffers whose filetype is not `pico8`.
- Do not enable semantic tokens or completion from this hook.
- Do not assume `vim.lsp.codelens.is_enabled` exists on 0.11; capability
  reporting and tests must use the same version-aware helper.

### 2. Setup options

`require("pico_lsp").setup(opts)` accepts:

```lua
require("pico_lsp").setup({
  codelens = true,      -- default true
  inlay_hints = true,   -- default true
})
```

- Options apply to clients started after `setup`.
- For an already-running client, the options affect the next attach; document
  that a restart is needed (`:lsp restart` on Neovim 0.12+).
- The shipped config's `on_attach` reads the current helper options. If
  `setup` was never called, both default to enabled.
- `disable = true` continues to disable the helper itself. It must not disable
  the base config's code-lens/inlay-hint behavior for users who still call
  `vim.lsp.enable`; document that distinction.

### 3. Code-lens refresh

- Neovim 0.12 refreshes code lenses automatically after document changes.
- Neovim 0.11 has no `enable` state; call `vim.lsp.codelens.refresh({ bufnr =
  bufnr })` on attach and add a buffer-local `BufWritePost` autocmd for carts
  that refreshes again.
- Do not call refresh while the client is not attached.
- Do not refresh on every `TextChanged` event; the budget lens is allowed to be
  one save behind on older clients.
- If the server later adds `workspace/codeLens/refresh`, M33 handles it; this
  milestone remains client-side.

### 4. Inlay hint toggle

`:Pico8ToggleInlayHints`:

- Toggles `vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })` for the current
  buffer.
- Works only when a `pico_lsp` client is attached to a `pico8` buffer.
- When enabling, if the client's `settings.pico8.inlayHints` is explicitly
  `false`, show a warning that the server will continue to return no hints and
  point to `docs/configuration.md`.
- Does not call `workspace/didChangeConfiguration` and does not modify
  `client.settings`.
- Is idempotent and safe on read-only `.p8.png` virtual buffers.

### 5. Documentation

- `README.md`: add a short "Opt-in LSP features" subsection that
  explains code lens and inlay hints are enabled by the shipped config, how to
  turn them off, and how to enable them manually for a custom config:

  ```lua
  -- Neovim 0.12+
  vim.lsp.codelens.enable(true, { bufnr = bufnr })
  -- Neovim 0.11
  vim.lsp.codelens.refresh({ bufnr = bufnr })

  vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
  ```

- `README.md`: remove the implication that the lens appears without client
  setup.
- `docs/configuration.md`: link `pico8.inlayHints` to the Neovim client-side
  enablement requirement and the toggle command.
- `docs/troubleshooting.md`: add "lens or hints missing" checks:
  attached client, `:Pico8ToggleInlayHints`, server setting, and client logs.

### 6. Tests

- Headless Neovim tests assert:
  - on Neovim 0.12+, `vim.lsp.codelens.is_enabled({ bufnr = bufnr })` is true
    after attach;
  - on Neovim 0.11, the budget lens is available through
    `vim.lsp.codelens.get(bufnr)` after the attach refresh, because 0.11 has no
    `is_enabled`;
  - `vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })` is true after attach on
    both versions;
  - direct `textDocument/codeLens` returns the budget lens;
  - direct `textDocument/inlayHint` returns a hint when
    `pico8.inlayHints = true` and an empty result when false;
  - `setup({ codelens = false })` suppresses the lens request/display on both
    versions (0.12 reports disabled; 0.11 has no request and no cached lens);
  - `setup({ inlay_hints = false })` leaves inlay hints disabled;
  - toggling inlay hints flips the per-buffer state;
  - with `pico8.inlayHints = false`, `:Pico8ToggleInlayHints` warns through a
    stubbed `vim.notify` and does not change server settings;
  - a non-PICO-8 buffer is unaffected.
- Add a test for a config that does not call `require("pico_lsp").setup` but
  uses the shipped `lsp/pico_lsp.lua`; the default enablement must still apply.
- Keep tests compatible with Neovim 0.11 and 0.12. Use a version check rather
  than calling a 0.12-only function unconditionally.

## Interfaces and state

- New helper options: `codelens`, `inlay_hints`.
- New command: `:Pico8ToggleInlayHints`.
- `lsp/pico_lsp.lua` gains `on_attach`.
- No new server request, response, setting, or protocol behavior.
- Client capability state is per buffer; no global Neovim state is changed.

## Error handling

- A failed `vim.lsp.codelens.enable`, `vim.lsp.codelens.refresh`, or
  `vim.lsp.inlay_hint.enable` must not prevent the client from attaching.
- A missing `pico_lsp` client produces a clear notification for the toggle
  command and does nothing for autocmds.
- A server that returns no lens or hints is a valid state, not an error.
- The toggle command must not mutate read-only buffers.
- Do not spam warnings when several buffers attach without a client.

## Testing and CI

- The Neovim CI job from M25 runs the new cases on 0.11 and 0.12.
- Server tests remain in `pico-lsp`; this repository does not run the Go suite.
- If capability behavior is found to be incorrect, add a focused LSP e2e test
  in `pico-lsp` rather than weakening the client.
- Manual smoke: open a cart, confirm the lens and toggle command, and record
  the result in the milestone checklist.

## Exit criteria

- [x] The budget lens is visible in a stock Neovim session with the shipped
      config.
- [x] Inlay hints appear when `pico8.inlayHints = true` without additional
      user setup.
- [x] `codelens` and `inlay_hints` setup options disable the client-side
      display.
- [x] `:Pico8ToggleInlayHints` works and warns when the server setting is off.
- [x] Base-config users without `require("pico_lsp").setup` get the defaults.
- [x] Non-PICO-8 buffers and other clients are unaffected.
- [x] Headless tests cover capability state and server responses in CI.

## Verification

- `tests/features.lua`, run by `tests/run.sh`, covers the shipped config
  without setup, helper defaults, `codelens`/`inlay_hints` options separately,
  option changes on re-attach, the toggle and its warning, direct
  `textDocument/codeLens` and `textDocument/inlayHint` responses, visible
  inlay hints after attach without an edit, non-PICO-8 buffers, PNG buffers,
  the no-client toggle path, the disabled-helper command, and wildcard
  `vim.lsp.config("*")` on_attach preservation. It passed on Neovim 0.11.4 and
  0.12.6 against a pico-lsp development build.
- `tests/fallback.lua` also asserts the fallback config enables the display.
- The manual smoke equivalent is opening `tests/fixtures/smoke.p8`, confirming
  `vim.lsp.codelens.get` reports the budget lens on line 0, and running
  `:Pico8ToggleInlayHints` twice to confirm the per-buffer state flips.

## Known limitations

- Editing an included `.lua` file re-analyzes it on the server, but the client
  does not automatically redraw the root cart's budget lens or type hints.
  Change and save the cart buffer, or restart Neovim, to refresh.
  Server-driven cross-file refresh belongs to M33.

## Risks

| Risk | Mitigation |
|---|---|
| Enabling hints for all `pico8` buffers adds requests when the server setting is off | The server returns an empty result quickly; the client cost is one request per change, not per keystroke. |
| Users want inlay hints off globally in Neovim | The helper defaults can be overridden; document the setup options and the toggle command. |
| Code-lens refresh behavior differs by Neovim version | Enable on attach, refresh on save where needed, and rely on 0.12's automatic refresh. |
| `setup` options do not affect an already-attached client | Document the restart requirement. |
