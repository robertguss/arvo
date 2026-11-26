## Durable MoDB-backed background job queue (`_arvo_jobs`) with transactional `WriteTx`
## enqueue (composable inside `Modb.Ledger` / `Modb.Table` transactions), indexed due-job
## claiming, exponential backoff retries, and stale-lock recovery.
module Arvo.Modb.Jobs
expose JobRecord(..),
jobs_table,
format_utc_iso,
backoff_seconds,
prepare,
prepare_at,
tx_put,
tx_enqueue,
tx_enqueue_at,
enqueue,
enqueue_at,
claim_next,
complete,
fail_or_retry,
requeue_stale_running,
list_recent
use Arvo.Id
use Json
use Modb
use Modb.Errors
use Modb.Table

default_queue = "default"
default_max_attempts = 5

## One durable job row stored in `_arvo_jobs` (schema-compatible with `Arvo.Sqlite.Jobs.JobRecord`).
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

fn jobs_by_ready() : Table.Index(Text, JobRecord, Text)
  Table.text_index[Text, JobRecord]("_arvo_jobs_by_ready", fn(j) "#{j.state}|#{j.run_at}" end)
end

## Layer 2 `Modb.Table` definition for `_arvo_jobs` with a `(state, run_at)` readiness index.
fn jobs_table() : Table.Table(Text, JobRecord)
  Table.text_key[JobRecord]("_arvo_jobs").with_index(jobs_by_ready())
end

fn not_found_table?(err: Table.TableError) : Bool
  err is Table.Storage(Errors.Io(NotFound(path: _)))
end

## Formats `Time` as fixed-width 27-byte UTC RFC 3339 (`YYYY-MM-DDTHH:MM:SS.ffffffZ`)
## so index key ordering matches exact microsecond chronological order.
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
  while step < attempts and delay < 3600
    next = delay * 4
    delay = if next > 3600: 3600 else: next
    step += 1
  end
  delay
end

## Builds a pure `'pending'` `JobRecord` for immediate execution (safe to pass into `WriteTx` closures).
fn prepare(rng: SecureRandom, clock: Clock, job_name: Text, payload: Json) : JobRecord
  prepare_at(rng, clock, default_queue, job_name, payload, clock.now, default_max_attempts)
end

## Builds a pure `'pending'` `JobRecord` scheduled for `run_at` (safe to pass into `WriteTx` closures).
fn prepare_at(
  rng: SecureRandom,
  clock: Clock,
  queue: Text,
  job_name: Text,
  payload: Json,
  run_at: Time,
  max_attempts: Int
) : JobRecord
  job_id = Id.ulid(rng, clock)
  now_iso = format_utc_iso(clock.now)
  run_iso = format_utc_iso(run_at)
  eff_queue = if queue.empty?: default_queue else: queue
  eff_max = if max_attempts < 1: 1 else: max_attempts
  JobRecord(
    id: job_id,
    queue: eff_queue,
    job_name: job_name,
    payload_json: payload.to_text,
    state: "pending",
    attempts: 0,
    max_attempts: eff_max,
    run_at: run_iso,
    locked_at: None,
    last_error: None,
    created_at: now_iso,
    updated_at: now_iso
  )
end

## Persists a pre-built `JobRecord` inside an open `Modb.WriteTx` without capturing capabilities.
fn tx_put(tx: Modb.WriteTx, rec: JobRecord) : Result((Modb.WriteTx, Text), Table.TableError)
  tx1 = try Table.put(tx, jobs_table(), rec.id, rec)
  Ok((tx1, rec.id))
end

## Enqueues an immediate `'pending'` job inside an open `Modb.WriteTx` (for named helpers with `rng`/`clock`).
fn tx_enqueue(tx: Modb.WriteTx, rng: SecureRandom, clock: Clock, job_name: Text, payload: Json) : Result(
  (Modb.WriteTx, Text),
  Table.TableError
)
  tx_put(tx, prepare(rng, clock, job_name, payload))
end

## Enqueues a `'pending'` job scheduled for `run_at` inside an open `Modb.WriteTx`.
fn tx_enqueue_at(
  tx: Modb.WriteTx,
  rng: SecureRandom,
  clock: Clock,
  queue: Text,
  job_name: Text,
  payload: Json,
  run_at: Time,
  max_attempts: Int
) : Result((Modb.WriteTx, Text), Table.TableError)
  tx_put(tx, prepare_at(rng, clock, queue, job_name, payload, run_at, max_attempts))
end

