## WRONG VERSION (strength/arvo_jobs/02_unbounded_backoff.mo): Omits upper 3600s clamp on backoff delay.
## Durable SQLite-backed background job queue (`arvo_jobs`) with transactional enqueue,
## atomic `BEGIN IMMEDIATE` claiming, exponential backoff retries, and stale-lock recovery.
module Arvo.Sqlite.Jobs
expose JobRecord(..),
JobError(..),
schema_sql,
init_schema,
backoff_seconds,
enqueue,
enqueue_at,
claim_next,
complete,
fail_or_retry,
requeue_stale_running,
list_recent
use Arvo.Id
use Json

default_queue = "default"
default_max_attempts = 5

## One durable row decoded from `arvo_jobs` (derives `Json` and `Sqlite.decode[JobRecord]`).
struct JobRecord
  id: Text
  queue: Text
  job_name: Text
  payload_json: Text
  state: Text
  attempts: Int
  max_attempts: Int
  run_at: Text
  locked_at: Option(Text)
  last_error: Option(Text)
  created_at: Text
  updated_at: Text
end

## Errors arising when claiming or listing `arvo_jobs` rows.
enum JobError
  Sql(SqliteError)
  Decode(Sqlite.SqliteDecodeError)
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_jobs (id TEXT PRIMARY KEY, queue TEXT NOT NULL DEFAULT 'default', job_name TEXT NOT NULL, payload_json TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending', 'running', 'completed', 'failed')), attempts INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 5, run_at TEXT NOT NULL, locked_at TEXT, last_error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL) STRICT"
index_ddl = "CREATE INDEX IF NOT EXISTS arvo_jobs_ready ON arvo_jobs (state, run_at)"
select_cols = "id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, locked_at, last_error, created_at, updated_at"

## DDL creating `arvo_jobs` and its `(state, run_at)` readiness index (ready for `Arvo.Sqlite.Migrations`).
fn schema_sql() : Text
  "#{table_ddl};\n#{index_ddl};"
end

## Ensures `arvo_jobs` and `arvo_jobs_ready` exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  db.run(index_ddl, [])
end

## Formats `Time` as fixed-width 27-byte UTC RFC 3339 (`YYYY-MM-DDTHH:MM:SS.ffffffZ`)
## so SQLite `TEXT` index ordering matches exact microsecond chronological order.
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

## Computes exponential retry delay `15 * 4^(attempts - 1)` in seconds, clamped to `15..3600`.
fn backoff_seconds(attempts: Int) : Int
  promise "backoff delay is positive and bounded between 15 and 3600 seconds"
    result >= 15 and result <= 3600
    (attempts >= 5) implies (result == 3600)
  end

  examples
    backoff_seconds(0) == 15
    backoff_seconds(1) == 15
    backoff_seconds(2) == 60
    backoff_seconds(3) == 240
    backoff_seconds(4) == 960
    backoff_seconds(5) == 3600
    backoff_seconds(50) == 3600
  end

  var delay = 15
  var step = 1
  while step < attempts
    delay = delay * 4
    step += 1
  end
  delay
end

## Enqueues an immediate `'pending'` job on the `'default'` queue without opening a nested transaction,
## so callers can enqueue inside `Sqlite.transaction` alongside domain writes.
fn enqueue(db: Sqlite.Database, rng: SecureRandom, clock: Clock, job_name: Text, payload: Json) : Result(
  Text,
  SqliteError
)
  enqueue_at(db, rng, clock, default_queue, job_name, payload, clock.now, default_max_attempts)
end

## Enqueues a `'pending'` job scheduled for `run_at` on `queue` with `max_attempts` (clamped >= 1).
fn enqueue_at(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  queue: Text,
  job_name: Text,
  payload: Json,
  run_at: Time,
  max_attempts: Int
) : Result(Text, SqliteError)
  job_id = Id.ulid(rng, clock)
  now_iso = format_utc_iso(clock.now)
  run_iso = format_utc_iso(run_at)
  eff_queue = if queue.empty?: default_queue else: queue
  eff_max = if max_attempts < 1: 1 else: max_attempts
  _ins = try db.execute(
    "INSERT INTO arvo_jobs (id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, locked_at, last_error, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, NULL, NULL, ?, ?)",
    [
      Sqlite.String(job_id),
      Sqlite.String(eff_queue),
      Sqlite.String(job_name),
      Sqlite.String(payload.to_text),
      Sqlite.Integer(eff_max),
      Sqlite.String(run_iso),
      Sqlite.String(now_iso),
      Sqlite.String(now_iso)
    ]
  )
  Ok(job_id)
end

fn run_claim_tx(tx_db: Sqlite.Database, ctx: (Text, List(Text))) : Result(
  Option(JobRecord),
  JobError
)
  now_iso = ctx.0
  names = ctx.1
  placeholders = names.map(fn(_) "?" end).join(", ")
  params = [Sqlite.String(now_iso)].concat(names.map(fn(n) Sqlite.String(n) end))
  rows = try tx_db.query(
    "SELECT #{select_cols} FROM arvo_jobs WHERE state = 'pending' AND attempts < max_attempts AND run_at <= ? AND job_name IN (#{placeholders}) ORDER BY run_at ASC, id ASC LIMIT 1",
    params
  ).map_error(fn(e) Sql(e) end)
  maybe_job = try Sqlite.decode_optional[JobRecord](rows).map_error(fn(e) Decode(e) end)
  job = case maybe_job
    Some(j): j
    None: return Ok(None)
  end
  next_attempts = job.attempts + 1
  _upd = try tx_db.execute(
    "UPDATE arvo_jobs SET state = 'running', attempts = ?, locked_at = ?, updated_at = ? WHERE id = ?",
    [
      Sqlite.Integer(next_attempts),
      Sqlite.String(now_iso),
      Sqlite.String(now_iso),
      Sqlite.String(job.id)
    ]
  ).map_error(fn(e) Sql(e) end)
  var claimed = job
  claimed.state = "running"
  claimed.attempts = next_attempts
  claimed.locked_at = Some(now_iso)
  claimed.updated_at = now_iso
  Ok(Some(claimed))
end

## Atomically claims the oldest due `'pending'` job whose `job_name` is in `job_names` (`BEGIN IMMEDIATE`).
fn claim_next(db: Sqlite.Database, clock: Clock, job_names: List(Text)) : Result(
  Option(JobRecord),
  JobError
)
  return Ok(None) if job_names.empty?
  now_iso = format_utc_iso(clock.now)
  Sqlite.transaction(db, (now_iso, job_names), run_claim_tx, fn(e) Sql(e) end)
end

## Marks `job_id` as `'completed'` and clears `locked_at`.
fn complete(db: Sqlite.Database, clock: Clock, job_id: Text) : Result(Unit, SqliteError)
  now_iso = format_utc_iso(clock.now)
  _upd = try db.execute(
    "UPDATE arvo_jobs SET state = 'completed', locked_at = NULL, updated_at = ? WHERE id = ?",
    [Sqlite.String(now_iso), Sqlite.String(job_id)]
  )
  Ok(Unit)
end

## Transitions `job_id` back to `'pending'` with exponential backoff when `attempts < max_attempts`,
## or marks it terminal `'failed'` otherwise.
fn fail_or_retry(
  db: Sqlite.Database,
  clock: Clock,
  job_id: Text,
  attempts: Int,
  max_attempts: Int,
  error_msg: Text
) : Result(Unit, SqliteError)
  now = clock.now
  now_iso = format_utc_iso(now)
  if attempts < max_attempts
    next_run_iso = format_utc_iso(now + backoff_seconds(attempts).seconds)
    _upd = try db.execute(
      "UPDATE arvo_jobs SET state = 'pending', run_at = ?, locked_at = NULL, last_error = ?, updated_at = ? WHERE id = ?",
      [
        Sqlite.String(next_run_iso),
        Sqlite.String(error_msg),
        Sqlite.String(now_iso),
        Sqlite.String(job_id)
      ]
    )
    return Ok(Unit)
  end
  _upd = try db.execute(
    "UPDATE arvo_jobs SET state = 'failed', locked_at = NULL, last_error = ?, updated_at = ? WHERE id = ?",
    [Sqlite.String(error_msg), Sqlite.String(now_iso), Sqlite.String(job_id)]
  )
  Ok(Unit)
end

## Requeues orphaned `'running'` jobs whose `locked_at` is missing or at least `stale_seconds` old,
## failing jobs whose `attempts >= max_attempts` cleanly rather than allowing unbounded retries.
fn requeue_stale_running(db: Sqlite.Database, clock: Clock, stale_seconds: Int) : Result(
  Int,
  SqliteError
)
  clamped = if stale_seconds < 0: 0 else: stale_seconds
  now = clock.now
  now_iso = format_utc_iso(now)
  cutoff_iso = format_utc_iso(now - clamped.seconds)
  exec_failed = try db.execute(
    "UPDATE arvo_jobs SET state = 'failed', locked_at = NULL, last_error = COALESCE(last_error, 'stale lock exhausted max_attempts'), updated_at = ? WHERE state = 'running' AND attempts >= max_attempts AND (locked_at IS NULL OR locked_at <= ?)",
    [Sqlite.String(now_iso), Sqlite.String(cutoff_iso)]
  )
  exec_requeued = try db.execute(
    "UPDATE arvo_jobs SET state = 'pending', locked_at = NULL, updated_at = ? WHERE state = 'running' AND attempts < max_attempts AND (locked_at IS NULL OR locked_at <= ?)",
    [Sqlite.String(now_iso), Sqlite.String(cutoff_iso)]
  )
  Ok(exec_requeued.changes + exec_failed.changes)
end

## Lists the most recently created jobs up to `limit`.
fn list_recent(db: Sqlite.Database, limit: Int) : Result(List(JobRecord), JobError)
  return Ok([]) if limit <= 0
  rows = try db.query(
    "SELECT #{select_cols} FROM arvo_jobs ORDER BY created_at DESC, id DESC LIMIT ?",
    [Sqlite.Integer(limit)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode[JobRecord](rows).map_error(fn(e) Decode(e) end)
end
