## Minimal test-only API fixture for `Arvo.Feature` in-memory scenario execution.
module Arvo.Fixtures.FeatureApp
expose FeatureBillIn(..), FeatureErr(..), init_schema, list_bills, add_bill
use Api

struct FeatureBillIn
  name: Text
  amount_cents: Int
end

enum FeatureErr
  FeatCsrf
  FeatDb(reason: Text)
end

api
  sqlite db from "feature.sqlite"
  get "/bills" list_bills
  post "/bills" add_bill
  status FeatCsrf = 403
  status FeatDb(_) = 500
end

fn init_schema(db: Sqlite.Database) : Result(Unit, Text)
  db.run(
    "CREATE TABLE IF NOT EXISTS f_bills (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, amount_cents INTEGER NOT NULL) STRICT",
    []
  ).map_error(fn(e) "#{e}" end)
end

fn list_bills(db: Sqlite.Database) : Result(List(Text), FeatureErr)
  _s = try init_schema(db).map_error(fn(e) FeatDb(reason: e) end)
  rows = try db.query("SELECT name FROM f_bills ORDER BY id ASC", []).map_error(
    fn(e) FeatDb(reason: "#{e}") end
  )
  Ok(
    rows.rows.filter_map(fn(r)
      case r.first
        Some(Sqlite.String(n)): Some(n)
        None | Some(_): None
      end
    end)
  )
end

fn add_bill(req: Api.Request, db: Sqlite.Database, body: FeatureBillIn) : Result(
  Map(Text, Int),
  FeatureErr
)
  return Error(FeatCsrf) if req.header("X-XSRF-TOKEN") != Some("feat_tok")
  _s = try init_schema(db).map_error(fn(e) FeatDb(reason: e) end)
  ins = try db.execute(
    "INSERT INTO f_bills (name, amount_cents) VALUES (?, ?)",
    [Sqlite.String(body.name), Sqlite.Integer(body.amount_cents)]
  ).map_error(fn(e) FeatDb(reason: "#{e}") end)
  Ok({"id": ins.last_insert_rowid})
end
