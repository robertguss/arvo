## Durable MoDB-backed rate-limiter store (`_arvo_rate_limits`) using `Modb.Table`
## with an atomic transaction evaluator and O(expired) indexed expiry pruning.
module Arvo.Modb.RateLimit
expose rate_limits_table, check_in_store, check, reset, prune_expired_in_store, prune_expired
use Arvo.RateLimit
use Modb
use Modb.Errors
use Modb.Table

fn expiry_secs(t: Time) : Decimal
  epoch = Time.parse("1970-01-01T00:00:00Z") or t
  (t - epoch).in_seconds
end

fn rate_limits_by_expiry() : Table.Index(Text, RateLimit.BucketState, Decimal)
  Table.decimal_index[Text, RateLimit.BucketState](
    "_arvo_rate_limits_by_expiry",
    fn(b) expiry_secs(b.expires_at) end
  )
end

## Layer 2 `Modb.Table` definition for `_arvo_rate_limits` with an expiry `Decimal` index.
fn rate_limits_table() : Table.Table(Text, RateLimit.BucketState)
  Table.text_key[RateLimit.BucketState]("_arvo_rate_limits").with_index(rate_limits_by_expiry())
end

fn not_found_table?(err: Table.TableError) : Bool
  err is Table.Storage(Errors.Io(NotFound(path: _)))
end

## Evaluates and updates the bucket for `(rule.namespace, subject)` atomically inside `store`.
fn check_in_store(store: Modb.Store, now: Time, rule: RateLimit.LimitRule, subject: Text) : Result(
  (Modb.Store, RateLimit.LimitOutcome),
  Table.TableError
)
  tbl = rate_limits_table()
  bkey = RateLimit.bucket_key(rule.namespace, subject)
  Table.transact(
    store,
    fn(e) e end,
    fn(tx)
      existing = try Table.tx_get(tx, tbl, bkey)
      (next_st, outcome) = RateLimit.evaluate(existing, rule, now)
      tx1 = try Table.put(tx, tbl, bkey, next_st)
      Ok((tx1, outcome))
    end
  )
end

## Checks and increments the rate-limit bucket under an exclusive lock on `db_path`.
fn check(files: Files, db_path: Text, clock: Clock, rule: RateLimit.LimitRule, subject: Text) : Result(
  RateLimit.LimitOutcome,
  Table.TableError
)
  now = clock.now
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_next, outcome) = try check_in_store(s, now, rule, subject)
      Ok(outcome)
    end
  )
end

## Deletes the bucket for `(namespace, subject)` under an exclusive lock.
fn reset(files: Files, db_path: Text, namespace: Text, subject: Text) : Result(
  Unit,
  Table.TableError
)
  return Ok(Unit) if not files.read_only.exists?(db_path)
  bkey = RateLimit.bucket_key(namespace, subject)
  tbl = rate_limits_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      _next = try Table.write_tx(s, fn(tx) Table.delete(tx, tbl, bkey) end)
      Ok(Unit)
    end
  )
  case res
    Ok(_): Ok(Unit)
    Error(e): if not_found_table?(e): Ok(Unit) else: Error(e)
  end
end

## Deletes all expired rate-limit buckets (`expires_at <= now`) using an indexed O(expired) scan.
fn prune_expired_in_store(store: Modb.Store, now: Time) : Result(
  (Modb.Store, Int),
  Table.TableError
)
  tbl = rate_limits_table()
  idx = rate_limits_by_expiry()
  # Half-open upper bound +1us so exact `expires_at == now` rows are pruned and `now + 1us` survive.
  hi = expiry_secs(now) + ("0.000001".to_decimal or 0.000001)
  expired = try Table.range_by(store, tbl, idx, None, Some(hi), 0)
  return Ok((store, 0)) if expired.empty?
  Table.transact(
    store,
    fn(e) e end,
    fn(tx)
      var cur = tx
      for (bkey, _st) in expired
        cur = try Table.delete(cur, tbl, bkey)
      end
      Ok((cur, expired.size))
    end
  )
end

## Deletes all expired rate-limit buckets (`expires_at <= clock.now`) under an exclusive lock.
fn prune_expired(files: Files, db_path: Text, clock: Clock) : Result(Int, Table.TableError)
  return Ok(0) if not files.read_only.exists?(db_path)
  now = clock.now
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_next, deleted) = try prune_expired_in_store(s, now)
      Ok(deleted)
    end
  )
  case res
    Ok(n): Ok(n)
    Error(e): if not_found_table?(e): Ok(0) else: Error(e)
  end
end

test "Modb.RateLimit allows, exhausts, resets on expiry, prunes with O(expired) index, and resets"
  files = Files.in_memory({})
  path = "rate_limits.modb"
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  rule = RateLimit.LimitRule(namespace: "login", max_requests: 2, window_seconds: 60)

  assert reset(files, path, "login", "203.0.113.1") == Ok(Unit)
  assert prune_expired(files, path, Clock.fixed(t0)) == Ok(0)

  assert check(files, path, Clock.fixed(t0), rule, "203.0.113.1") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 60.seconds, limit: 2))
  assert check(files, path, Clock.fixed(t0 + 10.seconds), rule, "203.0.113.1") ==
    Ok(RateLimit.Allowed(remaining: 0, reset_at: t0 + 60.seconds, limit: 2))
  assert check(files, path, Clock.fixed(t0 + 20.seconds), rule, "203.0.113.1") ==
    Ok(RateLimit.Limited(retry_after_seconds: 40, reset_at: t0 + 60.seconds, limit: 2))

  # Different subject is isolated
  assert check(files, path, Clock.fixed(t0 + 20.seconds), rule, "203.0.113.2") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 80.seconds, limit: 2))

  # Exact boundary prune deletes 203.0.113.1 (expires_at == t0 + 60s) and keeps 203.0.113.2 (expires_at == t0 + 80s)
  assert prune_expired(files, path, Clock.fixed(t0 + 60.seconds)) == Ok(1)
  assert prune_expired(files, path, Clock.fixed(t0 + 79.seconds)) == Ok(0)

  # Reset clears remaining subject immediately
  assert reset(files, path, "login", "203.0.113.2") == Ok(Unit)
  assert check(files, path, Clock.fixed(t0 + 79.seconds), rule, "203.0.113.2") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 139.seconds, limit: 2))
end
