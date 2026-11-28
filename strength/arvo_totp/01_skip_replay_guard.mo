## WRONG VERSION (strength/arvo_totp/01_skip_replay_guard.mo): Accepts a TOTP code even when step <= last_used_step.
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

fn verify(secret: Bytes, code: Text, now: Time, cfg: TotpConfig, last_used_step: Option(Int)) : TotpVerifyResult
  _ = last_used_step
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
        return Accepted(matched_step: step)
      end
    end
    delta += 1
  end
  InvalidCode
end
