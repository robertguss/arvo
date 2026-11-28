## Multi-key AES-256-GCM keyring (`v2.<kid>.<b64>` + legacy cookie compatibility)
## supporting zero-downtime key rotation and cryptographically AAD-bound key IDs.
module Arvo.Keyring
expose KeyEntry(..),
Keyring(..),
Opened(..),
KeyringError(..),
to_text,
valid_key?,
valid_key_id?,
single,
from_entries,
parse_env,
from_env,
primary_key,
seal,
open
use Crypto

## One named 32-byte encryption key inside an `Arvo.Keyring`.
struct KeyEntry
  id: Text
  key: Bytes
end

## Ordered encryption keyring whose `primary_id` seals new payloads while all `keys` remain valid for decryption.
struct Keyring
  primary_id: Text
  keys: List(KeyEntry)
end

## Decrypted payload alongside the matched key ID and whether re-encryption to the primary key is needed.
struct Opened
  plaintext: Bytes
  key_id: Text
  needs_rekey?: Bool
end

## Errors arising from keyring construction, env parsing, key validation, or AEAD sealing.
enum KeyringError
  EmptyKeyring
  InvalidKeyId(id: Text)
  DuplicateKeyId(id: Text)
  InvalidKeyLength(id: Text, size: Int)
  MissingEnvVar(name: Text)
  InvalidEnvFormat(reason: Text)
  CryptoFailed(Crypto.CryptoError)
end

## Formats a `KeyringError` as a human-readable message.
fn to_text(err: KeyringError) : Text
  case err
    EmptyKeyring: "keyring must contain at least one key"
    InvalidKeyId(id: id): "invalid key id '#{id}'"
    DuplicateKeyId(id: id): "duplicate key id '#{id}'"
    InvalidKeyLength(id: id, size: sz): "key '#{id}' must be 32 bytes, got #{sz}"
    MissingEnvVar(name: n): "missing keyring env var '#{n}'"
    InvalidEnvFormat(reason: r): "invalid keyring env format: #{r}"
    CryptoFailed(e): "keyring crypto failed: #{e}"
  end
end

## Returns `true` iff `key` is an exact 32-byte AES-256-GCM key.
fn valid_key?(key: Bytes) : Bool
  examples
    not valid_key?("".bytes)
    not valid_key?("0123456789012345678901234567890".bytes)
    valid_key?("01234567890123456789012345678901".bytes)
    not valid_key?("012345678901234567890123456789012".bytes)
  end

  key.size == 32
end

