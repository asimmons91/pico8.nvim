# Security policy

## Supported versions

Security fixes are provided for the latest `pico8.nvim` release. The current
tested pair is `pico8.nvim` v0.1.0 with `pico-lsp` v1.8.1.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting:

<https://github.com/asimmons91/pico8.nvim/security/advisories/new>

Include:

- the affected `pico8.nvim` version or commit;
- the Neovim version, OS, and architecture;
- a description of the issue and its impact;
- minimal reproduction steps, a cart, or configuration;
- whether the issue also affects `pico-lsp` or the Tree-sitter installer.

If the report is about the Go server, parser, analysis, formatter, or standard
LSP capabilities, report it in the
[`pico-lsp` repository](https://github.com/asimmons91/pico-lsp) instead.

## Scope

This policy covers the Lua plugin, runtime files, commands, include helper,
statusline helpers, health check, documentation checks, and Tree-sitter
installer in this repository.

It does not cover:

- the `pico-lsp` server binary or its dependencies;
- PICO-8 itself;
- third-party plugin managers, terminals, fonts, or editors;
- the vendored grammar sources, which are maintained in `pico-lsp` and
  re-vendored here.

## Privacy

The plugin has no telemetry, analytics, or crash reporting. Carts are parsed
and analyzed by `pico-lsp`; they are never executed by this plugin. Logs may
contain source excerpts when verbose logging is enabled; review a log before
sharing it.

## Response

Reports are handled on a best-effort basis. There is no guaranteed response
time or support SLA. Please allow time for verification before public
disclosure.
