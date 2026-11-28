import { router, useForm } from "@inertiajs/react";
import { type FormEvent, type ReactElement, useState } from "react";
import {
  prepareCreationOptions,
  type ServerCreationOptions,
  serializeRegistrationCredential,
  supportsPasskeys,
} from "../../lib/webauthn";

export interface SecuritySessionItem {
  id: string;
  device_label: string;
  ip_prefix: string | null;
  auth_method: string | null;
  mfa_verified: boolean;
  expires_at: string;
  current?: boolean;
}

export interface SecurityPasskeyItem {
  credential_id: string;
  name: string;
  created_at: string;
  last_used_at: string | null;
}

export interface SecurityApiTokenItem {
  id: string;
  name: string;
  prefix: string;
  scopes: string[];
  expires_at: string | null;
  revoked_at: string | null;
}

export interface ArvoSecuritySettingsProps {
  userEmail: string;
  mfaEnabled: boolean;
  needsSudo?: boolean;
  totpUri?: string | null;
  recoveryCodes?: string[];
  plaintextApiToken?: string | null;
  sessions: SecuritySessionItem[];
  passkeys: SecurityPasskeyItem[];
  apiTokens: SecurityApiTokenItem[];
  csrfToken?: string;
  flash?: { notice?: string | null; alert?: string | null };
  errors?: Record<string, string>;
}

