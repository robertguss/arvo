#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MO="${MO:-mo}"
CLEANUP_DIRS=()
cleanup() {
  if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then
    rm -rf "${CLEANUP_DIRS[@]}"
  fi
}
trap cleanup EXIT

if [ "${MODB_PATH+x}" = x ] && { [ ! -f "$MODB_PATH/mo.toml" ] || [ ! -d "$MODB_PATH/src" ]; }; then
  echo "ERROR: MODB_PATH must point to a MoDB checkout containing mo.toml and src: '$MODB_PATH'" >&2
  exit 1
fi

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

echo "==> Checking and testing Arvo SQLite testing modules ($MO)"
for f in "$ROOT"/lib/arvo/testing/*.mo; do
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

if [ "${MODB_PATH+x}" = x ]; then
  TMP="$(mktemp -d)"
  CLEANUP_DIRS+=("$TMP")
  mkdir -p "$TMP/arvo" "$TMP/modb"
  tar -C "$ROOT" --exclude=.git --exclude=node_modules -cf - . | tar -C "$TMP/arvo" -xf -
  cp -a "$MODB_PATH/mo.toml" "$MODB_PATH/src" "$TMP/modb/"
  run_modb_suite "$TMP/arvo"
elif [ -d "$ROOT/../modb" ]; then
  run_modb_suite "$ROOT"
else
  echo "==> Skipping optional MoDB tests (sibling ../modb not found; set MODB_PATH=/path/to/modb to run)"
fi

echo "All Arvo tests passed."
