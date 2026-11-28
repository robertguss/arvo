## RFC 6238 Time-Based One-Time Passwords (TOTP), RFC 4648 Base32, provisioning URIs,
## monotonic replay protection, AEAD keyring secret sealing, and one-time recovery codes.
module Arvo.Totp
expose TotpConfig(..),
TotpVerifyResult(..),
TotpError(..),
to_text,
default_config,
base32_encode,
base32_decode,
generate_secret,
provisioning_uri,
hotp_code,
time_step,
code_at,
verify,
seal_secret,
open_secret,
generate_recovery_codes,
verify_and_consume_recovery_code
use Arvo.Keyring
use Crypto

base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
recovery_alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

## Parameters controlling TOTP code length, time step duration, and clock-skew tolerance.
struct TotpConfig
  digits: Int
  period_seconds: Int
  skew_steps: Int
end

## Outcome of checking a user-supplied TOTP code against a secret and monotonic step watermark.
enum TotpVerifyResult
  Accepted(matched_step: Int)
  ReplayedStep(step: Int)
  InvalidCode
end

## Errors raised when sealing or unsealing TOTP secrets with `Arvo.Keyring`.
enum TotpError
  EmptySecret
  InvalidKeyring(Keyring.KeyringError)
  BadSealedSecret
end

## Formats a `TotpError` into a human-readable diagnostic.
fn to_text(err: TotpError) : Text
  case err
    EmptySecret: "TOTP secret cannot be empty"
    InvalidKeyring(e): "TOTP keyring error: #{Keyring.to_text(e)}"
    BadSealedSecret: "invalid or tampered sealed TOTP secret"
  end
end

## Standard 6-digit, 30-second TOTP configuration permitting +/-1 step (30s) clock skew.
fn default_config() : TotpConfig
  TotpConfig(digits: 6, period_seconds: 30, skew_steps: 1)
end

fn effective_digits(digits: Int) : Int
  if digits == 8: 8 else: 6
end

fn effective_period(period_seconds: Int) : Int
  if period_seconds < 1
    30
  else if period_seconds > 3600
    3600
  else
    period_seconds
  end
end

fn effective_skew(skew_steps: Int) : Int
  if skew_steps < 0
    0
  else if skew_steps > 5
    5
  else
    skew_steps
  end
end

## Encodes `data` into uppercase unpadded RFC 4648 Base32.
fn base32_encode(data: Bytes) : Text
  examples
    base32_encode("".bytes) == ""
    base32_encode("f".bytes) == "MY"
    base32_encode("fo".bytes) == "MZXQ"
    base32_encode("foo".bytes) == "MZXW6"
    base32_encode("foob".bytes) == "MZXW6YQ"
    base32_encode("fooba".bytes) == "MZXW6YTB"
    base32_encode("foobar".bytes) == "MZXW6YTBOI"
  end

  return "" if data.size == 0
  alpha = base32_alphabet.chars
  var out = []
  var buffer = 0
  var bits = 0
  var i = 0
  while i < data.size
    b = (data.get(i) or 0).to_int
    buffer = buffer * 256 + b
    bits += 8
    while bits >= 5
      shift = bits - 5
      var pow = 1
      var s = 0
      while s < shift
        pow = pow * 2
        s += 1
      end
      idx = buffer.floor_div(pow) % 32
      out = out.append(alpha.get(idx) or 'A')
      bits -= 5
      buffer = buffer % pow
    end
    i += 1
  end
  if bits > 0
    pad_shift = 5 - bits
    var idx = buffer
    var p = 0
    while p < pad_shift
      idx = idx * 2
      p += 1
    end
    out = out.append(alpha.get(idx % 32) or 'A')
  end
  Text.from_chars(out)
end

fn base32_val(ch: Char) : Option(Int)
  bs = ch.ascii_uppercase.to_text.bytes
  return None if bs.size != 1
  n = (
    case bs.get(0)
      Some(b): b.to_int
      None: 0
    end
  )
  if n >= 65 and n <= 90
    Some(n - 65)
  else if n >= 50 and n <= 55
    Some(26 + (n - 50))
  else
    None
  end
end

