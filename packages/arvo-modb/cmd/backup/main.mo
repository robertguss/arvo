## Native pure-Mo runner for `arvo backup <verify|sync|restore>` over `Arvo.Modb.Backup`.
module Main
expose BackupCliArgs(..),
parse_cli_args,
verify_database,
build_runtime_config,
build_runtime_keyring,
run_backup_cli,
main
use Arvo.Keyring
use Arvo.Modb.Backup
use Arvo.S3
use Http
use Json
use Modb
use Modb.Ledger

## Parsed CLI options for the MoDB backup CLI runner.
struct BackupCliArgs
  action: Text
  db_path: Text
  peer_id: Text
  bucket: Option(Text)
  region: Text
  endpoint: Option(Text)
  key_prefix: Text
  path_style?: Bool
  include_internal?: Bool
  help?: Bool
end

fn usage() : Text
  """
    usage: mo run packages/arvo-modb/cmd/backup/main.mo <verify|sync|restore> --db-path PATH [flags]

    Flags:
      --db-path PATH       MoDB database file path
      --peer-id ID         Peer ID (default: ARVO_BACKUP_PEER_ID or "primary")
      --bucket NAME        S3/R2 bucket name (default: ARVO_S3_BUCKET)
      --region REGION      S3 region (default: ARVO_S3_REGION or "auto")
      --endpoint URL       S3 endpoint URL (default: ARVO_S3_ENDPOINT)
      --key-prefix PREFIX  Object prefix (default: ARVO_S3_PREFIX or "backups")
      --path-style         Use path-style S3 URLs (default: true)
      --no-path-style      Use virtual-hosted S3 URLs
      --include-internal   Include internal `_modb_*` buckets
      -h, --help           Show help
    """
end

fn need_arg(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("#{flag} requires a value")
  else
    Ok(v)
  end
end

## Parses command-line arguments and applies `env` fallbacks.
fn parse_cli_args(raw: List(Text), env: Env) : Result(BackupCliArgs, Text)
  var action = ""
  var db_path = env.get("ARVO_BACKUP_DB_PATH") or ""
  var peer_id = env.get("ARVO_BACKUP_PEER_ID") or "primary"
  var bucket = env.get("ARVO_S3_BUCKET")
  var region = env.get("ARVO_S3_REGION") or "auto"
  var endpoint = env.get("ARVO_S3_ENDPOINT")
  var key_prefix = env.get("ARVO_S3_PREFIX") or "backups"
  var path_style? = true
  var include_internal? = false
  var i = 0
  while i < raw.size
    a = raw.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        BackupCliArgs(
          action: action,
          db_path: db_path,
          peer_id: peer_id,
          bucket: bucket,
          region: region,
          endpoint: endpoint,
          key_prefix: key_prefix,
          path_style?: path_style?,
          include_internal?: include_internal?,
          help?: true
        )
      )
    else if a == "--path-style"
      path_style? = true
    else if a == "--no-path-style"
      path_style? = false
    else if a == "--include-internal"
      include_internal? = true
    else if a == "--db-path"
      db_path = try need_arg(raw, i, "--db-path")
      i += 1
    else if a == "--peer-id"
      peer_id = try need_arg(raw, i, "--peer-id")
      i += 1
    else if a == "--bucket"
      bucket = Some(try need_arg(raw, i, "--bucket"))
      i += 1
    else if a == "--region"
      region = try need_arg(raw, i, "--region")
      i += 1
    else if a == "--endpoint"
      endpoint = Some(try need_arg(raw, i, "--endpoint"))
      i += 1
    else if a == "--key-prefix"
      key_prefix = try need_arg(raw, i, "--key-prefix")
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}'")
    else if action.empty?
      if a != "verify" and a != "sync" and a != "restore"
        return Error("unknown action '#{a}' (expected verify, sync, or restore)")
      end
      action = a
    else
      return Error("unexpected argument '#{a}'")
    end
    i += 1
  end
  if action.empty?
    return Error("missing action (`verify`, `sync`, or `restore`)")
  end
  if db_path.trim.empty?
    return Error("missing --db-path (or ARVO_BACKUP_DB_PATH)")
  end
  Ok(
    BackupCliArgs(
      action: action,
      db_path: db_path.trim,
      peer_id: peer_id.trim,
      bucket: bucket,
      region: region.trim,
      endpoint: endpoint,
      key_prefix: key_prefix.trim,
      path_style?: path_style?,
      include_internal?: include_internal?,
      help?: false
    )
  )
