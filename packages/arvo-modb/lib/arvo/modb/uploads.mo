## Durable MoDB-backed metadata store (`_arvo_uploads`) over Layer 2 `Modb.Table`
## with `ReadFiles`-only owner/quota lookups and local+DB orphan sweeping.
module Arvo.Modb.Uploads
expose UploadStoreError(..),
uploads_table,
tx_put,
create_record,
get_record,
list_by_owner,
owner_usage_bytes,
mark_attached,
mark_deleted,
list_expired_pending,
sweep_orphans
use Arvo.Uploads
use Modb
use Modb.Errors
use Modb.Table

## Errors returned by MoDB upload metadata operations.
enum UploadStoreError
  TableFailure(Table.TableError)
  UploadFailure(Uploads.UploadError)
end

fn uploads_by_owner() : Table.Index(Text, Uploads.UploadRecord, Text)
  Table.text_index[Text, Uploads.UploadRecord]("_arvo_uploads_by_owner", fn(u) u.owner_id end)
end

fn uploads_by_status() : Table.Index(Text, Uploads.UploadRecord, Text)
  Table.text_index[Text, Uploads.UploadRecord]("_arvo_uploads_by_status", fn(u) u.status end)
end

## Layer 2 `Modb.Table` definition for `_arvo_uploads` with `owner_id` and `status` indexes.
fn uploads_table() : Table.Table(Text, Uploads.UploadRecord)
  Table.text_key[Uploads.UploadRecord]("_arvo_uploads").with_index(uploads_by_owner()).with_index(
    uploads_by_status()
  )
end

fn not_found_table?(err: Table.TableError) : Bool
  err is Table.Storage(Errors.Io(NotFound(path: _)))
end

## Persists `rec` inside an open `Modb.WriteTx` (composable with `Modb.Ledger.transact`).
fn tx_put(tx: Modb.WriteTx, rec: Uploads.UploadRecord) : Result(
  (Modb.WriteTx, Uploads.UploadRecord),
  Table.TableError
)
  tx1 = try Table.put(tx, uploads_table(), rec.id, rec)
  Ok((tx1, rec))
end

## Stores a new `UploadRecord` into `db_path` under an exclusive lock.
fn create_record(files: Files, db_path: Text, rec: Uploads.UploadRecord) : Result(
  Uploads.UploadRecord,
  UploadStoreError
)
  tbl = uploads_table()
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) TableFailure(Table.Storage(me)) end,
    fn(s)
      _next = try Table.write_tx(s, fn(tx) Table.put(tx, tbl, rec.id, rec) end).map_error(
        fn(e) TableFailure(e) end
      )
      Ok(rec)
    end
  )
end

## Reads a single upload record strictly via `ReadFiles`.
fn get_record(rf: ReadFiles, db_path: Text, upload_id: Text) : Result(
  Option(Uploads.UploadRecord),
  Table.TableError
)
  return Ok(None) if not rf.exists?(db_path)
  tbl = uploads_table()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      buckets = try Modb.buckets(s).map_error(fn(e) Table.Storage(e) end)
      return Ok(None) if not buckets.contains?("_arvo_uploads")
      Table.get(s, tbl, upload_id)
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok(None) else: Error(e)
  end
end

## Lists non-deleted upload records for `owner_id` newest-first via `ReadFiles`.
fn list_by_owner(rf: ReadFiles, db_path: Text, owner_id: Text, limit: Int) : Result(
  List(Uploads.UploadRecord),
  Table.TableError
)
  return Ok([]) if limit <= 0 or not rf.exists?(db_path)
  tbl = uploads_table()
  idx = uploads_by_owner()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      buckets = try Modb.buckets(s).map_error(fn(e) Table.Storage(e) end)
      return Ok([]) if not buckets.contains?("_arvo_uploads")
      rows = try Table.lookup(s, tbl, idx, owner_id)
      active = rows.map(fn(p) p.1 end).filter(fn(u) u.status != "deleted" end).sort_by_desc(
        fn(u) "#{u.created_at}|#{u.id}" end
      )
      Ok(active.take(limit))
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok([]) else: Error(e)
  end