## Returns `true` iff `id` is 1..32 ASCII bytes from `[A-Za-z0-9_-]`.
fn valid_key_id?(id: Text) : Bool
  examples
    valid_key_id?("k1")
    valid_key_id?("prod_2026-11")
    not valid_key_id?("")
    not valid_key_id?("k.1")
    not valid_key_id?("k:1")
    not valid_key_id?("k,1")
    not valid_key_id?("k 1")
  end

  bs = id.bytes
  return false if bs.size == 0 or bs.size > 32
  var i = 0
  while i < bs.size
    b = (bs.get(i) or 0).to_int
    ok_char = (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or
      b == 45 or
      b == 95
    return false if not ok_char
    i += 1
  end
  true
end

## Builds a single-key keyring.
fn single(id: Text, key: Bytes) : Result(Keyring, KeyringError)
  from_entries([KeyEntry(id: id, key: key)])
end

## Validates `entries` (first entry is primary) and builds a `Keyring`.
fn from_entries(entries: List(KeyEntry)) : Result(Keyring, KeyringError)
  first = case entries.first
    Some(e): e
    None: return Error(EmptyKeyring)
  end
  var seen = Set.empty
  for e in entries
    if not valid_key_id?(e.id)
      return Error(InvalidKeyId(id: e.id))
    end
    if seen.has?(e.id)
      return Error(DuplicateKeyId(id: e.id))
    end
    if not valid_key?(e.key)
      return Error(InvalidKeyLength(id: e.id, size: e.key.size))
    end
    seen = seen.add(e.id)
  end
  Ok(Keyring(primary_id: first.id, keys: entries))
end

## Parses `"k2:<64hex>,k1:<64hex>"` (first entry primary) or legacy bare `"<64hex>"` (`id = "legacy"`).
fn parse_env(raw: Text) : Result(Keyring, KeyringError)
  trimmed = raw.trim
  return Error(EmptyKeyring) if trimmed.empty?
  segs = trimmed.split(",")
  if segs.size == 1 and not trimmed.contains?(":")
    hex_str = trimmed
    key_bytes = case Bytes.from_hex(hex_str)
      Some(b): b
      None: return Error(InvalidEnvFormat(reason: "expected 64-char hex key"))
    end
    return single("legacy", key_bytes)
  end

  var entries = []
  for seg in segs
    s = seg.trim
    if s.empty?
      return Error(InvalidEnvFormat(reason: "empty entry in keyring list"))
    end
    parts = s.split(":")
    if parts.size != 2
      return Error(InvalidEnvFormat(reason: "each entry must have form <id>:<64hex>"))
    end
    kid = (parts.get(0) or "").trim
    hex_str = (parts.get(1) or "").trim
    if not valid_key_id?(kid)
      return Error(InvalidKeyId(id: kid))
    end
    key_bytes = case Bytes.from_hex(hex_str)
      Some(b): b
      None: return Error(InvalidEnvFormat(reason: "invalid hex key for '#{kid}'"))
    end
    entries = entries.append(KeyEntry(id: kid, key: key_bytes))
  end
  from_entries(entries)
end

## Reads and parses a `Keyring` from environment variable `var_name`.
fn from_env(env: Env, var_name: Text) : Result(Keyring, KeyringError)
  raw = case env.get(var_name)
    Some(v): v
    None: return Error(MissingEnvVar(name: var_name))
  end
  parse_env(raw)
end

## Returns the primary `KeyEntry` used for sealing new tokens.
fn primary_key(kr: Keyring) : KeyEntry
  kr.keys.find(fn(e) e.id == kr.primary_id end) or (
    kr.keys.first or KeyEntry(id: kr.primary_id, key: Bytes.empty)
  )
end

fn find_key(kr: Keyring, key_id: Text) : Option(Bytes)
  kr.keys.find(fn(e) e.id == key_id end).map(fn(e) e.key end)
end

fn bound_aad(aad: Bytes, key_id: Text) : Bytes
  Bytes.join([aad, ":v2:#{key_id}".bytes])
end

## Seals `plaintext` under `kr.primary_id`, returning `"v2.<kid>.<base64url(nonce||ct)>"`.
## Binds `key_id` into AES-256-GCM AAD so downgrading/swapping `kid` fails authentication.
fn seal(rng: SecureRandom, kr: Keyring, plaintext: Bytes, aad: Bytes) : Result(Text, KeyringError)
  entry = primary_key(kr)
  return Error(InvalidKeyId(id: entry.id)) if not valid_key_id?(entry.id)
  return Error(InvalidKeyLength(id: entry.id, size: entry.key.size)) if not valid_key?(entry.key)
  nonce = rng.bytes(12)
  ct = try Crypto.seal(entry.key, nonce, plaintext, bound_aad(aad, entry.id)).map_error(
    fn(e) CryptoFailed(e) end
  )
  Ok("v2.#{entry.id}.#{Bytes.join([nonce, ct]).to_base64url}")
end

## Authenticates and decrypts either `"v2.<kid>.<b64>"` or legacy single-key raw `base64url(nonce||ct)`.
## Fails closed (`None`) on tampered tokens, wrong AAD, unknown key IDs, or short inputs.
fn open(kr: Keyring, token: Text, aad: Bytes) : Option(Opened)
  examples
    case Crypto.seal(
      "01234567890123456789012345678901".bytes,
      "0123456789ab".bytes,
      "hi".bytes,
      "a:v2:k1".bytes
    )
      Ok(ct): open(
        Keyring(
          primary_id: "k1",
          keys: [KeyEntry(id: "k1", key: "01234567890123456789012345678901".bytes)]
        ),
        "v2.k1.#{Bytes.join(["0123456789ab".bytes, ct]).to_base64url}",
        "a".bytes
      ) ==
        Some(Opened(plaintext: "hi".bytes, key_id: "k1", needs_rekey?: false))
      Error(_): false
    end
    case Crypto.seal(
      "01234567890123456789012345678901".bytes,
      "0123456789ab".bytes,
      "hi".bytes,
      "a:v2:k1".bytes
    )
      Ok(ct): open(
        Keyring(
          primary_id: "k1",
          keys: [KeyEntry(id: "k1", key: "01234567890123456789012345678901".bytes)]
        ),
        "v2.k1.#{Bytes.join(["0123456789ab".bytes, ct]).to_base64url}",
        "b".bytes
      ) ==
        None
      Error(_): false
    end
    case Crypto.seal(
      "01234567890123456789012345678901".bytes,
      "0123456789ab".bytes,
      "hi".bytes,
      "a:v2:k1".bytes
    )
      Ok(ct): open(
        Keyring(
          primary_id: "k2",
          keys: [
            KeyEntry(id: "k2", key: "abcdefghijklmnopqrstuvwxyz012345".bytes),
            KeyEntry(id: "k1", key: "01234567890123456789012345678901".bytes)
          ]
        ),
        "v2.k1.#{Bytes.join(["0123456789ab".bytes, ct]).to_base64url}",
        "a".bytes
      ) ==
        Some(Opened(plaintext: "hi".bytes, key_id: "k1", needs_rekey?: true))
      Error(_): false
    end
  end

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
    return Some(Opened(plaintext: pt, key_id: kid, needs_rekey?: kid != kr.primary_id))
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
        Ok(pt): return Some(Opened(plaintext: pt, key_id: entry.id, needs_rekey?: true))
        Error(_): Unit
      end
    end
  end
  None
end

test "Keyring seals, rotates, opens legacy cookies, binds AAD+kid, and parses env formats"
  rng = SecureRandom.seeded(91)
  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  k1_hex = k1.to_hex
  k2_hex = k2.to_hex

  # Validation and parse_env
  assert parse_env("") == Error(EmptyKeyring)
  assert parse_env("   ") == Error(EmptyKeyring)
  assert parse_env("deadbeef") == Error(InvalidKeyLength(id: "legacy", size: 4))
  assert parse_env("not-hex") is Error(InvalidEnvFormat(reason: _))
  assert parse_env("k.1:#{k1_hex}") == Error(InvalidKeyId(id: "k.1"))
  assert parse_env("k1:#{k1_hex},") is Error(InvalidEnvFormat(reason: _))
  assert parse_env("k1:#{k1_hex},k1:#{k2_hex}") == Error(DuplicateKeyId(id: "k1"))
  assert parse_env("k1:abcd") == Error(InvalidKeyLength(id: "k1", size: 2))

  assert parse_env(k1_hex) is Ok(kr_legacy)
  assert kr_legacy.primary_id == "legacy"
  assert primary_key(kr_legacy).key == k1

  env = Env.of({"ARVO_SECRET_KEY": "k2:#{k2_hex},k1:#{k1_hex}"})
  assert from_env(Env.of({}), "ARVO_SECRET_KEY") == Error(MissingEnvVar(name: "ARVO_SECRET_KEY"))
  assert from_env(env, "ARVO_SECRET_KEY") is Ok(kr2)
  assert kr2.primary_id == "k2"

  assert single("k1", k1) is Ok(kr1)
  aad = "arvo:session:arvo_session".bytes
  msg = "secret-session-payload".bytes

  # Sealed with kr1 (primary k1), opened with kr1 (needs_rekey? == false)
  tok1 = case seal(rng, kr1, msg, aad)
    Ok(t): t
    Error(_): stop "seal kr1 failed"
  end
  assert tok1.starts_with?("v2.k1.")
  assert open(kr1, tok1, aad) == Some(Opened(plaintext: msg, key_id: "k1", needs_rekey?: false))

  # Opened with rotated kr2 (k2 primary, k1 secondary): succeeds & flags needs_rekey? = true
  assert open(kr2, tok1, aad) == Some(Opened(plaintext: msg, key_id: "k1", needs_rekey?: true))

  # Sealed with kr2 (primary k2): needs_rekey? == false under kr2, fails under kr1 (unknown k2)
  tok2 = case seal(rng, kr2, msg, aad)
    Ok(t): t
    Error(_): stop "seal kr2 failed"
  end
  assert tok2.starts_with?("v2.k2.")
  assert open(kr2, tok2, aad) == Some(Opened(plaintext: msg, key_id: "k2", needs_rekey?: false))
  assert open(kr1, tok2, aad) == None

  # AAD mismatch and tampered kid prefix both fail closed
  assert open(kr2, tok2, "arvo:session:other_cookie".bytes) == None
  swapped_kid = "v2.k1.#{tok2.drop_prefix("v2.k2.") or ""}"
  assert open(kr2, swapped_kid, aad) == None
  assert open(kr2, "", aad) == None
  assert open(kr2, "v3.k2.AAAA", aad) == None

  # Legacy raw base64url(nonce || ct) under k1 decrypts with rotated keyring and flags needs_rekey?
  leg_nonce = rng.bytes(12)
  leg_ct = case Crypto.seal(k1, leg_nonce, msg, aad)
    Ok(c): c
    Error(_): stop "legacy Crypto.seal"
  end
  leg_tok = Bytes.join([leg_nonce, leg_ct]).to_base64url
  assert open(kr2, leg_tok, aad) == Some(Opened(plaintext: msg, key_id: "k1", needs_rekey?: true))
  assert open(kr2, leg_tok, "wrong-aad".bytes) == None
end
