## SQLite-specific test assertions for `Arvo.Testing.*` and SQLite-backed apps,
## kept separate from DB-agnostic `Arvo.WebTest`.
module Arvo.Testing.SqliteTest
expose check_max_queries, expect_max_queries

fn fail_assertion(detail: Text) : A
  _ = detail
  stop "sqlite-test assertion failed"
end

## Checks that `db.stats().query_count <= max_queries` for `label`.
fn check_max_queries(db: Sqlite.Database, max_queries: Int, label: Text) : Result(Unit, Text)
  st = db.stats()
  if st.query_count <= max_queries
    Ok(Unit)
  else
    Error(
      "query budget exceeded for #{label}: #{st.query_count} queries > max #{max_queries}: #{st
        .statements.join(" | ")}"
    )
  end
end

## Asserts that `db.stats().query_count <= max_queries` for `label`.
fn expect_max_queries(db: Sqlite.Database, max_queries: Int, label: Text) : Unit
  case check_max_queries(db, max_queries, label)
    Ok(_): Unit
    Error(msg): fail_assertion(msg)
  end
end

test "SqliteTest checks and enforces per-action query budgets"
  sql = Sqlite.in_memory()
  assert sql.open("budget.sqlite") is Ok(db)
  assert db.run("CREATE TABLE IF NOT EXISTS w_items (id INTEGER PRIMARY KEY, val TEXT) STRICT", []) ==
    Ok(Unit)

  db.reset_stats()
  assert db.query("SELECT id, val FROM w_items", []) is Ok(_)
  expect_max_queries(db, 1, "GET /page")
  assert check_max_queries(db, 1, "GET /page") == Ok(Unit)
  assert check_max_queries(db, 0, "GET /page") is Error(q_err)
  assert q_err.contains?("query budget exceeded for GET /page: 1 queries > max 0")
  assert q_err.contains?("SELECT id, val FROM w_items")
end
