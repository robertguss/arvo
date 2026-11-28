## WRONG VERSION (strength/arvo_totp/02_accept_invalid_base32.mo): Silently ignores invalid Base32 characters.
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

fn base32_decode(encoded: Text) : Option(Bytes)
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
      None: continue
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