## Enqueues an immediate `'pending'` job into `db_path` under an exclusive advisory lock.
fn enqueue(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  job_name: Text,
  payload: Json
) : Result(Text, Table.TableError)
  enqueue_at(
    files,
    db_path,
    rng,
    clock,
    default_queue,
    job_name,
    payload,
    clock.now,
    default_max_attempts
  )
end

## Enqueues a `'pending'` job scheduled for `run_at` into `db_path` under an exclusive advisory lock.
fn enqueue_at(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  queue: Text,
  job_name: Text,
  payload: Json,
  run_at: Time,
  max_attempts: Int
) : Result(Text, Table.TableError)
  rec = prepare_at(rng, clock, queue, job_name, payload, run_at, max_attempts)
  tbl = jobs_table()
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      _next = try Table.write_tx(s, fn(tx) Table.put(tx, tbl, rec.id, rec) end)
      Ok(rec.id)
    end
  )
end

## Atomically claims the oldest due `'pending'` job whose `job_name` is in `job_names` (`run_at <= now`, FIFO by `id`).
fn claim_next(files: Files, db_path: Text, clock: Clock, job_names: List(Text)) : Result(
  Option(JobRecord),
  Table.TableError
)
  return Ok(None) if job_names.empty? or not files.read_only.exists?(db_path)
  now_iso = format_utc_iso(clock.now)
  tbl = jobs_table()
  idx = jobs_by_ready()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      due = try Table.range_by(s, tbl, idx, Some("pending|"), Some("pending|#{now_iso}~"), 0)
      maybe_match = due.find(fn(pair)
        j = pair.1
        j.state == "pending" and j.run_at <= now_iso and job_names.any?(fn(n) n == j.job_name end)
      end)
      (target_id, _) = case maybe_match
        Some(p): p
        None: return Ok(None)
      end
      (_next, claimed) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          current = case try Table.tx_get(tx, tbl, target_id)
            Some(j): j
            None: return Ok((tx, None))
          end
          var updated = current
          updated.state = "running"
          updated.attempts = current.attempts + 1
          updated.locked_at = Some(now_iso)
          updated.updated_at = now_iso
          tx1 = try Table.put(tx, tbl, target_id, updated)
          Ok((tx1, Some(updated)))
        end
      )
      Ok(claimed)
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok(None) else: Error(e)
  end
end

## Completes the running attempt returned by `claim_next`; stale attempts are ignored.
fn complete(files: Files, db_path: Text, clock: Clock, job_id: Text, attempt: Int) : Result(
  Unit,
  Table.TableError
)
  return Ok(Unit) if not files.read_only.exists?(db_path)
  now_iso = format_utc_iso(clock.now)
  tbl = jobs_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      _next = try Table.write_tx(
        s,
        fn(tx)
          case try Table.tx_get(tx, tbl, job_id)
            None: Ok(tx)
            Some(job):
              return Ok(tx) if job.state != "running" or job.attempts != attempt
              var updated = job
              updated.state = "completed"
              updated.locked_at = None
              updated.updated_at = now_iso
              Table.put(tx, tbl, job_id, updated)
          end
        end
      )
      Ok(Unit)
    end
  )
  case res
    Ok(_): Ok(Unit)
    Error(e): if not_found_table?(e): Ok(Unit) else: Error(e)
  end
end

## Retries or fails the running attempt returned by `claim_next`; stale attempts are ignored.
fn fail_or_retry(
  files: Files,
  db_path: Text,
  clock: Clock,
  job_id: Text,
  attempt: Int,
  error_msg: Text
) : Result(Unit, Table.TableError)
  return Ok(Unit) if not files.read_only.exists?(db_path)
  now = clock.now
  now_iso = format_utc_iso(now)
  tbl = jobs_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      _next = try Table.write_tx(
        s,
        fn(tx)
          case try Table.tx_get(tx, tbl, job_id)
            None: Ok(tx)
            Some(job):
              return Ok(tx) if job.state != "running" or job.attempts != attempt
              var updated = job
              if job.attempts < job.max_attempts
                updated.state = "pending"
                updated.run_at = format_utc_iso(now + backoff_seconds(job.attempts).seconds)
              else
                updated.state = "failed"
              end
              updated.locked_at = None
              updated.last_error = Some(error_msg)
              updated.updated_at = now_iso
              Table.put(tx, tbl, job_id, updated)
          end
        end
      )
      Ok(Unit)
    end
  )
  case res
    Ok(_): Ok(Unit)
    Error(e): if not_found_table?(e): Ok(Unit) else: Error(e)
  end
end