end

## Sums active (`pending` + `attached`) bytes owned by `owner_id` strictly via `ReadFiles`.
fn owner_usage_bytes(rf: ReadFiles, db_path: Text, owner_id: Text) : Result(Int, Table.TableError)
  return Ok(0) if not rf.exists?(db_path)
  tbl = uploads_table()
  idx = uploads_by_owner()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      buckets = try Modb.buckets(s).map_error(fn(e) Table.Storage(e) end)
      return Ok(0) if not buckets.contains?("_arvo_uploads")
      rows = try Table.lookup(s, tbl, idx, owner_id)
      total = rows.map(fn(p) p.1 end).filter(fn(u) u.status != "deleted" end).map(
        fn(u) u.size_bytes end
      ).sum
      Ok(total)
    end
  )
  case res
    Ok(n): Ok(n)
    Error(e): if not_found_table?(e): Ok(0) else: Error(e)
  end
end

## Marks an upload `'attached'` and clears its pending expiry inside `db_path`.
fn mark_attached(files: Files, db_path: Text, upload_id: Text, now: Time) : Result(
  Bool,
  Table.TableError
)
  return Ok(false) if not files.read_only.exists?(db_path)
  now_iso = Uploads.format_utc_iso(now)
  tbl = uploads_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_next, changed) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          case try Table.tx_get(tx, tbl, upload_id)
            None: Ok((tx, false))
            Some(rec):
              return Ok((tx, false)) if rec.status == "deleted"
              var updated = rec
              updated.status = "attached"
              updated.attached_at = Some(now_iso)
              updated.expires_at = None
              tx1 = try Table.put(tx, tbl, upload_id, updated)
              Ok((tx1, true))
          end
        end
      )
      Ok(changed)
    end
  )
  case res
    Ok(b): Ok(b)
    Error(e): if not_found_table?(e): Ok(false) else: Error(e)
  end
end

## Marks an upload `'deleted'` inside `db_path`.
fn mark_deleted(files: Files, db_path: Text, upload_id: Text) : Result(Bool, Table.TableError)
  return Ok(false) if not files.read_only.exists?(db_path)
  tbl = uploads_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_next, changed) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          case try Table.tx_get(tx, tbl, upload_id)
            None: Ok((tx, false))
            Some(rec):
              return Ok((tx, false)) if rec.status == "deleted"
              var updated = rec
              updated.status = "deleted"
              tx1 = try Table.put(tx, tbl, upload_id, updated)
              Ok((tx1, true))
          end
        end
      )
      Ok(changed)
    end
  )
  case res
    Ok(b): Ok(b)
    Error(e): if not_found_table?(e): Ok(false) else: Error(e)
  end
end

fn upload_expired?(rec: Uploads.UploadRecord, now: Time) : Bool
  return false if rec.status != "pending"
  case rec.expires_at
    None: false
    Some(exp_s):
      case Time.parse(exp_s)
        Some(exp_t): exp_t <= now
        None: false
      end
  end
end

## Lists up to `limit` `'pending'` uploads whose `expires_at <= now` strictly via `ReadFiles`.
fn list_expired_pending(rf: ReadFiles, db_path: Text, now: Time, limit: Int) : Result(
  List(Uploads.UploadRecord),
  Table.TableError
)
  return Ok([]) if limit <= 0 or not rf.exists?(db_path)
  tbl = uploads_table()
  idx = uploads_by_status()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      buckets = try Modb.buckets(s).map_error(fn(e) Table.Storage(e) end)
      return Ok([]) if not buckets.contains?("_arvo_uploads")
      rows = try Table.lookup(s, tbl, idx, "pending")
      exp = rows.map(fn(p) p.1 end).filter(fn(r) upload_expired?(r, now) end).sort_by(
        fn(r) r.expires_at or "" end
      )
      Ok(exp.take(limit))
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok([]) else: Error(e)
  end
end

