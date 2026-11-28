## WRONG VERSION (strength/arvo_rate_limit/03_zero_retry_after.mo): Truncates sub-second Retry-After to 0 instead of ceiling to >= 1.
module Arvo.RateLimit

fn retry_after_ceil(reset_at: Time, now: Time) : Int
  diff_ms = (reset_at - now).in_milliseconds
  if diff_ms <= 0
    0
  else
    diff_ms.floor_div(1000)
  end
end
