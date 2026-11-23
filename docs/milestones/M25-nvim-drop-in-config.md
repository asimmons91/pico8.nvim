# M25 — Neovim Drop-in Configuration and Cart-Aware Roots

**Status:** Done — shipped config, cart-aware roots, setup activation, helper
integration, tests, CI, and documentation are complete.

**Depends on:** pico-lsp M6 (server features and editor integration)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-23.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

Installing the plugin and calling `require("pico_lsp").setup()` is the complete
base setup for a `.p8` cart. Users no longer copy a configuration block from the
README, and the helper and base config share one definition instead of
maintaining duplicate defaults.

The client root is anchored to the cart rather than to `.git`, so a cart in a
plain directory still has a workspace root, includes resolve from the expected
directory, and workspace symbols scan the cart's directory instead of an
unrelated repository root or a single open document.

**Demo:** In a temporary directory with no `.git` and no user LSP config, start
Neovim with the plugin on `runtimepath`, call `require("pico_lsp").setup()`, and
open `cart.p8`. The server attaches with the cart's directory as `root_dir`;
document symbols, workspace symbols, and includes work. Opening `lib.lua`
through the helper attaches the same client. Defining a user
`vim.lsp.config("pico_lsp", { ... })` still overrides the shipped defaults.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Config location | Ship `lsp/pico_lsp.lua`, loaded by Neovim 0.11+ from `runtimepath`, so `vim.lsp.config["pico_lsp"]` exists without user setup. |
| D2 | Activation | `require("pico_lsp").setup()` calls `vim.lsp.enable("pico_lsp")` by default. Set `lsp = false` to manage activation manually. |
| D3 | Root strategy | For `.p8` buffers, use the cart's directory as `root_dir`. Do not default to `.git`. Confirmed 2026-11-23. |
| D4 | Settings | Do not duplicate server defaults in the shipped config. An empty or absent `settings` table lets `internal/config` remain authoritative; documentation shows how to override individual fields. |
| D5 | Command discovery | Resolve the executable from `vim.g.pico_lsp_cmd`, then `vim.env.PICO_LSP_BIN`, then `{ "pico-lsp" }`. Normalize string values to a one-element list because Neovim's LSP `cmd` must be a list or function. Local builds and headless tests can point at an absolute binary. |
| D6 | Filetypes | The base config handles `pico8` only. Cart-owned `.lua` files remain the helper's job. |
| D7 | Helper integration | The helper reads the merged `vim.lsp.config["pico_lsp"]` value and stops carrying its own copy of `apiVersion`, `typeChecking`, and `inlayHints`. |
| D8 | Keymaps | No default keymaps beyond Neovim's own LSP defaults. |
| D9 | Editor floor | Neovim 0.11+ remains the supported floor. Use `vim.lsp.config`/`vim.lsp.enable`; no `nvim-lspconfig` dependency. |
| D10 | Release | M25 is the foundation for M26–M32 and supplies the config/test job used by M34. It should land first and can ship independently in a patch. |

### Resolved decision

**D3 confirmed:** anchoring to the cart's directory gives predictable include
and workspace-symbol scope for PICO-8 projects. Two carts in different
subdirectories receive separate clients and workspace symbols are scoped to one
cart directory. Users who want repository-wide symbol searches can override
`root_dir` in their own `vim.lsp.config` call, as documented in the install and
configuration guides.

## Scope

### In scope

- `lsp/pico_lsp.lua` with `cmd`, `filetypes`, `root_dir`, and
  command resolution.
- Cart-directory root resolution for `.p8` buffers.
- `setup({ lsp = true })` activation and `lsp = false` opt-out.
- Helper reuse of the merged LSP config and removal of duplicated defaults.
- README and `docs/install.md` install paths: lazy.nvim, runtime-path fallback,
  and manual configuration.
- A headless Neovim test for config loading and root selection.
- A CI job that runs the headless Neovim tests on the supported Neovim
  versions.

### Out of scope

