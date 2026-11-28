import { useForm } from "@inertiajs/react";
import type { FormEvent, ReactElement } from "react";

export interface ArvoRegisterProps {
  hint?: string;
  registerAction?: string;
  loginHref?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function RegisterPage({
  hint = "Use at least 12 characters.",
  registerAction = "/register",
  loginHref = "/login",
  flash,
  errors = {},
}: ArvoRegisterProps): ReactElement {
  const form = useForm({ email: "", display_name: "", password: "" });

  function submit(e: FormEvent) {
    e.preventDefault();
    form.post(registerAction, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-md space-y-5 p-6 text-slate-900">
      <header>
        <h1 className="text-2xl font-semibold">Create account</h1>
        {hint && <p className="mt-1 text-sm text-slate-600">{hint}</p>}
      </header>

      {flash?.alert && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {flash.alert}
        </p>
      )}

      <form onSubmit={submit} aria-label="Register account" className="space-y-4">
        <div>
          <label htmlFor="register-email" className="block text-sm font-medium text-slate-800">
            Email
          </label>
          <input
            id="register-email"
            type="email"
            autoComplete="email"
            aria-invalid={Boolean(errors.email)}
            aria-describedby={errors.email ? "register-email-error" : undefined}
            value={form.data.email}
            onChange={(e) => form.setData("email", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.email && (
            <p id="register-email-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.email}
            </p>
          )}
        </div>

        <div>
          <label htmlFor="register-name" className="block text-sm font-medium text-slate-800">
            Display name
          </label>
          <input
            id="register-name"
            type="text"
            autoComplete="name"
            aria-invalid={Boolean(errors.display_name)}
            aria-describedby={errors.display_name ? "register-name-error" : undefined}
            value={form.data.display_name}
            onChange={(e) => form.setData("display_name", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.display_name && (
            <p id="register-name-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.display_name}
            </p>
          )}
        </div>

        <div>
          <label htmlFor="register-password" className="block text-sm font-medium text-slate-800">
            Password
          </label>
          <input
            id="register-password"
            type="password"
            autoComplete="new-password"
            aria-invalid={Boolean(errors.password)}
            aria-describedby={errors.password ? "register-password-error" : undefined}
            value={form.data.password}
            onChange={(e) => form.setData("password", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.password && (
            <p id="register-password-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.password}
            </p>
          )}
        </div>

        <button
          type="submit"
          disabled={form.processing}
          className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
        >
          {form.processing ? "Creating account..." : "Create account"}
        </button>
      </form>

      {loginHref && (
        <p className="text-center text-sm text-slate-600">
          Already have an account?{" "}
          <a href={loginHref} className="font-medium underline">
            Sign in
          </a>
        </p>
      )}
    </main>
  );
}

export default RegisterPage;
