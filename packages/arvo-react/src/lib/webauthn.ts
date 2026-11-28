export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function base64UrlToBytes(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const pad = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  const binary = atob(normalized + pad);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    out[i] = binary.charCodeAt(i);
  }
  return out;
}

export function supportsPasskeys(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.PublicKeyCredential !== "undefined" &&
    typeof navigator !== "undefined" &&
    Boolean(navigator.credentials?.create) &&
    Boolean(navigator.credentials?.get)
  );
}

export interface ServerCreationOptions {
  challenge: string;
  rp: { id?: string; name: string };
  user: { id: string; name: string; displayName: string };
  pubKeyCredParams: PublicKeyCredentialParameters[];
  timeout?: number;
  excludeCredentials?: Array<{ id: string; type: "public-key" }>;
  authenticatorSelection?: AuthenticatorSelectionCriteria;
  attestation?: AttestationConveyancePreference;
}

export function prepareCreationOptions(
  opts: ServerCreationOptions,
): PublicKeyCredentialCreationOptions {
  return {
    challenge: base64UrlToBytes(opts.challenge) as BufferSource,
    rp: opts.rp,
    user: {
      id: base64UrlToBytes(opts.user.id) as BufferSource,
      name: opts.user.name,
      displayName: opts.user.displayName,
    },
    pubKeyCredParams: opts.pubKeyCredParams,
    timeout: opts.timeout ?? 60000,
    excludeCredentials: (opts.excludeCredentials ?? []).map((c) => ({
      id: base64UrlToBytes(c.id) as BufferSource,
      type: c.type,
    })),
    authenticatorSelection: opts.authenticatorSelection,
    attestation: opts.attestation ?? "none",
  };
}

export interface SerializedRegistrationCredential {
  id: string;
  rawId: string;
  type: "public-key";
  clientDataJSON: string;
  attestationObject: string;
}

export function serializeRegistrationCredential(
  cred: PublicKeyCredential,
): SerializedRegistrationCredential {
  const resp = cred.response as AuthenticatorAttestationResponse;
  return {
    id: cred.id,
    rawId: bytesToBase64Url(new Uint8Array(cred.rawId)),
    type: "public-key",
    clientDataJSON: bytesToBase64Url(new Uint8Array(resp.clientDataJSON)),
    attestationObject: bytesToBase64Url(new Uint8Array(resp.attestationObject)),
  };
}

export interface ServerRequestOptions {
  challenge: string;
  rpId?: string;
  timeout?: number;
  allowCredentials?: Array<{ id: string; type: "public-key" }>;
  userVerification?: UserVerificationRequirement;
}

export function prepareRequestOptions(
  opts: ServerRequestOptions,
): PublicKeyCredentialRequestOptions {
  return {
    challenge: base64UrlToBytes(opts.challenge) as BufferSource,
    rpId: opts.rpId,
    timeout: opts.timeout ?? 60000,
    allowCredentials: (opts.allowCredentials ?? []).map((c) => ({
      id: base64UrlToBytes(c.id) as BufferSource,
      type: c.type,
    })),
    userVerification: opts.userVerification ?? "preferred",
  };
}

export interface SerializedAuthenticationCredential {
  id: string;
  rawId: string;
  type: "public-key";
  clientDataJSON: string;
  authenticatorData: string;
  signature: string;
  userHandle: string | null;
}

export function serializeAuthenticationCredential(
  cred: PublicKeyCredential,
): SerializedAuthenticationCredential {
  const resp = cred.response as AuthenticatorAssertionResponse;
  return {
    id: cred.id,
    rawId: bytesToBase64Url(new Uint8Array(cred.rawId)),
    type: "public-key",
    clientDataJSON: bytesToBase64Url(new Uint8Array(resp.clientDataJSON)),
    authenticatorData: bytesToBase64Url(new Uint8Array(resp.authenticatorData)),
    signature: bytesToBase64Url(new Uint8Array(resp.signature)),
    userHandle: resp.userHandle ? bytesToBase64Url(new Uint8Array(resp.userHandle)) : null,
  };
}