- Enabling code lens, inlay hints, or other client capabilities (M27).
- Cart budget commands or statusline integration (M28).
- Changes to the helper's include-ownership algorithm (M26).
- Auto-opening `.p8.png` or `#include` navigation (M30).
- Server changes, new LSP capabilities, or protocol behavior.
- Mason packaging, a LazyVim extra, or Zed support.

## Deliverables

1. `lsp/pico_lsp.lua` — the shipped client configuration.
2. `lua/pico_lsp/init.lua` — helper reads the merged config, uses a shared
   command resolver, and enables the client from `setup`.
3. `tests/config.lua` or an equivalent headless test.
4. `.github/workflows/ci.yml` — headless Neovim job.
5. `README.md` and `docs/install.md` — plugin install, root behavior, and
   override examples.
6. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Shipped configuration

`lsp/pico_lsp.lua` returns a table equivalent to:

```lua
local function command()
  local configured = vim.g.pico_lsp_cmd
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" and #configured > 0 and type(configured[1]) == "string" then
    return configured
  end
  if vim.env.PICO_LSP_BIN and vim.env.PICO_LSP_BIN ~= "" then
    return { vim.env.PICO_LSP_BIN }
  end
  return { "pico-lsp" }
end

-- Neovim 0.11 expands URI-like buffer names to absolute paths, so the helper
-- marks its virtual PNG buffers with `pico8_virtual_cart`. A scheme-prefixed
-- name covers Neovim 0.12 and buffers created without the marker.
local function is_virtual(bufnr, name)
  return vim.b[bufnr].pico8_virtual_cart == true or name:match("^pico8%-cart:") ~= nil
end

return {
  cmd = command(),
  filetypes = { "pico8" },
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" or is_virtual(bufnr, name) then
      return
    end
    on_dir(vim.fs.dirname(vim.fs.normalize(name)))
  end,
}
```

Requirements:

- The file must return a plain table. It must not call `vim.lsp.enable`, create
  autocmds, or start clients as a side effect.
- `root_dir` must call `on_dir` at most once and must not call it for unnamed
  buffers.
- The resolved `cmd` must always be a non-empty list of strings or a function.
  Neovim's LSP client rejects a bare string, so normalize `vim.g.pico_lsp_cmd`
  strings to `{ value }`. Empty values fall through to the environment/default.
- Do not include server settings that merely repeat `internal/config` defaults.
- Do not include `on_attach`; M27 adds the helper's client-capability wiring.
- Add a short comment explaining that users can override the config with
  `vim.lsp.config("pico_lsp", { ... })`.

### 2. Root behavior

- A named `.p8` buffer uses the normalized directory containing the cart.
- Unnamed buffers and `pico8-cart:` virtual buffers are not auto-activated by
  the base config. Return without calling `on_dir`; do not fabricate a root.
  Neovim skips activation when the callback is not called. Neovim 0.11 expands
  URI-like buffer names to absolute paths, so the helper marks `.p8.png`
  virtual buffers with `b:pico8_virtual_cart` and the callback recognizes that
  marker as well as a scheme-prefixed name. The helper starts `.p8.png` virtual
  documents explicitly with the source directory.
- Do not call `on_dir(nil)` as a fallback for skipped buffers. The shipped
  config has no rootless activation path for unnamed or virtual buffers.
- The helper continues to use the owning cart's directory as the root for
  cart-owned `.lua` buffers.
- Multiple carts in one directory share one client. Carts in different
  directories may start separate clients.
- Do not walk upward to find a `.p8` file for a `.lua` buffer. That would make
  the base config attach to unrelated Lua files.

### 3. Settings and helper integration

- Remove the helper's `default_settings` duplication. The helper's `setup`
  options may still provide overrides, which merge over the resolved config.
- The helper must tolerate `vim.lsp.config["pico_lsp"]` being absent and fall
  back to a minimal table with the same command resolution.
- The README's manual `vim.lsp.config` example remains available for users who
  prefer not to use the plugin setup. That example may keep explicit settings
  because it is a standalone starting point.
- Document that `workspace/configuration` pulls the `pico8` section when the
  client supports it, and that the server owns defaults.

### 4. Documentation

