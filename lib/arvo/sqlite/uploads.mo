## Durable SQLite-backed metadata store (`arvo_uploads`) for `Arvo.Uploads`:
## owner quotas, attachment status tracking, and expired pending orphan cleanup.
module Arvo.Sqlite.Uploads
expose UploadStoreError(..),
to_text,
schema_sql,
init_schema,
create_record,
get_record,
list_by_owner,
owner_usage_bytes,
mark_attached,
mark_deleted,
list_expired_pending,
sweep_orphans
use Arvo.Uploads

## Errors returned by SQLite upload metadata queries and orphan sweeps.
enum UploadStoreError
  Sql(SqliteError)
  Decode(Sqlite.SqliteDecodeError)
  Upload(Uploads.UploadError)
end

## Formats an `UploadStoreError` as a human-readable diagnostic.
fn to_text(err: UploadStoreError) : Text
  case err
    Sql(e): "#{e}"
    Decode(e): e.to_text
    Upload(e): Uploads.to_text(e)
  end
end

struct UsageRow
  total_bytes: Int
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_uploads (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, storage_backend TEXT NOT NULL, storage_key TEXT NOT NULL, original_filename TEXT NOT NULL, content_type TEXT NOT NULL, size_bytes INTEGER NOT NULL, sha256_hex TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('pending', 'attached', 'deleted')), created_at TEXT NOT NULL, attached_at TEXT, expires_at TEXT) STRICT"
owner_idx_ddl = "CREATE INDEX IF NOT EXISTS arvo_uploads_by_owner ON arvo_uploads (owner_id, status, created_at)"
pending_idx_ddl = "CREATE INDEX IF NOT EXISTS arvo_uploads_pending ON arvo_uploads (status, expires_at)"
select_cols = "id, owner_id, storage_backend, storage_key, original_filename, content_type, size_bytes, sha256_hex, status, created_at, attached_at, expires_at"

## DDL creating `arvo_uploads` and its owner/pending indexes (ready for `Arvo.Sqlite.Migrations`).
fn schema_sql() : Text
  "#{table_ddl};\n#{owner_idx_ddl};\n#{pending_idx_ddl};"
end

## Ensures `arvo_uploads` and its indexes exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  try db.run(owner_idx_ddl, [])
  db.run(pending_idx_ddl, [])
end

fn opt_text_param(opt: Option(Text)) : Sqlite.Value
  case opt
    Some(v): Sqlite.String(v)
    None: Sqlite.Null
  end
end

