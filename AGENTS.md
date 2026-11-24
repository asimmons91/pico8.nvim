# AGENTS.md

## Current state

- Skeleton extraction from `pico-lsp/editors/nvim` is complete: `lua/pico_lsp`,
  `lsp/pico_lsp.lua`, `ftdetect`, `ftplugin`, `syntax`, `tests`, `doc`, and the
  vendored editor-only Tree-sitter grammar.
- The existing helper behavior is preserved: cart-owned `.lua` attachment,
  `pico8/decodeCart` PNG commands, P8SCII glyph input and Shift maps, comments,
  and syntax highlighting.
- `require("pico_lsp").setup()` enables `vim.lsp.enable("pico_lsp")` by default.
  Set `lsp = false` to manage activation manually.
- M25, M26, M27, M28, M29, and M30 are complete. M31, M32, and M34 are
  proposed. M33 remains server-owned in `pico-lsp`. M35 (Mason and LazyVim
  extra) is proposed.
- The M27 client module enables the budget code lens and inlay-hint display for
  `pico8` buffers, with `codelens`/`inlay_hints` setup options and
  `:Pico8ToggleInlayHints`. The shipped `lsp/pico_lsp.lua` enables the display
  through `on_attach`, so base-config users get the defaults without
  `require("pico_lsp").setup`.
- The M28 cart module caches `pico8/cartInfo` by the server's `rootUri`,
  formats statusline text without blocking, refreshes on attach/save/
  `InsertLeave` plus a 500 ms edit debounce, and adds `:Pico8CartInfo` and
  `:Pico8Tabs`. It supports root carts, helper-managed `.lua` includes, and
  decoded `.p8.png` virtual buffers. The shipped config loads the module so
  base-config users get the cache and commands; a disabled helper clears the
  cache but keeps the read-only commands.
- The M29 include settings apply PICO-8 `comments`/`commentstring` per option
  when the buffer still has stock or empty Lua values, record only what changed,
  and restore it on managed detach when still in place. Managed includes expose
  `b:pico8_cart`/`b:pico8_cart_root` and `:Pico8OpenCart`; exact PICO-8 values
  are treated as user values, and the command is managed-include only. Restore
  records are module-local, so a plugin reload before detach leaves exact
  PICO-8 values in place. Tests are in `tests/include_buffers.lua`.
- The M30 include module parses `#include` targets for both the helper and the
  `pico8` ftplugin. The ftplugin sets buffer-local `include`/`includeexpr` and
  scopes `path` to the cart without helper setup; `includeexpr` prefers the
  full target on the cursor's include line so spaces, literal `.lua:2` names,
  and selector digits survive `gf` tokenization. An enabled `setup` installs a
  `*.p8.png` `BufReadCmd`, auto-opens through `pico8/decodeCart`, reuses an
  existing virtual buffer on reopen, deletes the source buffer on success, and
  leaves a named empty read-only `nofile` buffer on failure. Decoded PNG
  virtual buffers carry `b:pico8_cart_root` and a scoped `path`. Tests are in
  `tests/includes.lua`.
- The M26 helper reads loaded cart buffers for unsaved `#include` edits, caches
  parsed includes by changedtick or mtime/size, reuses only root-matched
  clients, tracks helper-managed attachments, revalidates ownership, and
  rescans cart saves/reloads plus cart edits after a 300 ms debounce.
  `:Pico8Refresh` clears the cache and rescans; it is registered even when the
  helper is disabled. A re-`setup()` while the client is already enabled, and a
  plugin module reload, preserve managed attachments.
- `pico-lsp` remains the source of truth for the server, parser, analysis,
  formatter, diagnostics, and standard LSP capabilities. Do not add server code
  here.

## Source of truth

- `docs/ROADMAP.md` is the plugin roadmap.
- `docs/milestones/M25-*.md` through `docs/milestones/M32-*.md` and
  `docs/milestones/M34-*.md` are the client milestone specs. M33 lives in
  `pico-lsp`.
- `docs/install.md`, `docs/usage.md`, `docs/configuration.md`, and
  `docs/troubleshooting.md` are user documentation.
- `vendor/tree-sitter-pico8/` is a vendored copy of the editor grammar. Do not
  edit it here; regenerate and test it in `pico-lsp` and re-vendor.
- The historical `pico-lsp/editors/nvim` copy is not maintained here. This
  repository is the canonical client source.

## Commands

- `PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh` runs the headless Neovim tests
  (config, helper smoke, M26 correctness, M27 features, M28 cart info, M29
  include buffers, M30 includes/PNG auto-open, and fallback). The binary must be
  installed; the test does not build the Go server.
- `nvim --headless --clean -u NONE --cmd "set runtimepath+=$PWD" -l tests/helper.lua`
  runs the test directly with `PICO8_NVIM_ROOT` set.
- `:helptags doc` regenerates the help tags when manually testing.
- `git diff --check` is the minimum text sanity check.
- CI installs Neovim 0.11 and 0.12, builds or downloads a `pico-lsp` test
  binary, and runs the headless tests.

## Testing rules

- Prefer real `pico-lsp` behavior over mocks for LSP integration tests.
- Every proposed command and error path should have a headless test when
  implemented.
- Tests must use temporary directories, bounded `vim.wait` conditions, and
  clean up clients and buffers.
- Never claim a test passed unless it was run.
- Server tests, Go fuzzing, and LSP e2e tests belong in `pico-lsp`.

## Git workflow

- Create a branch from an up-to-date `main`:
  `feat/<short-slug>` for features, `fix/<short-slug>` for bug fixes, or
  `chore/<short-slug>` for docs and tooling.
- Use Conventional Commits: `<type>(<optional scope>): <description>`, with an
  imperative, lowercase description and no trailing period.
- Push the branch and open a PR; do not bypass branch protection.
- After opening the PR, run the `code-review` skill in PR mode. Address every
  validated finding, run the relevant tests, and push the fixes to the same
  branch so the PR is updated. Re-run the review after substantive follow-up
  changes.
- Merge only when the review has no unresolved findings and CI is green.

## Documentation rules

- Keep the README installation path compatible with lazy.nvim and LazyVim.
- Keep the server and plugin responsibilities separate.
- When a milestone moves between repositories, update the roadmap, the
  milestone index, and the `pico-lsp` pointer in the same change.
- Do not duplicate server settings documentation; link to the `pico-lsp`
  configuration reference.
- Keep `doc/pico8.txt` tags valid.
