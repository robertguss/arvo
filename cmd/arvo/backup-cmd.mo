## Storage-aware backup, restore, and integrity CLI driver (`arvo backup`).
module BackupCmd
expose BackupArgs(..),
BackupPlan(..),
backup_usage,
parse_backup_args,
build_backup_plan,
build_backup_script,
run_backup
use Config
use DevCmd

## Parsed CLI options for `arvo backup`.
struct BackupArgs
  action: Text
  db: Option(Text)
  db_path: Option(Text)
  out_dir: Text
  peer_id: Option(Text)
  dry_run?: Bool
  emit_script?: Bool
  help?: Bool
end

## Resolved execution plan JSON emitted by `--dry-run`.
struct BackupPlan
  action: Text
  app_dir: Text
  db: Text
  db_path: Text
  out_dir: Text
  peer_id: Text
  script: Text
end

## Usage text for `arvo backup`.
fn backup_usage() : Text
  """
    usage: arvo backup <sync|restore|verify|local> [--app DIR] [flags]

    Runs local snapshots, integrity checks (`Modb.verify` / SQLite `PRAGMA integrity_check`),
    or crash-safe S3/R2 delta sync & restore (`Arvo.Modb.Backup`).

    Flags:
      --app DIR       Target application subdirectory (default: `.`)
      --db modb|sqlite  Override storage backend from arvo.toml
      --db-path PATH  Override database file path
      --out DIR       Output folder for local snapshots (default: `.arvo/backups`)
      --peer-id ID    Peer ID for S3 delta manifests (default: `primary`)
      --dry-run       Emit resolved BackupPlan JSON without running
      --emit-script   Print POSIX execution script for host execution
      -h, --help      Show this help
    """
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo backup --help`.")
  else
    Ok(v)
  end
end

## Parses arguments after `arvo backup`.
fn parse_backup_args(rest: List(Text)) : Result(BackupArgs, Text)
  var action = ""
  var db = None
  var db_path = None
  var out_dir = ".arvo/backups"
  var peer_id = None
  var dry_run? = false
  var emit_script? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        BackupArgs(
          action: action,
          db: db,
          db_path: db_path,
          out_dir: out_dir,
          peer_id: peer_id,
          dry_run?: dry_run?,
          emit_script?: emit_script?,
          help?: true
        )
      )
    else if a == "--dry-run"
      dry_run? = true
    else if a == "--emit-script"
      emit_script? = true
    else if a == "--db"
      v = try need_val(rest, i, "--db")
      if v != "modb" and v != "sqlite"
        return Error("invalid --db '#{v}' (expected modb or sqlite)")
      end
      db = Some(v)
      i += 1
    else if a == "--db-path"
      db_path = Some(try need_val(rest, i, "--db-path"))
      i += 1
    else if a == "--out"
      out_dir = try need_val(rest, i, "--out")
      i += 1
    else if a == "--peer-id"
      peer_id = Some(try need_val(rest, i, "--peer-id"))
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo backup`. Run `arvo backup --help`.")
    else if action.empty?
      if a != "sync" and a != "restore" and a != "verify" and a != "local"
        return Error("unknown backup action '#{a}' (expected sync, restore, verify, or local)")
      end
      action = a
    else
      return Error("unexpected extra positional argument '#{a}' for `arvo backup`.")
    end
    i += 1
  end
  if action.empty?
    return Error(
      "missing backup subcommand (`sync`, `restore`, `verify`, or `local`). Run `arvo backup --help`."
    )
  end
  Ok(
    BackupArgs(
      action: action,
      db: db,
      db_path: db_path,
      out_dir: out_dir,
      peer_id: peer_id,
      dry_run?: dry_run?,
      emit_script?: emit_script?,
      help?: false
    )
  )
end

