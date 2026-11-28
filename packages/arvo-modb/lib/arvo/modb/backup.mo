## Native Litestream-for-MoDB encrypted continuous off-host backup & replica pull client.
## Pairs `Modb.Sync` (persistent CoW root pins + AES-256-GCM snapshots/hash-chained deltas)
## with `Arvo.S3` (AWS SigV4) and `Arvo.Keyring` zero-downtime key rotation, plus `Modb.Pull`.
module Arvo.Modb.Backup
expose BackupConfig(..),
BackupManifest(..),
BackupCycleReport(..),
BackupError(..),
to_text,
keyring_to_map,
base_snapshot_key,
delta_object_key,
manifest_object_key,
sync_to_s3,
restore_from_s3,
pull_replica_step
use Arvo.Keyring
use Arvo.S3
use Http
use Json
use Modb
use Modb.Pull
use Modb.Sync

## S3/R2 bucket destination and peer tracking configuration for continuous MoDB backup.
struct BackupConfig
  peer_id: Text
  s3: S3.S3Config
  key_prefix: Text
  aad: Text
  include_internal?: Bool
end

## Remote JSON manifest indexing the base snapshot and hash-chained delta sequence in S3/R2.
struct BackupManifest
  peer_id: Text
  base_key: Text
  delta_keys: List(Text)
  last_seq: Int
  last_hash: Text
  updated_at: Time
end

## Summary returned after one `sync_to_s3` execution.
struct BackupCycleReport
  peer_id: Text
  bootstrapped?: Bool
  uploaded_delta?: Bool
  seq: Int
  ops_exported: Int
  delta_hash: Text
  object_key: Text
end

## Errors raised by `Arvo.Modb.Backup` during sealing, S3 upload/fetch, or delta/chain verification.
enum BackupError
  S3Failure(S3.S3Error)
  SyncFailure(Sync.SyncError)
  PullFailure(Pull.PullError)
  HttpStatus(url: Text, status: Int, body: Text)
  NetworkFailure(url: Text, detail: Text)
  DecodeFailure(context: Text, detail: Text)
end

## Formats a `BackupError` cleanly without leaking secret access keys or backup key material.
fn to_text(err: BackupError) : Text
  case err
    S3Failure(e): S3.to_text(e)
    SyncFailure(e): Sync.to_text(e)
    PullFailure(e): Pull.to_text(e)
    HttpStatus(url: u, status: st, body: b):
      suffix = if b.trim.empty?: "" else: ": #{b.trim}"
      "S3 HTTP #{st} at #{u}#{suffix}"
    NetworkFailure(url: u, detail: d): "S3 network error at #{u}: #{d}"
    DecodeFailure(context: c, detail: d): "backup decode failure (#{c}): #{d}"
  end
end

## Converts an `Arvo.Keyring` into the `Map(Text, Bytes)` format consumed by `Modb.Sync`.
fn keyring_to_map(kr: Keyring.Keyring) : Map(Text, Bytes)
  var out = {}
  for entry in kr.keys
    out = out.set(entry.id, entry.key)
  end
  out
end

fn join_s3_key(prefix: Text, suffix: Text) : Result(Text, BackupError)
  var p = prefix.trim
  while p.starts_with?("/")
    p = p.drop_prefix("/") or p
  end
  while p.ends_with?("/")
    p = p.drop_suffix("/") or p
  end
  raw = if p.empty?: suffix else: "#{p}/#{suffix}"
  S3.sanitize_object_key(raw).map_error(fn(e) S3Failure(e) end)
end

## Returns the sanitized S3 object key storing the sealed base snapshot for `cfg.peer_id`.
fn base_snapshot_key(cfg: BackupConfig) : Result(Text, BackupError)
  join_s3_key(cfg.key_prefix, "#{cfg.peer_id.trim}/base.sealed.json")
end

## Returns the sanitized S3 object key storing sealed delta `seq` for `cfg.peer_id`.
fn delta_object_key(cfg: BackupConfig, seq: Int) : Result(Text, BackupError)
  join_s3_key(cfg.key_prefix, "#{cfg.peer_id.trim}/deltas/#{seq}.sealed.json")
