import { useForm } from "@inertiajs/react";
import type { FormEvent, ReactElement } from "react";

export interface ArvoResetPasswordProps {
  token: string;
  action?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function ResetPasswordPage({
  token,
  action = "/auth/reset-password",
  flash,
  errors = {},
}: ArvoResetPasswordProps): ReactElement {
  const form = useForm({ token, password: "", password_confirmation: "" });

  function submit(e: FormEvent) {
    e.preventDefault();
    form.post(action, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-md space-y-4 p-6 text-slate-900">
      <h1 className="text-2xl font-semibold">Choose a new password</h1>

      {flash?.alert && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {flash.alert}
        </p>
      )}

      <form onSubmit={submit} aria-label="Reset password" className="space-y-4">
        <div>
          <label htmlFor="reset-password" className="block text-sm font-medium text-slate-800">
            New password
          </label>
          <input
            id="reset-password"
            type="password"
            autoComplete="new-password"
            aria-invalid={Boolean(errors.password)}
            aria-describedby={errors.password ? "reset-password-error" : undefined}
            value={form.data.password}
            onChange={(e) => form.setData("password", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.password && (
            <p id="reset-password-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.password}
            </p>
          )}
        </div>

        <div>
          <label htmlFor="reset-password-confirm" className="block text-sm font-medium text-slate-800">
            Confirm password
          </label>
          <input
            id="reset-password-confirm"
            type="password"
            autoComplete="new-password"
            aria-invalid={Boolean(errors.password_confirmation)}
            aria-describedby={
              errors.password_confirmation ? "reset-password-confirm-error" : undefined
            }
            value={form.data.password_confirmation}
            onChange={(e) => form.setData("password_confirmation", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.password_confirmation && (
            <p id="reset-password-confirm-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.password_confirmation}
            </p>
          )}
        </div>

        <button
          type="submit"
          disabled={form.processing}
          className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
        >
          {form.processing ? "Saving password..." : "Update password"}
        </button>
      </form>
    </main>
  );
}

export default ResetPasswordPage;
