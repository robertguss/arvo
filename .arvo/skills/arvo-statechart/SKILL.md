---
name: arvo-statechart
description: State-machine verification workflow when changing Arvo.Jobs, Arvo.Session, workflows, or concurrency transitions. Runs Arvo.Statechart exploration, real-code replay, broken-variant proofs, and sync-commit checks.
---

# Formal Statechart & Replay Verification

Activate whenever modifying `lib/arvo/jobs.mo`, `lib/arvo/session.mo`, job workers, session lifecycle, or concurrent state transitions.

## Protocol

1. **Explore Models & Check Code Sync:**
   - Run `arvo statechart check` against the repository / app:
     ```bash
     arvo statechart check --app examples/arvo-starter
     ```
   - Inspect generated Mermaid `stateDiagram-v2` charts and JSON report under `examples/arvo-starter/.arvo/dossier/statecharts/` (`jobs.mmd`, `session.mmd`, `report.json`).
   - Run the Mo test + mutant gate directly on `lib/arvo/statechart.mo` and target state modules:
     ```bash
     mo check lib/arvo/statechart.mo
     mo test --mutants --jobs 4 lib/arvo/statechart.mo
     ```

2. **Prove Invariants Can Fail on Scratch Broken Variants:**
   - Every modeled invariant MUST fail on a concrete broken transition (e.g., double-claiming a running job, unbounded retry above `max_attempts`, accepting a revoked or expired session) and emit a shortest counterexample path in plain user words (`breaks` / `mayBreak` Mermaid styling).
   - Verify `broken_caught: true` appears in `statecharts/report.json`.

3. **Replay Counterexamples Against Real Mo Code:**
   - Ensure every explored transition and broken counterexample path replays against real `Arvo.Jobs` (`claim_next`, `complete`, `fail_or_retry`, `requeue_stale_running`) and `Arvo.Session` (`create`, `load`, `rotate`, `revoke`, `revoke_all_for_member`, `prune_expired`) APIs backed by real `Sqlite` state.

4. **Update `sync_commit` Safely:**
   - Never bump `sync_commit` in `lib/arvo/statechart.mo` (and `cmd/arvo/statechart-cmd.mo`) blindly to silence a `stale` warning.
   - First inspect `git diff <old_sync_commit>..HEAD -- <covered_files>`, verify model-to-code transition fidelity, update the `ChartSpec` transitions/invariants if code behavior changed, verify replay tests pass, and only then update `sync_commit` to the covered commit SHA.
