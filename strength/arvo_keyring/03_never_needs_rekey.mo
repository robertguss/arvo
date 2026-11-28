## WRONG VERSION (strength/arvo_keyring/03_never_needs_rekey.mo): Fails to flag needs_rekey? when decrypting with a rotated or legacy key.
module Arvo.Keyring
use Crypto

fn open(kr: Keyring, token: Text, aad: Bytes) : Option(Opened)
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
    pt = case Crypto.open(key, nonce, ct, bound_aad(aad, kid))
      Ok(p): p
      Error(_): return None
    end
    return Some(Opened(plaintext: pt, key_id: kid, needs_rekey?: false))
  end

  return None if token.contains?(".")
  raw = case Bytes.from_base64url(token)
    Some(b): b
    None: return None
  end
  return None if raw.size < 28
  nonce = raw.slice(0, 12)
  ct = raw.slice(12, raw.size)
  for entry in kr.keys
    if valid_key?(entry.key)
      case Crypto.open(entry.key, nonce, ct, aad)
        Ok(pt): return Some(Opened(plaintext: pt, key_id: entry.id, needs_rekey?: false))
        Error(_): Unit
      end
    end
  end
  None
end
