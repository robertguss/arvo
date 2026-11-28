## WRONG VERSION (strength/arvo_totp/03_keep_used_recovery_code.mo): Does not remove consumed recovery code digest.
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

fn verify_and_consume_recovery_code(candidate: Text, stored_digests: List(Text)) : Option(
  List(Text)
)
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
  Some(stored_digests)
end
