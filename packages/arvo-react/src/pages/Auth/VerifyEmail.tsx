import { useForm } from "@inertiajs/react";
import type { FormEvent, ReactElement } from "react";

export interface ArvoVerifyEmailProps {
  email?: string | null;
  verified?: boolean;
  resendAction?: string;
  continueHref?: string;
  flash?: { notice?: string | null; alert?: string | null };
}

export function VerifyEmailPage({
  email,
  verified = false,
  resendAction = "/auth/verify-email/resend",
  continueHref = "/",
  flash,
}: ArvoVerifyEmailProps): ReactElement {
  const form = useForm({ email: email ?? "" });

  function resend(e: FormEvent) {
    e.preventDefault();
    form.post(resendAction, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-md space-y-4 p-6 text-slate-900">
      <h1 className="text-2xl font-semibold">
        {verified ? "Email verified" : "Verify your email"}
      </h1>
      <p className="text-sm text-slate-600">
        {verified
          ? "Your email address is confirmed."
          : `Check your inbox${email ? ` (${email})` : ""} or open the Dev Mailbox at /__arvo/mailbox in development.`}
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

      {verified ? (
        <a
          href={continueHref}
          className="inline-block rounded bg-slate-900 px-4 py-2 text-sm font-medium text-white"
        >
          Continue
        </a>
      ) : (
        <form onSubmit={resend} aria-label="Resend verification email" className="space-y-3">
          <button
            type="submit"
            disabled={form.processing}
            className="rounded border border-slate-300 px-4 py-2 text-sm font-medium"
          >
            {form.processing ? "Sending..." : "Resend verification email"}
          </button>
        </form>
      )}
    </main>
  );
}

export default VerifyEmailPage;