export function SecuritySettingsPage({
  userEmail,
  mfaEnabled,
  needsSudo = false,
  totpUri,
  recoveryCodes = [],
  plaintextApiToken,
  sessions,
  passkeys,
  apiTokens,
  csrfToken,
  flash,
  errors = {},
}: ArvoSecuritySettingsProps): ReactElement {
  const sudoForm = useForm({ password: "" });
  const totpForm = useForm({ code: "" });
  const tokenForm = useForm({ name: "", prefix: "arvo_live", scopes: "*" });
  const [passkeyName, setPasskeyName] = useState("Laptop Passkey");
  const [passkeyMessage, setPasskeyMessage] = useState<string | null>(null);
  const [passkeyError, setPasskeyError] = useState<string | null>(null);

  function submitSudo(e: FormEvent) {
    e.preventDefault();
    sudoForm.post("/settings/security/sudo", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => sudoForm.reset(),
    });
  }

  function submitEnableTotp(e: FormEvent) {
    e.preventDefault();
    totpForm.post("/settings/security/totp", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => totpForm.reset(),
    });
  }

  function submitMintToken(e: FormEvent) {
    e.preventDefault();
    tokenForm.post("/settings/security/api-tokens", {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      onSuccess: () => tokenForm.reset("name"),
    });
  }

  async function addPasskey() {
    setPasskeyError(null);
    setPasskeyMessage(null);
    if (!supportsPasskeys()) {
      setPasskeyError("WebAuthn passkeys are not available in this browser.");
      return;
    }
    try {
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
      };
      if (csrfToken) headers["X-XSRF-TOKEN"] = csrfToken;

      const begin = await fetch("/settings/security/passkeys/begin", {
        method: "POST",
        credentials: "same-origin",
        headers,
        body: JSON.stringify({ name: passkeyName }),
      });
      if (!begin.ok) {
        setPasskeyError(`Passkey registration start failed (HTTP ${begin.status}).`);
        return;
      }
      const opts = (await begin.json()) as ServerCreationOptions;
      const cred = (await navigator.credentials.create({
        publicKey: prepareCreationOptions(opts),
      })) as PublicKeyCredential | null;
      if (!cred) {
        setPasskeyError("Passkey creation was cancelled.");
        return;
      }
      const finish = await fetch("/settings/security/passkeys", {
        method: "POST",
        credentials: "same-origin",
        headers,
        body: JSON.stringify({
          name: passkeyName,
          credential: serializeRegistrationCredential(cred),
        }),
      });
      if (!finish.ok) {
        setPasskeyError(`Passkey registration failed (HTTP ${finish.status}).`);
        return;
      }
      setPasskeyMessage("Passkey registered.");
      router.reload();
    } catch {
      setPasskeyError("Passkey registration failed.");
    }
  }

  return (
    <main className="mx-auto max-w-3xl space-y-8 p-6 text-slate-900">
      <header>
        <h1 className="text-2xl font-semibold">Security Settings</h1>
        <p className="text-sm text-slate-600">{userEmail}</p>
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

      {needsSudo && (
        <section aria-labelledby="sudo-heading" className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3">
          <h2 id="sudo-heading" className="font-medium">Confirm password (Sudo mode)</h2>
          <p className="text-xs text-slate-700">
            Re-enter your password before modifying MFA, passkeys, or API tokens.
          </p>
          <form onSubmit={submitSudo} className="flex gap-2">
            <label htmlFor="sudo-password" className="sr-only">Password</label>
            <input
              id="sudo-password"
              type="password"
              value={sudoForm.data.password}
              onChange={(e) => sudoForm.setData("password", e.target.value)}
              placeholder="Current password"
              className="flex-1 rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
            />
            <button type="submit" className="rounded bg-slate-900 px-3 py-1.5 text-sm text-white">
              Unlock
            </button>
          </form>
        </section>
      )}

      <section aria-labelledby="totp-heading" className="space-y-3 rounded border border-slate-200 p-4">
        <div className="flex items-center justify-between">
          <h2 id="totp-heading" className="font-medium">Two-Factor Authentication (TOTP)</h2>
          <span className="text-xs font-medium text-slate-600">
            {mfaEnabled ? "Enabled" : "Not enrolled"}
          </span>
        </div>
        {totpUri && (
          <p className="break-all rounded bg-slate-100 p-2 font-mono text-xs">{totpUri}</p>
        )}
        {recoveryCodes.length > 0 && (
          <div className="rounded bg-slate-100 p-3">
            <p className="text-xs font-medium">Save these one-time recovery codes:</p>
            <ul className="mt-1 grid grid-cols-2 gap-1 font-mono text-xs">
              {recoveryCodes.map((c) => <li key={c}>{c}</li>)}
            </ul>
          </div>
        )}
        {mfaEnabled ? (
          <button
            type="button"
            onClick={() => router.delete("/settings/security/totp")}
            className="rounded border border-red-300 px-3 py-1.5 text-sm text-red-700"
          >
            Disable 2FA
          </button>
        ) : (
          <form onSubmit={submitEnableTotp} className="flex gap-2">
            <label htmlFor="totp-verify" className="sr-only">6-digit code</label>
            <input
              id="totp-verify"
              type="text"
              placeholder="6-digit verification code"
              value={totpForm.data.code}
              onChange={(e) => totpForm.setData("code", e.target.value)}
              className="flex-1 rounded border border-slate-300 px-3 py-1.5 text-sm"
            />
            <button type="submit" className="rounded bg-slate-900 px-3 py-1.5 text-sm text-white">
              Verify & Enable
            </button>
          </form>
        )}
        {errors.code && <p role="alert" className="text-xs text-red-700">{errors.code}</p>}
      </section>

      <section aria-labelledby="passkeys-heading" className="space-y-3 rounded border border-slate-200 p-4">
        <h2 id="passkeys-heading" className="font-medium">Passkeys ({passkeys.length})</h2>
        {passkeyMessage && <p role="status" className="text-xs text-emerald-800">{passkeyMessage}</p>}
        {passkeyError && <p role="alert" className="text-xs text-red-700">{passkeyError}</p>}
        <div className="flex gap-2">
          <label htmlFor="passkey-name" className="sr-only">Passkey label</label>
          <input
            id="passkey-name"
            type="text"
            value={passkeyName}
            onChange={(e) => setPasskeyName(e.target.value)}
            className="flex-1 rounded border border-slate-300 px-3 py-1.5 text-sm"
          />
          <button
            type="button"
            onClick={() => void addPasskey()}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium"
          >
            Add passkey
          </button>
        </div>
        <ul className="divide-y text-sm">
          {passkeys.map((pk) => (
            <li key={pk.credential_id} className="flex items-center justify-between py-2">
              <span>{pk.name}</span>
              <button
                type="button"
                onClick={() => router.delete(`/settings/security/passkeys/${pk.credential_id}`)}
                className="text-xs text-red-700 underline"
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="sessions-heading" className="space-y-3 rounded border border-slate-200 p-4">
        <div className="flex items-center justify-between">
          <h2 id="sessions-heading" className="font-medium">Active Sessions ({sessions.length})</h2>
          <button
            type="button"
            onClick={() => router.delete("/settings/security/sessions")}
            className="text-xs text-red-700 underline"
          >
            Sign out other devices
          </button>
        </div>
        <ul className="divide-y text-sm">
          {sessions.map((s) => (
            <li key={s.id} className="flex items-center justify-between py-2">
              <div>
                <p className="font-medium">
                  {s.device_label} {s.current ? "(current)" : ""}
                </p>
                <p className="text-xs text-slate-600">
                  {s.auth_method ?? "session"} · {s.ip_prefix ?? "unknown"} · expires {s.expires_at}
                </p>
              </div>
              {!s.current && (
                <button
                  type="button"
                  onClick={() => router.delete(`/settings/security/sessions/${s.id}`)}
                  className="text-xs text-red-700 underline"
                >
                  Revoke
                </button>
              )}
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="tokens-heading" className="space-y-3 rounded border border-slate-200 p-4">
        <h2 id="tokens-heading" className="font-medium">API & Agent Bearer Tokens ({apiTokens.length})</h2>
        {plaintextApiToken && (
          <p role="status" className="break-all rounded bg-emerald-50 p-2 font-mono text-xs text-emerald-900">
            Copy token now (shown once): {plaintextApiToken}
          </p>
        )}
        <form onSubmit={submitMintToken} className="grid grid-cols-3 gap-2">
          <input
            aria-label="Token name"
            placeholder="CLI or agent name"
            value={tokenForm.data.name}
            onChange={(e) => tokenForm.setData("name", e.target.value)}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm"
          />
          <input
            aria-label="Scopes"
            placeholder="bills:read bills:write"
            value={tokenForm.data.scopes}
            onChange={(e) => tokenForm.setData("scopes", e.target.value)}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm"
          />
          <button type="submit" className="rounded bg-slate-900 px-3 py-1.5 text-sm text-white">
            Mint token
          </button>
        </form>
        <ul className="divide-y text-sm">
          {apiTokens.map((t) => (
            <li key={t.id} className="flex items-center justify-between py-2">
              <span>
                {t.name} <code className="text-xs text-slate-500">{t.prefix}_{t.id}_***</code>
              </span>
              {t.revoked_at ? (
                <span className="text-xs text-slate-500">revoked</span>
              ) : (
                <button
                  type="button"
                  onClick={() => router.delete(`/settings/security/api-tokens/${t.id}`)}
                  className="text-xs text-red-700 underline"
                >
                  Revoke
                </button>
              )}
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}

export default SecuritySettingsPage;
