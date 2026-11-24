# Vendored PICO-8 Tree-sitter grammar

This directory contains the editor-only PICO-8 Tree-sitter parser sources and
queries from
[`pico-lsp/editors/tree-sitter-pico8`](https://github.com/asimmons91/pico-lsp/tree/main/editors/tree-sitter-pico8).

- `src/parser.c`, `src/scanner.c` — committed generated parser at ABI 14.
- `queries/*.scm` — highlights, indents, and text objects.
- `LICENSE.tree-sitter-lua` — license for the tree-sitter-lua derivation.

The grammar is derived from
[tree-sitter-lua](https://github.com/tree-sitter-grammars/tree-sitter-lua) by
Munif Tanjim (MIT).

The grammar remains editor highlighting only. It never replaces `pico-lsp`
diagnostics, completion, or semantic tokens. Regeneration and corpus tests
remain in `pico-lsp`; this repository tests compilation, loading, and query
installation.

With the plugin on `runtimepath`, build and install the parser and queries:

```vim
:Pico8InstallParser
```

The command uses the committed sources, installs
`stdpath("data")/site/parser/pico8.so` (`.dll` on Windows) and the three query
files under `stdpath("data")/site/queries/pico8/`, and registers the language
for the current session. `:Pico8InstallParser!` forces a rebuild.

Manual build fallback:

```sh
cc -shared -fPIC -I src src/parser.c src/scanner.c -o pico8.so
```

See `docs/install.md#tree-sitter` for the manual parser and query install paths.