- Lead the install section with the lazy.nvim spec:

  ```lua
  {
    "asimmons91/pico8.nvim",
    main = "pico_lsp",
    lazy = false,
    opts = {},
  }
  ```

- Document the vanilla `runtimepath` plus `require("pico_lsp").setup()` path as
  the fallback.
- Keep the manual `vim.lsp.config` example as a fallback and label it as such.
- Explain the cart-directory root and how to override it, including how to use
  a repository root when the user wants workspace-wide symbols.
- Document `vim.g.pico_lsp_cmd` and `PICO_LSP_BIN` for local binaries.
- Mention that the plugin also carries `ftdetect`, syntax, ftplugin, and the
  helper. `lsp/pico_lsp.lua` is the only LSP config file, but `ftdetect` is
  still required to assign the `pico8` filetype that activates it.

### 5. Testing and CI

- Add a headless test that starts Neovim with `--clean -u NONE`, appends the
  plugin root to `runtimepath`, and asserts:
  - `vim.lsp.config["pico_lsp"]` exists and has the expected fields;
  - `vim.g.pico_lsp_cmd` as a string resolves to a one-element `cmd` list, and
    an empty string falls through to the default;
  - a cart in a temporary non-git directory attaches;
  - `client.root_dir` is the cart directory;
  - two carts in sibling directories use separate roots;
  - a user override of `root_dir` wins;
  - the helper attaches an included `.lua` file to the same client;
  - the helper falls back to its own config and command resolution when
    `lsp/pico_lsp.lua` is absent from `runtimepath`;
  - `setup({ lsp = false })` leaves the client disabled.
- The test must use `PICO_LSP_BIN` and an installed server binary.
- Add a CI job that installs Neovim 0.11.x and 0.12.x, builds or downloads a
  `pico-lsp` test binary, and runs the headless tests. Keep the job independent
  of server-only CI.

## Interfaces and state

- New file: `lsp/pico_lsp.lua`.
- Existing helper API remains `require("pico_lsp").setup(opts)`.
- New optional globals: `vim.g.pico_lsp_cmd` and `PICO_LSP_BIN`.
- No new server request, response, command, setting, or protocol behavior.
- The helper still never runs for unrelated `.lua` buffers.

## Error handling

- A missing executable remains a one-time warning from the helper. The base
  config lets Neovim report its normal spawn failure when the helper is not
  used.
- A failed `vim.lsp.start` must not leave duplicate clients or partial helper
  state.
- A skipped buffer has no `root_dir`; do not fall back to the current working
  directory or invent a root. A user override may provide its own root for a
  special buffer, but the shipped config does not.
- A user override must replace, not merge with, the shipped `root_dir`.

## Testing and CI

- `tests/run.sh` and the new config test pass on Neovim 0.11 and 0.12.
- The plugin CI workflow builds or downloads a `pico-lsp` test binary and runs
  the headless tests.
- No network access is required by the tests beyond obtaining the test binary.
- Server tests remain in `pico-lsp`; this repository does not run the Go suite.

## Exit criteria

- [x] Installing the plugin and calling `require("pico_lsp").setup()` attaches
      to `.p8` carts without a copied config.
- [x] `setup({ lsp = false })` leaves client activation to the user.
- [x] A cart outside a git repository has a cart-directory workspace root.
- [x] Carts in different directories do not share a root by accident.
- [x] A user `vim.lsp.config` override wins over the shipped configuration.
- [x] The helper uses the merged config and no longer duplicates server
      defaults.
- [x] Headless Neovim tests run in CI on the supported versions.
- [x] `README.md` and `docs/install.md` describe plugin and fallback installs.

## Risks

| Risk | Mitigation |
|---|---|
| Cart-directory roots reduce repository-wide workspace symbols | Document the override and provide a repository-root example. |
| `vim.lsp.config` loading differs between 0.11 patch releases | Test the pinned CI versions and keep the copy-paste fallback. |
| Command resolution surprises users with an environment variable set | Document the precedence and keep `pico-lsp` as the final fallback. |
| Helper and base config both attach a client | The helper checks for an existing matching client before starting one. |
