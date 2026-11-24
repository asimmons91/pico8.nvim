# M34 — Neovim Tree-sitter Installer and Distribution

**Status:** Done — installer module, command, tests, CI, and documentation are
complete.

**Depends on:** pico-lsp M6 (server features), pico-lsp M12 (Tree-sitter
grammar), M25 (drop-in configuration)

**Release target:** pico8.nvim v0.1.0; completed 2026-11-24.

**Roadmap:** [ROADMAP.md](../ROADMAP.md)

## Outcome

Neovim users can install the committed PICO-8 Tree-sitter parser and queries
without manually running `cc`, creating directories, and copying `.scm` files.
`:Pico8InstallParser` builds the parser from the repository's committed sources,
installs it into Neovim's data directory, copies the queries, and registers the
language for the current session.

The installer is additive and optional. The existing Vim syntax file, LSP
semantic tokens, and manual compile instructions remain available. Helix users
are unaffected and keep their own grammar build path.

**Demo:** With this repository on `runtimepath`, run `:Pico8InstallParser` on a
machine with a C compiler. The command reports the parser path and query
directory. Opening `tests/fixtures/smoke.p8` and running
`:lua vim.treesitter.start(0, "pico8")` highlights the cart. Running the command
again says the parser is up to date; `:Pico8InstallParser!` rebuilds it. With no
`$CC`, `cc`, or `clang`, the command shows an actionable error and the manual
instructions.

## Decisions

| ID | Decision | Choice |
|---|---|---|
| D1 | Build source | Use the committed `vendor/tree-sitter-pico8/src/parser.c` and `src/scanner.c`; do not require the tree-sitter CLI or network access. |
| D2 | Compiler | Use `$CC` as a single executable path when set, otherwise `cc`, then `clang`, on every platform. Detect a missing compiler and show the manual path. Windows builds are best-effort with the user's `cc`/clang and are not a CI requirement. |
| D3 | Install location | Install `pico8.so` under `stdpath("data")/site/parser` and queries under `stdpath("data")/site/queries/pico8`, which are on Neovim's default runtimepath. |
| D4 | Session registration | Call `vim.treesitter.language.add("pico8", { path = ... })` after a successful build so the current session works without a restart. |
| D5 | Idempotence | Skip the build when the installed parser is at least as new as both sources, unless `!` is used. Copy queries when missing or changed. |
| D6 | Atomicity | Build into a temporary file in the destination directory and rename it into place only after a successful compiler exit. Do not leave a partial `.so`. |
| D7 | Start behavior | Do not start Tree-sitter automatically on every `.p8` buffer. Document the one-line `FileType` autocmd and offer an optional start after install only if the current buffer is `pico8`. |
| D8 | Distribution | Keep the installer in this plugin and vendor the committed grammar under `vendor/tree-sitter-pico8`. Do not add an `nvim-treesitter` parser registry dependency. |
| D9 | Fallback | Keep `syntax/pico8.vim` and the manual compile/copy instructions; the installer is a convenience, not a requirement. |
| D10 | Tests | Build and load the parser in a temporary `XDG_DATA_HOME` on Linux; macOS covers compilation where the CI image has a compiler; Windows is manual/documented. |

### Deferred follow-up

**D8 follow-up:** the installer vendors the parser sources so it can work
without network access. Prebuilt parser assets per OS/architecture were
deferred after M34 shipped; if the grammar changes often, they would remove the
C compiler requirement but add a release matrix.

## Scope

### In scope

- `:Pico8InstallParser` and `:Pico8InstallParser!`.
- Source discovery relative to the helper module, with explicit overrides.
- Parser compilation, atomic install, query copying, and session registration.
- Idempotence and clear compiler/source errors.
- Headless tests in an isolated data directory.
- README and grammar README updates.
- Distribution guidance for plugin managers.

### Out of scope

- Regenerating the parser with the tree-sitter CLI.
- Updating the grammar, queries, or parser ABI.
- Installing parsers for other languages.
- A parser download service or network access.
- An `nvim-treesitter` parser registry or `:TSInstall` integration.
- Automatic highlighting for every `.p8` buffer by default.
- Helix grammar installation.
- Windows CI compilation unless a supported compiler image is already available.
- Publishing prebuilt parser assets in this milestone.

## Deliverables

