#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MO="${MO:-mo}"

echo "==> Checking core Arvo modules are SQLite-free"
if grep -rn "Sqlite" "$ROOT"/lib/arvo/*.mo; then
  echo "ERROR: top-level core module references Sqlite!" >&2
  exit 1
fi

echo "==> Checking and testing core Arvo library modules ($MO)"
for f in "$ROOT"/lib/arvo/*.mo; do
  echo "  -> $f"
  "$MO" check "$f"
  "$MO" test "$f"
done

echo "==> Checking and testing Arvo SQLite backend modules ($MO)"
for f in "$ROOT"/lib/arvo/sqlite/*.mo; do
  echo "  -> $f"
  "$MO" check "$f"
  "$MO" test "$f"
done

echo "==> Checking and testing examples/arvo-starter via mo.toml path dependency"
"$MO" check "$ROOT/examples/arvo-starter/main.mo"
"$MO" test "$ROOT/examples/arvo-starter/main.mo"

run_modb_suite() {
  local arvo_root="$1"
  echo "==> Checking and testing Arvo MoDB adapter modules ($MO)"
  for f in "$arvo_root"/packages/arvo-modb/lib/arvo/modb/*.mo; do
    echo "  -> $f"
    "$MO" check "$f"
    "$MO" test "$f"
  done

  echo "==> Checking and testing examples/arvo-modb-starter via mo.toml path dependencies"
  "$MO" check "$arvo_root/examples/arvo-modb-starter/main.mo"
  "$MO" test "$arvo_root/examples/arvo-modb-starter/main.mo"
}

if [ -d "$ROOT/../modb" ]; then
  run_modb_suite "$ROOT"
elif [ -n "${MODB_PATH:-}" ] && [ -d "$MODB_PATH" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/arvo" "$TMP/modb"
  tar -C "$ROOT" --exclude=.git --exclude=node_modules -cf - . | tar -C "$TMP/arvo" -xf -
  cp -a "$MODB_PATH/mo.toml" "$MODB_PATH/src" "$TMP/modb/"
  run_modb_suite "$TMP/arvo"
else
  echo "==> Skipping optional MoDB tests (sibling ../modb not found; set MODB_PATH=/path/to/modb to run)"
fi

echo "All Arvo tests passed."
