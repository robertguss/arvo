## Deterministic seed profile registry shared across `Sqlite.in_memory()` tests,
## `Arvo.Sim`, `arvo control launch --seed`, and local development.
module Arvo.Testing.Seed
expose SeedContext(..), SeedProfile(..), default_context, profile_names, find_profile, run_profile

## Deterministic context parameters for seed execution.
struct SeedContext
  now: Time
  seed: Int
  env_overrides: Map(Text, Text)
end

## One named database seed profile executable identically against in-memory or real SQLite.
struct SeedProfile
  name: Text
  description: Text
  apply: fn(Sqlite.Database, SecureRandom, Clock, Env) : Result(Unit, Text)
end

## Builds a `SeedContext` at `now` with default deterministic seed `2026` and no env overrides.
fn default_context(now: Time) : SeedContext
  SeedContext(now: now, seed: 2026, env_overrides: {})
end

## Lists all registered profile names in declaration order.
fn profile_names(profiles: List(SeedProfile)) : List(Text)
  profiles.map(fn(p) p.name end)
end

## Finds a `SeedProfile` by exact `name`.
fn find_profile(profiles: List(SeedProfile), name: Text) : Option(SeedProfile)
  profiles.find(fn(p) p.name == name end)
end

## Runs the named `SeedProfile` against `db`, or returns a descriptive error listing available profiles.
fn run_profile(
  profiles: List(SeedProfile),
  name: Text,
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Unit, Text)
  case find_profile(profiles, name)
    Some(profile): profile.apply(db, rng, clock, env)
    None:
      names = profile_names(profiles)
      available = if names.empty?: "none" else: names.join(", ")
      Error("unknown seed profile '#{name}' (available: #{available})")
  end
end

fn seed_empty(db: Sqlite.Database, _rng: SecureRandom, _clock: Clock, _env: Env) : Result(
  Unit,
  Text
)
  db.run(
    "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, label TEXT NOT NULL, token TEXT NOT NULL) STRICT",
    []
  ).map_error(fn(e) "#{e}" end)
end

fn seed_baseline(db: Sqlite.Database, rng: SecureRandom, clock: Clock, env: Env) : Result(
  Unit,
  Text
)
  try seed_empty(db, rng, clock, env)
  tok = rng.bytes(4).to_hex
  label = env.get("SEED_LABEL") or "baseline"
  _ins = try db.execute(
    "INSERT INTO items (id, label, token) VALUES (1, ?, ?)",
    [Sqlite.String("#{label}@#{clock.now.to_text}"), Sqlite.String(tok)]
  ).map_error(fn(e) "#{e}" end)
  Ok(Unit)
end

fn seed_failing(_db: Sqlite.Database, _rng: SecureRandom, _clock: Clock, _env: Env) : Result(
  Unit,
  Text
)
  Error("boom during seed")
end

test "Seed runs profiles deterministically across fresh Sqlite.in_memory databases and reports unknown/failing profiles"
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  ctx = default_context(t0)
  assert ctx.now == t0
  assert ctx.seed == 2026
  assert ctx.env_overrides == {}

  profiles = [
    SeedProfile(name: "empty", description: "Schema only", apply: seed_empty),
    SeedProfile(name: "baseline", description: "One deterministic item", apply: seed_baseline),
    SeedProfile(name: "broken", description: "Failing seed", apply: seed_failing)
  ]
  assert profile_names(profiles) == ["empty", "baseline", "broken"]
  assert find_profile(profiles, "missing") is None
  assert find_profile(profiles, "baseline") is Some(bp)
  assert bp.description == "One deterministic item"

  sql_a = Sqlite.in_memory()
  assert sql_a.open("a.sqlite") is Ok(db_a)
  sql_b = Sqlite.in_memory()
  assert sql_b.open("b.sqlite") is Ok(db_b)
  env = Env.of({"SEED_LABEL": "household"})

  assert run_profile(
    profiles,
    "baseline",
    db_a,
    SecureRandom.seeded(ctx.seed),
    Clock.fixed(ctx.now),
    env
  ) ==
    Ok(Unit)
  assert run_profile(
    profiles,
    "baseline",
    db_b,
    SecureRandom.seeded(ctx.seed),
    Clock.fixed(ctx.now),
    env
  ) ==
    Ok(Unit)
  assert db_a.query("SELECT id, label, token FROM items", []) ==
    db_b.query("SELECT id, label, token FROM items", [])
  assert db_a.query("SELECT token FROM items WHERE id = 1", []) is Ok(tok_rows)
  assert tok_rows.rows.get(0) is Some([Sqlite.String(tok_val)])
  assert tok_val.byte_count == 8

  sql_e = Sqlite.in_memory()
  assert sql_e.open("e.sqlite") is Ok(db_e)
  assert run_profile(profiles, "empty", db_e, SecureRandom.seeded(1), Clock.fixed(t0), Env.of({})) ==
    Ok(Unit)
  assert db_e.query("SELECT id FROM items", []) == Ok(Sqlite.Rows(columns: ["id"], rows: []))

  assert run_profile(profiles, "broken", db_e, SecureRandom.seeded(1), Clock.fixed(t0), env) ==
    Error("boom during seed")
  assert run_profile(profiles, "unknown", db_e, SecureRandom.seeded(1), Clock.fixed(t0), env) ==
    Error("unknown seed profile 'unknown' (available: empty, baseline, broken)")
  assert run_profile([], "empty", db_e, SecureRandom.seeded(1), Clock.fixed(t0), env) ==
    Error("unknown seed profile 'empty' (available: none)")
end
