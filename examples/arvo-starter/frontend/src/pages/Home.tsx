import { router, useForm } from "@inertiajs/react";
import { type FormEvent, useState } from "react";
import type { HomePageProps } from "../arvo.gen";
import { formatCents, readCsrfToken } from "../lib/format";

export default function Home({
  auth,
  bills,
  total_due_cents,
  audit_feed,
  errors,
  flash,
}: HomePageProps) {
  const form = useForm({ name: "", category: "utilities", amount_cents: "" });
  const [payingId, setPayingId] = useState<number | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  function addBill(e: FormEvent) {
    e.preventDefault();
    setActionError(null);
    form.post("/bills", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => form.reset(),
    });
  }

  async function markPaid(billId: number, expectedVersion: number) {
    setActionError(null);
    setPayingId(billId);
    try {
      const token = readCsrfToken(typeof document !== "undefined" ? document.cookie : "");
      const res = await fetch(`/bills/${billId}/pay`, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-XSRF-TOKEN": token,
        },
        body: JSON.stringify({ expected_version: expectedVersion, reason: null }),
      });
      if (!res.ok) {
        setActionError(
          res.status === 409
            ? "Bill was updated by someone else; please reload."
            : `Could not mark bill paid (HTTP ${res.status}).`,
        );
        return;
      }
      router.reload();
    } catch {
      setActionError("Could not mark bill paid (network error).");
    } finally {
      setPayingId(null);
    }
  }

  return (
    <main className="mx-auto max-w-xl p-6 space-y-6 text-slate-900">
      <header className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold">{auth?.display_name ?? "Household"}</h1>
          <p className="text-sm text-slate-700">Due this paycheck: {formatCents(total_due_cents)}</p>
        </div>
        <button
          type="button"
          onClick={() => router.post("/logout")}
          className="rounded border border-slate-400 px-3 py-1 text-sm font-medium text-slate-900"
        >
          Sign out
        </button>
      </header>

      {flash.notice && (
        <p role="status" className="rounded bg-emerald-50 p-3 text-sm text-emerald-900">
          {flash.notice}
        </p>
      )}
      {flash.alert && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {flash.alert}
        </p>
      )}
      {actionError && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {actionError}
        </p>
      )}

      <section aria-labelledby="bills-heading" className="space-y-2">
        <h2 id="bills-heading" className="font-medium">
          Paycheck Bills
        </h2>
        <ul className="divide-y rounded border border-slate-300">
          {bills.map((b) => (
            <li key={b.id} className="flex items-center justify-between gap-3 p-3 text-sm">
              <span>
                {b.name} <span className="text-slate-700">({b.status})</span>
              </span>
              <div className="flex items-center gap-3">
                <span>{formatCents(b.amount_cents)}</span>
                {b.status === "due" && (
                  <button
                    type="button"
                    disabled={payingId === b.id}
                    aria-label={`Mark in flight ${b.name}`}
                    onClick={() => void markPaid(b.id, b.version)}
                    className="rounded border border-slate-400 px-2 py-1 text-xs font-medium text-slate-900"
                  >
                    Mark in flight
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      <form
        onSubmit={addBill}
        aria-labelledby="add-bill-heading"
        className="space-y-3 rounded border border-slate-300 p-4"
      >
        <h2 id="add-bill-heading" className="font-medium">
          Add Bill
        </h2>
        <div>
          <label htmlFor="bill-name" className="block text-xs font-medium text-slate-800">
            Bill name
          </label>
          <input
            id="bill-name"
            aria-invalid={Boolean(errors.name)}
            aria-describedby={errors.name ? "bill-name-error" : undefined}
            placeholder="Bill name"
            value={form.data.name}
            onChange={(e) => form.setData("name", e.target.value)}
            className="mt-1 w-full rounded border border-slate-400 px-3 py-2 text-sm"
          />
          {errors.name && (
            <p id="bill-name-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.name}
            </p>
          )}
        </div>
        <div>
          <label htmlFor="bill-category" className="block text-xs font-medium text-slate-800">
            Category
          </label>
          <select
            id="bill-category"
            aria-invalid={Boolean(errors.category)}
            value={form.data.category}
            onChange={(e) => form.setData("category", e.target.value)}
            className="mt-1 w-full rounded border border-slate-400 px-3 py-2 text-sm"
          >
            <option value="utilities">utilities</option>
            <option value="housing">housing</option>
            <option value="groceries">groceries</option>
            <option value="card">card</option>
          </select>
          {errors.category && (
            <p role="alert" className="mt-1 text-xs text-red-700">
              {errors.category}
            </p>
          )}
        </div>
        <div>
          <label htmlFor="bill-amount" className="block text-xs font-medium text-slate-800">
            Amount in cents
          </label>
          <input
            id="bill-amount"
            aria-invalid={Boolean(errors.amount_cents)}
            aria-describedby={errors.amount_cents ? "bill-amount-error" : undefined}
            placeholder="Amount in cents (e.g. 7500)"
            value={form.data.amount_cents}
            onChange={(e) => form.setData("amount_cents", e.target.value)}
            className="mt-1 w-full rounded border border-slate-400 px-3 py-2 text-sm"
          />
          {errors.amount_cents && (
            <p id="bill-amount-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.amount_cents}
            </p>
          )}
        </div>
        <button type="submit" className="rounded bg-slate-900 px-4 py-2 text-sm font-medium text-white">
          Save Bill
        </button>
      </form>

      <section aria-labelledby="audit-heading" className="space-y-1">
        <h2 id="audit-heading" className="font-medium text-sm">
          Recent Audit Trail ({audit_feed.length})
        </h2>
        {audit_feed.slice(0, 5).map((ev) => (
          <p key={ev.id} className="text-xs text-slate-700">
            {ev.actor_name}: {ev.action} ({ev.entity_table}/{ev.entity_id})
          </p>
        ))}
      </section>
    </main>
  );
}
