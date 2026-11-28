## Durable SQLite-backed rate-limiter store (`arvo_rate_limits`) using atomic `BEGIN IMMEDIATE`
## transactions and fixed-width UTC expiry timestamps.
module Arvo.Sqlite.RateLimit
expose RateLimitError(..), schema_sql, init_schema, check, reset, prune_expired
use Arvo.RateLimit

## Errors returned by SQLite rate-limit operations.
enum RateLimitError
  Sql(SqliteError)
  Decode(Sqlite.SqliteDecodeError)
  InvalidTimestamp(Text)
end

struct StoredBucketRow
  count: Int
  window_start: Text
  expires_at: Text
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_rate_limits (bucket_key TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start TEXT NOT NULL, expires_at TEXT NOT NULL) STRICT"
index_ddl = "CREATE INDEX IF NOT EXISTS arvo_rate_limits_by_expiry ON arvo_rate_limits (expires_at)"

## DDL creating `arvo_rate_limits` and its expiry index (ready for `Arvo.Sqlite.Migrations`).
fn schema_sql() : Text
  "#{table_ddl};\n#{index_ddl};"
end

## Ensures `arvo_rate_limits` and its expiry index exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  db.run(index_ddl, [])
end

fn format_utc_iso(t: Time) : Text
  raw = t.to_text
  base = raw.drop_suffix("Z") or raw
  parts = base.split(".")
  return "#{base}.000000Z" if parts.size == 1
  whole = parts.first or base
  frac = parts.get(1) or ""
  zeros = if frac.byte_count < 6: "0".repeat(6 - frac.byte_count) else: ""
  "#{whole}.#{frac}#{zeros}Z"
end

fn run_check_tx(tx_db: Sqlite.Database, ctx: (Text, RateLimit.LimitRule, Time)) : Result(
  RateLimit.LimitOutcome,
  RateLimitError
)
  bkey = ctx.0
  rule = ctx.1
  now = ctx.2
  rows = try tx_db.query(
    "SELECT count, window_start, expires_at FROM arvo_rate_limits WHERE bucket_key = ?",
    [Sqlite.String(bkey)]
  ).map_error(fn(e) Sql(e) end)
  maybe_row = try Sqlite.decode_optional[StoredBucketRow](rows).map_error(fn(e) Decode(e) end)
  existing = case maybe_row
    None: None
    Some(r):
      ws = try Time.parse(r.window_start).or_fail(InvalidTimestamp(r.window_start))
      exp = try Time.parse(r.expires_at).or_fail(InvalidTimestamp(r.expires_at))
      Some(RateLimit.BucketState(count: r.count, window_start: ws, expires_at: exp))
  end
  (next_st, outcome) = RateLimit.evaluate(existing, rule, now)
  _up = try tx_db.execute(
    "INSERT INTO arvo_rate_limits (bucket_key, count, window_start, expires_at) VALUES (?, ?, ?, ?) ON CONFLICT(bucket_key) DO UPDATE SET count = excluded.count, window_start = excluded.window_start, expires_at = excluded.expires_at",
    [
      Sqlite.String(bkey),
      Sqlite.Integer(next_st.count),
      Sqlite.String(format_utc_iso(next_st.window_start)),
      Sqlite.String(format_utc_iso(next_st.expires_at))
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(outcome)
end

## Atomically checks and increments the rate-limit bucket in `db` (`BEGIN IMMEDIATE`).
fn check(db: Sqlite.Database, clock: Clock, rule: RateLimit.LimitRule, subject: Text) : Result(
  RateLimit.LimitOutcome,
  RateLimitError
)
  bkey = RateLimit.bucket_key(rule.namespace, subject)
  Sqlite.transaction(db, (bkey, rule, clock.now), run_check_tx, fn(e) Sql(e) end)
end

## Deletes the bucket for `(namespace, subject)` from `arvo_rate_limits`.
fn reset(db: Sqlite.Database, namespace: Text, subject: Text) : Result(Unit, SqliteError)
  bkey = RateLimit.bucket_key(namespace, subject)
  _del = try db.execute("DELETE FROM arvo_rate_limits WHERE bucket_key = ?", [Sqlite.String(bkey)])
  Ok(Unit)
end

## Deletes all expired buckets (`expires_at <= clock.now`), returning the deleted row count.
fn prune_expired(db: Sqlite.Database, clock: Clock) : Result(Int, SqliteError)
  now_iso = format_utc_iso(clock.now)
  exec = try db.execute(
    "DELETE FROM arvo_rate_limits WHERE expires_at <= ?",
    [Sqlite.String(now_iso)]
  )
  Ok(exec.changes)
end

test "Sqlite.RateLimit enforces fixed windows, resets on expiry, prunes at exact boundary, and resets"
  sql = Sqlite.in_memory()
  assert sql.open("rl.sqlite") is Ok(db)
  assert init_schema(db) == Ok(Unit)
  assert schema_sql().contains?("arvo_rate_limits_by_expiry")

  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  rule = RateLimit.LimitRule(namespace: "login", max_requests: 2, window_seconds: 60)

  assert check(db, Clock.fixed(t0), rule, "198.51.100.1") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 60.seconds, limit: 2))
  assert check(db, Clock.fixed(t0 + 5.seconds), rule, "198.51.100.1") ==
    Ok(RateLimit.Allowed(remaining: 0, reset_at: t0 + 60.seconds, limit: 2))
  assert check(db, Clock.fixed(t0 + 15.seconds), rule, "198.51.100.1") ==
    Ok(RateLimit.Limited(retry_after_seconds: 45, reset_at: t0 + 60.seconds, limit: 2))

  assert check(db, Clock.fixed(t0 + 15.seconds), rule, "198.51.100.2") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 75.seconds, limit: 2))

  # Exact boundary prune clears 198.51.100.1 and preserves 198.51.100.2
  assert prune_expired(db, Clock.fixed(t0 + 60.seconds)) == Ok(1)
  assert prune_expired(db, Clock.fixed(t0 + 74.seconds)) == Ok(0)

  assert reset(db, "login", "198.51.100.2") == Ok(Unit)
  assert check(db, Clock.fixed(t0 + 74.seconds), rule, "198.51.100.2") ==
    Ok(RateLimit.Allowed(remaining: 1, reset_at: t0 + 134.seconds, limit: 2))
end