end

## Returns the sanitized S3 object key storing `BackupManifest` JSON for `cfg.peer_id`.
fn manifest_object_key(cfg: BackupConfig) : Result(Text, BackupError)
  join_s3_key(cfg.key_prefix, "#{cfg.peer_id.trim}/manifest.json")
end

fn send_signed_s3(
  cfg: BackupConfig,
  method: Text,
  obj_key: Text,
  extra_headers: List((Text, Text)),
  body: Bytes,
  now: Time,
  net: Network
) : Result(Http.Response, BackupError)
  req = try S3.sign_request(cfg.s3, method, obj_key, [], extra_headers, body, now).map_error(
    fn(e) S3Failure(e) end
  )
  case req.send(net)
    Error(ne): Error(NetworkFailure(url: req.url, detail: "#{ne}"))
    Ok(resp):
      if resp.ok?
        Ok(resp)
      else
        Error(HttpStatus(url: req.url, status: resp.status, body: resp.text or ""))
      end
  end
end

fn put_json_s3(cfg: BackupConfig, obj_key: Text, json_text: Text, now: Time, net: Network) : Result(
  Unit,
  BackupError
)
  _resp = try send_signed_s3(
    cfg,
    "PUT",
    obj_key,
    [("Content-Type", "application/json")],
    json_text.bytes,
    now,
    net
  )
  Ok(Unit)
end

fn get_json_text_s3(cfg: BackupConfig, obj_key: Text, now: Time, net: Network) : Result(
  Text,
  BackupError
)
  resp = try send_signed_s3(cfg, "GET", obj_key, [], "".bytes, now, net)
  Ok(resp.text or "")
end

fn decode_manifest(raw: Text) : Result(BackupManifest, BackupError)
  Json.decode[BackupManifest](raw).map_error(
    fn(e) DecodeFailure(context: "backup manifest", detail: e.to_text) end
  )
end

fn decode_sealed(raw: Text, ctx: Text) : Result(Sync.SealedEnvelope, BackupError)
  Json.decode[Sync.SealedEnvelope](raw).map_error(
    fn(e) DecodeFailure(context: ctx, detail: e.to_text) end
  )
end

