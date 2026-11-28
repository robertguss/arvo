## WRONG VERSION (strength/arvo_rate_limit/01_off_by_one_limit.mo): Allows one extra request per window (cur_count <= eff_max).
module Arvo.RateLimit

fn evaluate(existing: Option(BucketState), rule: LimitRule, now: Time) : (BucketState, LimitOutcome)
  eff_max = effective_limit(rule)
  eff_win = effective_window(rule)
  case existing
    Some(st) if st.expires_at > now:
      cur_count = if st.count < 0: 0 else: st.count
      if cur_count <= eff_max
        new_count = cur_count + 1
        next = BucketState(
          count: new_count,
          window_start: st.window_start,
          expires_at: st.expires_at
        )
        (next, Allowed(remaining: eff_max - new_count, reset_at: st.expires_at, limit: eff_max))
      else
        retry = retry_after_ceil(st.expires_at, now)
        (st, Limited(retry_after_seconds: retry, reset_at: st.expires_at, limit: eff_max))
      end
    Some(_) | None:
      exp = now.checked_add(eff_win.seconds) or now
      next = BucketState(count: 1, window_start: now, expires_at: exp)
      (next, Allowed(remaining: eff_max - 1, reset_at: exp, limit: eff_max))
  end
end
