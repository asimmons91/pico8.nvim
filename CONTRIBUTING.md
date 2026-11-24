# Contributing

Thanks for helping with `pico8.nvim`.

## AI-assisted development

**This is an AI vibe-coded project.** Most of the code, tests, and
documentation are produced by AI coding agents working from human direction and
written milestone specifications. A human maintainer reviews changes, runs the
automated test suite, and cuts releases, but this is not a traditionally
hand-written codebase and does not have a large human review team.

Treat it accordingly: inspect the implementation for your use case before
relying on it in critical workflows, expect occasional rough edges, and report
bugs with a minimal reproduction so they can be verified and fixed.

## Project boundaries

- `pico-lsp` owns the Go server, parser, analysis, formatter, diagnostics, and
  standard LSP capabilities. Do not add server code here.
- `pico8.nvim` owns the Neovim plugin, filetype runtime files, commands,
  statusline helpers, health checks, documentation, and Neovim-specific tests.
- `vendor/tree-sitter-pico8/` is a vendored copy. Do not edit it here;
  regenerate and test it in `pico-lsp`, then re-vendor it.
- The historical `pico-lsp/editors/nvim` copy is not maintained here.

## Prerequisites

- Neovim 0.11.4 or 0.12.6. The CI matrix uses those versions.
- A `pico-lsp` v1.8.1 or newer binary for the LSP tests.
- Optional: `cc` or `clang` for the Tree-sitter installer tests.
- Go is only needed when working in the `pico-lsp` repository.

## Run the tests

```sh
PICO_LSP_BIN=/path/to/pico-lsp tests/run.sh
```

The suite uses real `pico-lsp` behavior. It creates temporary carts, starts
real clients, and cleans up clients and buffers. Do not replace LSP integration
with mocks when the real server is available.

Run the documentation checks without a server:

```sh
nvim --headless --clean -u NONE -l tests/docs.lua
```

Check whitespace before committing:

```sh
git diff --check
```

Never claim a test passed unless it was run. Record the Neovim and `pico-lsp`
versions when reporting results.

## Branch and commit rules

- Branch from an up-to-date `main`:
  `feat/<short-slug>` for features, `fix/<short-slug>` for bug fixes, or
  `chore/<short-slug>` for docs and tooling.
- Use Conventional Commits:
  `<type>(<optional scope>): <description>`.
- Use an imperative, lowercase description with no trailing period.
- Push the branch and open a PR. Do not bypass branch protection.
- After opening the PR, run the `code-review` skill in PR mode. Address every
  validated finding, rerun the relevant tests, and push the fixes to the same
  branch.
- Merge only when the review has no unresolved findings and CI is green.

## Documentation

- `docs/ROADMAP.md` is the plugin roadmap.
- `docs/milestones/` holds client milestone specs.
- `docs/install.md`, `docs/usage.md`, `docs/configuration.md`, and
  `docs/troubleshooting.md` are user documentation.
- Keep the README installation path compatible with lazy.nvim and LazyVim.
- Do not duplicate server settings; link the
  [`pico-lsp` configuration reference](https://github.com/asimmons91/pico-lsp/blob/main/docs/configuration.md).
- Keep `doc/pico8.txt` tags valid and run `:helptags doc` after editing help;
  commit the updated `doc/tags`.
- Update the roadmap, milestone index, and `AGENTS.md` together when a
  milestone moves or changes status.

## Licensing

By contributing, you agree that your contribution is licensed under the
repository's [MIT license](LICENSE). The Tree-sitter parser sources are derived
from tree-sitter-lua; see
`vendor/tree-sitter-pico8/LICENSE.tree-sitter-lua`.