## Exports either an initial sealed snapshot or next incremental sealed delta from `db_path`
## using `keyring.primary_id`, uploads it + updated `BackupManifest` to S3/R2, and ONLY calls
## `Modb.Sync.ack_peer_locked` after S3 confirms `2xx` (preserving the CoW root pin on crash/error).
fn sync_to_s3(
  files: Files,
  db_path: Text,
  cfg: BackupConfig,
  keyring: Keyring.Keyring,
  rng: SecureRandom,
  clock: Clock,
  net: Network
) : Result(BackupCycleReport, BackupError)
  now = clock.now
  primary = Keyring.primary_key(keyring)
  manifest_key = try manifest_object_key(cfg)
  peer_opt = try Sync.get_peer_locked(files.read_only, db_path, cfg.peer_id).map_error(
    fn(e) SyncFailure(e) end
  )

  case peer_opt
    None:
      _peer = try Sync.init_peer_locked(
        files,
        db_path,
        cfg.peer_id,
        cfg.include_internal?,
        false,
        now
      ).map_error(fn(e) SyncFailure(e) end)
      snap = try Sync.export_peer_base_snapshot_locked(files.read_only, db_path, cfg.peer_id, now)
        .map_error(fn(e) SyncFailure(e) end)
      sealed = try Sync.seal_snapshot(rng, primary.key, primary.id, cfg.aad, snap, now).map_error(
        fn(e) SyncFailure(e) end
      )
      bkey = try base_snapshot_key(cfg)
      try put_json_s3(cfg, bkey, Sync.encode_sealed_json(sealed), now, net)
      man = BackupManifest(
        peer_id: cfg.peer_id,
        base_key: bkey,
        delta_keys: [],
        last_seq: 0,
        last_hash: Sync.genesis_hash,
        updated_at: now
      )
      try put_json_s3(cfg, manifest_key, Json.encode(man.to_json), now, net)
      Ok(
        BackupCycleReport(
          peer_id: cfg.peer_id,
          bootstrapped?: true,
          uploaded_delta?: false,
          seq: 0,
          ops_exported: 0,
          delta_hash: Sync.genesis_hash,
          object_key: bkey
        )
      )
    Some(peer):
      delta = try Sync.export_delta_locked(files, db_path, cfg.peer_id, now).map_error(
        fn(e) SyncFailure(e) end
      )
      if delta.op_count == 0
        return Ok(
          BackupCycleReport(
            peer_id: cfg.peer_id,
            bootstrapped?: false,
            uploaded_delta?: false,
            seq: peer.acked_seq,
            ops_exported: 0,
            delta_hash: peer.acked_hash,
            object_key: ""
          )
        )
      end
      raw_man = try get_json_text_s3(cfg, manifest_key, now, net)
      man = try decode_manifest(raw_man)
      sealed_delta = try Sync.seal_delta(rng, primary.key, primary.id, cfg.aad, delta, now)
        .map_error(fn(e) SyncFailure(e) end)
      dkey = try delta_object_key(cfg, delta.seq)
      try put_json_s3(cfg, dkey, Sync.encode_sealed_json(sealed_delta), now, net)
      next_man = BackupManifest(
        peer_id: man.peer_id,
        base_key: man.base_key,
        delta_keys: man.delta_keys.append(dkey),
        last_seq: delta.seq,
        last_hash: delta.delta_hash,
        updated_at: now
      )
      try put_json_s3(cfg, manifest_key, Json.encode(next_man.to_json), now, net)
      _acked = try Sync.ack_peer_locked(
        files,
        db_path,
        cfg.peer_id,
        delta.seq,
        delta.delta_hash,
        now
      ).map_error(fn(e) SyncFailure(e) end)
      Ok(
        BackupCycleReport(
          peer_id: cfg.peer_id,
          bootstrapped?: false,
          uploaded_delta?: true,
          seq: delta.seq,
          ops_exported: delta.op_count,
          delta_hash: delta.delta_hash,
          object_key: dkey
        )
      )
  end
end

## Downloads the remote `BackupManifest`, base snapshot, and all incremental delta envelopes
## from S3/R2, verifies hashes + decrypts across key rotation via `keyring`, and restores `dst_path`.
fn restore_from_s3(
  files: Files,
  dst_path: Text,
  cfg: BackupConfig,
  keyring: Keyring.Keyring,
  clock: Clock,
  net: Network
) : Result(Sync.RestoreChainReport, BackupError)
  now = clock.now
  manifest_key = try manifest_object_key(cfg)
  man = try decode_manifest(try get_json_text_s3(cfg, manifest_key, now, net))
  raw_base = try get_json_text_s3(cfg, man.base_key, now, net)
  sealed_base = try decode_sealed(raw_base, "sealed base snapshot")
  var sealed_deltas = []
  for dkey in man.delta_keys
    raw_d = try get_json_text_s3(cfg, dkey, now, net)
    sealed_d = try decode_sealed(raw_d, "sealed delta #{dkey}")
    sealed_deltas = sealed_deltas.append(sealed_d)
  end
  Sync.restore_sealed_chain_with_keyring(
    files,
    dst_path,
    sealed_base,
    sealed_deltas,
    keyring_to_map(keyring),
    cfg.aad
  ).map_error(fn(e) SyncFailure(e) end)
end

## Runs one scheduled `Modb.Pull.pull_once` replication step against an upstream HTTP peer.
fn pull_replica_step(files: Files, cfg: Pull.PullConfig, net: Network, clock: Clock) : Result(
  Pull.PullCycleReport,
  BackupError
)
  Pull.pull_once(files, net, clock, cfg).map_error(fn(e) PullFailure(e) end)
end