## Inserts an `UploadRecord` row into `arvo_uploads`.
fn create_record(db: Sqlite.Database, rec: Uploads.UploadRecord) : Result(
  Uploads.UploadRecord,
  UploadStoreError
)
  _ins = try db.execute(
    "INSERT INTO arvo_uploads (id, owner_id, storage_backend, storage_key, original_filename, content_type, size_bytes, sha256_hex, status, created_at, attached_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(rec.id),
      Sqlite.String(rec.owner_id),
      Sqlite.String(rec.storage_backend),
      Sqlite.String(rec.storage_key),
      Sqlite.String(rec.original_filename),
      Sqlite.String(rec.content_type),
      Sqlite.Integer(rec.size_bytes),
      Sqlite.String(rec.sha256_hex),
      Sqlite.String(rec.status),
      Sqlite.String(rec.created_at),
      opt_text_param(rec.attached_at),
      opt_text_param(rec.expires_at)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(rec)
end

## Looks up a single upload record by ID.
fn get_record(db: Sqlite.Database, upload_id: Text) : Result(
  Option(Uploads.UploadRecord),
  UploadStoreError
)
  rows = try db.query(
    "SELECT #{select_cols} FROM arvo_uploads WHERE id = ?",
    [Sqlite.String(upload_id)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode_optional[Uploads.UploadRecord](rows).map_error(fn(e) Decode(e) end)
end

## Lists non-deleted upload records for `owner_id`, newest first (default cap `50`).
fn list_by_owner(db: Sqlite.Database, owner_id: Text, limit: Int) : Result(
  List(Uploads.UploadRecord),
  UploadStoreError
)
  return Ok([]) if limit <= 0
  eff = if limit > 500: 500 else: limit
  rows = try db.query(
    "SELECT #{select_cols} FROM arvo_uploads WHERE owner_id = ? AND status != 'deleted' ORDER BY created_at DESC, id DESC LIMIT ?",
    [Sqlite.String(owner_id), Sqlite.Integer(eff)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode[Uploads.UploadRecord](rows).map_error(fn(e) Decode(e) end)
end

## Sums active (`pending` + `attached`) bytes attributed to `owner_id` for quota checks.
fn owner_usage_bytes(db: Sqlite.Database, owner_id: Text) : Result(Int, UploadStoreError)
  rows = try db.query(
    "SELECT COALESCE(SUM(size_bytes), 0) AS total_bytes FROM arvo_uploads WHERE owner_id = ? AND status != 'deleted'",
    [Sqlite.String(owner_id)]
  ).map_error(fn(e) Sql(e) end)
  row = try Sqlite.decode_one[UsageRow](rows).map_error(fn(e) Decode(e) end)
  Ok(row.total_bytes)
end

## Transitions a `'pending'` (or existing) upload to `'attached'` and clears its pending expiry.
fn mark_attached(db: Sqlite.Database, upload_id: Text, now: Time) : Result(Bool, UploadStoreError)
  now_iso = Uploads.format_utc_iso(now)
  exec = try db.execute(
    "UPDATE arvo_uploads SET status = 'attached', attached_at = ?, expires_at = NULL WHERE id = ? AND status != 'deleted'",
    [Sqlite.String(now_iso), Sqlite.String(upload_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(exec.changes > 0)
end

## Marks an upload record as `'deleted'` (returns `true` if a live row transitioned).
fn mark_deleted(db: Sqlite.Database, upload_id: Text) : Result(Bool, UploadStoreError)
  exec = try db.execute(
    "UPDATE arvo_uploads SET status = 'deleted' WHERE id = ? AND status != 'deleted'",
    [Sqlite.String(upload_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(exec.changes > 0)
end

## Lists `'pending'` uploads whose `expires_at <= now` for orphan sweeping.
fn list_expired_pending(db: Sqlite.Database, now: Time, limit: Int) : Result(
  List(Uploads.UploadRecord),
  UploadStoreError
)
  return Ok([]) if limit <= 0
  eff = if limit > 500: 500 else: limit
  now_iso = Uploads.format_utc_iso(now)
  rows = try db.query(
    "SELECT #{select_cols} FROM arvo_uploads WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at ASC LIMIT ?",
    [Sqlite.String(now_iso), Sqlite.Integer(eff)]
  ).map_error(fn(e) Sql(e) end)
  Sqlite.decode[Uploads.UploadRecord](rows).map_error(fn(e) Decode(e) end)
end

## Sweeps up to `limit` expired `'pending'` uploads, removing any `"local"` blobs beneath `local_dir`
## and transitioning rows to `'deleted'`.
fn sweep_orphans(db: Sqlite.Database, files: Files, local_dir: Text, now: Time, limit: Int) : Result(
  Int,
  UploadStoreError
)
  expired = try list_expired_pending(db, now, limit)
  var swept = 0
  for rec in expired
    if rec.storage_backend == "local"
      _del = try Uploads.delete_local(files, local_dir, rec.storage_key).map_error(
        fn(e) Upload(e) end
      )
    end
    if try mark_deleted(db, rec.id)
      swept += 1
    end
  end
  Ok(swept)
end

test "Arvo.Sqlite.Uploads manages upload lifecycle, quota usage, attachment, and orphan sweeping"
  sql = Sqlite.in_memory()
  db = case sql.open("uploads.db")
    Ok(d): d
    Error(_): stop "open"
  end
  assert init_schema(db) == Ok(Unit)
  assert schema_sql().contains?("arvo_uploads_pending")

  files = Files.in_memory({})
  t0 = Time.parse("2026-11-28T05:00:00Z") or stop "t0"
  pending_local = Uploads.UploadRecord(
    id: "up_1",
    owner_id: "usr_1",
    storage_backend: "local",
    storage_key: "receipts/usr_1/up_1.png",
    original_filename: "r1.png",
    content_type: "image/png",
    size_bytes: 512,
    sha256_hex: "0".repeat(64),
    status: "pending",
    created_at: Uploads.format_utc_iso(t0),
    attached_at: None,
    expires_at: Some(Uploads.format_utc_iso(t0 + 300.seconds))
  )
  keep_local = Uploads.UploadRecord(
    id: "up_2",
    owner_id: "usr_1",
    storage_backend: "local",
    storage_key: "receipts/usr_1/up_2.png",
    original_filename: "r2.png",
    content_type: "image/png",
    size_bytes: 1024,
    sha256_hex: "1".repeat(64),
    status: "pending",
    created_at: Uploads.format_utc_iso(t0 + 10.seconds),
    attached_at: None,
    expires_at: Some(Uploads.format_utc_iso(t0 + 900.seconds))
  )

  assert Uploads.store_local(files, "var/uploads", pending_local.storage_key, "png1".bytes) is Ok(_)
  assert Uploads.store_local(files, "var/uploads", keep_local.storage_key, "png2".bytes) is Ok(_)
  assert create_record(db, pending_local) == Ok(pending_local)
  assert create_record(db, keep_local) == Ok(keep_local)

  assert owner_usage_bytes(db, "usr_1") == Ok(1536)
  assert list_by_owner(db, "usr_1", 10) is Ok(rows) and rows.size == 2

  # Attach up_2 and advance clock past up_1 expiry (t0 + 300s)
  assert mark_attached(db, "up_2", t0 + 60.seconds) == Ok(true)
  assert get_record(db, "up_2") is Ok(Some(r2)) and
    r2.status == "attached" and
    r2.expires_at == None

  assert list_expired_pending(db, t0 + 299.seconds, 10) == Ok([])
  assert list_expired_pending(db, t0 + 300.seconds, 10) is Ok(exp) and exp.size == 1

  # Sweep removes orphan blob from disk and drops owner usage back down to 1024
  assert sweep_orphans(db, files, "var/uploads", t0 + 300.seconds, 10) == Ok(1)
  assert not files.exists?("var/uploads/#{pending_local.storage_key}")
  assert files.exists?("var/uploads/#{keep_local.storage_key}")
  assert owner_usage_bytes(db, "usr_1") == Ok(1024)
end
