## WRONG VERSION (strength/arvo_keyring/02_accept_short_key.mo): Accepts non-32-byte keys (>= 16 bytes).
module Arvo.Keyring

fn valid_key?(key: Bytes) : Bool
  key.size >= 16
end
