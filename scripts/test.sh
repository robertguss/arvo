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
"$MO" run "$ROOT/cmd/arvo/main.mo" statechart check --app examples/arvo-starter

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