## Recovers orphaned running jobs, failing those with no attempts left, and returns the count.
fn requeue_stale_running(files: Files, db_path: Text, clock: Clock, stale_seconds: Int) : Result(
  Int,
  Table.TableError
)
  return Ok(0) if not files.read_only.exists?(db_path)
  clamped = if stale_seconds < 0: 0 else: stale_seconds
  now = clock.now
  now_iso = format_utc_iso(now)
  cutoff_iso = format_utc_iso(now - clamped.seconds)
  tbl = jobs_table()
  idx = jobs_by_ready()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      running = try Table.range_by(s, tbl, idx, Some("running|"), Some("running|~"), 0)
      var stale = []
      for (jid, job) in running
        is_stale? = case job.locked_at
          None: true
          Some(ts): ts <= cutoff_iso
        end
        if is_stale?
          stale = stale.append((jid, job))
        end
      end
      return Ok(0) if stale.empty?
      (_next, count) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          var cur = tx
          for (jid, job) in stale
            var updated = job
            if job.attempts >= job.max_attempts
              updated.state = "failed"
              updated.last_error = Some("job lease expired on the final attempt")
            else
              updated.state = "pending"
            end
            updated.locked_at = None
            updated.updated_at = now_iso
            cur = try Table.put(cur, tbl, jid, updated)
          end
          Ok((cur, stale.size))
        end
      )
      Ok(count)
    end
  )
  case res
    Ok(n): Ok(n)
    Error(e): if not_found_table?(e): Ok(0) else: Error(e)
  end
end

## Lists the most recently created jobs up to `limit` using `ReadFiles`.
fn list_recent(rf: ReadFiles, db_path: Text, limit: Int) : Result(List(JobRecord), Table.TableError)
  return Ok([]) if limit <= 0 or not rf.exists?(db_path)
  tbl = jobs_table()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      rows = try Table.all(s, tbl)
      recs = rows.map(fn(p) p.1 end).sort_by_desc(fn(j) "#{j.created_at}|#{j.id}" end)
      Ok(recs.take(limit))
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok([]) else: Error(e)
  end
end