## Builds deterministic POSIX execution script for `bargs` and `cfg`.
fn build_backup_script(bargs: BackupArgs, cfg: Config.ArvoConfig) : (Text, Text, Text, Text, Text)
  db_kind = bargs.db or (if cfg.deploy.db == "sqlite": "sqlite" else: "modb")
  resolved_db_path = bargs.db_path or cfg.backup.db_path
  resolved_peer = bargs.peer_id or (cfg.backup.peer_id or "primary")
  q = DevCmd.shell_quote

  script = if db_kind == "sqlite"
    if bargs.action == "local" or bargs.action == "sync"
      """
      set -euo pipefail
      DB_PATH=#{q(resolved_db_path)}
      OUT_DIR=#{q(bargs.out_dir)}
      mkdir -p "$OUT_DIR"
      STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
      DEST="$OUT_DIR/snapshot-$STAMP.sqlite"
      if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$DB_PATH" ".backup '$DEST'"
        sqlite3 "$DEST" "PRAGMA integrity_check;"
      else
        cp "$DB_PATH" "$DEST"
      fi
      printf 'Wrote SQLite backup: %s\\n' "$DEST"
      """
    else if bargs.action == "verify"
      """
      set -euo pipefail
      sqlite3 #{q(resolved_db_path)} "PRAGMA integrity_check;"
      """
    else
      """
      set -euo pipefail
      OUT_DIR=#{q(bargs.out_dir)}
      LATEST="$(ls -1t "$OUT_DIR"/snapshot-*.sqlite 2>/dev/null | head -n 1 || true)"
      if [ -z "$LATEST" ]; then
        printf 'No snapshot-*.sqlite found in %s\\n' "$OUT_DIR" >&2
        exit 1
      fi
      sqlite3 "$LATEST" "PRAGMA integrity_check;"
      cp "$LATEST" #{q(resolved_db_path)}
      printf 'Restored %s from %s\\n' #{q(resolved_db_path)} "$LATEST"
      """
    end
  else
    # MoDB backend delegates native sync/restore/verify to packages/arvo-modb/cmd/backup/main.mo
    if bargs.action == "local"
      """
      set -euo pipefail
      MO_BIN="${MO_BIN:-${MO:-mo}}"
      ARVO_ROOT="${ARVO_ROOT:-$(pwd)}"
      DB_PATH=#{q(resolved_db_path)}
      OUT_DIR=#{q(bargs.out_dir)}
      mkdir -p "$OUT_DIR"
      STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
      DEST="$OUT_DIR/$(basename "$DB_PATH").$STAMP"
      cp "$DB_PATH" "$DEST"
      "$MO_BIN" run "$ARVO_ROOT/packages/arvo-modb/cmd/backup/main.mo" verify --db-path "$DEST"
      printf 'Wrote and verified MoDB snapshot: %s\\n' "$DEST"
      """
    else
      """
      set -euo pipefail
      MO_BIN="${MO_BIN:-${MO:-mo}}"
      ARVO_ROOT="${ARVO_ROOT:-$(pwd)}"
      exec "$MO_BIN" run "$ARVO_ROOT/packages/arvo-modb/cmd/backup/main.mo" #{q(bargs.action)} \\
        --db-path #{q(resolved_db_path)} \\
        --peer-id #{q(resolved_peer)} \\
        --region #{q(cfg.backup.region)} \\
        --key-prefix #{q(cfg.backup.key_prefix)}#{if cfg.backup.bucket is Some(b): " --bucket #{q(b)}" else: ""}#{if cfg
        .backup.endpoint is
        Some(ep): " --endpoint #{q(ep)}" else: ""}#{if cfg.backup.path_style?: " --path-style" else: " --no-path-style"}
      """
    end
  end
  (db_kind, resolved_db_path, resolved_peer, bargs.out_dir, script)
end

## Builds `BackupPlan` combining CLI args and `arvo.toml`.
fn build_backup_plan(app_dir: Text, bargs: BackupArgs, cfg: Config.ArvoConfig) : BackupPlan
  (db_kind, resolved_db_path, resolved_peer, out_dir, script) = build_backup_script(bargs, cfg)
  BackupPlan(
    action: bargs.action,
    app_dir: app_dir,
    db: db_kind,
    db_path: resolved_db_path,
    out_dir: out_dir,
    peer_id: resolved_peer,
    script: script
  )
end

## Executes `arvo backup` (`--dry-run` / `--emit-script` or host execution).
fn run_backup(app_dir: Text, bargs: BackupArgs, app_files: Files, console: Console) : Int
  if bargs.help?
    console.print(backup_usage())
    return 0
  end
  cfg = case Config.load(app_files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo backup: #{e}")
      return 1
  end
  plan = build_backup_plan(app_dir, bargs, cfg)
  if bargs.dry_run?
    console.print(plan.to_json.to_text)
    return 0
  end
  if bargs.emit_script?
    console.print(plan.script)
    return 0
  end
  console.print(
    "arvo backup requires `bin/arvo` or `--emit-script` / `--dry-run`. Run `arvo backup --help`."
  )
  1
end

test "BackupCmd parses subcommands, renders MoDB S3 + SQLite backup scripts, and emits dry-run JSON"
  assert parse_backup_args(["--help"]) is Ok(h) and h.help?
  assert parse_backup_args([]) is Error(_)
  assert parse_backup_args(["bogus"]) is Error(_)
  assert parse_backup_args(["sync", "--db", "modb", "--peer-id", "vm1", "--dry-run"]) is Ok(ba) and
    ba.action == "sync" and
    ba.db == Some("modb") and
    ba.peer_id == Some("vm1")

  files = Files.in_memory({
    "arvo.toml": "[backup]\ndb_path = \"data/vellum.modb\"\nbucket = \"bkt\"\n"
  })
  c_dry = Console.fake()
  assert run_backup(".", ba, files, c_dry) == 0
  out_json = c_dry.printed.first or ""
  assert out_json.contains?("\"db\":\"modb\"")
  assert out_json.contains?("packages/arvo-modb/cmd/backup/main.mo")

  assert parse_backup_args(["verify", "--db", "sqlite", "--db-path", "data/app.db", "--emit-script"]) is
    Ok(sql_v)
  c_sql = Console.fake()
  assert run_backup(".", sql_v, files, c_sql) == 0
  assert (c_sql.printed.first or "").contains?("PRAGMA integrity_check;")
end
