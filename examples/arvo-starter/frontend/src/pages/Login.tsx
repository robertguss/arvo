import { useForm } from "@inertiajs/react";
import type { FormEvent } from "react";
import type { LoginPageProps } from "../arvo.gen";

export default function Login({ allowlist_hint, errors, flash }: LoginPageProps) {
  const form = useForm({ email: "", password: "" });

  function submit(e: FormEvent) {
    e.preventDefault();
    form.post("/login", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-sm p-6 text-slate-900">
      <h1 className="text-2xl font-semibold">Sign in to Arvo</h1>
      <p className="mt-1 text-sm text-slate-700">{allowlist_hint}</p>
      {flash.alert && (
        <p role="alert" className="mt-3 rounded bg-red-50 p-2 text-sm text-red-800">
          {flash.alert}
        </p>
      )}
      <form onSubmit={submit} aria-label="Sign in" className="mt-6 space-y-4">
        <div>
          <label htmlFor="email" className="block text-sm font-medium text-slate-800">
            Email
          </label>
          <input
            id="email"
            type="email"
            autoComplete="email"
            aria-invalid={Boolean(errors.email)}
            aria-describedby={errors.email ? "email-error" : undefined}
            value={form.data.email}
            onChange={(e) => form.setData("email", e.target.value)}
            className="mt-1 w-full rounded border border-slate-400 px-3 py-2"
          />
          {errors.email && (
            <p id="email-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.email}
            </p>
          )}
        </div>
        <div>
          <label htmlFor="password" className="block text-sm font-medium text-slate-800">
            Password
          </label>
          <input
            id="password"
            type="password"
            autoComplete="current-password"
            aria-invalid={Boolean(errors.password)}
            aria-describedby={errors.password ? "password-error" : undefined}
            value={form.data.password}
            onChange={(e) => form.setData("password", e.target.value)}
            className="mt-1 w-full rounded border border-slate-400 px-3 py-2"
          />
          {errors.password && (
            <p id="password-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.password}
            </p>
          )}
        </div>
        <button
          type="submit"
          disabled={form.processing}
          className="w-full rounded bg-slate-900 py-2 font-medium text-white"
        >
          Sign in
        </button>
      </form>
    </main>
  );
}