1. `lua/pico_lsp/treesitter.lua` or equivalent installer module.
2. `lua/pico_lsp/init.lua` — command registration.
3. `tests/treesitter.lua` or an extension to the helper test.
4. `.github/workflows/ci.yml` — parser build/load coverage in the Neovim job.
5. `README.md` and
   `vendor/tree-sitter-pico8/README.md` — new install path and fallback.
6. `docs/ROADMAP.md` — milestone status.

## Detailed requirements

### 1. Source discovery

Resolve the grammar directory in this order:

1. `vim.g.pico8_treesitter_source` when set to a directory.
2. `vim.env.PICO_LSP_TREE_SITTER` when set to a directory.
3. A directory relative to the helper module: `lua/pico_lsp/` → plugin root →
   `vendor/tree-sitter-pico8`.

Validate that the directory contains:

- `src/parser.c`
- `src/scanner.c`
- `queries/highlights.scm`
- `queries/indents.scm`
- `queries/textobjects.scm`

If any required file is missing, show an error naming the expected path and
the override variables. Do not attempt a partial install.

### 2. Destinations

- Parser directory: `vim.fn.stdpath("data") .. "/site/parser"`.
- Parser file:
  - `.so` on Linux and macOS;
  - `.dll` on Windows.
- Query directory: `vim.fn.stdpath("data") .. "/site/queries/pico8"`.
- Create directories with `vim.fn.mkdir(..., "p")`.
- If `stdpath("data")/site` is not on `runtimepath`, prepend it once and note
  the change. Do not reorder the rest of `runtimepath`.
- Never write inside the repository or the user's config directory.

### 3. Compilation

- Determine the compiler from `$CC`, then `cc`, then `clang` on every platform.
  `$CC` is one executable path, not a shell command. Document that MSVC's `cl`
  is not supported by this installer.
- Build command for POSIX:

  ```sh
  $CC -shared -fPIC -O2 -I <grammar>/src \
    <grammar>/src/parser.c \
    <grammar>/src/scanner.c \
    -o <tmp>/pico8.so
  ```

- Use `vim.system` with a list of arguments, not a shell string.
- Capture stdout and stderr and include the tail in the error message.
- Set a bounded timeout (for example 60 seconds) so a hung compiler cannot
  freeze Neovim.
- Build into a temporary file in `site/parser` and rename it to `pico8.so` only
  after a zero exit code.
- On failure, remove the temporary file and leave any existing parser untouched.
- Do not execute arbitrary commands from the cart or configuration.

### 4. Idempotence and force

- Compare the installed parser's mtime with the newer of `parser.c` and
  `scanner.c`.
- If the installed parser exists and is at least as new as the sources, skip
  compilation and report "up to date".
- If any query file is missing or differs, copy it; query copying is cheap.
- `:Pico8InstallParser!` forces compilation even when the parser is up to date.
- A failed forced rebuild must not delete the previous working parser.
- Do not rebuild merely because Neovim restarted.

### 5. Query installation

- Copy `highlights.scm`, `indents.scm`, and `textobjects.scm` to
  `site/queries/pico8/`.
- Copy only these files; do not copy the grammar test corpus.
- Preserve file contents byte-for-byte.
- If the destination file exists with identical contents, leave it untouched.
- Report the query directory in the success message.

### 6. Session registration and optional start

After a successful build or when the parser is already up to date:

- Call `pcall(vim.treesitter.language.add, "pico8", { path = parser_path })`.
- If registration fails, report an error that names the parser path and the
  Neovim version; do not claim success.
- Do not call `vim.treesitter.start` automatically in the command.
- Document the `FileType pico8` autocmd that starts highlighting.
- Optionally, if the current buffer is `pico8` and the user ran the command
  interactively, offer a follow-up notification with the start command. Do not
  add a second command in this milestone.

### 7. Errors and safety

- Missing compiler: error with install hints for the platform and a link to the
  manual compile section.
- Missing sources: error with the override variables.
- Compiler failure: show the tail of stderr, at most a bounded number of lines.
- Timeout: kill the process and report a timeout.
- No permission to write: report the destination path and the underlying error.
- Never write to stdout outside Neovim's UI; this is a Neovim plugin, not the
  server.
- The installer must not inspect cart contents.

### 8. Distribution guidance

- Document installing the plugin with lazy.nvim and vanilla `runtimepath`, then
  running `:Pico8InstallParser`.
- Keep the manual `cc` + query-copy instructions as the fallback using the
  vendored grammar paths.
