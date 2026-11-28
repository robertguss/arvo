import { describe, expect, it } from "vitest";
import {
  base64UrlToBytes,
  bytesToBase64Url,
  prepareCreationOptions,
  prepareRequestOptions,
} from "../lib/webauthn";

describe("webauthn helpers", () => {
  it("round-trips base64url bytes without padding", () => {
    const bytes = new Uint8Array([0, 255, 17, 128, 63, 42]);
    const encoded = bytesToBase64Url(bytes);
    expect(encoded.includes("=")).toBe(false);
    expect(base64UrlToBytes(encoded)).toEqual(bytes);
  });

  it("prepares WebAuthn creation and request options", () => {
    const ch = bytesToBase64Url(new Uint8Array([1, 2, 3, 4]));
    const uid = bytesToBase64Url(new Uint8Array([9, 8]));
    const creation = prepareCreationOptions({
      challenge: ch,
      rp: { name: "Arvo App" },
      user: { id: uid, name: "ada@example.com", displayName: "Ada" },
      pubKeyCredParams: [{ type: "public-key", alg: -7 }],
    });
    expect(new Uint8Array(creation.challenge as ArrayBuffer)).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(new Uint8Array(creation.user.id as ArrayBuffer)).toEqual(new Uint8Array([9, 8]));

    const req = prepareRequestOptions({
      challenge: ch,
      allowCredentials: [{ id: uid, type: "public-key" }],
    });
    expect(new Uint8Array(req.challenge as ArrayBuffer)).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(req.allowCredentials?.length).toBe(1);
  });
});
