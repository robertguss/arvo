#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MO="${MO:-mo}"

echo "==> Checking and testing all Arvo library modules ($MO)"
for f in "$ROOT"/lib/arvo/*.mo; do
  echo "  -> $f"
  "$MO" check "$f"
  "$MO" test "$f"
done

echo "==> Checking Arvo fixture modules"
for f in "$ROOT"/lib/arvo/fixtures/*.mo; do
  echo "  -> $f"
  "$MO" check "$f"
done

echo "==> Checking and testing pure-Mo arvo CLI (cmd/arvo)"
"$MO" check "$ROOT/cmd/arvo/main.mo"
"$MO" test "$ROOT/cmd/arvo/main.mo"

echo "==> Checking and testing examples/arvo-starter"
"$MO" check "$ROOT/examples/arvo-starter/main.mo"
"$MO" test "$ROOT/examples/arvo-starter/main.mo"

echo "==> Validating starter Executable Feature Maps and contract sync"
"$MO" run "$ROOT/cmd/arvo/main.mo" feature --app examples/arvo-starter --validate
"$MO" run "$ROOT/cmd/arvo/main.mo" contracts --app examples/arvo-starter --check

echo "All Arvo tests and starter checks passed."
