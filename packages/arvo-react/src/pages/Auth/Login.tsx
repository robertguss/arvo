import { useForm } from "@inertiajs/react";
import { type FormEvent, type ReactElement, useState } from "react";
import {
  prepareRequestOptions,
  type ServerRequestOptions,
  serializeAuthenticationCredential,
  supportsPasskeys,
} from "../../lib/webauthn";

export interface OidcProviderLink {
  id: string;
  label: string;
  href: string;
}

export interface ArvoLoginProps {
  hint?: string;
  loginAction?: string;
  registerHref?: string;
  forgotPasswordHref?: string;
  magicLinkAction?: string;
  passkeyBeginAction?: string;
  passkeyFinishAction?: string;
  oidcProviders?: OidcProviderLink[];
  csrfToken?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function LoginPage({
  hint,
  loginAction = "/login",
  registerHref = "/register",
  forgotPasswordHref = "/auth/forgot-password",
  magicLinkAction,
  passkeyBeginAction,
  passkeyFinishAction,
  oidcProviders = [],
  csrfToken,
  flash,
  errors = {},
}: ArvoLoginProps): ReactElement {
  const form = useForm({ email: "", password: "" });
  const magicForm = useForm({ email: "" });
  const [passkeyStatus, setPasskeyStatus] = useState<string | null>(null);
  const [passkeyError, setPasskeyError] = useState<string | null>(null);
  const [passkeyBusy, setPasskeyBusy] = useState(false);

  function submitPassword(e: FormEvent) {
    e.preventDefault();
    form.post(loginAction, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  function submitMagicLink(e: FormEvent) {
    e.preventDefault();
    if (!magicLinkAction) return;
    magicForm.post(magicLinkAction, {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  }

  async function signInWithPasskey() {
    if (!passkeyBeginAction || !passkeyFinishAction) return;
    setPasskeyError(null);
    setPasskeyStatus(null);
    if (!supportsPasskeys()) {
      setPasskeyError("Passkeys are not supported by this browser.");
      return;
    }
    setPasskeyBusy(true);
    try {
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
      };
      if (csrfToken) headers["X-XSRF-TOKEN"] = csrfToken;

      const beginRes = await fetch(passkeyBeginAction, {
        method: "POST",
        credentials: "same-origin",
        headers,
        body: JSON.stringify({ email: form.data.email || null }),
      });
      if (!beginRes.ok) {
        setPasskeyError(`Passkey start failed (HTTP ${beginRes.status}).`);
        return;
      }
      const reqOpts = (await beginRes.json()) as ServerRequestOptions;
      const cred = (await navigator.credentials.get({
        publicKey: prepareRequestOptions(reqOpts),
      })) as PublicKeyCredential | null;
      if (!cred) {
        setPasskeyError("Passkey prompt was cancelled.");
        return;
      }
      const finishRes = await fetch(passkeyFinishAction, {
        method: "POST",
        credentials: "same-origin",
        headers,
        body: JSON.stringify(serializeAuthenticationCredential(cred)),
      });
      if (!finishRes.ok) {
        setPasskeyError(`Passkey verification failed (HTTP ${finishRes.status}).`);
        return;
      }
      setPasskeyStatus("Passkey verified. Redirecting...");
      if (typeof window !== "undefined") {
        window.location.assign("/");
      }
    } catch {
      setPasskeyError("Passkey authentication failed.");
    } finally {
      setPasskeyBusy(false);
    }
  }

  return (
    <main className="mx-auto max-w-md space-y-5 p-6 text-slate-900">
      <header>
        <h1 className="text-2xl font-semibold">Sign in</h1>
        {hint && <p className="mt-1 text-sm text-slate-600">{hint}</p>}
      </header>

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
      {passkeyStatus && (
        <p role="status" className="rounded bg-emerald-50 p-3 text-sm text-emerald-900">
          {passkeyStatus}
        </p>
      )}
      {passkeyError && (
        <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
          {passkeyError}
        </p>
      )}

      <form onSubmit={submitPassword} aria-label="Password sign in" className="space-y-4">
        <div>
          <label htmlFor="login-email" className="block text-sm font-medium text-slate-800">
            Email
          </label>
          <input
            id="login-email"
            type="email"
            autoComplete="username webauthn"
            aria-invalid={Boolean(errors.email)}
            aria-describedby={errors.email ? "login-email-error" : undefined}
            value={form.data.email}
            onChange={(e) => form.setData("email", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.email && (
            <p id="login-email-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.email}
            </p>
          )}
        </div>

        <div>
          <div className="flex items-center justify-between">
            <label htmlFor="login-password" className="block text-sm font-medium text-slate-800">
              Password
            </label>
            {forgotPasswordHref && (
              <a href={forgotPasswordHref} className="text-xs text-slate-600 underline">
                Forgot password?
              </a>
            )}
          </div>
          <input
            id="login-password"
            type="password"
            autoComplete="current-password"
            aria-invalid={Boolean(errors.password)}
            aria-describedby={errors.password ? "login-password-error" : undefined}
            value={form.data.password}
            onChange={(e) => form.setData("password", e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
          {errors.password && (
            <p id="login-password-error" role="alert" className="mt-1 text-xs text-red-700">
              {errors.password}
            </p>
          )}
        </div>

        <button
          type="submit"
          disabled={form.processing}
          className="w-full rounded bg-slate-900 py-2 font-medium text-white disabled:opacity-60"
        >
          {form.processing ? "Signing in..." : "Sign in"}
        </button>
      </form>

      {passkeyBeginAction && passkeyFinishAction && (
        <button
          type="button"
          disabled={passkeyBusy}
          onClick={() => void signInWithPasskey()}
          className="w-full rounded border border-slate-300 py-2 text-sm font-medium text-slate-800"
        >
          {passkeyBusy ? "Waiting for passkey..." : "Sign in with passkey"}
        </button>
      )}

      {magicLinkAction && (
        <form onSubmit={submitMagicLink} aria-label="Magic link sign in" className="space-y-2 border-t border-slate-200 pt-4">
          <label htmlFor="magic-email" className="block text-xs font-medium text-slate-700">
            Or email me a sign-in link
          </label>
          <div className="flex gap-2">
            <input
              id="magic-email"
              type="email"
              placeholder="you@example.com"
              value={magicForm.data.email}
              onChange={(e) => magicForm.setData("email", e.target.value)}
              className="flex-1 rounded border border-slate-300 px-3 py-1.5 text-sm"
            />
            <button
              type="submit"
              disabled={magicForm.processing}
              className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium"
            >
              Send link
            </button>
          </div>
        </form>
      )}

      {oidcProviders.length > 0 && (
        <div className="space-y-2 border-t border-slate-200 pt-4">
          {oidcProviders.map((p) => (
            <a
              key={p.id}
              href={p.href}
              className="block w-full rounded border border-slate-300 py-2 text-center text-sm font-medium text-slate-800"
            >
              Continue with {p.label}
            </a>
          ))}
        </div>
      )}

      {registerHref && (
        <p className="text-center text-sm text-slate-600">
          New here?{" "}
          <a href={registerHref} className="font-medium underline">
            Create an account
          </a>
        </p>
      )}
    </main>
  );
}

export default LoginPage;
