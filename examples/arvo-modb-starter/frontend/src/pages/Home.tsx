import { router, useForm } from "@inertiajs/react";
import { type FormEvent, useState } from "react";
import type { HomePageProps } from "../arvo.gen";
import { useArvoLive } from "../hooks/useArvoLive";

interface SearchHit {
  doc_id: string;
  score: number;
  matched_terms: string[];
}

export default function Home({
  auth,
  bills,
  total_due_cents,
  audit_feed,
  errors,
  flash,
}: HomePageProps) {
  const { connected } = useArvoLive("/live", true);
  const form = useForm({ name: "", category: "utilities", amount_cents: "" });
  const [searchQuery, setSearchQuery] = useState("");
  const [searchHits, setSearchHits] = useState<SearchHit[]>([]);
  const [actionError, setActionError] = useState<string | null>(null);

  function addBill(e: FormEvent) {
    e.preventDefault();
    form.post("/bills", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => form.reset(),
    });
  }

  async function runSearch(e: FormEvent) {
    e.preventDefault();
    setActionError(null);
    try {
      const res = await fetch(`/bills/search?q=${encodeURIComponent(searchQuery)}`, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) {
        setActionError(`Search failed (HTTP ${res.status}).`);
        return;
      }
      const data = (await res.json()) as { hits?: SearchHit[] };
      setSearchHits(data.hits ?? []);
    } catch {
      setActionError("Search failed (network error).");
    }
  }

  return (
    <main className="mx-auto max-w-2xl space-y-6 p-6 text-slate-900">
      <header className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold">{auth?.display_name ?? "Household"}</h1>
          <p className="text-sm text-slate-700">
            Due this paycheck: ${(total_due_cents / 100).toFixed(2)} · Live:{" "}
            {connected ? "connected" : "connecting"}
          </p>
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

      <form onSubmit={(e) => void runSearch(e)} className="flex gap-2">
        <input
          aria-label="Search bills"
          placeholder="Search bills via MoDB FTS..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="flex-1 rounded border border-slate-300 px-3 py-1.5 text-sm"
        />
        <button type="submit" className="rounded border border-slate-400 px-3 py-1.5 text-sm">
          Search
        </button>
      </form>
      {searchHits.length > 0 && (
        <p className="text-xs text-slate-700">
          FTS hits: {searchHits.map((h) => `${h.doc_id} (${h.matched_terms.join(",")})`).join("; ")}
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
              <span>${(b.amount_cents / 100).toFixed(2)}</span>
            </li>
          ))}
        </ul>
      </section>

      <form onSubmit={addBill} className="space-y-3 rounded border border-slate-300 p-4">
        <h2 className="font-medium">Add Bill</h2>
        <input
          aria-label="Bill name"
          placeholder="Bill name"
          value={form.data.name}
          onChange={(e) => form.setData("name", e.target.value)}
          className="w-full rounded border border-slate-400 px-3 py-2 text-sm"
        />
        {errors.name && <p role="alert" className="text-xs text-red-700">{errors.name}</p>}
        <input
          aria-label="Amount in cents"
          placeholder="Amount in cents"
          value={form.data.amount_cents}
          onChange={(e) => form.setData("amount_cents", e.target.value)}
          className="w-full rounded border border-slate-400 px-3 py-2 text-sm"
        />
        {errors.amount_cents && (
          <p role="alert" className="text-xs text-red-700">{errors.amount_cents}</p>
        )}
        <button type="submit" className="rounded bg-slate-900 px-4 py-2 text-sm text-white">
          Save Bill
        </button>
      </form>

      <section aria-labelledby="audit-heading" className="space-y-1">
        <h2 id="audit-heading" className="font-medium text-sm">
          Hash-Chained Audit Trail ({audit_feed.length})
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
