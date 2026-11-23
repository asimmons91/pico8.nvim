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
- M25 and M26 are complete. M27–M32 and M34 are proposed. M33 remains
  server-owned in `pico-lsp`. M35 (Mason and LazyVim extra) is proposed.
- The M26 helper reads loaded cart buffers for unsaved `#include` edits, caches
  parsed includes by changedtick or mtime/size, reuses only root-matched
  clients, tracks helper-managed attachments, revalidates ownership, and
  rescans cart saves/reloads plus cart edits after a 300 ms debounce.
  `:Pico8Refresh` clears the cache and rescans; it is registered even when the
  helper is disabled. An enabled re-`setup()` preserves managed records.
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
  (config, helper smoke, M26 correctness, and fallback). The binary must be
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
