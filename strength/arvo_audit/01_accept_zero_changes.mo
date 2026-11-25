## WRONG VERSION (strength/arvo_audit/01_accept_zero_changes.mo): Treats zero-row optimistic UPDATE as Ok(Unit).
## Append-only `arvo_events` audit trail with before/after/undo JSON snapshots,
## lexicographically time-ordered ULID primary keys, and optimistic concurrency helpers.
module Arvo.Audit
expose AuditEntry(..),
AuditError(..),
VersionConflict(..),
schema_sql,
init_schema,
generate_id,
record,
list_recent,
get_by_id,
ensure_updated
use Json

## One immutable event row decoded from `arvo_events` (`actor` aliased as `actor_name` because `actor` is a Mo keyword).
struct AuditEntry
  id: Text
  actor_name: Text
  action: Text
  entity_table: Text
  entity_id: Text
  before_json: Option(Json)
  after_json: Option(Json)
  reason: Option(Text)
  undo_json: Option(Json)
  created_at: Time
end

## Errors arising when querying or decoding `arvo_events`.
enum AuditError
  Sql(SqliteError)
  Decode(Sqlite.SqliteDecodeError)
end

## Optimistic concurrency failure when an `UPDATE ... WHERE version = ?` matches zero rows.
enum VersionConflict
  StaleVersion
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_events (id TEXT PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL, entity_table TEXT NOT NULL, entity_id TEXT NOT NULL, before_json TEXT, after_json TEXT, reason TEXT, undo_json TEXT, created_at TEXT NOT NULL) STRICT"
entity_idx_ddl = "CREATE INDEX IF NOT EXISTS arvo_events_by_entity ON arvo_events (entity_table, entity_id, created_at)"
time_idx_ddl = "CREATE INDEX IF NOT EXISTS arvo_events_by_time ON arvo_events (created_at)"

## DDL creating `arvo_events` and its entity/time indexes (ready for `Arvo.Migrations`).
fn schema_sql() : Text
  "#{table_ddl}; #{entity_idx_ddl}; #{time_idx_ddl};"
end

## Ensures `arvo_events` and its indexes exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  try db.run(entity_idx_ddl, [])
  db.run(time_idx_ddl, [])
end

fn crockford_char(idx: Int) : Char
  alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  alphabet.chars.get(idx.floor_mod(32)) or '0'
end

fn encode_time_48(ms: Int) : List(Char)
  clamped = if ms < 0: 0 else: ms
  var v = clamped
  var rev = []
  var i = 0
  while i < 10
    rev = rev.append(crockford_char(v.floor_mod(32)))
    v = v.floor_div(32)
    i += 1
  end
  rev.reverse
end

fn encode_5bytes_base32(bs: Bytes, offset: Int) : List(Char)
  b0 = (bs.get(offset) or 0).to_int
  b1 = (bs.get(offset + 1) or 0).to_int
  b2 = (bs.get(offset + 2) or 0).to_int
  b3 = (bs.get(offset + 3) or 0).to_int
  b4 = (bs.get(offset + 4) or 0).to_int
  n40 = (((b0 * 256 + b1) * 256 + b2) * 256 + b3) * 256 + b4
  var v = n40
  var rev = []
  var i = 0
  while i < 8
    rev = rev.append(crockford_char(v.floor_mod(32)))
    v = v.floor_div(32)
    i += 1
  end
  rev.reverse
end

## Generates a 26-character Crockford Base32 ULID combining `clock.now` (ms) and 80 random bits.
fn generate_id(rng: SecureRandom, clock: Clock) : Text
  epoch = Time.parse("1970-01-01T00:00:00Z") or clock.now
  ms = (clock.now - epoch).in_milliseconds
  rand10 = rng.bytes(10)
  t_chars = encode_time_48(ms)
  r_hi = encode_5bytes_base32(rand10, 0)
  r_lo = encode_5bytes_base32(rand10, 5)
  Text.from_chars(t_chars.concat(r_hi).concat(r_lo))
end

fn json_sql_val(opt: Option(Json)) : Sqlite.Value
  case opt
    Some(j): Sqlite.String(j.to_text)
    None: Sqlite.Null
  end
end

fn text_sql_val(opt: Option(Text)) : Sqlite.Value
  case opt
    Some(s): Sqlite.String(s)
    None: Sqlite.Null
  end
end

## Appends an audit event to `arvo_events` and returns its newly generated ULID `id`.
fn record(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  actor_name: Text,
  action: Text,
  entity_table: Text,
  entity_id: Text,
  before: Option(Json),
  after: Option(Json),
  reason: Option(Text),
  undo: Option(Json)
) : Result(Text, SqliteError)
  event_id = generate_id(rng, clock)
  now_iso = clock.now.to_text
  _ins = try db.execute(
    "INSERT INTO arvo_events (id, actor, action, entity_table, entity_id, before_json, after_json, reason, undo_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(event_id),
      Sqlite.String(actor_name),
      Sqlite.String(action),
      Sqlite.String(entity_table),
      Sqlite.String(entity_id),
      json_sql_val(before),
      json_sql_val(after),
      text_sql_val(reason),
      json_sql_val(undo),
      Sqlite.String(now_iso)
    ]
  )
  Ok(event_id)
end

## Lists up to `limit` (`1..1000`) newest audit entries, newest first.
fn list_recent(db: Sqlite.Database, limit: Int) : Result(List(AuditEntry), AuditError)
  return Ok([]) if limit <= 0
  capped = if limit > 1000: 1000 else: limit
  rows = try db.query(
    "SELECT id, actor AS actor_name, action, entity_table, entity_id, before_json, after_json, reason, undo_json, created_at FROM arvo_events ORDER BY created_at DESC, id DESC LIMIT ?",
    [Sqlite.Integer(capped)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode[AuditEntry](rows).map_error(fn(e) Decode(e) end)
end

## Looks up a single `AuditEntry` by primary key `id`.
fn get_by_id(db: Sqlite.Database, id: Text) : Result(Option(AuditEntry), AuditError)
  rows = try db.query(
    "SELECT id, actor AS actor_name, action, entity_table, entity_id, before_json, after_json, reason, undo_json, created_at FROM arvo_events WHERE id = ?",
    [Sqlite.String(id)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode_optional[AuditEntry](rows).map_error(fn(e) Decode(e) end)
end

## Verifies that an optimistic-concurrency `UPDATE ... WHERE id = ? AND version = ?` updated a row.
fn ensure_updated(exec: Sqlite.ExecResult) : Result(Unit, VersionConflict)
  examples
    ensure_updated(Sqlite.ExecResult(changes: 1, last_insert_rowid: 0)) == Ok(Unit)
    ensure_updated(Sqlite.ExecResult(changes: 0, last_insert_rowid: 0)) == Error(StaleVersion)
  end

  promise "changes > 0 succeeds and changes <= 0 returns StaleVersion"
    (result == Ok(Unit)) == (exec.changes > 0)
  end

  if exec.changes >= 0
    Ok(Unit)
  else
    Error(StaleVersion)
  end
end