## Decodes RFC 4648 Base32 (case-insensitive, optional spaces/trailing `=`), returning `None` on invalid characters.
fn base32_decode(encoded: Text) : Option(Bytes)
  examples
    base32_decode("") == Some("".bytes)
    base32_decode("MZXW6YTBOI") == Some("foobar".bytes)
    base32_decode("mzxw6ytb oi======") == Some("foobar".bytes)
    base32_decode("NOT!BASE32") == None
    base32_decode("AB=CD") == None
    base32_decode("0189") == None
  end

  promise "invalid punctuation never decodes as valid Base32"
    encoded.contains?("!") implies result == None
  end

  trimmed = encoded.trim
  return Some(Bytes.empty) if trimmed.empty?
  var out = []
  var buffer = 0
  var bits = 0
  var seen_pad? = false
  for ch in trimmed.chars
    if ch == ' ' or ch == '-'
      continue
    else if ch == '='
      seen_pad? = true
      continue
    end
    return None if seen_pad?
    val = case base32_val(ch)
      Some(v): v
      None: return None
    end
    buffer = buffer * 32 + val
    bits += 5
    if bits >= 8
      shift = bits - 8
      var pow = 1
      var s = 0
      while s < shift
        pow = pow * 2
        s += 1
      end
      byte_val = (buffer.floor_div(pow)) % 256
      if byte_val.to_byte is Some(bv)
        out = out.append(bv)
      end
      bits -= 8
      buffer = buffer % pow
    end
  end
  Some(Bytes.from_list(out))
end

## Generates a fresh 160-bit (20-byte) CSPRNG TOTP shared secret.
fn generate_secret(rng: SecureRandom) : Bytes
  rng.bytes(20)
end