fn must_ok_bkp(res: Result(A, B)) : A
  case res
    Ok(v): v
    Error(_): stop "unexpected Arvo.Modb.Backup error"
  end
end

test "Arvo.Modb.Backup performs crash-safe 2-phase S3 backup, key-rotated restore, and idle no-op"
  files = Files.in_memory({})
  path = "primary.modb"
  rng = SecureRandom.seeded(9991)
  t0 = Time.parse("2026-11-28T04:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)

  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  kr1 = must_ok_bkp(Keyring.single("k1", k1))
  kr2 = must_ok_bkp(
    Keyring.from_entries([Keyring.KeyEntry(id: "k2", key: k2), Keyring.KeyEntry(id: "k1", key: k1)])
  )

  s3_cfg = S3.S3Config(
    endpoint: "http://127.0.0.1:9000",
    region: "us-east-1",
    bucket: "arvo-backups",
    access_key_id: "minioadmin",
    secret_access_key: "minioadminsecret",
    session_token: None,
    path_style?: true
  )
  bcfg = BackupConfig(
    peer_id: "s3-main",
    s3: s3_cfg,
    key_prefix: "/prod/",
    aad: "app:primary",
    include_internal?: false
  )
  assert must_ok_bkp(base_snapshot_key(bcfg)) == "prod/s3-main/base.sealed.json"
  assert must_ok_bkp(delta_object_key(bcfg, 1)) == "prod/s3-main/deltas/1.sealed.json"
  assert must_ok_bkp(manifest_object_key(bcfg)) == "prod/s3-main/manifest.json"

  # Seed initial item a=1 in primary.modb
  _init = must_ok_bkp(
    Modb.with_exclusive_lock(
      files,
      path,
      fn(me) me.to_text end,
      fn(s)
        Modb.write_tx(s, fn(tx) Modb.tx_put(tx, "items", "a".bytes, "1".bytes) end).map_error(
          fn(e) e.to_text end
        )
      end
    )
  )

  # 1. Bootstrap snapshot with k1
  base_url = "http://127.0.0.1:9000/arvo-backups/prod/s3-main/base.sealed.json"
  man_url = "http://127.0.0.1:9000/arvo-backups/prod/s3-main/manifest.json"
  d1_url = "http://127.0.0.1:9000/arvo-backups/prod/s3-main/deltas/1.sealed.json"
  net_boot = Network.fake_scripted([
    ("PUT", base_url, [Network.Respond(response: Http.reply(200, ""))]),
    ("PUT", man_url, [Network.Respond(response: Http.reply(200, ""))])
  ])
  r_boot = must_ok_bkp(sync_to_s3(files, path, bcfg, kr1, rng, clk, net_boot))
  assert r_boot.bootstrapped? and r_boot.seq == 0

  # 2. Idle sync with zero DB writes performs ZERO network calls
  empty_net = Network.fake({})
  r_idle = must_ok_bkp(sync_to_s3(files, path, bcfg, kr1, rng, clk, empty_net))
  assert not r_idle.bootstrapped? and not r_idle.uploaded_delta? and r_idle.ops_exported == 0

  # 3. Mutate b=2 -> simulate failed S3 PUT 500 -> acked_seq MUST stay 0!
  _w1 = must_ok_bkp(
    Modb.with_exclusive_lock(
      files,
      path,
      fn(me) me.to_text end,
      fn(s)
        Modb.write_tx(s, fn(tx) Modb.tx_put(tx, "items", "b".bytes, "2".bytes) end).map_error(
          fn(e) e.to_text end
        )
      end
    )
  )
  init_man = BackupManifest(
    peer_id: "s3-main",
    base_key: "prod/s3-main/base.sealed.json",
    delta_keys: [],
    last_seq: 0,
    last_hash: Sync.genesis_hash,
    updated_at: t0
  )
  init_man_json = Json.encode(init_man.to_json)

  net_fail_put = Network.fake_scripted([
    ("GET", man_url, [Network.Respond(response: Http.reply(200, init_man_json))]),
    ("PUT", d1_url, [Network.Respond(response: Http.reply(500, "S3 transient failure"))])
  ])
  assert sync_to_s3(files, path, bcfg, kr1, rng, clk, net_fail_put) is
    Error(HttpStatus(url: _, status: 500, body: _))
  peer_unacked = must_ok_bkp(Sync.get_peer_locked(files.read_only, path, "s3-main")) or stop "peer"
  assert peer_unacked.acked_seq == 0

  # 4. Retry under rotated keyring kr2 (seals delta 1 under k2) -> acks seq 1!
  net_retry_ok = Network.fake_scripted([
    ("GET", man_url, [Network.Respond(response: Http.reply(200, init_man_json))]),
    ("PUT", d1_url, [Network.Respond(response: Http.reply(200, ""))]),
    ("PUT", man_url, [Network.Respond(response: Http.reply(200, ""))])
  ])
  r_d1 = must_ok_bkp(sync_to_s3(files, path, bcfg, kr2, rng, clk, net_retry_ok))
  assert r_d1.uploaded_delta? and r_d1.seq == 1 and r_d1.ops_exported == 1
  peer_acked = must_ok_bkp(Sync.get_peer_locked(files.read_only, path, "s3-main")) or stop "peer"
  assert peer_acked.acked_seq == 1 and peer_acked.acked_hash == r_d1.delta_hash

  # 5. Cross-key restore_from_s3 test: real sealed base(k1) + real sealed delta(k2) -> restored DB verified
  assert Modb.with_exclusive_lock(
    files,
    "src_chain.modb",
    fn(me) me.to_text end,
    fn(s0)
      s1 = try Modb.write_tx(s0, fn(tx) Modb.tx_put(tx, "items", "x".bytes, "10".bytes) end)
        .map_error(fn(e) e.to_text end)
      (s2, _p) = try Sync.init_peer(s1, "s3-main", false, false, t0).map_error(Sync.to_text)
      snap = try Sync.export_peer_base_snapshot(s2, "s3-main", t0).map_error(Sync.to_text)
      s3 = try Modb.write_tx(s2, fn(tx) Modb.tx_put(tx, "items", "y".bytes, "20".bytes) end)
        .map_error(fn(e) e.to_text end)
      (_s4, delta1) = try Sync.export_delta(s3, "s3-main", t0).map_error(Sync.to_text)
      Ok((snap, delta1))
    end
  ) is
    Ok((real_snap, real_d1))

  sb = must_ok_bkp(Sync.seal_snapshot(rng, k1, "k1", bcfg.aad, real_snap, t0))
  sd1 = must_ok_bkp(Sync.seal_delta(rng, k2, "k2", bcfg.aad, real_d1, t0))
  full_man = BackupManifest(
    peer_id: "s3-main",
    base_key: "prod/s3-main/base.sealed.json",
    delta_keys: ["prod/s3-main/deltas/1.sealed.json"],
    last_seq: real_d1.seq,
    last_hash: real_d1.delta_hash,
    updated_at: t0
  )
  net_restore = Network.fake_scripted([
    ("GET", man_url, [Network.Respond(response: Http.reply(200, Json.encode(full_man.to_json)))]),
    ("GET", base_url, [Network.Respond(response: Http.reply(200, Sync.encode_sealed_json(sb)))]),
    ("GET", d1_url, [Network.Respond(response: Http.reply(200, Sync.encode_sealed_json(sd1)))])
  ])
  rest_files = Files.in_memory({})
  rep = must_ok_bkp(restore_from_s3(rest_files, "restored.modb", bcfg, kr2, clk, net_restore))
  assert rep.final_txid >= 2
  assert Modb.open_read_only(rest_files.read_only, "restored.modb") is Ok(rst)
  assert Modb.get(rst, "items", "x".bytes) == Ok(Some("10".bytes))
  assert Modb.get(rst, "items", "y".bytes) == Ok(Some("20".bytes))
  assert Modb.verify(rst) is Ok(_)
end
