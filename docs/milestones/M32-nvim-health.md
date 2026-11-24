# M32 — Neovim Health Check

**Status:** Done — module, report sections, tests, and documentation are
complete.

**Depends on:** M25 (drop-in configuration), M26 (helper correctness), M27
(client capability wiring), M28 (cart cache), M29 (include buffer settings),
M30 (PNG helper), M31 (glyph cache)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-24.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

`:checkhealth pico_lsp` explains why PICO-8 support is or is not working in the
current Neovim session. It checks the configured binary, server version,
attached clients and roots, settings, client-side code-lens/inlay-hint state,
cart-owned `.lua` attachment, `lua_ls` conflicts, optional helper commands, and
Tree-sitter availability. The report never starts a client, downloads a binary,
edits a buffer, or changes configuration.

**Demo:** Run `:checkhealth pico_lsp` with the helper enabled and a cart open.
The report shows the Neovim version, the resolved `pico-lsp` executable and
version, the `pico_lsp` client's root and settings, the cart's owning client,
and whether code lens and inlay hints are enabled. Disable the helper or point
`cmd` at a missing binary and rerun; the report identifies the failure and the
next step.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Module | Add `lua/pico_lsp/health.lua`; Neovim's `:checkhealth pico_lsp` loads it automatically. |
| D2 | Read-only | Health checks must not start clients, send configuration, install parsers, or modify buffers/settings. |
| D3 | Binary check | Resolve a list/string `cmd` and report `vim.fn.executable`/`filereadable` plus the resolved path. For a function `cmd`, report it as user-supplied and skip executable resolution. Do not download anything. |
| D4 | Version check | For a list/string `cmd`, run `<cmd> --version` with a 2-second timeout and show the parsed server version. For a function `cmd`, skip the probe and use a running client's `server_info.version` when available. If a client is running, also show `client.server_info.version` and warn on a mismatch. |
| D5 | Client report | For each `pico_lsp` client, show root, attached buffer count, settings source/type, and workspace folders. Redact nothing beyond source text, which is never included. |
| D6 | Capability report | For the current `pico8` buffer, report code-lens and inlay-hint enablement. Use `is_enabled` only where the Neovim version provides it; on 0.11 report the legacy refresh-based code-lens path instead. Warn when the server setting asks for a feature the client has disabled. |
| D7 | Include report | For helper-managed `.lua` buffers, report the owning cart and whether the client is attached. Warn when `lua_ls` and `pico_lsp` are both attached. |
| D8 | Helper report | Report whether `require("pico_lsp").setup` ran, whether it is disabled, and which optional commands exist. Missing commands are a warning only when the helper is expected. |
| D9 | Tree-sitter report | Advisory only: report whether the `pico8` parser loads and point to M34's installer. Do not install it. |
| D10 | Errors | Missing binary and malformed config are errors with actionable text. Failed probes and optional features are warnings or info. |

Implementation choices confirmed on 2026-11-24: an unset
`pico8.limits.codeLens` is treated as the server default `true`, so health warns
when the client display is disabled. Missing helper commands warn only after an
enabled `require("pico_lsp").setup()`; base-config users get info. The settings
report shows `apiVersion`, `typeChecking`, `inlayHints`, `limits.codeLens`, and
`diagnostics.mode` instead of the full `pico8` table. Because `:checkhealth`
switches to its own buffer before running checks, the "current buffer" sections
use the alternate buffer and then the previous tab's window to find the cart the
user was editing.

## Scope

### In scope

- `lua/pico_lsp/health.lua` and `:checkhealth pico_lsp`.
- Neovim version, config, binary, version, client, settings, capability,
  include, helper, command, and Tree-sitter checks.
- Actionable messages with file and command references.
- Headless tests for report sections and failure paths.
- README, troubleshooting, and health documentation.

### Out of scope

- Starting, restarting, or stopping clients from health.
- Downloading or installing a server binary.
- Installing Tree-sitter parsers or queries (M34).
- Fixing configuration automatically.
- VS Code health or server diagnostics.
- Telemetry, network calls, or uploading diagnostics.
- Changing server behavior or adding a server health request.

## Deliverables

1. `lua/pico_lsp/health.lua`.
2. `tests/health.lua` or an extension to the helper test.
3. `README.md` — health check section.
4. `docs/troubleshooting.md` — `:checkhealth pico_lsp` as the first diagnostic
   step.
5. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Report structure

