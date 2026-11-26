import { router, useForm } from "@inertiajs/react";
import type { FormEvent } from "react";
import type { HomePageProps } from "../arvo.gen";

export default function Home({
  auth,
  bills,
  total_due_cents,
  audit_feed,
  errors,
  flash,
}: HomePageProps) {
  const form = useForm({ name: "", category: "utilities", amount_cents: "" });

  function addBill(e: FormEvent) {
    e.preventDefault();
    form.post("/bills", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => form.reset(),
    });
  }

  return (
    <main className="mx-auto max-w-xl p-6 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">{auth?.display_name ?? ""}</h1>
          <p className="text-sm text-slate-600">
            Due this paycheck: ${(total_due_cents / 100).toFixed(2)}
          </p>
        </div>
        <button
          type="button"
          onClick={() => router.post("/logout")}
          className="rounded border px-3 py-1 text-sm"
        >
          Sign out
        </button>
      </header>

      {flash.notice && (
        <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-800">{flash.notice}</p>
      )}
      {flash.alert && <p className="rounded bg-red-50 p-3 text-sm text-red-800">{flash.alert}</p>}

      <section className="space-y-2">
        <h2 className="font-medium">Paycheck Bills</h2>
        <ul className="divide-y rounded border">
          {bills.map((b) => (
            <li key={b.id} className="flex items-center justify-between gap-3 p-3 text-sm">
              <span>
                {b.name} <span className="text-slate-500">({b.status})</span>
              </span>
              <div className="flex items-center gap-3">
                <span>${(b.amount_cents / 100).toFixed(2)}</span>
                {b.status === "due" && (
                  <button
                    type="button"
                    onClick={() =>
                      router.post(`/bills/${b.id}/pay`, {
                        expected_version: b.version,
                        reason: null,
                      })
                    }
                    className="rounded border px-2 py-1 text-xs font-medium"
                  >
                    Mark in flight
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      <form onSubmit={addBill} className="space-y-3 rounded border p-4">
        <h2 className="font-medium">Add Bill</h2>
        <div>
          <label htmlFor="bill-name" className="block text-xs font-medium text-slate-700">
            Bill name
          </label>
          <input
            id="bill-name"
            placeholder="Bill name"
            value={form.data.name}
            onChange={(e) => form.setData("name", e.target.value)}
            className="mt-1 w-full rounded border px-3 py-2 text-sm"
          />
          {errors.name && <p className="mt-1 text-xs text-red-600">{errors.name}</p>}
        </div>
        <div>
          <label htmlFor="bill-category" className="block text-xs font-medium text-slate-700">
            Category
          </label>
          <select
            id="bill-category"
            value={form.data.category}
            onChange={(e) => form.setData("category", e.target.value)}
            className="mt-1 w-full rounded border px-3 py-2 text-sm"
          >
            <option value="utilities">utilities</option>
            <option value="housing">housing</option>
            <option value="groceries">groceries</option>
            <option value="card">card</option>
          </select>
          {errors.category && <p className="mt-1 text-xs text-red-600">{errors.category}</p>}
        </div>
        <div>
          <label htmlFor="bill-amount" className="block text-xs font-medium text-slate-700">
            Amount in cents
          </label>
          <input
            id="bill-amount"
            placeholder="Amount in cents (e.g. 7500)"
            value={form.data.amount_cents}
            onChange={(e) => form.setData("amount_cents", e.target.value)}
            className="mt-1 w-full rounded border px-3 py-2 text-sm"
          />
          {errors.amount_cents && (
            <p className="mt-1 text-xs text-red-600">{errors.amount_cents}</p>
          )}
        </div>
        <button type="submit" className="rounded bg-slate-900 px-4 py-2 text-sm text-white">
          Save Bill
        </button>
      </form>

      <section className="space-y-1">
        <h2 className="font-medium text-sm">Recent Audit Trail ({audit_feed.length})</h2>
        {audit_feed.slice(0, 5).map((ev) => (
          <p key={ev.id} className="text-xs text-slate-500">
            {ev.actor_name}: {ev.action} ({ev.entity_table}/{ev.entity_id})
          </p>
        ))}
      </section>
    </main>
  );
}