end

## Runs `Modb.verify` and optional `Ledger.verify_audit_store` against `db_path` using `ReadFiles`.
fn verify_database(rf: ReadFiles, db_path: Text) : Result((Modb.VerifyReport, Option(Int)), Text)
  if not rf.exists?(db_path)
    return Error("MoDB file does not exist: #{db_path}")
  end
  store = try Modb.open_read_only(rf, db_path).map_error(fn(e) e.to_text end)
  rep = try Modb.verify(store).map_error(fn(e) e.to_text end)
  buckets = try Modb.buckets(store).map_error(fn(e) e.to_text end)
  audit_count = if buckets.contains?(Ledger.audit_bucket)
    aud = try Ledger.verify_audit_store(store).map_error(fn(e) Ledger.to_text(e) end)
    Some(aud.entry_count)
  else
    None
  end
  Ok((rep, audit_count))
end

## Resolves an `Arvo.Keyring` from `ARVO_BACKUP_KEY` or `ARVO_SECRET_KEY`.
fn build_runtime_keyring(env: Env) : Result(Keyring.Keyring, Text)
  raw_hex = (env.get("ARVO_BACKUP_KEY") or (env.get("ARVO_SECRET_KEY") or "")).trim
  key_id = (env.get("ARVO_BACKUP_KEY_ID") or "k1").trim
  return Error("ARVO_BACKUP_KEY (or ARVO_SECRET_KEY) must be set (64 hex chars)") if raw_hex.empty?
  key_bytes = try Bytes.from_hex(raw_hex).or_fail("backup key must be valid hex")
  Keyring.single(key_id, key_bytes).map_error(fn(e) Keyring.to_text(e) end)
end

## Constructs `Arvo.Modb.Backup.BackupConfig` from CLI args and `Env`.
fn build_runtime_config(bargs: BackupCliArgs, env: Env) : Result(Backup.BackupConfig, Text)
  bucket = try bargs.bucket.or_fail("S3 bucket required (--bucket or ARVO_S3_BUCKET)")
  endpoint = try bargs.endpoint.or_fail("S3 endpoint required (--endpoint or ARVO_S3_ENDPOINT)")
  ak = try (env.get("ARVO_S3_ACCESS_KEY_ID")).or_fail("ARVO_S3_ACCESS_KEY_ID required")
  sk = try (env.get("ARVO_S3_SECRET_ACCESS_KEY")).or_fail("ARVO_S3_SECRET_ACCESS_KEY required")
  s3 = S3.S3Config(
    endpoint: endpoint,
    region: bargs.region,
    bucket: bucket,
    access_key_id: ak,
    secret_access_key: sk,
    session_token: env.get("ARVO_S3_SESSION_TOKEN"),
    path_style?: bargs.path_style?
  )
  Ok(
    Backup.BackupConfig(
      peer_id: bargs.peer_id,
      s3: s3,
      key_prefix: bargs.key_prefix,
      aad: "arvo-modb:#{bargs.peer_id}",
      include_internal?: bargs.include_internal?
    )
  )
end

