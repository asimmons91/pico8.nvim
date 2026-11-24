# Release checklist

This checklist is for cutting a `pico8.nvim` release and verifying the
end-user path. Replace the version placeholders with the release being cut.

## Release identity

| Item | Value |
|---|---|
| `pico8.nvim` release | v0.1.0 |
| Minimum `pico-lsp` | v1.8.1 |
| Tested Neovim | 0.11.4, 0.12.6 |
| Release date | 2026-11-24 |
| Release manager | |

## Automated checks

Run these before tagging.

- [x] `git diff --check` passes.
- [x] `PICO_LSP_BIN=/path/to/pico-lsp-v1.8.1 tests/run.sh` passes on
      Neovim 0.11.4.
- [x] The same suite passes on Neovim 0.12.6. CI covers both versions; a local
      run may use the nearest installed patch and must record that version.
- [x] `nvim --headless --clean -u NONE -l tests/docs.lua` passes on both
      versions. The check regenerates help tags and verifies every tag in
      `doc/pico8.txt`.
- [x] `tests/standard_hooks.lua` passes against a server build that includes
      M33 (`v1.8.2-0.20261124204614-a51e75329238`), so `gq` and Neovim 0.12
      `gx` have coverage. The v1.8.1 release predates M33 and skips those
      checks.
- [ ] The documentation job is green on the release commit.
- [ ] The Neovim test jobs are green on the release commit.

## Clean install matrix

Repeat the quickstart from `docs/getting-started.md` without an existing plugin
or server configuration.

| Path | Neovim | Result | Notes |
|---|---|---|---|
| lazy.nvim pinned tag | 0.11.4 | Pass | Local sandbox tag; GitHub tag pending |
| lazy.nvim pinned tag | 0.12.6 | Pass | Local sandbox tag; GitHub tag pending |
| `vim.pack` pinned version | 0.12.6 | Pass | Local `file://` sandbox tag |
| vanilla `runtimepath` + `setup()` | 0.11.4/0.12.6 | Pass | Headless suite |
| manual `vim.lsp.config` fallback | 0.12.6 | Pass | Existing config/fallback tests |

For each successful path, confirm:

- [x] `:set filetype?` reports `pico8` in `examples/hello.p8`.
- [x] `:checkhealth pico_lsp` resolves the pinned binary and reports one
      attached client rooted at the cart directory.
- [x] Completion and hover work; diagnostics are covered by the suite.
- [x] The cart budget lens or statusline shows cart data.
- [x] `:Pico8CartInfo` returns the cart summary with per-file detail.
- [x] `gf` on `hello_lib.lua` in the `#include` line opens the include.
- [x] `:Pico8Tabs` lists both demo tabs.
- [x] `:Pico8InstallParser` succeeds in the isolated Tree-sitter test.
- [x] A `.p8.png` cart opens read-only in the virtual buffer.

Record the OS, architecture, Neovim version, and `pico-lsp` version for every
manual run. Do not mark an unrun platform as passing.

## LuaLS coexistence

- [x] In a LazyVim-style configuration with `lua_ls` enabled, the recipe in
      `docs/usage.md#coexisting-with-luals` prevents `lua_ls` from attaching to
      `examples/hello_lib.lua`.
- [x] An unrelated `.lua` file still attaches `lua_ls`.
- [x] `:lua =vim.lsp.get_clients({ bufnr = 0 })` shows only `pico_lsp` on the
      include. The live check used Mason's `lua-language-server` on 0.12.6.

## Standalone `.lua` cart check

- [x] Create a small standalone `.lua` cart.
- [x] `:set filetype=pico8` attaches `pico_lsp` with the file's directory as the
      root on 0.12.6.
- [x] The statusline emits token/character data and omits the compressed
      segment. `:Pico8Tabs` follows the documented single-tab behavior.
- [x] Keep the best-effort standalone `.lua` guidance in `docs/usage.md`.

## Visuals and documentation

- [x] `docs/assets/onboarding.svg` was captured from a real headless Neovim
      0.12.5 screen with `examples/hello.p8` and `pico-lsp` v1.8.1.
- [x] The image is referenced by the README and quickstart with alt text.
- [ ] The quickstart works from the published release without cloning the
      repository.
- [x] `doc/pico8.txt` contains `*pico8-install*`, `*pico8-requirements*`, and
      `*pico8-options*`; `:help :Pico8OpenPng` resolves.
- [x] `docs/release-checklist.md` and `CHANGELOG.md` match the release.

## Tag and publish

1. Confirm the release commit is the merged `main` commit and CI is green.
2. Create an annotated tag with release notes:

   ```sh
   git tag -a v0.1.0 -F /tmp/pico8.nvim-v0.1.0-notes.txt
   git push origin v0.1.0
   ```

3. Publish the GitHub release from the tag:

   ```sh
   gh release create v0.1.0 --title "pico8.nvim v0.1.0" \
     --notes-file /tmp/pico8.nvim-v0.1.0-notes.txt --latest
   ```

4. Confirm the release page shows the install snippet, quickstart link, demo
   cart, known limitations, and compatibility table.

## Repository metadata

- [ ] GitHub description mentions the Neovim client for `pico-lsp`.
- [ ] Topics include at least `pico-8`, `pico8`, `neovim`, `lua`,
      `language-server`, and `lsp`.
- [ ] A social preview is uploaded in the repository settings.
- [ ] The README CI and release badges resolve.

## Verification record

| Date | Platform | Neovim | `pico-lsp` | Result | Notes |
|---|---|---|---|---|---|
| 2026-11-24 | Linux amd64 | 0.11.4 | v1.8.1 | Pass | Full headless suite; standard hooks skipped |
| 2026-11-24 | Linux amd64 | 0.12.6 | v1.8.1 | Pass | Full headless suite; standard hooks skipped |
| 2026-11-24 | Linux amd64 | 0.12.6 | dev M33 build | Pass | `gq`/`gx` standard hooks |
| 2026-11-24 | Linux amd64 | 0.12.5 | v1.8.1 | Pass | Demo cart, `gf`, include attach, terminal capture |
| 2026-11-24 | Linux amd64 | 0.12.6 | v1.8.1 | Pass | Lazy/Vim.pack/vanilla sandbox installs; LuaLS recipe |

CI is the source of truth for Neovim 0.12.6. Local 0.12.5 results do not claim
0.12.6 coverage. A PICO-8 runtime load was not part of the Linux local run; the
demo uses the same cart header and `__gfx__` layout as the smoke-test fixture
and is parsed by `pico-lsp`.