test "modb jobs support transactional rollback, FIFO claim_next, backoff retry, terminal failed, and stale recovery"
  files = Files.in_memory({})
  rf = files.read_only
  path = "jobs.modb"
  rng = SecureRandom.seeded(42)
  t0 = Time.parse("2026-11-22T06:00:00Z") or stop "valid t0"
  c0 = Clock.fixed(t0)

  assert list_recent(rf, path, 10) == Ok([])
  assert claim_next(files, path, c0, ["csv.import"]) == Ok(None)
  assert requeue_stale_running(files, path, c0, 300) == Ok(0)

  # Transactional rollback: tx_put inside a failing Modb transaction leaves zero jobs & zero domain rows
  domain_tbl = Table.text_key[Text]("domain_items")
  draft_job = prepare(rng, c0, "csv.import", Json.Object({"rows": Json.int(3)}))
  tx_res = Modb.with_exclusive_lock(
    files,
    path,
    fn(me) "#{me.to_text}" end,
    fn(s)
      Table.transact(
        s,
        fn(e) e.to_text end,
        fn(tx)
          tx1 = try Table.put(tx, domain_tbl, "item1", "draft").map_error(fn(e) e.to_text end)
          (tx2, _jid) = try tx_put(tx1, draft_job).map_error(fn(e) e.to_text end)
          if true
            return Error("abort domain write")
          end
          Ok((tx2, Unit))
        end
      )
    end
  )
  assert tx_res is Error("abort domain write")
  assert list_recent(rf, path, 10) == Ok([])
  assert Modb.with_shared_lock(
    rf,
    path,
    fn(me) Table.Storage(me) end,
    fn(s) Table.all(s, domain_tbl) end
  ) ==
    Ok([])

  # Enqueue two due jobs + one future job + one unregistered job
  assert enqueue(files, path, rng, c0, "csv.import", Json.Object({"batch": Json.int(1)})) is Ok(id1)
  c1 = Clock.fixed(t0 + 500.milliseconds)
  assert enqueue(files, path, rng, c1, "csv.import", Json.Object({"batch": Json.int(2)})) is Ok(id2)
  assert enqueue_at(files, path, rng, c1, "sync", "mercury.sync", Json.Null, t0 + 10.minutes, 2) is
    Ok(id_future)
  assert enqueue(files, path, rng, c1, "other.job", Json.Null) is Ok(_id_other)

  assert claim_next(files, path, c1, []) == Ok(None)

  # FIFO claim_next claims id1 first (including sub-second run_at ordering)
  assert claim_next(files, path, c1, ["csv.import", "mercury.sync"]) is Ok(Some(j1))
  assert j1.id == id1
  assert j1.state == "running"
  assert j1.attempts == 1
  assert j1.payload_json == "{\"batch\":1}"
  assert j1.locked_at is Some(_)

  # Second claim gets id2 while id1 is running and id_future is not yet due
  assert claim_next(files, path, c1, ["csv.import", "mercury.sync"]) is Ok(Some(j2))
  assert j2.id == id2
  assert j2.attempts == 1
  assert claim_next(files, path, c1, ["csv.import", "mercury.sync"]) == Ok(None)

  assert complete(files, path, c1, id1, j1.attempts) == Ok(Unit)

  # Retry id2 on error: attempts=1 < max_attempts=5 -> pending at t1 + 15s
  assert fail_or_retry(files, path, c1, id2, j2.attempts, "temporary timeout") == Ok(Unit)
  assert claim_next(files, path, Clock.fixed(t0 + 10.seconds), ["csv.import"]) == Ok(None)
  c_after_backoff = Clock.fixed(t0 + 16.seconds)
  assert claim_next(files, path, c_after_backoff, ["csv.import"]) is Ok(Some(j2_retry))
  assert j2_retry.id == id2
  assert j2_retry.attempts == 2
  assert j2_retry.last_error == Some("temporary timeout")

  # Stale running recovery: after 6 minutes, j2_retry is requeued to pending
  c_stale = Clock.fixed(t0 + 7.minutes)
  assert requeue_stale_running(files, path, c_stale, 300) == Ok(1)
  assert requeue_stale_running(files, path, c_stale, 300) == Ok(0)

  # Advance past 10m so id_future (max_attempts = 2) becomes due; fail twice -> terminal 'failed'
  c_due = Clock.fixed(t0 + 11.minutes)
  assert claim_next(files, path, c_due, ["mercury.sync"]) is Ok(Some(jf1))
  assert jf1.id == id_future
  assert jf1.attempts == 1
  assert fail_or_retry(files, path, c_due, jf1.id, jf1.attempts, "502 bad gateway") == Ok(Unit)

  c_due2 = Clock.fixed(t0 + 12.minutes)
  assert claim_next(files, path, c_due2, ["mercury.sync"]) is Ok(Some(jf2))
  assert jf2.attempts == 2
  assert fail_or_retry(files, path, c_due2, jf2.id, jf2.attempts, "502 again") == Ok(Unit)
  assert claim_next(files, path, Clock.fixed(t0 + 3.hours), ["mercury.sync"]) == Ok(None)

  assert list_recent(rf, path, 10) is Ok(recent)
  assert recent.size == 4
  failed_rec = recent.find(fn(r) r.id == id_future end) or stop "id_future present"
  assert failed_rec.state == "failed"
  assert failed_rec.attempts == 2
  assert failed_rec.last_error == Some("502 again")
  assert failed_rec.to_json.text_at("state") == Some("failed")
end

test "stale claim owners cannot complete or retry jobs and stale final attempts fail"
  files = Files.in_memory({})
  path = "jobs.modb"
  rng = SecureRandom.seeded(72)
  t0 = Time.parse("2026-11-22T06:00:00Z") or stop "valid t0"
  c0 = Clock.fixed(t0)
  c1 = Clock.fixed(t0 + 60.seconds)
  assert enqueue_at(files, path, rng, c0, "default", "worker", Json.Null, t0, 2) is Ok(id)
  assert claim_next(files, path, c0, ["worker"]) is Ok(Some(old))
  assert requeue_stale_running(files, path, c1, 30) == Ok(1)
  assert claim_next(files, path, c1, ["worker"]) is Ok(Some(current))
  assert current.id == id and current.attempts == old.attempts + 1

  assert complete(files, path, c1, id, old.attempts) == Ok(Unit)
  assert list_recent(files.read_only, path, 1) == Ok([current])
  assert fail_or_retry(files, path, c1, id, old.attempts, "late failure") == Ok(Unit)
  assert list_recent(files.read_only, path, 1) == Ok([current])

  c2 = Clock.fixed(t0 + 120.seconds)
  assert requeue_stale_running(files, path, c2, 30) == Ok(1)
  assert claim_next(files, path, c2, ["worker"]) == Ok(None)
  assert list_recent(files.read_only, path, 1) is Ok(rows)
  failed = rows.first or stop "expected failed job"
  assert failed.state == "failed"
  assert failed.attempts == failed.max_attempts and failed.locked_at == None
  assert failed.last_error is Some(_)
end
