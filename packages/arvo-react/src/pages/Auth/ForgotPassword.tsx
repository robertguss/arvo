import { useForm } from "@inertiajs/react";
import type { FormEvent, ReactElement } from "react";

export interface ArvoForgotPasswordProps {
  action?: string;
  loginHref?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function ForgotPasswordPage({
  action = "/auth/forgot-password",
  loginHref = "/login",
  flash,
  errors = {},
}: ArvoForgotPasswordProps): ReactElement {
  const form = useForm({ email: "" });

  function submit(e: FormEvent) {
    e.preventDefault();
    form.post(action, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-md space-y-4 p-6 text-slate-900">
      <h1 className="text-2xl font-semibold">Reset your password</h1>
      <p className="text-sm text-slate-600">
        Enter your account email and we will send a single-use password reset link.
      </p>

      {flash?.notice && (
        <p role="status" className="rounded bg-emerald-50 p-3 text-sm text-emerald-900">
          {flash.notice}
        </p>
      )}
      {flash?.alert && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {flash.alert}
        </p>
      )}

      <form onSubmit={submit} aria-label="Forgot password" className="space-y-4">
        <div>
          <label htmlFor="forgot-email" className="block text-sm font-medium text-slate-800">
            Email
          </label>
          <input
            id="forgot-email"
            type="email"
            autoComplete="email"
            aria-invalid={Boolean(errors.email)}
            aria-describedby={errors.email ? "forgot-email-error" : undefined}
            value={form.data.email}
            onChange={(e) => form.setData("email", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.email && (
            <p id="forgot-email-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.email}
            </p>
          )}
        </div>

        <button
          type="submit"
          disabled={form.processing}
          className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
        >
          {form.processing ? "Sending..." : "Send reset link"}
        </button>
      </form>

      <p className="text-center text-sm text-slate-600">
        <a href={loginHref} className="underline">
          Back to sign in
        </a>
      </p>
    </main>
  );
}

export default ForgotPasswordPage;
