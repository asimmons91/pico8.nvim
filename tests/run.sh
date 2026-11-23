#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${PICO_LSP_BIN:-}" ]]; then
  binary="$PICO_LSP_BIN"
else
  binary="$(command -v pico-lsp || true)"
fi

if [[ -z "$binary" || ! -x "$binary" ]]; then
  echo "pico-lsp binary not found: ${binary:-<not on PATH>}" >&2
  echo "install pico-lsp or set PICO_LSP_BIN to an executable" >&2
  echo "release binaries: https://github.com/asimmons91/pico-lsp/releases" >&2
  exit 1
fi

PICO8_NVIM_ROOT="$root" PICO_LSP_BIN="$binary" \
  nvim --headless --clean -u NONE \
    --cmd "set runtimepath+=$root" \
    -l "$root/tests/config.lua"

PICO8_NVIM_ROOT="$root" PICO_LSP_BIN="$binary" \
  nvim --headless --clean -u NONE \
    --cmd "set runtimepath+=$root" \
    -l "$root/tests/helper.lua"