fn url_unreserved?(b: Int) : Bool
  (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or
    b == 45 or
    b == 95 or
    b == 46 or
    b == 126
end

fn url_encode_component(raw: Text) : Text
  hex_chars = "0123456789ABCDEF".chars
  var out = []
  for byte in raw.bytes.to_list
    n = byte.to_int
    if n < 32 or n == 127
      continue
    end
    if url_unreserved?(n)
      out = out.append(n.to_char or '_')
    else
      out = out.append('%')
      out = out.append(hex_chars.get(n.floor_div(16)) or '0')
      out = out.append(hex_chars.get(n % 16) or '0')
    end
  end
  Text.from_chars(out)
end

## Builds an RFC-compatible `otpauth://totp/...` provisioning URI suitable for QR code rendering.
fn provisioning_uri(issuer: Text, account_email: Text, secret: Bytes, cfg: TotpConfig) : Text
  enc_issuer = url_encode_component(issuer.trim)
  enc_email = url_encode_component(account_email.trim)
  b32 = base32_encode(secret)
  d = effective_digits(cfg.digits)
  p = effective_period(cfg.period_seconds)
  "otpauth://totp/#{enc_issuer}:#{enc_email}?secret=#{b32}&issuer=#{enc_issuer}&algorithm=SHA1&digits=#{d}&period=#{p}"
end

fn counter_be8(counter: Int) : Bytes
  var c = if counter < 0: 0 else: counter
  var rev = []
  var i = 0
  while i < 8
    if (c % 256).to_byte is Some(b)
      rev = rev.append(b)
    end
    c = c.floor_div(256)
    i += 1
  end
  Bytes.from_list(rev.reverse)
end

## Computes the zero-padded HOTP/TOTP decimal code for `(secret, counter, digits)` via HMAC-SHA1.
fn hotp_code(secret: Bytes, counter: Int, digits: Int) : Text
  examples
    hotp_code("12345678901234567890".bytes, 1, 8) == "94287082"
    hotp_code("12345678901234567890".bytes, 37037036, 8) == "07081804"
    hotp_code("12345678901234567890".bytes, 41152263, 8) == "89005924"
    hotp_code("12345678901234567890".bytes, 66666666, 8) == "69279037"
  end

  d = effective_digits(digits)
  mac = Crypto.hmac_sha1(secret, counter_be8(counter))
  offset = (mac.get(19) or 0).to_int % 16
  b0 = (mac.get(offset) or 0).to_int % 128
  b1 = (mac.get(offset + 1) or 0).to_int
  b2 = (mac.get(offset + 2) or 0).to_int
  b3 = (mac.get(offset + 3) or 0).to_int
  bin_code = ((b0 * 256 + b1) * 256 + b2) * 256 + b3
  modulus = if d == 8: 100000000 else: 1000000
  raw = (bin_code % modulus).to_text
  zeros = if raw.byte_count < d: "0".repeat(d - raw.byte_count) else: ""
  "#{zeros}#{raw}"
end

## Computes the Unix time-step counter `floor(unix_seconds(now) / period_seconds)`.
fn time_step(now: Time, period_seconds: Int) : Int
  epoch = Time.parse("1970-01-01T00:00:00Z") or now
  p = effective_period(period_seconds)
  (now - epoch).in_milliseconds.floor_div(p * 1000)
end

## Computes the current TOTP code at `now` for `cfg`.
fn code_at(secret: Bytes, now: Time, cfg: TotpConfig) : Text
  step = time_step(now, cfg.period_seconds)
  hotp_code(secret, step, cfg.digits)
end

fn all_ascii_digits?(s: Text) : Bool
  for ch in s.chars
    return false if not ch.ascii_digit?
  end
  true
end

## Verifies a TOTP code against `secret` at `now` with skew window and strict monotonic replay protection.
fn verify(secret: Bytes, code: Text, now: Time, cfg: TotpConfig, last_used_step: Option(Int)) : TotpVerifyResult
  examples
    case Time.parse("1970-01-01T00:00:59Z")
      Some(t):
        s = "12345678901234567890".bytes
        c = TotpConfig(digits: 8, period_seconds: 30, skew_steps: 1)
        verify(s, "94287082", t, c, None) == Accepted(matched_step: 1) and
          verify(s, "94287082", t, c, Some(1)) == ReplayedStep(step: 1)
      None: false
    end
  end

  promise "replayed time steps are never accepted again"
    case last_used_step
      Some(prev):
        case result
          Accepted(matched_step: m): m > prev
          ReplayedStep(step: _) | InvalidCode: true
        end
      None: true
    end
  end

  return InvalidCode if secret.size == 0
  clean = code.trim
  d = effective_digits(cfg.digits)
  return InvalidCode if clean.byte_count != d or not all_ascii_digits?(clean)
  cur_step = time_step(now, cfg.period_seconds)
  skew = effective_skew(cfg.skew_steps)
  clean_bytes = clean.bytes
  var delta = 0 - skew
  while delta <= skew
    step = cur_step + delta
    if step >= 0
      expected = hotp_code(secret, step, d).bytes
      if Crypto.constant_time_eq?(clean_bytes, expected)
        return case last_used_step
          Some(prev) if step <= prev: ReplayedStep(step: step)
          Some(_) | None: Accepted(matched_step: step)
        end
      end
    end
    delta += 1
  end
  InvalidCode
end

fn totp_aad(user_id: Text) : Bytes
  "arvo:totp:#{user_id}".bytes
end

## Encrypts and AAD-binds a raw TOTP secret using `keyring` (`"arvo:totp:<user_id>"`).
fn seal_secret(rng: SecureRandom, keyring: Keyring.Keyring, user_id: Text, secret: Bytes) : Result(
  Text,
  TotpError
)
  return Error(EmptySecret) if secret.size == 0
  Keyring.seal(rng, keyring, secret, totp_aad(user_id)).map_error(fn(e) InvalidKeyring(e) end)
end

## Opens and verifies a sealed TOTP secret, returning `(secret, needs_rekey?)`.
fn open_secret(keyring: Keyring.Keyring, user_id: Text, sealed: Text) : Result(
  (Bytes, Bool),
  TotpError
)
  case Keyring.open(keyring, sealed, totp_aad(user_id))
    Some(opened) if opened.plaintext.size > 0: Ok((opened.plaintext, opened.needs_rekey?))
    Some(_) | None: Error(BadSealedSecret)
  end
end

## Generates `count` recovery codes formatted `XXXX-XXXX` paired with SHA-256 hex digests.
fn generate_recovery_codes(rng: SecureRandom, count: Int) : (List(Text), List(Text))
  n = if count < 1
    1
  else if count > 20
    20
  else
    count
  end
  alpha = recovery_alphabet.chars
  var display_codes = []
  var digests = []
  var i = 0
  while i < n
    raw_bytes = rng.bytes(8)
    var chars = []
    var j = 0
    while j < 8
      idx = (raw_bytes.get(j) or 0).to_int % 32
      chars = chars.append(alpha.get(idx) or 'A')
      j += 1
    end
    plain_norm = Text.from_chars(chars)
    formatted = "#{Text.from_chars(chars.take(4))}-#{Text.from_chars(chars.drop(4))}"
    digest = Crypto.sha256(plain_norm.bytes).to_hex
    display_codes = display_codes.append(formatted)
    digests = digests.append(digest)
    i += 1
  end
  (display_codes, digests)
end

fn normalize_recovery_code(raw: Text) : Text
  var out = []
  for ch in raw.trim.chars
    continue if ch == '-' or ch == ' '
    out = out.append(ch.ascii_uppercase)
  end
  Text.from_chars(out)
end

## Verifies a single-use recovery code against `stored_digests` and returns remaining digests on match.
fn verify_and_consume_recovery_code(candidate: Text, stored_digests: List(Text)) : Option(
  List(Text)
)
  examples
    verify_and_consume_recovery_code(
      "abcd-efgh",
      [
        Crypto.sha256("11112222".bytes).to_hex,
        Crypto.sha256("ABCDEFGH".bytes).to_hex,
        Crypto.sha256("99998888".bytes).to_hex
      ]
    ) ==
      Some([Crypto.sha256("11112222".bytes).to_hex, Crypto.sha256("99998888".bytes).to_hex])
    verify_and_consume_recovery_code("wrong-code", [Crypto.sha256("ABCDEFGH".bytes).to_hex]) == None
  end

  promise "consuming a recovery code removes one digest from the remaining list"
    case result
      Some(rem): rem.size == stored_digests.size - 1
      None: true
    end
  end

  norm = normalize_recovery_code(candidate)
  return None if norm.empty?
  cand_hash = Crypto.sha256(norm.bytes).to_hex.bytes
  var matched_idx = -1
  var idx = 0
  for digest in stored_digests
    if Crypto.constant_time_eq?(cand_hash, digest.bytes) and matched_idx < 0
      matched_idx = idx
    end
    idx += 1
  end
  return None if matched_idx < 0
  var remaining = []
  var j = 0
  for digest in stored_digests
    if j != matched_idx
      remaining = remaining.append(digest)
    end
    j += 1
  end
  Some(remaining)
end

test "RFC 6238 TOTP vectors, Base32 round-trip, keyring seal, replay guard, and recovery codes"
  assert base32_encode("foobar".bytes) == "MZXW6YTBOI"
  assert base32_decode("MZXW6YTBOI") == Some("foobar".bytes)
  assert base32_decode("mzxw6ytb oi==") == Some("foobar".bytes)
  assert base32_decode("BAD!DATA") == None

  rfc_secret = "12345678901234567890".bytes
  cfg8 = TotpConfig(digits: 8, period_seconds: 30, skew_steps: 0)
  t59 = Time.parse("1970-01-01T00:00:59Z") or stop "t59"
  t111 = Time.parse("2005-03-18T01:58:29Z") or stop "t111"
  t123 = Time.parse("2009-02-13T23:31:30Z") or stop "t123"
  t200 = Time.parse("2033-05-18T03:33:20Z") or stop "t200"
  assert code_at(rfc_secret, t59, cfg8) == "94287082"
  assert code_at(rfc_secret, t111, cfg8) == "07081804"
  assert code_at(rfc_secret, t123, cfg8) == "89005924"
  assert code_at(rfc_secret, t200, cfg8) == "69279037"

  rng = SecureRandom.seeded(42)
  sec = generate_secret(rng)
  assert sec.size == 20
  uri = provisioning_uri("Arvo App", "ada@acme.io", sec, default_config())
  assert uri.starts_with?("otpauth://totp/Arvo%20App:ada%40acme.io?secret=")
  assert uri.contains?("&digits=6&period=30")

  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  kr1 = case Keyring.single("k1", k1)
    Ok(k): k
    Error(_): stop "kr1"
  end
  kr2 = case Keyring.from_entries([
    Keyring.KeyEntry(id: "k2", key: k2),
    Keyring.KeyEntry(id: "k1", key: k1)
  ])
    Ok(k): k
    Error(_): stop "kr2"
  end
  sealed = case seal_secret(rng, kr1, "usr_1", sec)
    Ok(s): s
    Error(_): stop "seal"
  end
  assert open_secret(kr1, "usr_1", sealed) == Ok((sec, false))
  assert open_secret(kr2, "usr_1", sealed) == Ok((sec, true))
  assert open_secret(kr2, "usr_2", sealed) == Error(BadSealedSecret)

  # Verify skew & monotonic replay protection
  cfg6 = default_config()
  c_prev = code_at(sec, t200 - 30.seconds, cfg6)
  c_cur = code_at(sec, t200, cfg6)
  s_cur = time_step(t200, 30)
  assert verify(sec, c_prev, t200, cfg6, None) == Accepted(matched_step: s_cur - 1)
  assert verify(sec, c_cur, t200, cfg6, Some(s_cur - 1)) == Accepted(matched_step: s_cur)
  assert verify(sec, c_cur, t200, cfg6, Some(s_cur)) == ReplayedStep(step: s_cur)
  assert verify(sec, "000000", t200, cfg6, Some(s_cur + 10)) is _

  # Recovery codes: generate 10, consume once, reject reuse
  (codes, digests) = generate_recovery_codes(rng, 10)
  assert codes.size == 10 and digests.size == 10
  first_code = codes.first or stop "code 0"
  assert first_code.byte_count == 9
  rem1 = verify_and_consume_recovery_code(first_code.ascii_lowercase, digests) or stop "consume"
  assert rem1.size == 9
  assert verify_and_consume_recovery_code(first_code, rem1) == None
end
