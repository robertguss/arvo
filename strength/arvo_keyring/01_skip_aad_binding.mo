## WRONG VERSION (strength/arvo_keyring/01_skip_aad_binding.mo): Omits AAD binding when sealing/opening.
module Arvo.Keyring
use Crypto

fn seal(rng: SecureRandom, kr: Keyring, plaintext: Bytes, aad: Bytes) : Result(Text, KeyringError)
  _ = aad
  entry = primary_key(kr)
  return Error(InvalidKeyId(id: entry.id)) if not valid_key_id?(entry.id)
  return Error(InvalidKeyLength(id: entry.id, size: entry.key.size)) if not valid_key?(entry.key)
  nonce = rng.bytes(12)
  ct = try Crypto.seal(entry.key, nonce, plaintext, Bytes.empty).map_error(
    fn(e) CryptoFailed(e) end
  )
  Ok("v2.#{entry.id}.#{Bytes.join([nonce, ct]).to_base64url}")
end

fn open(kr: Keyring, token: Text, aad: Bytes) : Option(Opened)
  _ = aad
  return None if token.empty?
  if token.starts_with?("v2.")
    parts = token.split(".")
    return None if parts.size != 3
    kid = parts.get(1) or ""
    b64 = parts.get(2) or ""
    return None if not valid_key_id?(kid) or b64.empty?
    key = case find_key(kr, kid)
      Some(k): k
      None: return None
    end
    return None if not valid_key?(key)
    raw = case Bytes.from_base64url(b64)
      Some(b): b
      None: return None
    end
    return None if raw.size < 28
    nonce = raw.slice(0, 12)
    ct = raw.slice(12, raw.size)
    pt = case Crypto.open(key, nonce, ct, Bytes.empty)
      Ok(p): p
      Error(_): return None
    end
    return Some(Opened(plaintext: pt, key_id: kid, needs_rekey?: kid != kr.primary_id))
  end
  None
end
