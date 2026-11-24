# M36 — End-User Onboarding, Documentation, and Release Readiness

**Status:** Done — onboarding docs, demo cart, support files, documentation
checks, and the v0.1.0 release are complete. The only unrun check is a manual
PICO-8 runtime load; the demo is parsed by `pico-lsp` and the release checklist
records the gap. Mason packaging and LazyVim extra publication are explicitly
out of scope and remain M35.

**Depends on:** M25–M34; a released `pico-lsp` binary (v1.8.1 or later). This
milestone supplies the Neovim side of
[`pico-lsp` M24](https://github.com/asimmons91/pico-lsp/blob/main/docs/M24-end-user-onboarding.md):
the tagged client, quickstart, and support files. M35 is not a dependency.

**Release target:** `pico8.nvim` v0.1.0; completed 2026-11-24. Automated
release publishing remains M35.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

A new user can go from zero to a working PICO-8 editing session using only the
repository README, a pinned release, and a five-minute quickstart. The docs
explain the server and plugin install paths, the demo cart, the first features
to try, the limits of the plugin, and how to get help. A maintainer can tag a
release from a documented checklist without relying on unpublished branches or
unpinned server builds.

This milestone is documentation, setup, support, and release readiness. It does
not add LSP behavior, commands, settings, or server features. Mason packaging
and the LazyVim extra are not part of this milestone; if they are unavailable
at launch, the manual install path must be complete and clearly labeled as the
supported path.

**Demo:** On a clean Neovim 0.11.4 and 0.12.6 install, follow
`docs/getting-started.md`: install the pinned `pico-lsp` release, install
`pico8.nvim` at its tag, open `examples/hello.p8`, and run
`:checkhealth pico_lsp`. The cart attaches, completion and diagnostics work,
the budget lens/statusline appears, `gf` opens the included `.lua` file,
`:Pico8Tabs` lists the demo tabs, and the quickstart explains what to try next.
The same page states plainly what the plugin does not do.

## Decisions proposed

| ID | Decision | Choice |
|---|---|---|
| D1 | Scope | Treat this as an onboarding and release-readiness milestone. Do not change LSP behavior, commands, defaults, or server code; file defects found during verification as separate fixes. |
| D2 | Release model | Cut `v0.1.0` manually and write release notes. Do not build a release workflow or publish Mason/LazyVim assets in this milestone; those remain M35. |
| D3 | Server version | Pin the tested `pico-lsp` release (v1.8.1 at the time of writing) in install docs and state the minimum supported version. Link the server's per-OS install/upgrade/uninstall docs instead of duplicating them. |
| D4 | Quickstart | Add a one-page, copy-paste quickstart plus a small `examples/hello.p8` demo with a second tab and an `#include`. The quickstart must not require cloning the repository. |
| D5 | Visuals | Add a real screenshot or short recording captured from the documented quickstart. Do not use a mockup or a rendering of an unreleased interface. |
| D6 | Help | Add requirements/install content and per-command tags to `doc/pico8.txt`; `:help :Pico8OpenPng` must work. |
| D7 | LuaLS | Document a tested way to scope `lua_ls` away from cart-owned `.lua` buffers. Do not automatically detach a user's `lua_ls` clients in plugin code. |
| D8 | Standalone `.lua` carts | Document the manual `filetype=pico8` path as best-effort, or mark standalone `.lua` carts unsupported. Do not add automatic `.lua` cart detection. |
| D9 | Tree-sitter | State that `:TSInstall pico8`/`nvim-treesitter` is not the install path. Keep `:Pico8InstallParser`, document optional auto-start, and document parser removal and the Windows compiler limit. |
| D10 | Support files | Add a bug-report form, security policy, contribution guide, and release checklist. The bug form must request enough diagnostics to reproduce without a round trip. |
| D11 | Documentation checks | Add a local-link/anchor check and a help-tags check to CI. External links may warn rather than fail. |
| D12 | Install paths | Document lazy.nvim, `vim.pack`, and vanilla `runtimepath`, all pinned to the release. State that commands and PNG auto-open require `require("pico_lsp").setup()` because the plugin has no `plugin/` entry. |
| D13 | Compatibility | Record the tested matrix: `pico8.nvim` v0.1.0, `pico-lsp` v1.8.1, Neovim 0.11.4 and 0.12.6. Do not claim untested Neovim patch releases. |
| D14 | Distribution boundary | Mason packaging, the LazyVim extra, plugin-managed server downloads, prebuilt parser assets, and release automation stay out of scope and remain M35 or later. |
| D15 | Server installation | The plugin does not download or install the server. It documents the release archive, `go install`, and `cmd`/`PICO_LSP_BIN` overrides. |

### Resolved decisions

- **Release:** cut the manual `v0.1.0` tag and GitHub release after the PR
  merges and CI is green. Automated release publishing remains M35.
- **LuaLS:** use the include-aware `root_dir` recipe. It was verified on
  Neovim 0.12.6 with Mason's `lua-language-server`: the cart-owned include got
  only `pico_lsp`, and an unrelated Lua file kept `lua_ls`.
- **Standalone `.lua`:** keep the manual `:set filetype=pico8` path as
  best-effort. It was verified on 0.12.6 with the cart-directory root and
  token/character status data; compressed size was `unavailable`.
- **Visual:** use a real headless Neovim 0.12.5 screen capture rendered to
  `docs/assets/onboarding.svg`. The capture shows `examples/hello.p8`, the
  budget code lens and statusline, and the include.
- **Versions:** claim `pico-lsp` v1.8.1 and Neovim 0.11.4/0.12.6. The v1.8.1
  release predates M33, so `gq` and Neovim 0.12 `gx` are documented as
  requiring a newer server build; `gf` remains the fallback.
- **Documentation checks:** local links/anchors and help tags are checked by
  `tests/docs.lua` on both Neovim versions and in the CI docs job.
- **Support files:** add the bug form, security policy, contribution guide,
  and release checklist. Repository metadata and the social preview remain
  manual release-checklist items.

## Scope

### In scope

- A tagged v0.1.0 release with release notes and a compatibility table.
- Pinned plugin and server install commands in the README and install docs.
- A quickstart, demo cart, and real screenshot or recording.
- LuaLS coexistence instructions with a tested scoping recipe.
- Server install, upgrade, uninstall, offline, PATH, and version-mismatch
  documentation, linked to the server's authoritative pages.
- `vim.pack`, lazy.nvim, and vanilla install paths, plus upgrade and uninstall
  guidance.
- Help-file installation and command tags.
- Tree-sitter expectations, auto-start, rebuild, and removal documentation.
- Standalone `.lua` cart documentation or an explicit unsupported statement.
- A known-limitations section and terminal-font guidance for P8SCII glyphs.
- Bug-report, security, contribution, support, and release-checklist files.
- Link/tag checks in CI and release metadata checks.

### Out of scope

- Mason packaging, a LazyVim extra, or publishing either to a registry.
- Automated release publishing, version bumping, or GitHub release workflows
  (M35).
- Plugin-managed server downloads or a bundled `pico-lsp` binary.
- Prebuilt Tree-sitter parser assets per OS/architecture.
- New LSP features, commands, settings, statusline behavior, or server
  requests.
- Server, parser, analysis, or formatter changes.
- A documentation website or localization.
- Windows CI for the Tree-sitter installer.
- A code of conduct, community platform, or support SLA.
- A redesign of the plugin UI.

## Deliverables

1. `docs/milestones/M36-nvim-onboarding-release.md` — this specification.
2. `docs/getting-started.md` — five-minute quickstart and first-feature tour.
3. `examples/hello.p8` and `examples/hello_lib.lua` — public demo cart with a
   second tab and a cart-owned include.
4. `docs/assets/` — a real screenshot or short recording with alt text.
5. `README.md` — release status, badges, pinned install, quickstart link,
   known limitations, support/privacy, and documentation links.
6. `docs/install.md` — pinned plugin/server install, `vim.pack`, upgrade,
   uninstall, offline, PATH, and tested-version matrix.
7. `docs/usage.md` — LuaLS coexistence, standalone `.lua` carts, Tree-sitter
   expectations, and glyph-font guidance.
8. `docs/configuration.md` — clarify the Neovim helper versus the VS Code
   `pico8.attachLua` setting; link the compatibility matrix.
9. `docs/troubleshooting.md` — binary PATH/version, LuaLS conflicts, font
   fallback, upgrade/uninstall, and quickstart verification.
10. `doc/pico8.txt` and `doc/tags` — requirements/install sections and
    per-command tags.
11. `CHANGELOG.md` — dated v0.1.0 release entry and known limitations.
12. `.github/ISSUE_TEMPLATE/bug.yml` and `.github/ISSUE_TEMPLATE/config.yml`.
13. `SECURITY.md`, `CONTRIBUTING.md`, and `docs/release-checklist.md`.
14. `.github/workflows/ci.yml` — documentation link/anchor and help-tag checks,
    plus a CI badge in the README.
15. `docs/ROADMAP.md`, `docs/milestones/README.md`, and `AGENTS.md` — milestone
    status and index updates.

## Detailed requirements

### 1. Tagged release and compatibility

- Tag `v0.1.0` only after `tests/run.sh` passes against the pinned `pico-lsp`
  release on Neovim 0.11.4 and 0.12.6.
- Add a dated `CHANGELOG.md` entry that summarizes the client surface and links
  the release. Leave the current `Unreleased` history intact or convert it into
  the release entry without dropping items.
- Pin the plugin in the README and install docs. Show the lazy.nvim `tag`, the
  `vim.pack` `version`, and the manual checkout/tag path. Do not tell users to
  install an unreleased branch.
- Pin the server install to the tested release. Replace `@latest` examples with
  the tested tag and add a note telling users to use the matching release
  archive or `go install ...@v1.8.1`.
- Add a compatibility table to the README or `docs/install.md`:

  | `pico8.nvim` | `pico-lsp` | Tested Neovim |
  |---|---|---|
  | v0.1.0 | v1.8.1 (minimum) | 0.11.4, 0.12.6 |

- State the supported Neovim floor as the tested patch version, not a vague
  "0.11+"; newer 0.12 patch releases may work but are not claimed as tested.
- Document upgrade and uninstall:
  - update the plugin tag and `pico-lsp` binary together;
  - restart Neovim or `:lsp restart` where supported;
  - remove the plugin and the parser under `stdpath("data")/site` when no
    longer wanted;
  - state that removing the plugin does not remove the server binary.

### 2. README and install paths

- Replace milestone-status prose with a release/version status. Keep internal
  milestone history in `docs/ROADMAP.md`, not the first screen of the README.
- Add CI and release badges once the release exists. Do not add a badge for a
  nonexistent workflow or package registry.
- Put the quickstart link, screenshot, and one-line description near the top.
- Document all supported install paths:
  - lazy.nvim/LazyVim with `main = "pico_lsp"`, `lazy = false`, `opts = {}`,
    and the release tag;
  - `vim.pack.add` with `version = "v0.1.0"` followed by
    `require("pico_lsp").setup()`;
  - vanilla `runtimepath` plus `require("pico_lsp").setup()`;
  - the manual `vim.lsp.config` fallback for users who do not want the plugin.
- State the requirements plainly: Neovim 0.11.4+, a pinned `pico-lsp` binary,
  and an optional C compiler for `:Pico8InstallParser`. PICO-8 is not required
  to edit carts and the plugin never runs them.
- State that `filetype plugin on` is required for the `ftplugin` options.
- State that `setup()` is required for commands, the include helper, and PNG
  auto-open. There is no `plugin/` file; do not imply that installing the
  plugin alone registers everything.
- Explain `lsp = false` and `disable = true` without duplicating the full
  configuration reference.
- Move `tests/run.sh` out of the end-user "Verify" section and into
  "Development". The end-user verification path is `:checkhealth pico_lsp` plus
  opening the demo cart.
- Link the server's install, upgrade, uninstall, and offline pages instead of
  restating archive names, checksums, and macOS/Windows caveats.

### 3. Quickstart, demo cart, and screenshot

- `docs/getting-started.md` must take a new user from nothing to a working
  client in about five minutes:
  - prerequisites and non-prerequisites: no PICO-8 install, no Go toolchain
    when using a release archive, no compiler unless the optional parser is
    wanted;
  - install and verify the pinned server;
  - install the pinned plugin with lazy.nvim, then show `vim.pack` and the
    vanilla path as alternatives;
  - open the demo cart;
  - run `:checkhealth pico_lsp` and state what a healthy report contains;
  - try completion, hover, diagnostics, the budget lens/statusline,
    `:Pico8CartInfo`, `:Pico8Tabs`, `gf` on the include, and the optional glyph
    command;
  - explain the optional PNG demo and that PNG carts are read-only;
  - end with "what this is not" and links to configuration, troubleshooting,
    and the server docs.
- The quickstart must not require cloning the repository. It may link to
  `examples/hello.p8` and also include a copyable minimal cart.
- Add `examples/hello.p8`:
  - a valid PICO-8 header and enough sections to load in PICO-8;
  - at least two code tabs;
  - one `#include "hello_lib.lua"` owned by the cart;
  - no internal test comments or fixture-only assumptions.
- Add `examples/hello_lib.lua` with a small function used by the demo.
- Add a real screenshot or short recording under `docs/assets/`. Capture it
  from the documented quickstart with the demo cart, showing the budget lens
  or statusline and the included file. Include descriptive alt text and keep
  the asset reasonably small. Refresh it when the UI changes.
- Optionally show the glyph picker or `:Pico8InsertGlyph` in the same asset or a
  second image. Do not claim a font or terminal feature that was not tested.

### 4. LuaLS coexistence

- Explain the symptoms: duplicate diagnostics, completion, hover, and code
  actions when `lua_ls` and `pico_lsp` are both attached to a cart-owned `.lua`
  buffer.
- Provide a tested recipe that scopes `lua_ls` away from cart-owned `.lua`
  buffers. Prefer a `root_dir`/directory check or another non-destructive
  scoping approach; do not recommend detaching `lua_ls` from unrelated Lua
  files.
- If the recipe declines `lua_ls` for a directory that contains a cart, state
  that tradeoff explicitly and show how to narrow it.
- Keep the plugin's health-check warning as the diagnostic, not as an automatic
  fix.
- Clarify that `pico8.attachLua` in the server docs is a VS Code extension
  setting. Neovim attachment is owned by the native config and the helper.
- Verify the recipe in a LazyVim-style configuration with `lua_ls` enabled and
  record the result in the release checklist.

### 5. Server installation and troubleshooting

- Link the server's per-OS install page for archives, checksums, Windows
  `.zip`, macOS Gatekeeper, offline/air-gapped use, upgrade, and uninstall.
- Document `go install` with a pinned version and the Go version requirement
  from the server repository.
- Add troubleshooting for:
  - `pico-lsp` not found after `go install`: `GOBIN`, `PATH`, and a full
    `cmd` path;
  - shell `pico-lsp --version` differing from Neovim's resolved binary: use
    `:checkhealth pico_lsp`, which reports the resolved executable and source;
  - server/client version mismatch: install the pinned release, restart, and
    recheck health;
  - macOS Gatekeeper and Windows SmartScreen warnings for unsigned binaries;
  - offline install and `cmd`/`PICO_LSP_BIN` overrides;
  - upgrade and uninstall steps.
- Do not duplicate the server's full configuration reference; link it.

### 6. Help file

- Add `*pico8-install*`, `*pico8-requirements*`, and `*pico8-options*` sections
  or tags. The install section summarizes requirements, the pinned server, the
  three plugin install paths, and the setup requirement, then links the
  repository docs.
- Add stable tags for each command, for example `*:Pico8OpenPng*`,
  `*:Pico8ReloadPng*`, `*:Pico8InsertGlyph*`, `*:Pico8Refresh*`,
  `*:Pico8ToggleInlayHints*`, `*:Pico8CartInfo*`, `*:Pico8Tabs*`,
  `*:Pico8OpenCart*`, and `*:Pico8InstallParser*`.
- Ensure `:helptags doc` succeeds and that `:help :Pico8OpenPng` resolves.
- Keep server setting defaults out of the help file; link the server reference.

### 7. Tree-sitter expectations

- State that `nvim-treesitter` does not install this grammar, and that
  `:TSInstall pico8` is not supported.
- Keep `:Pico8InstallParser` as the supported installer. Document the
  `FileType pico8` auto-start snippet for plain Neovim and a LazyVim-ready
  variant.
- Document parser removal: delete
  `stdpath("data")/site/parser/pico8.*` and
  `stdpath("data")/site/queries/pico8/`, or install to a clean data directory.
- Document rebuilds: `:Pico8InstallParser!`, restart when the parser was
  already loaded, and the ABI/session-registration behavior.
- Document the Windows limit: the installer looks for `$CC`, `cc`, or `clang`;
  MSVC's `cl` is not supported, and Windows compilation is best-effort and not
  in CI.
- Do not claim that Tree-sitter is required for LSP behavior.

### 8. Standalone `.lua` carts

- The current user docs mention standalone `.lua` carts only in the statusline
  section. Give the path a real description or remove the implication that it
  is supported.
- Proposed path: document `:set filetype=pico8` for a standalone `.lua` cart,
  note that the normal `pico8` LSP config then attaches with the file's
  directory as the root, and note that the include helper still ignores
  unrelated `.lua` files.
- Test the manual path with a small `.lua` cart. If it does not produce useful
  analysis or commands, mark standalone `.lua` carts unsupported and remove
  the statusline claim.
- Do not add automatic `.lua` cart detection or broaden the helper's ownership
  rules in this milestone.

### 9. Known limitations and P8SCII font guidance

- Add a "Known limitations" section to the README covering:
  - `.p8.png` carts are read-only;
  - the plugin does not run, compile, or emulate carts;
  - only the PICO-8 0.2.7 API is modeled; the Lua standard library is absent;
  - PICO-8 `CTRL-J`, `CTRL-K`, and `CTRL-P` input modes are not implemented;
  - Neovim 0.11 has no document-link `gx` path;
  - Mason and the LazyVim extra are not available yet;
  - Windows Tree-sitter builds are best-effort and not CI-tested;
  - standalone `.lua` carts are manual or unsupported per the decision above.
- Add a short P8SCII font note: inserted glyphs are Unicode characters, so the
  terminal font must render them. When a glyph is unavailable, use
  `:Pico8InsertGlyph` or a literal uppercase letter; the Shift maps fall back
  by design.
- Link the relevant usage and troubleshooting sections instead of repeating
  every caveat.

### 10. Support, security, and contribution files

- Add `.github/ISSUE_TEMPLATE/bug.yml` with required fields for:
  - `pico8.nvim` version/tag;
  - Neovim version and OS/architecture;
  - `pico-lsp --version` and the resolved path from `:checkhealth`;
  - `:checkhealth pico_lsp` output;
  - a minimal cart or include and exact steps;
  - the relevant client log lines;
  - whether `lua_ls` was attached.
- Add `.github/ISSUE_TEMPLATE/config.yml` with links to the quickstart,
  troubleshooting, discussions or support path, and security policy.
- Add `SECURITY.md` with a private reporting path and a scope statement for the
  plugin, server binary, parser installer, and downloaded compiler artifacts.
- Add `CONTRIBUTING.md` with the development prerequisites, test command,
  branch/commit rules, documentation expectations, and an AI-assisted
  development disclosure consistent with the server repository.
- Add `docs/release-checklist.md` with:
  - tests against the pinned server release on 0.11.4 and 0.12.6;
  - clean lazy.nvim, `vim.pack`, and vanilla quickstart runs;
  - LazyVim + `lua_ls` coexistence check;
  - help tags and link checks;
  - demo cart/screenshot verification;
  - tag, release-notes, and repository-metadata steps.
- Add a README "Support and privacy" section: where to ask, how to report a
  bug, the security path, no telemetry, carts are parsed not executed, and
  where logs live.
- Include a GitHub repository metadata checklist: description, topics,
  homepage, and social preview. These are manual release steps, not code.

### 11. Documentation validation and CI

- Add a documentation check for relative links and anchors in `README.md`,
  `docs/`, and `doc/pico8.txt`.
- Add a help-tags check that runs `:helptags doc` and verifies the expected
  command tags resolve. A headless Neovim test or a small script is acceptable;
  do not add a network dependency.
- External links may warn rather than fail if the check becomes flaky.
- Add the documentation job to CI and the README badge row.
- Keep `tests/run.sh` and the existing Neovim test jobs unchanged except for
  the release-binary verification described in the checklist.
- If a docs check finds a real feature mismatch, record it as a separate bug;
  do not silently change LSP behavior in this milestone.

## Testing and verification

- Run `PICO_LSP_BIN=/path/to/pico-lsp-v1.8.1 tests/run.sh` on Neovim 0.11.4
  and 0.12.6 before tagging.
- Run the documentation link/anchor check and `:helptags doc` locally.
- Follow `docs/getting-started.md` verbatim on a clean Neovim configuration
  with:
  - lazy.nvim and the pinned tag;
  - `vim.pack` on 0.12;
  - vanilla `runtimepath` plus `setup()`;
  - the manual `vim.lsp.config` fallback.
- Open `examples/hello.p8` and verify:
  - `:checkhealth pico_lsp` reports a healthy config and binary;
  - completion, hover, and diagnostics work;
  - the budget lens or statusline shows cart data;
  - `gf` opens `examples/hello_lib.lua`;
  - `:Pico8Tabs` lists both tabs;
  - the optional PNG path works or fails as documented.
- Verify the `lua_ls` recipe with a LazyVim-style config and confirm only
  `pico_lsp` remains on the cart-owned include.
- Verify the standalone `.lua` path or the explicit unsupported statement.
- Verify upgrade and uninstall instructions, including the parser directory and
  server binary.
- Record manual results, platform, Neovim version, and server version in
  `docs/release-checklist.md`. Do not mark unrun platforms as passing.

## Exit criteria

- [x] `v0.1.0` is tagged with dated release notes and a `CHANGELOG.md` entry.
- [x] README and install docs use the tagged plugin and pinned server versions;
      no end-user install command uses `@latest` or an unreleased branch.
- [x] A compatibility table records the plugin, server, and tested Neovim
      versions.
- [x] `docs/getting-started.md` works without cloning the repository and links
      the demo cart.
- [x] `examples/hello.p8` and `examples/hello_lib.lua` exist, use the standard
      cart header and `__gfx__` layout, and exercise a tab and an include.
- [ ] The demo cart was loaded in the PICO-8 runtime. That runtime check was not
      run in this pass; `pico-lsp` parses the cart and the release checklist
      records the gap.
- [x] A real terminal capture is in `docs/assets/` and used by the
      README/quickstart with alt text.
- [x] The LuaLS coexistence recipe is documented and verified.
- [x] Server install, PATH, version-mismatch, offline, upgrade, and uninstall
      guidance is present and links the server reference.
- [x] `vim.pack`, lazy.nvim, and vanilla install paths are documented; the
      setup requirement is explicit.
- [x] `doc/pico8.txt` has requirements/install content and per-command tags;
      `:help :Pico8OpenPng` and `:helptags doc` pass.
- [x] Tree-sitter expectations, auto-start, rebuild, removal, and Windows limits
      are documented.
- [x] Standalone `.lua` carts are documented as manual best-effort.
- [x] README has known limitations, P8SCII font guidance, support/privacy, and
      license/changelog links.
- [x] Bug-report, security, contribution, and release-checklist files exist.
- [x] Documentation link/anchor and help-tag checks run in CI; the README has a
      CI badge.
- [x] Tests pass against the pinned `pico-lsp` release on 0.11.4 and 0.12.6.
- [x] No LSP behavior, command, setting, server, or parser behavior changed.
- [x] Mason packaging and the LazyVim extra remain out of scope under M35.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| The milestone turns into feature work | Keep D1 explicit: docs/setup/release only; file behavior defects separately. |
| Docs drift from the server's install and configuration docs | Pin the tested server release and link the server pages instead of duplicating them. |
| A LuaLS recipe detaches the wrong client or races the helper | Prefer non-destructive directory/root scoping; verify in a LazyVim-style config; document the tradeoff. |
| The demo cart or screenshot goes stale | Use the demo in the release checklist and refresh the asset when the UI changes. |
| The tag is cut before the released server binary is tested | Tag only after the release-binary test matrix passes; record the exact versions. |
| Windows or standalone `.lua` behavior is unverified | Mark both as best-effort or unsupported; do not claim CI coverage that does not exist. |
| Link checks fail on external sites | Fail on local links/anchors; warn on external links. |
| Users expect Mason or a LazyVim extra | State clearly that the manual install is supported and link M35 as future distribution work. |
| `vim.pack` or LazyVim behavior differs from the docs | Test the exact snippets in the release checklist; keep the vanilla fallback. |

## Implementation order

1. Pin the release and server versions; add the compatibility table and
   upgrade/uninstall docs.
2. Add the quickstart, demo cart, and screenshot.
3. Add the LuaLS coexistence recipe and verify it.
4. Add the support, security, contribution, and release-checklist files.
5. Add the help sections/tags, Tree-sitter guidance, standalone `.lua` decision,
   and known limitations.
6. Add the documentation checks, CI badge, tag, and release notes.
7. Record the release verification and update the roadmap, milestone index, and
   `AGENTS.md`.