## Sweeps up to `limit` expired `'pending'` uploads from both local disk and `_arvo_uploads`.
fn sweep_orphans(files: Files, db_path: Text, local_dir: Text, now: Time, limit: Int) : Result(
  Int,
  UploadStoreError
)
  return Ok(0) if limit <= 0 or not files.read_only.exists?(db_path)
  expired = try list_expired_pending(files.read_only, db_path, now, limit).map_error(
    fn(e) TableFailure(e) end
  )
  return Ok(0) if expired.empty?
  for rec in expired
    if rec.storage_backend == "local"
      _rm = try Uploads.delete_local(files, local_dir, rec.storage_key).map_error(
        fn(e) UploadFailure(e) end
      )
    end
  end
  tbl = uploads_table()
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) TableFailure(Table.Storage(me)) end,
    fn(s)
      (_next, count) = try Table.transact(
        s,
        fn(e) TableFailure(e) end,
        fn(tx)
          var cur = tx
          var swept = 0
          for rec in expired
            case try Table.tx_get(cur, tbl, rec.id).map_error(fn(e) TableFailure(e) end)
              Some(cur_rec) if cur_rec.status != "deleted":
                var updated = cur_rec
                updated.status = "deleted"
                cur = try Table.put(cur, tbl, rec.id, updated).map_error(fn(e) TableFailure(e) end)
                swept += 1
              Some(_) | None: Unit
            end
          end
          Ok((cur, swept))
        end
      )
      Ok(count)
    end
  )
end

test "Arvo.Modb.Uploads supports ReadFiles queries, quotas, attach flow, and orphan sweeps"
  files = Files.in_memory({})
  rf = files.read_only
  path = "uploads.modb"
  t0 = Time.parse("2026-11-28T06:00:00Z") or stop "t0"

  assert get_record(rf, path, "missing") == Ok(None)
  assert owner_usage_bytes(rf, path, "usr_1") == Ok(0)

  r1 = Uploads.UploadRecord(
    id: "up_1",
    owner_id: "usr_1",
    storage_backend: "local",
    storage_key: "docs/usr_1/up_1.pdf",
    original_filename: "a.pdf",
    content_type: "application/pdf",
    size_bytes: 2048,
    sha256_hex: "a".repeat(64),
    status: "pending",
    created_at: Uploads.format_utc_iso(t0),
    attached_at: None,
    expires_at: Some(Uploads.format_utc_iso(t0 + 120.seconds))
  )
  r2 = Uploads.UploadRecord(
    id: "up_2",
    owner_id: "usr_1",
    storage_backend: "local",
    storage_key: "docs/usr_1/up_2.pdf",
    original_filename: "b.pdf",
    content_type: "application/pdf",
    size_bytes: 4096,
    sha256_hex: "b".repeat(64),
    status: "pending",
    created_at: Uploads.format_utc_iso(t0 + 5.seconds),
    attached_at: None,
    expires_at: Some(Uploads.format_utc_iso(t0 + 600.seconds))
  )

  assert Uploads.store_local(files, "var/uploads", r1.storage_key, "pdf1".bytes) is Ok(_)
  assert Uploads.store_local(files, "var/uploads", r2.storage_key, "pdf2".bytes) is Ok(_)
  assert create_record(files, path, r1) == Ok(r1)
  assert create_record(files, path, r2) == Ok(r2)

  assert owner_usage_bytes(rf, path, "usr_1") == Ok(6144)
  assert list_by_owner(rf, path, "usr_1", 10) is Ok(items) and items.size == 2

  assert mark_attached(files, path, "up_2", t0 + 30.seconds) == Ok(true)
  assert get_record(rf, path, "up_2") is Ok(Some(loaded)) and
    loaded.status == "attached" and
    loaded.expires_at == None

  assert list_expired_pending(rf, path, t0 + 120.seconds, 10) is Ok(exp) and exp.size == 1
  assert sweep_orphans(files, path, "var/uploads", t0 + 120.seconds, 10) == Ok(1)
  assert not files.exists?("var/uploads/#{r1.storage_key}")
  assert files.exists?("var/uploads/#{r2.storage_key}")
  assert owner_usage_bytes(rf, path, "usr_1") == Ok(4096)
end
