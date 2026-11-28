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
if [ "${MOBROWSE_PATH+x}" = x ] && { [ ! -f "$MOBROWSE_PATH/mo.toml" ] || [ ! -d "$MOBROWSE_PATH/src" ]; }; then
  echo "ERROR: MOBROWSE_PATH must point to a MoBrowse checkout containing mo.toml and src: '$MOBROWSE_PATH'" >&2
  exit 1
fi

echo "==> Checking core Arvo modules are SQLite-, MoDB-, and MoBrowse-free"
if grep -rnE "Sqlite|Modb|Mobrowse" "$ROOT"/lib/arvo/*.mo; then
  echo "ERROR: top-level core module references Sqlite, Modb, or Mobrowse!" >&2
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
(
  cd "$ROOT"
  "$MO" run "$ROOT/cmd/arvo/main.mo" feature --app examples/arvo-starter --validate
  "$MO" run "$ROOT/cmd/arvo/main.mo" contracts --app examples/arvo-starter --check
)

echo "==> Checking Arvo.Testing.Statechart models, replay, and sync commits"
# Statechart models check repository-level SQLite/core session modules cleanly from repo root.
# In linked git worktrees (.git is a pointer file outside $ROOT, blocked by Landlock), bridge real host git diff.
(
  cd "$ROOT"
  if [ -f .git ]; then
    sync_diff="$(
      git diff --name-only dbaaf0311d379d828af75ab08b6fa2b61ce9e839 -- lib/arvo/sqlite/jobs.mo
      git diff --name-only 9321ddbfd5b20abf8bd62d4e04d8f4a7129769ed -- lib/arvo/sqlite/sessions.mo lib/arvo/session.mo
      git diff --name-only 20e56108473c06e7b1018bccd54348020a85f276 -- lib/arvo/auth.mo lib/arvo/totp.mo lib/arvo/sqlite/auth-store.mo
    )"
    export ARVO_GIT_DIFF_FILES="$sync_diff"
  fi
  "$MO" run "$ROOT/cmd/arvo/main.mo" statechart check
)

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

echo "==> Running all 14 --strength intent suites (must score 1.0 with 0 survived)"
check_strength_suite() {
  local sdir="$1"
  local target="$2"
  echo "  -> $sdir vs $target"
  local out
  out="$("$MO" test --jobs 4 --json --strength "$sdir" "$target")"
  printf '%s\n' "$out" | jq -e -s '
    (map(select(.record == "strength")) | length) == 1 and
    (map(select(.record == "strength")) | all(.original == "passed" and (.counts.invalid + .counts.changes_intent + .counts.defect) == 0)) and
    (map(select(.record == "strength_summary")) | length) == 1 and
    (map(select(.record == "strength_summary")) | all(.original == "passed" and .scored > 0 and .survived == 0 and .kill_rate == 1))
  ' > /dev/null
}

for mod in session csrf auth inertia changeset keyring rate-limit totp policy; do
  dir_mod="${mod//-/_}"
  check_strength_suite "$ROOT/strength/arvo_${dir_mod}" "$ROOT/lib/arvo/${mod}.mo"
done
check_strength_suite "$ROOT/strength/arvo_auth_v2" "$ROOT/lib/arvo/auth.mo"
for mod in migrations jobs audit; do
  check_strength_suite "$ROOT/strength/arvo_${mod}" "$ROOT/lib/arvo/sqlite/${mod}.mo"
done
check_strength_suite "$ROOT/examples/arvo-starter/strength/routes" "$ROOT/examples/arvo-starter/routes.mo"

run_modb_suite() {
  local arvo_root="$1"
  echo "==> Checking and testing Arvo MoDB adapter modules ($MO)"
  for f in "$arvo_root"/packages/arvo-modb/lib/arvo/modb/*.mo; do
    echo "  -> $f"
    "$MO" check "$f"
    "$MO" test "$f"
  done

  echo "==> Checking and testing MoDB backup runner ($MO)"
  "$MO" check "$arvo_root/packages/arvo-modb/cmd/backup/main.mo"
  "$MO" test "$arvo_root/packages/arvo-modb/cmd/backup/main.mo"

  echo "==> Checking and testing examples/arvo-modb-starter via mo.toml path dependencies"
  "$MO" check "$arvo_root/examples/arvo-modb-starter/main.mo"
  "$MO" test "$arvo_root/examples/arvo-modb-starter/main.mo"
  (
    app_parent="$(cd "$arvo_root/.." && pwd)"
    app_base="$(basename "$arvo_root")"
    cd "$app_parent"
    "$MO" run "$arvo_root/cmd/arvo/main.mo" feature --app "$app_base/examples/arvo-modb-starter" --validate
    "$MO" run "$arvo_root/cmd/arvo/main.mo" contracts --app "$app_base/examples/arvo-modb-starter" --check
  )
}

run_mobrowse_suite() {
  local arvo_root="$1"
  local mobrowse_root
  mobrowse_root="$(cd "$arvo_root/../mobrowse" && pwd)"

  echo "==> Checking and testing Arvo MoBrowse E2E + SEO package ($MO)"
  "$MO" check "$arvo_root/packages/arvo-mobrowse/lib/arvo/mobrowse/e2e.mo"
  "$MO" test "$arvo_root/packages/arvo-mobrowse/lib/arvo/mobrowse/e2e.mo"
  "$MO" check "$arvo_root/packages/arvo-mobrowse/tests/e2e-suite.mo"
  "$MO" test "$arvo_root/packages/arvo-mobrowse/tests/e2e-suite.mo"

  local smoke_tmp
  smoke_tmp="$(mktemp -d)"
  CLEANUP_DIRS+=("$smoke_tmp")

  echo "==> Scaffolding and testing \`arvo new --mobrowse\` (SQLite + Full Auth)"
  (
    cd "$smoke_tmp"
    "$MO" run "$arvo_root/cmd/arvo/main.mo" new mobrowse-smoke \
      --db sqlite --auth full --mobrowse \
      --dir mobrowse-smoke \
      --arvo-path "$arvo_root" \
      --mobrowse-path "$mobrowse_root"
  )
  "$MO" check "$smoke_tmp/mobrowse-smoke/main.mo"
  "$MO" test "$smoke_tmp/mobrowse-smoke/main.mo"
  "$MO" check "$smoke_tmp/mobrowse-smoke/test-mobrowse-e2e.mo"
  "$MO" test "$smoke_tmp/mobrowse-smoke/test-mobrowse-e2e.mo"

  if [ -f "$arvo_root/../modb/mo.toml" ]; then
    echo "==> Scaffolding and testing \`arvo new --mobrowse\` (MoDB + Allowlist Auth)"
    (
      cd "$smoke_tmp"
      "$MO" run "$arvo_root/cmd/arvo/main.mo" new mobrowse-modb-smoke \
        --db modb --auth allowlist --mobrowse \
        --dir mobrowse-modb-smoke \
        --arvo-path "$arvo_root" \
        --modb-path "$arvo_root/../modb" \
        --mobrowse-path "$mobrowse_root"
    )
    "$MO" check "$smoke_tmp/mobrowse-modb-smoke/main.mo"
    "$MO" test "$smoke_tmp/mobrowse-modb-smoke/main.mo"
    "$MO" check "$smoke_tmp/mobrowse-modb-smoke/test-mobrowse-e2e.mo"
    "$MO" test "$smoke_tmp/mobrowse-modb-smoke/test-mobrowse-e2e.mo"
  fi
}

MODB_SRC=""
MOBROWSE_SRC=""
NEED_STAGE=0

if [ "${MODB_PATH+x}" = x ]; then
  MODB_SRC="$MODB_PATH"
  NEED_STAGE=1
elif [ -d "$ROOT/../modb" ]; then
  MODB_SRC="$ROOT/../modb"
fi

if [ "${MOBROWSE_PATH+x}" = x ]; then
  MOBROWSE_SRC="$MOBROWSE_PATH"
  NEED_STAGE=1
elif [ -d "$ROOT/../mobrowse" ]; then
  MOBROWSE_SRC="$ROOT/../mobrowse"
fi

TARGET_ARVO="$ROOT"
if [ "$NEED_STAGE" = "1" ]; then
  TMP="$(mktemp -d)"
  CLEANUP_DIRS+=("$TMP")
  mkdir -p "$TMP/arvo"
  tar -C "$ROOT" --exclude=.git --exclude=node_modules --exclude=.arvo --exclude=target -cf - . | tar -C "$TMP/arvo" -xf -
  if [ -n "$MODB_SRC" ]; then
    mkdir -p "$TMP/modb"
    cp -a "$MODB_SRC/mo.toml" "$MODB_SRC/src" "$TMP/modb/"
  fi
  if [ -n "$MOBROWSE_SRC" ]; then
    mkdir -p "$TMP/mobrowse"
    cp -a "$MOBROWSE_SRC/mo.toml" "$MOBROWSE_SRC/src" "$TMP/mobrowse/"
  fi
  TARGET_ARVO="$TMP/arvo"
fi

if [ -n "$MODB_SRC" ]; then
  run_modb_suite "$TARGET_ARVO"
else
  echo "==> Skipping optional MoDB tests (sibling ../modb not found; set MODB_PATH=/path/to/modb to run)"
fi

if [ -n "$MOBROWSE_SRC" ]; then
  run_mobrowse_suite "$TARGET_ARVO"
else
  echo "==> Skipping optional MoBrowse tests (sibling ../mobrowse not found; set MOBROWSE_PATH=/path/to/mobrowse to run)"
fi

echo "All Arvo tests passed."
