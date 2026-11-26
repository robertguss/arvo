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

echo "==> Checking Arvo.Statechart models, replay, and sync commits"
# Statechart models check repository-level lib/arvo/{jobs,session}.mo cleanly from repo root.
# In linked git worktrees (.git is a pointer file outside $ROOT, blocked by Landlock), bridge real host git diff.
if [ -f "$ROOT/.git" ]; then
  jobs_diff="$(git -C "$ROOT" diff --name-only 623f404124b5bf27f13a595a0dc174a997f49dee -- lib/arvo/jobs.mo)"
  sess_diff="$(git -C "$ROOT" diff --name-only 4ea7e818b88a38fe86021a500fd866e0aa392557 -- lib/arvo/session.mo)"
  sync_diff="$(printf '%s\n%s\n' "$jobs_diff" "$sess_diff" | sed '/^$/d' | sort -u)"
  ARVO_GIT_DIFF_FILES="$sync_diff" "$MO" run "$ROOT/cmd/arvo/main.mo" statechart check
else
  "$MO" run "$ROOT/cmd/arvo/main.mo" statechart check
fi

echo "==> Checking arvo replay capture/gen compiles and executes under mo check/test"
mkdir -p "$ROOT/.arvo/tmp"
REPLAY_REL="$(cd "$ROOT" && mktemp -d ".arvo/tmp/arvo-replay-smoke.XXXXXX")"
REPLAY_TMP="$ROOT/$REPLAY_REL"
trap 'rm -rf "$REPLAY_TMP"' EXIT
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

echo "==> Running all 9 --strength intent suites (must score 1.0 with 0 survived)"
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

for mod in session csrf auth inertia migrations jobs audit changeset; do
  check_strength_suite "$ROOT/strength/arvo_${mod}" "$ROOT/lib/arvo/${mod}.mo"
done
check_strength_suite "$ROOT/examples/arvo-starter/strength/routes" "$ROOT/examples/arvo-starter/routes.mo"

echo "All Arvo tests, statecharts, strength suites, and starter checks passed."