- State that the grammar remains editor-highlighting only and never replaces
  LSP diagnostics or semantic tokens.
- Note that the committed parser targets ABI 14 for Neovim 0.11+.

### 9. Tests

- Use a temporary `XDG_DATA_HOME` or equivalent so the user's data directory is
  never modified.
- Headless tests:
  - install from the repository sources and assert the parser and three query
    files exist;
  - register the language and assert `vim.treesitter.language.add` succeeds;
  - start highlighting on a `.p8` buffer and assert no error;
  - run the command twice and assert the second run is up to date;
  - force a rebuild and assert the parser still loads;
  - set a missing source override and assert an actionable error;
  - set `$CC` to a missing executable and assert an actionable error;
  - verify a failed forced rebuild leaves the previous parser loadable.
- Run the build/load tests on Linux and macOS in the Neovim CI job when a
  compiler is available. Skip Windows compilation in CI and keep the manual
  instructions.
- Do not require network access in tests.

## Interfaces and state

- New commands: `:Pico8InstallParser`, `:Pico8InstallParser!`.
- New optional globals: `vim.g.pico8_treesitter_source` and
  `PICO_LSP_TREE_SITTER`.
- New installed files under `stdpath("data")/site`:
  - `parser/pico8.so` (or `.dll`);
  - `queries/pico8/*.scm`.
- No new LSP request, response, server command, or setting.
- No change to the grammar or parser sources.

## Error handling

- Missing compiler, missing source files, write failures, compiler failures,
  and timeouts each produce a distinct actionable error with the destination
  or source path.
- A failed forced rebuild leaves the previous parser and queries untouched.
- A failed language registration reports the parser path instead of claiming
  success.
- The installer never prints partial compiler output to the editor message
  area without a bound; include at most a short stderr tail.

## Testing and CI

- Extend the headless Neovim job from M25.
- `cc` is expected on the Linux CI image; guard the macOS test on compiler
  availability.
- The grammar corpus and generated-parser checks remain in `pico-lsp`; this
  repository tests only compilation, loading, and query installation.
- No network access.

## Implementation notes

- `lua/pico_lsp/treesitter.lua` owns source discovery, compiler resolution,
  atomic builds, query repair, runtimepath insertion, and registration.
  `install({ force = true, timeout_ms = ... })` returns a result table or an
  actionable error and never notifies; the command reports the result.
- The command is registered by `setup()` even when the helper is disabled and
  by `lsp/pico_lsp.lua` for base-config users. Requiring the module registers
  the command but builds nothing.
- Compiler lookup is `$CC`, `cc`, then `clang`. `$CC` is one executable path;
  a wrapper script is the supported way to add arguments such as `ccache`.
- A forced rebuild in a session that already loaded the parser reports that a
  restart is needed; a first install is registered in the current session.
- `tests/treesitter.lua` runs under an isolated `XDG_DATA_HOME` from
  `tests/run.sh`. It covers build/load/start, idempotence, query repair, forced
  rebuilds, missing and incomplete sources, missing compilers, compiler
  failures, bounded stderr, timeouts, registration failures, and recovery.
- The macOS CI job runs the installer test with the system compiler. The Linux
  matrix runs it through `tests/run.sh`.

## Exit criteria

- [x] `:Pico8InstallParser` builds and installs the committed parser and
      queries without manual `cc`/`cp` commands.
- [x] The current Neovim session can load and start the `pico8` parser after
      installation.
- [x] Repeated runs are idempotent; `!` forces a safe rebuild.
- [x] Missing sources, missing compilers, compiler failures, and write failures
      produce actionable errors.
- [x] A failed rebuild leaves the previous parser usable.
- [x] The manual compile path and Vim syntax fallback remain documented.
- [x] Headless tests and CI cover the installer on supported platforms.
- [x] Distribution guidance covers runtimepath and plugin-manager installs.

## Risks

| Risk | Mitigation |
|---|---|
| The user has no C compiler | Keep the Vim syntax fallback and report manual instructions. |
| ABI mismatch with an older Neovim | Target 0.11+ and verify registration; document ABI 14. |
| Installing into `stdpath("data")` surprises users | Report both paths, use atomic renames, and never touch the repository. |
| A stale query file overrides new grammar behavior | Compare/copy query contents on every install. |
| A failed build removes a working parser | Build to a temporary file and rename only after success. |
| Windows compiler differences | Best-effort `cc`/clang support and documented manual fallback; no CI promise. |
