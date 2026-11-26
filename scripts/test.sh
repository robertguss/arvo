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

echo "==> Validating starter Executable Feature Maps and contract sync"
"$MO" run "$ROOT/cmd/arvo/main.mo" feature --app examples/arvo-starter --validate
"$MO" run "$ROOT/cmd/arvo/main.mo" contracts --app examples/arvo-starter --check

echo "==> Checking Arvo.Testing.Statechart models, replay, and sync commits"
# Statechart models check repository-level SQLite/core session modules cleanly from repo root.
# In linked git worktrees (.git is a pointer file outside $ROOT, blocked by Landlock), bridge real host git diff.
if [ -f "$ROOT/.git" ]; then
  jobs_diff="$(git -C "$ROOT" diff --name-only dbaaf0311d379d828af75ab08b6fa2b61ce9e839 -- lib/arvo/sqlite/jobs.mo)"
  sess_diff="$(git -C "$ROOT" diff --name-only dbaaf0311d379d828af75ab08b6fa2b61ce9e839 -- lib/arvo/sqlite/sessions.mo lib/arvo/session.mo)"
  sync_diff="$(printf '%s\n%s\n' "$jobs_diff" "$sess_diff" | sed '/^$/d' | sort -u)"
  ARVO_GIT_DIFF_FILES="$sync_diff" "$MO" run "$ROOT/cmd/arvo/main.mo" statechart check
else
  "$MO" run "$ROOT/cmd/arvo/main.mo" statechart check
fi

echo "==> Checking arvo replay capture/gen compiles and executes under mo check/test"
mkdir -p "$ROOT/.arvo/tmp"
REPLAY_REL="$(cd "$ROOT" && mktemp -d ".arvo/tmp/arvo-replay-smoke.XXXXXX")"
REPLAY_TMP="$ROOT/$REPLAY_REL"
CLEANUP_DIRS+=("$REPLAY_TMP")
mkdir -p "$REPLAY_TMP/req" "$REPLAY_TMP/noreq"
(
  cd "$ROOT"
  "$MO" run "$ROOT/cmd/arvo/main.mo" replay capture --id smoke-req --method POST --path "/bills/1/pay?token=sec" --body '{"password":"secret"}' --error "boom #{1+1}" --out "$REPLAY_REL/req.json"
  "$MO" run "$ROOT/cmd/arvo/main.mo" replay gen "$REPLAY_REL/req.json" --out "$REPLAY_REL/req/replay-regression.mo"
  "$MO" check "$REPLAY_REL/req/replay-regression.mo"
  "$MO" test "$REPLAY_REL/req/replay-regression.mo"
  python3 -c '
import json, pathlib
p = pathlib.Path("'"$REPLAY_REL"'/req.json")
b = json.loads(p.read_text())
b["request"] = None
pathlib.Path("'"$REPLAY_REL"'/noreq.json").write_text(json.dumps(b))
'
  "$MO" run "$ROOT/cmd/arvo/main.mo" replay gen "$REPLAY_REL/noreq.json" --out "$REPLAY_REL/noreq/replay-regression.mo"
  "$MO" check "$REPLAY_REL/noreq/replay-regression.mo"
  "$MO" test "$REPLAY_REL/noreq/replay-regression.mo"
)

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