## Dispatches `verify`, `sync`, or `restore` over explicit capabilities.
fn run_backup_cli(
  raw_args: List(Text),
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network,
  console: Console
) : Int
  bargs = case parse_cli_args(raw_args, env)
    Ok(a): a
    Error(e):
      console.error("arvo-modb-backup: #{e}")
      return 1
  end
  if bargs.help?
    console.print(usage())
    return 0
  end
  if bargs.action == "verify"
    case verify_database(files.read_only, bargs.db_path)
      Ok((rep, audit_count)):
        out = Json.Object({
          "ok": Json.Boolean(true),
          "db_path": Json.String(bargs.db_path),
          "txid": Json.int(rep.txid),
          "page_count": Json.int(rep.page_count),
          "bucket_count": Json.int(rep.bucket_count),
          "live_pages": Json.int(rep.live_pages),
          "audit_entries": case audit_count
            Some(c): Json.int(c)
            None: Json.Null
          end
        })
        console.print(out.to_text)
        0
      Error(e):
        console.error("verify failed: #{e}")
        1
    end
  else if bargs.action == "sync"
    kr = case build_runtime_keyring(env)
      Ok(k): k
      Error(e):
        console.error("keyring failed: #{e}")
        return 1
    end
    cfg = case build_runtime_config(bargs, env)
      Ok(c): c
      Error(e):
        console.error("config failed: #{e}")
        return 1
    end
    case Backup.sync_to_s3(files, bargs.db_path, cfg, kr, rng, clock, net)
      Ok(rep):
        console.print(
          Json.Object({
            "ok": Json.Boolean(true),
            "peer_id": Json.String(rep.peer_id),
            "bootstrapped": Json.Boolean(rep.bootstrapped?),
            "uploaded_delta": Json.Boolean(rep.uploaded_delta?),
            "seq": Json.int(rep.seq),
            "ops_exported": Json.int(rep.ops_exported),
            "object_key": Json.String(rep.object_key)
          }).to_text
        )
        0
      Error(e):
        console.error("sync failed: #{Backup.to_text(e)}")
        1
    end
  else
    kr = case build_runtime_keyring(env)
      Ok(k): k
      Error(e):
        console.error("keyring failed: #{e}")
        return 1
    end
    cfg = case build_runtime_config(bargs, env)
      Ok(c): c
      Error(e):
        console.error("config failed: #{e}")
        return 1
    end
    case Backup.restore_from_s3(files, bargs.db_path, cfg, kr, clock, net)
      Ok(rep):
        console.print(
          Json.Object({
            "ok": Json.Boolean(true),
            "db_path": Json.String(bargs.db_path),
            "final_txid": Json.int(rep.final_txid)
          }).to_text
        )
        0
      Error(e):
        console.error("restore failed: #{Backup.to_text(e)}")
        1
    end
  end
end

fn main(
  args: Args,
  console: Console,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  net: Network
) : Int
  run_backup_cli(args.list, files, rng, clock, env, net, console)
end

test "Backup CLI verifies MoDB integrity and runs S3 sync & restore with fake net"
  files = Files.in_memory({})
  db_path = "app.modb"
  t0 = Time.parse("2026-11-28T05:00:00Z") or stop "t0"
  rng = SecureRandom.seeded(101)
  clk = Clock.fixed(t0)

  assert Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) me.to_text end,
    fn(s)
      Modb.write_tx(s, fn(tx) Modb.tx_put(tx, "items", "k1".bytes, "v1".bytes) end).map_error(
        fn(e) e.to_text end
      )
    end
  ) is
    Ok(_)

  c_ver = Console.fake()
  assert run_backup_cli(
    ["verify", "--db-path", db_path],
    files,
    rng,
    clk,
    Env.of({}),
    Network.fake({}),
    c_ver
  ) ==
    0
  assert (c_ver.printed.first or "").contains?("\"ok\":true")

  env = Env.of({
    "ARVO_BACKUP_KEY": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
    "ARVO_S3_BUCKET": "arvo-test",
    "ARVO_S3_REGION": "us-east-1",
    "ARVO_S3_ENDPOINT": "http://127.0.0.1:9000",
    "ARVO_S3_ACCESS_KEY_ID": "minio",
    "ARVO_S3_SECRET_ACCESS_KEY": "miniopass"
  })
  base_url = "http://127.0.0.1:9000/arvo-test/backups/primary/base.sealed.json"
  man_url = "http://127.0.0.1:9000/arvo-test/backups/primary/manifest.json"
  net_sync = Network.fake_scripted([
    ("PUT", base_url, [Network.Respond(response: Http.reply(200, ""))]),
    ("PUT", man_url, [Network.Respond(response: Http.reply(200, ""))])
  ])
  c_sync = Console.fake()
  assert run_backup_cli(["sync", "--db-path", db_path], files, rng, clk, env, net_sync, c_sync) == 0
  assert (c_sync.printed.first or "").contains?("\"bootstrapped\":true")
end
