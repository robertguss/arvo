import { type ReactElement, useMemo, useState } from "react";

export interface AuditTimelineEntry {
  seq: number;
  txid: number;
  principal: string;
  action: string;
  summary: string;
  at: string;
}

export interface ReplayCallItem {
  seq: number;
  audit_seq?: number | null;
  schema_version: number;
  principal: string;
  action: string;
  reason: string;
  at: string;
  outcome_kind: string;
  outcome_detail: string;
  world_id?: string | null;
}

export interface RowDiffItem {
  bucket: string;
  added: number;
  removed: number;
  modified: number;
}

export interface ReplayProposalItem {
  id: string;
  description: string;
  status: string;
  created_by: string;
  created_at: string;
  total_calls: number;
  excluded: number;
  unchanged: number;
  reply_changed: number;
  now_refused: number;
  now_invariant_blocked: number;
  bucket_diffs: RowDiffItem[];
}

export interface AuditTimelineProps {
  auditEntries?: AuditTimelineEntry[];
  replayCalls?: ReplayCallItem[];
  proposals?: ReplayProposalItem[];
  onPreviewUndo?: (callSeq: number) => void;
  onAcceptProposal?: (proposalId: string) => void;
  onDiscardProposal?: (proposalId: string) => void;
}

export function AuditTimeline({
  auditEntries = [],
  replayCalls = [],
  proposals = [],
  onPreviewUndo,
  onAcceptProposal,
  onDiscardProposal,
}: AuditTimelineProps): ReactElement {
  const [filterText, setFilterText] = useState("");
  const needle = filterText.trim().toLowerCase();

  const filteredAudits = useMemo(() => {
    if (!needle) return auditEntries;
    return auditEntries.filter(
      (e) =>
        e.principal.toLowerCase().includes(needle) ||
        e.action.toLowerCase().includes(needle) ||
        e.summary.toLowerCase().includes(needle),
    );
  }, [auditEntries, needle]);

  const filteredCalls = useMemo(() => {
    if (!needle) return replayCalls;
    return replayCalls.filter(
      (c) =>
        c.principal.toLowerCase().includes(needle) ||
        c.action.toLowerCase().includes(needle) ||
        c.reason.toLowerCase().includes(needle),
    );
  }, [replayCalls, needle]);

  return (
    <section className="space-y-6 text-slate-900">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold">Audit &amp; Time-Travel Timeline</h2>
          <p className="text-sm text-slate-600">
            Hash-chained mutations, replayable calls, and pending selective-undo proposals.
          </p>
        </div>
        <div>
          <label htmlFor="arvo-audit-filter" className="sr-only">
            Filter audit timeline
          </label>
          <input
            id="arvo-audit-filter"
            type="search"
            value={filterText}
            onChange={(e) => setFilterText(e.target.value)}
            placeholder="Filter principal or action..."
            className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm shadow-xs"
          />
        </div>
      </div>

      {proposals.length > 0 && (
        <div className="space-y-3">
          <h3 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Replay Proposals ({proposals.length})
          </h3>
          {proposals.map((prop) => {
            const pending = prop.status.toLowerCase() === "pending";
            return (
              <div
                key={prop.id}
                className="rounded-lg border border-slate-200 bg-white p-4 shadow-xs"
              >
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <div className="flex items-center gap-2">
                      <code className="text-xs font-semibold text-slate-800">{prop.id}</code>
                      <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700">
                        {prop.status}
                      </span>
                    </div>
                    <p className="mt-1 text-sm font-medium text-slate-900">{prop.description}</p>
                    <p className="text-xs text-slate-500">
                      by {prop.created_by} &middot; {prop.excluded} excluded / {prop.unchanged}{" "}
                      unchanged / {prop.reply_changed} changed / {prop.now_refused} refused
                    </p>
                  </div>
                  {pending && (onAcceptProposal || onDiscardProposal) && (
                    <div className="flex items-center gap-2">
                      {onAcceptProposal && (
                        <button
                          type="button"
                          onClick={() => onAcceptProposal(prop.id)}
                          className="rounded bg-emerald-600 px-3 py-1 text-xs font-medium text-white hover:bg-emerald-700"
                        >
                          Accept Undo
                        </button>
                      )}
                      {onDiscardProposal && (
                        <button
                          type="button"
                          onClick={() => onDiscardProposal(prop.id)}
                          className="rounded border border-slate-300 bg-white px-3 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Discard
                        </button>
                      )}
                    </div>
                  )}
                </div>
                {prop.bucket_diffs.length > 0 && (
                  <div className="mt-2 flex flex-wrap gap-2">
                    {prop.bucket_diffs.map((d) => (
                      <span
                        key={d.bucket}
                        className="rounded bg-slate-100 px-2 py-0.5 font-mono text-xs text-slate-700"
                      >
                        {d.bucket}: +{d.added} / ~{d.modified} / -{d.removed}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {filteredCalls.length > 0 && (
        <div className="space-y-2">
          <h3 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Replayable Calls ({filteredCalls.length})
          </h3>
          <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 bg-slate-50 text-xs text-slate-500 uppercase">
                <tr>
                  <th className="px-3 py-2">Seq</th>
                  <th className="px-3 py-2">Principal</th>
                  <th className="px-3 py-2">Action</th>
                  <th className="px-3 py-2">Outcome</th>
                  <th className="px-3 py-2">Reason</th>
                  {onPreviewUndo && <th className="px-3 py-2">Time-Travel</th>}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200">
                {filteredCalls.map((call) => (
                  <tr key={call.seq}>
                    <td className="px-3 py-2 font-mono text-xs">#{call.seq}</td>
                    <td className="px-3 py-2">{call.principal}</td>
                    <td className="px-3 py-2 font-mono text-xs">{call.action}</td>
                    <td className="px-3 py-2">
                      <span className="rounded bg-slate-100 px-2 py-0.5 text-xs">
                        {call.outcome_kind}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-slate-600">{call.reason || "-"}</td>
                    {onPreviewUndo && (
                      <td className="px-3 py-2">
                        <button
                          type="button"
                          onClick={() => onPreviewUndo(call.seq)}
                          className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Preview Undo
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <div className="space-y-2">
        <h3 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
          Audit Log ({filteredAudits.length})
        </h3>
        {filteredAudits.length === 0 ? (
          <p className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-500">
            No matching audit entries recorded.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 bg-slate-50 text-xs text-slate-500 uppercase">
                <tr>
                  <th className="px-3 py-2">Seq / Tx</th>
                  <th className="px-3 py-2">Principal</th>
                  <th className="px-3 py-2">Action</th>
                  <th className="px-3 py-2">Summary</th>
                  <th className="px-3 py-2">At</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200">
                {filteredAudits.map((entry) => (
                  <tr key={`${entry.seq}-${entry.txid}`}>
                    <td className="px-3 py-2 font-mono text-xs">
                      #{entry.seq} (tx {entry.txid})
                    </td>
                    <td className="px-3 py-2">{entry.principal}</td>
                    <td className="px-3 py-2 font-mono text-xs">{entry.action}</td>
                    <td className="px-3 py-2">{entry.summary}</td>
                    <td className="px-3 py-2 text-xs text-slate-500">{entry.at}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </section>
  );
}
