import "@testing-library/jest-dom/vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AuditTimeline } from "../components/AuditTimeline";

describe("AuditTimeline", () => {
  it("filters entries and triggers selective undo and proposal action callbacks", async () => {
    const user = userEvent.setup();
    const onPreviewUndo = vi.fn();
    const onAcceptProposal = vi.fn();
    const onDiscardProposal = vi.fn();

    render(
      <AuditTimeline
        auditEntries={[
          {
            seq: 1,
            txid: 1,
            principal: "ada@household.local",
            action: "bill.create",
            summary: "Created Water",
            at: "2026-11-28T07:00:00Z",
          },
          {
            seq: 2,
            txid: 2,
            principal: "grace@household.local",
            action: "bill.pay",
            summary: "Paid Electric",
            at: "2026-11-28T07:05:00Z",
          },
        ]}
        replayCalls={[
          {
            seq: 2,
            audit_seq: 2,
            schema_version: 1,
            principal: "grace@household.local",
            action: "bills.pay",
            reason: "Paid on mobile",
            at: "2026-11-28T07:05:00Z",
            outcome_kind: "ok",
            outcome_detail: "{}",
          },
        ]}
        proposals={[
          {
            id: "undo_2",
            description: "Revert accidental bill payment",
            status: "pending",
            created_by: "ada@household.local",
            created_at: "2026-11-28T07:10:00Z",
            total_calls: 2,
            excluded: 1,
            unchanged: 1,
            reply_changed: 0,
            now_refused: 0,
            now_invariant_blocked: 0,
            bucket_diffs: [{ bucket: "bills", added: 0, removed: 0, modified: 1 }],
          },
        ]}
        onPreviewUndo={onPreviewUndo}
        onAcceptProposal={onAcceptProposal}
        onDiscardProposal={onDiscardProposal}
      />,
    );

    expect(screen.getByText("Created Water")).toBeInTheDocument();
    expect(screen.getByText("bills: +0 / ~1 / -0")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Preview Undo" }));
    expect(onPreviewUndo).toHaveBeenCalledWith(2);

    await user.click(screen.getByRole("button", { name: "Accept Undo" }));
    expect(onAcceptProposal).toHaveBeenCalledWith("undo_2");

    await user.click(screen.getByRole("button", { name: "Discard" }));
    expect(onDiscardProposal).toHaveBeenCalledWith("undo_2");

    await user.type(screen.getByLabelText("Filter audit timeline"), "grace");
    expect(screen.queryByText("Created Water")).not.toBeInTheDocument();
    expect(screen.getByText("Paid Electric")).toBeInTheDocument();
  });
});