Use `vim.health.start("pico_lsp")` and separate sections with
`vim.health.start("pico_lsp.<section>")` or headings equivalent to other
Neovim health modules. At minimum:

- `pico_lsp: Neovim`
- `pico_lsp: Configuration`
- `pico_lsp: Server binary`
- `pico_lsp: Running clients`
- `pico_lsp: Client features`
- `pico_lsp: Included .lua buffers`
- `pico_lsp: Helper`
- `pico_lsp: Tree-sitter`

Each section uses `vim.health.ok/warn/error/info` and ends with a concrete next
step where a problem is found. Keep the output stable enough for tests to match
section headings and key phrases.

### 2. Neovim and configuration

- Report `vim.version()` and pass when the version is 0.11 or newer.
- Report `vim.lsp.config["pico_lsp"]` presence.
  - If absent, warn that the shipped `lsp/pico_lsp.lua` is not on
    `runtimepath` and show the runtime-path line.
- Report the resolved `cmd` value and its source: `vim.g.pico_lsp_cmd`,
  `PICO_LSP_BIN`, or the default.
- Validate the command shape:
  - a non-empty list of non-empty strings, or a function;
  - warn on a bare string because Neovim's LSP client rejects it even though
    the shipped M25 config normalizes strings;
  - warn on an empty command or non-string list entries;
  - report a function as user-provided without executing it.
- Do not evaluate or spawn the command in this section beyond the binary check.

### 3. Server binary and version

- If `cmd` is a function, report `user-supplied function` for the binary and
  skip path resolution and `--version`. Do not execute the function. If a
  client is running, report its `server_info.version`.
- For a list/string `cmd`, resolve the executable with `vim.fn.exepath` for PATH
  names or `vim.fs.normalize` for absolute paths.
- If missing, report an error with build/install commands from
  `docs/install.md`.
- Run `vim.system({ executable, "--version" }, { timeout = 2000 }):wait()`.
- Parse the first line containing a version; show the raw output on failure.
- If the process exits non-zero or times out, report a warning with the raw
  output.
- If a `pico_lsp` client is running and reports `client.server_info.version`,
  compare normalized strings and warn on a mismatch.
- Never treat a development/empty version as an error; label it
  `development build`.

### 4. Running clients

For each `vim.lsp.get_clients({ name = "pico_lsp" })`:

- Report client ID, root directory, command, and number of attached buffers.
- Report workspace folders from `client.workspace_folders` when available.
- Report whether the current buffer is attached.
- Report `client.settings.pico8` as a compact table or selected keys. Never
  include source text, cart contents, or environment secrets.
- If a `.p8` buffer is current and no `pico_lsp` client is attached, warn with:
  - the detected filetype;
  - whether the file exists;
  - a pointer to the runtime-path config and `:checkhealth vim.lsp`.
- If a client exists but has no attached buffers, report it as info, not an
  error.

### 5. Client features

For the current `pico8` buffer with an attached client:

- Read `client.settings.pico8` defensively. Settings may be absent, partial, or
  pulled by the server.
- Report:
  - `pico8.inlayHints` value and `vim.lsp.inlay_hint.is_enabled({ bufnr })`;
  - `pico8.limits.codeLens` value and code-lens state:
    - Neovim 0.12+: `vim.lsp.codelens.is_enabled({ bufnr })`;
    - Neovim 0.11: the legacy refresh-based engine has no per-buffer enable
      state; report whether `vim.lsp.codelens.get(bufnr)` has cached lenses and
      do not claim a client-side toggle exists.
- If the server setting is true and a feature with a client-side toggle is
  disabled, warn with the relevant `require("pico_lsp").setup` option or manual
  enable call. On 0.11, do not warn about code lens for a missing toggle.
- If the server setting is false, report that the feature is intentionally off.
- Report `pico8.typeChecking` and `pico8.diagnostics.mode` when present, and
  warn on values outside `off/basic/strict` or `auto/push/pull`.
- Do not enable or toggle anything.

### 6. Included `.lua` buffers

- Iterate loaded buffers with `vim.b.pico8_cart` or helper-managed attachment
  state.
- For each, report:
  - buffer path;
  - owning cart URI/path;
  - attached client IDs and roots;
  - comment settings applied by M29.
- Warn when both `lua_ls` and `pico_lsp` are attached to the same cart-owned
  buffer, because the project documents that combination as unsupported.
- Info when a cart-owned `.lua` buffer has no `pico_lsp` client, with a pointer
  to `:Pico8Refresh` and the helper setup.
