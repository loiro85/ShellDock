#!/usr/bin/env bash
# Compila y muestra solo errores/avisos relevantes. Sale con 1 si hay errores.
cd "$(dirname "$0")/.."
OUT=$(swift build 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | sed -E 's#/Users/oriol/Documents/Github/ShellDock/##')
echo "$OUT" | grep -E "error:|Build complete" | grep -v "SwiftCompile" | head -${1:-30}
echo "$OUT" | grep -q "error:" && exit 1
exit 0
