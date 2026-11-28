import { useForm } from "@inertiajs/react";
import { type FormEvent, type ReactElement, useState } from "react";

export interface ArvoMfaChallengeProps {
  action?: string;
  recoveryAction?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function MfaChallengePage({
  action = "/auth/mfa",
  recoveryAction = "/auth/mfa/recovery",
  flash,
  errors = {},
}: ArvoMfaChallengeProps): ReactElement {
  const [recoveryMode, setRecoveryMode] = useState(false);
  const totpForm = useForm({ code: "" });
  const recoveryForm = useForm({ recovery_code: "" });

  function submitTotp(e: FormEvent) {
    e.preventDefault();
    totpForm.post(action, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  function submitRecovery(e: FormEvent) {
    e.preventDefault();
    recoveryForm.post(recoveryAction, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  return (
    <main className="mx-auto max-w-md space-y-4 p-6 text-slate-900">
      <h1 className="text-2xl font-semibold">Two-factor authentication</h1>
      <p className="text-sm text-slate-600">
        {recoveryMode
          ? "Enter one of your single-use backup recovery codes."
          : "Enter the 6-digit verification code from your authenticator app."}
      </p>

      {flash?.alert && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {flash.alert}
        </p>
      )}

      {!recoveryMode ? (
        <form onSubmit={submitTotp} aria-label="Verify authenticator code" className="space-y-4">
          <div>
            <label htmlFor="mfa-code" className="block text-sm font-medium text-slate-800">
              6-digit code
            </label>
            <input
              id="mfa-code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={8}
              aria-invalid={Boolean(errors.code)}
              aria-describedby={errors.code ? "mfa-code-error" : undefined}
              value={totpForm.data.code}
              onChange={(e) => totpForm.setData("code", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono tracking-widest"
            />
            {errors.code && (
              <p id="mfa-code-error" role="alert" className="mt-1 text-xs text-red-700">
                {errors.code}
              </p>
            )}
          </div>
          <button
            type="submit"
            disabled={totpForm.processing}
            className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
          >
            {totpForm.processing ? "Verifying..." : "Verify code"}
          </button>
        </form>
      ) : (
        <form onSubmit={submitRecovery} aria-label="Verify recovery code" className="space-y-4">
          <div>
            <label htmlFor="recovery-code" className="block text-sm font-medium text-slate-800">
              Recovery code
            </label>
            <input
              id="recovery-code"
              type="text"
              autoComplete="off"
              aria-invalid={Boolean(errors.recovery_code)}
              aria-describedby={errors.recovery_code ? "recovery-code-error" : undefined}
              value={recoveryForm.data.recovery_code}
              onChange={(e) => recoveryForm.setData("recovery_code", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono"
            />
            {errors.recovery_code && (
              <p id="recovery-code-error" role="alert" className="mt-1 text-xs text-red-700">
                {errors.recovery_code}
              </p>
            )}
          </div>
          <button
            type="submit"
            disabled={recoveryForm.processing}
            className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
          >
            {recoveryForm.processing ? "Verifying..." : "Use recovery code"}
          </button>
        </form>
      )}

      <button
        type="button"
        onClick={() => setRecoveryMode((prev) => !prev)}
        className="text-sm text-slate-700 underline"
      >
        {recoveryMode ? "Use authenticator app code instead" : "Use a recovery code instead"}
      </button>
    </main>
  );
}

export default MfaChallengePage;