- Do not scan the filesystem for every `.lua` file; use loaded, managed buffers
  only.

### 7. Helper and commands

- Report whether `require("pico_lsp").setup` has run.
- Report `disable` state from `setup({ disable = true })` or
  `vim.g.pico_lsp_helper_disabled`.
- Report command presence with `vim.fn.exists(":Pico8OpenPng") == 2`,
  `:Pico8ReloadPng`, `:Pico8InsertGlyph`, `:Pico8CartInfo`, `:Pico8Tabs`,
  `:Pico8Refresh`, and `:Pico8OpenCart`.
- When the helper is expected but commands are absent, warn with the runtime
  path/setup line.
- When the helper is disabled intentionally, report info and do not warn about
  missing commands.
- Report the Neovim LSP client log path from `vim.lsp.log.get_filename()`.
- If a server log path can be discovered from the configured `cmd` arguments,
  report it; otherwise show the documented
  `--log-level debug --log-file` example.

### 8. Tree-sitter

- Check whether the `pico8` parser can be loaded without side effects, for
  example with a `pcall` around `vim.treesitter.language.add`/`inspect`.
- Report OK when available.
- Report info, not an error, when absent, with the manual compile instructions
  and a pointer to M34's installer.
- Check whether the `pico8` filetype is detected for a synthetic `.p8` filename
  using `vim.filetype.match`.
- Do not start Tree-sitter or change `syntax`.

### 9. Output and privacy

- Never include buffer text, cart code, environment values, tokens, or paths
  beyond the configured binary, cart, and log paths.
- Keep each section short; link to repository docs with absolute or relative
  paths that render in Neovim.
- Do not call `vim.notify` for each check; write to the health buffer.
- A failed probe must not abort the remaining checks.

## Interfaces and state

- New module: `lua/pico_lsp/health.lua`.
- Entry point: `:checkhealth pico_lsp`.
- No new commands, settings, LSP requests, or server changes.
- Reads existing helper/client state only.

## Error handling

- Missing `vim.health` API: exit quietly; the target Neovim versions provide it.
- Missing client, settings, or command: report and continue.
- `vim.system` unavailable or fails: report an info/warn with the raw error.
- A function-valued `cmd` is not spawned; health never invokes a user command
  function for probing.
- A malformed `cmd` must not throw when health formats it.
- A buffer that disappears during iteration is skipped.
- Health must not hang on a wedged server; use bounded timeouts only for the
  version probe.

## Testing and CI

- Headless tests:
  - run `:checkhealth pico_lsp` with the helper enabled and a cart attached;
  - capture the health buffer and assert the section headings and key OK lines;
  - run with a missing binary and assert an error and install guidance;
  - run with a function-valued `cmd` and assert health reports it as
    user-supplied without spawning it or emitting a missing-binary error;
  - run with the helper disabled and assert no missing-command warnings;
  - run with `pico8.inlayHints = true` and client hints disabled and assert a
    warning;
  - on 0.12+, run with the server code lens enabled and the client codelens
    disabled and assert a warning; on 0.11 assert no false toggle warning;
  - run with `lua_ls` mocked as attached to a managed include and assert the
    conflict warning, without starting a real `lua_ls`;
  - run with no helper and no client, then assert the client list, buffers, and
    `stdpath("data")` tree are unchanged after health (the read-only
    guarantee).
- Keep the tests independent of server version strings; match `pico-lsp` and
  `development build` labels.
- Run on Neovim 0.11 and 0.12 in CI.
- No network access.

## Exit criteria

- [x] `:checkhealth pico_lsp` reports Neovim, config, binary, version, clients,
      client features, includes, helper commands, and Tree-sitter.
- [x] A missing binary produces an actionable error.
- [x] Missing/disabled capabilities produce warnings that match the actual cause.
- [x] `lua_ls` conflicts are reported for managed include buffers.
- [x] Health never starts clients, installs parsers, or modifies state.
- [x] README and troubleshooting make health the first diagnostic step.
- [x] Headless tests and CI cover the main sections.

## Risks

| Risk | Mitigation |
|---|---|
| Health probes take too long | Only the version probe spawns a process, with a 2-second timeout. |
| Reading `client.settings` is version-dependent | Treat it as optional and show partial data rather than failing. |
| False `lua_ls` warnings | Check only loaded, helper-managed cart-owned buffers. |
| Health output drifts from behavior | Test key lines and keep checks read-only. |
| Tree-sitter loading has side effects | Use a pcall and avoid starting the highlighter. |
