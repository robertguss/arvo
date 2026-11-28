## Ergonomic MoDB v0.9.0 transactional search and incremental analytics layer combining
## `Modb.Fts` (BM25+), `Modb.Vec` (quantized cosine + RRF fusion), `Modb.Policy` clearance
## governance, and `Modb.Matview` (CoW O(diff) Decimal-exact summaries).
module Arvo.Modb.Search
expose SearchError(..),
IndexedDocument(..),
TextSearchPage(..),
HybridSearchPage(..),
to_text,
tx_upsert_doc,
tx_delete_doc,
query_text,
query_text_governed,
query_hybrid,
query_hybrid_governed,
define_summary_view,
refresh_and_query_summary,
query_summary_read_only
use Modb
use Modb.Errors
use Modb.Fts
use Modb.Matview
use Modb.Policy
use Modb.Table
use Modb.Vec

## Errors returned by transactional indexing, search, and materialized view operations.
enum SearchError
  Storage(Errors.ModbError)
  FtsFailure(Fts.FtsError)
  VecFailure(Vec.VecError)
  PolicyFailure(Policy.PolicyError)
  MatViewFailure(Matview.MatViewError)
end

## Formats a `SearchError` as a human-readable diagnostic.
fn to_text(err: SearchError) : Text
  case err
    Storage(e): e.to_text
    FtsFailure(e): Fts.to_text(e)
    VecFailure(e): Vec.to_text(e)
    PolicyFailure(e): Policy.to_text(e)
    MatViewFailure(e): Matview.to_text(e)
  end
end

## Combined document payload written atomically into `Modb.Fts` and optional `Modb.Vec` indexes.
struct IndexedDocument
  doc_id: Text
  scope: Text
  fields: List(Fts.FieldInput)
  embedding: Option(List(Float))
end

## Paginated BM25 search response.
struct TextSearchPage
  query: Text
  page: Int
  per_page: Int
  total_returned: Int
  has_more?: Bool
  hits: List(Fts.SearchHit)
end

## Hybrid BM25 + vector RRF search response.
struct HybridSearchPage
  query: Text
  limit: Int
  hits: List(Vec.HybridHit)
end

## Atomically indexes or updates `doc` across `fts_idx` and optional `vec_idx` inside an active
## `Modb.WriteTx` (composable with domain table mutations and `Modb.Ledger`).
fn tx_upsert_doc(
  tx: Modb.WriteTx,
  fts_idx: Fts.FtsIndex,
  vec_idx: Option(Vec.VecIndex),
  doc: IndexedDocument
) : Result(Modb.WriteTx, SearchError)
  fts_doc = Fts.DocumentInput(doc_id: doc.doc_id, scope: doc.scope, fields: doc.fields)
  tx1 = try Fts.tx_index_document(tx, fts_idx, fts_doc).map_error(fn(e) FtsFailure(e) end)
  case vec_idx
    None: Ok(tx1)
    Some(vi):
      case doc.embedding
        Some(vals):
          vdoc = Vec.VectorInput(doc_id: doc.doc_id, scope: doc.scope, values: vals)
          Vec.tx_put_vector(tx1, vi, vdoc).map_error(fn(e) VecFailure(e) end)
        None: Vec.tx_remove_vector(tx1, vi, doc.doc_id).map_error(fn(e) VecFailure(e) end)
      end
  end
end

## Atomically removes `doc_id` from both `fts_idx` and optional `vec_idx` inside an active `WriteTx`.
fn tx_delete_doc(
  tx: Modb.WriteTx,
  fts_idx: Fts.FtsIndex,
  vec_idx: Option(Vec.VecIndex),
  doc_id: Text
) : Result(Modb.WriteTx, SearchError)
  tx1 = try Fts.tx_remove_document(tx, fts_idx, doc_id).map_error(fn(e) FtsFailure(e) end)
  case vec_idx
    None: Ok(tx1)
    Some(vi): Vec.tx_remove_vector(tx1, vi, doc_id).map_error(fn(e) VecFailure(e) end)
  end
end

fn clamp_pos(n: Int, fallback: Int) : Int
  if n < 1: fallback else: n
end

fn slice_hits(all_hits: List(Fts.SearchHit), query: Text, page: Int, per_page: Int) : TextSearchPage
  p = clamp_pos(page, 1)
  pp = clamp_pos(per_page, 20)
  offset = (p - 1) * pp
  after_off = all_hits.drop(offset)
  has_more? = after_off.size > pp
  kept = if has_more?: after_off.take(pp) else: after_off
  TextSearchPage(
    query: query,
    page: p,
    per_page: pp,
    total_returned: kept.size,
    has_more?: has_more?,
    hits: kept
  )
end

## Runs read-only paginated BM25+ full-text search via `ReadFiles`.
fn query_text(
  rf: ReadFiles,
  db_path: Text,
  fts_idx: Fts.FtsIndex,
  query: Text,
  opts: Fts.SearchOptions,
  page: Int,
  per_page: Int
) : Result(TextSearchPage, SearchError)
  p = clamp_pos(page, 1)
  pp = clamp_pos(per_page, 20)
  if not rf.exists?(db_path)
    return Ok(slice_hits([], query, p, pp))
  end
  var paged_opts = opts
  paged_opts.limit = p * pp + 1
  all_hits = try Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(me) end,
    fn(s) Fts.search(s, fts_idx, query, paged_opts).map_error(fn(e) FtsFailure(e) end) end
  )
  Ok(slice_hits(all_hits, query, p, pp))
end

## Runs `Modb.Policy` clearance-governed paginated BM25+ full-text search via `ReadFiles`.
fn query_text_governed(
  rf: ReadFiles,
  db_path: Text,
  pol: Policy.SensitivityPolicy,
  fts_idx: Fts.FtsIndex,
  query: Text,
  opts: Fts.SearchOptions,
  grant_id_opt: Option(Text),
  is_admin: Bool,
  page: Int,
  per_page: Int
) : Result(TextSearchPage, SearchError)
  p = clamp_pos(page, 1)
  pp = clamp_pos(per_page, 20)
  if not rf.exists?(db_path)
    return Ok(slice_hits([], query, p, pp))
  end
  var paged_opts = opts
  paged_opts.limit = p * pp + 1
  all_hits = try Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(me) end,
    fn(s)
      Policy.search_fts_governed(s, pol, fts_idx, query, paged_opts, grant_id_opt, is_admin)
        .map_error(fn(e) PolicyFailure(e) end)
    end
  )
  Ok(slice_hits(all_hits, query, p, pp))
end

## Runs read-only hybrid BM25 + quantized vector RRF search via `ReadFiles`.
fn query_hybrid(
  rf: ReadFiles,
  db_path: Text,
  fts_idx: Fts.FtsIndex,
  vec_idx: Vec.VecIndex,
  query_text: Text,
  query_vec: Option(List(Float)),
  opts: Vec.HybridOptions
) : Result(HybridSearchPage, SearchError)
  if not rf.exists?(db_path)
    return Ok(HybridSearchPage(query: query_text, limit: opts.limit, hits: []))
  end
  hits = try Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(me) end,
    fn(s)
      Vec.hybrid_search(s, fts_idx, vec_idx, query_text, query_vec, opts).map_error(
        fn(e) VecFailure(e) end
      )
    end
  )
  Ok(HybridSearchPage(query: query_text, limit: opts.limit, hits: hits))
end

## Runs `Modb.Policy` clearance-governed hybrid BM25 + vector RRF search via `ReadFiles`.
fn query_hybrid_governed(
  rf: ReadFiles,
  db_path: Text,
  pol: Policy.SensitivityPolicy,
  fts_idx: Fts.FtsIndex,
  vec_idx: Vec.VecIndex,
  query_text: Text,
  query_vec: Option(List(Float)),
  opts: Vec.HybridOptions,
  grant_id_opt: Option(Text),
  is_admin: Bool
) : Result(HybridSearchPage, SearchError)
  if not rf.exists?(db_path)
    return Ok(HybridSearchPage(query: query_text, limit: opts.limit, hits: []))
  end
  hits = try Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(me) end,
    fn(s)
      Policy.hybrid_search_governed(
        s,
        pol,
        fts_idx,
        vec_idx,
        query_text,
        query_vec,
        opts,
        grant_id_opt,
        is_admin
      ).map_error(fn(e) PolicyFailure(e) end)
    end
  )
  Ok(HybridSearchPage(query: query_text, limit: opts.limit, hits: hits))
end

## Registers or updates an incremental CoW materialized view (`Modb.Matview`).
fn define_summary_view(files: Files, db_path: Text, def: Matview.MatViewDef) : Result(
  Matview.MatViewMeta,
  SearchError
)
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Storage(me) end,
    fn(s)
      (_next, meta) = try Matview.define_matview(s, def).map_error(fn(e) MatViewFailure(e) end)
      Ok(meta)
    end
  )
end

## Refreshes `name` incrementally in O(diff) and returns `(MatRefreshReport, MatQueryResult)`.
fn refresh_and_query_summary(files: Files, db_path: Text, name: Text, min_group_size: Option(Int)) : Result(
  (Matview.MatRefreshReport, Matview.MatQueryResult),
  SearchError
)
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Storage(me) end,
    fn(s)
      (next_s, rep) = try Matview.refresh_matview(s, name).map_error(fn(e) MatViewFailure(e) end)
      qres = try Matview.query_matview(next_s, name, min_group_size).map_error(
        fn(e) MatViewFailure(e) end
      )
      Ok((rep, qres))
    end
  )
end

## Queries a previously refreshed materialized view strictly read-only via `ReadFiles`.
fn query_summary_read_only(rf: ReadFiles, db_path: Text, name: Text, min_group_size: Option(Int)) : Result(
  Matview.MatQueryResult,
  SearchError
)
  Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(me) end,
    fn(s) Matview.query_matview(s, name, min_group_size).map_error(fn(e) MatViewFailure(e) end) end
  )
end

struct DocRow
  category: Text
  amount_cents: Int
  title: Text
end

fn must_ok_search(res: Result(A, SearchError)) : A
  case res
    Ok(v): v
    Error(_e): stop "unexpected Arvo.Modb.Search error"
  end
end

test "Arvo.Modb.Search atomically indexes FTS+Vec, enforces Policy governance, and runs Matview analytics"
  files = Files.in_memory({})
  rf = files.read_only
  path = "search.modb"
  docs_tbl = Table.text_key[DocRow]("docs")
  fidx = Fts.index("docs")
  vidx = Vec.index("docs", 8)
  pol = Policy.policy().with_scope_sensitivity("secret", Policy.Secret)

  # 1. Atomic write: domain rows + FTS + Vec inside single Modb transaction
  v_water = Vec.text_sketch_embedding("municipal water utility invoice", 8)
  v_power = Vec.text_sketch_embedding("solar electric utility bill", 8)
  v_sec = Vec.text_sketch_embedding("confidential merger utility memo", 8)

  assert Modb.with_exclusive_lock(
    files,
    path,
    fn(me) me.to_text end,
    fn(s)
      tx0 = Modb.begin_write(s)
      t1 = try Table.put(
        tx0,
        docs_tbl,
        "d1",
        DocRow(category: "utilities", amount_cents: 4200, title: "Water Utility")
      ).map_error(fn(e) e.to_text end)
      t2 = try Table.put(
        t1,
        docs_tbl,
        "d2",
        DocRow(category: "utilities", amount_cents: 9800, title: "Electric Grid")
      ).map_error(fn(e) e.to_text end)
      t3 = try Table.put(
        t2,
        docs_tbl,
        "d3",
        DocRow(category: "secret", amount_cents: 50000, title: "Secret Utility")
      ).map_error(fn(e) e.to_text end)
      t4 = try tx_upsert_doc(
        t3,
        fidx,
        Some(vidx),
        IndexedDocument(
          doc_id: "d1",
          scope: "public",
          fields: [
            Fts.FieldInput(name: "title", text: "Municipal water utility invoice", weight: 3)
          ],
          embedding: Some(v_water)
        )
      ).map_error(to_text)
      t5 = try tx_upsert_doc(
        t4,
        fidx,
        Some(vidx),
        IndexedDocument(
          doc_id: "d2",
          scope: "public",
          fields: [Fts.FieldInput(name: "title", text: "Solar electric utility bill", weight: 3)],
          embedding: Some(v_power)
        )
      ).map_error(to_text)
      t6 = try tx_upsert_doc(
        t5,
        fidx,
        Some(vidx),
        IndexedDocument(
          doc_id: "d3",
          scope: "secret",
          fields: [
            Fts.FieldInput(name: "title", text: "Confidential merger utility memo", weight: 3)
          ],
          embedding: Some(v_sec)
        )
      ).map_error(to_text)
      Modb.commit(t6).map_error(fn(e) e.to_text end)
    end
  ) is
    Ok(_)

  # 2. Paginated FTS + Hybrid RRF search + Policy clearance governance
  page1 = must_ok_search(
    query_text(rf, path, fidx, "utility", Fts.default_search_options(10), 1, 2)
  )
  assert page1.total_returned == 2 and page1.has_more?
  page2 = must_ok_search(
    query_text(rf, path, fidx, "utility", Fts.default_search_options(10), 2, 2)
  )
  assert page2.total_returned == 1 and not page2.has_more?

  gov_pub = must_ok_search(
    query_text_governed(
      rf,
      path,
      pol,
      fidx,
      "utility",
      Fts.default_search_options(10),
      None,
      false,
      1,
      10
    )
  )
  assert gov_pub.hits.all?(fn(h) h.doc_id != "d3" end) and gov_pub.total_returned == 2

  gov_admin = must_ok_search(
    query_text_governed(
      rf,
      path,
      pol,
      fidx,
      "utility",
      Fts.default_search_options(10),
      None,
      true,
      1,
      10
    )
  )
  assert gov_admin.total_returned == 3

  hyb = must_ok_search(
    query_hybrid_governed(
      rf,
      path,
      pol,
      fidx,
      vidx,
      "water utility",
      Some(v_water),
      Vec.default_hybrid_options(5),
      None,
      false
    )
  )
  assert (hyb.hits.first or stop "expected hybrid hit").doc_id == "d1"
  assert hyb.hits.all?(fn(h) h.doc_id != "d3" end)

  # 3. Transactional Matview analytics
  mv_def = Matview.MatViewDef(
    name: "docs_by_cat",
    description: "Sum and count by category",
    source_bucket: "docs",
    group_by: "category",
    aggregates: [
      Matview.MatAggSpec(alias: "cnt", op: Matview.MatCount),
      Matview.MatAggSpec(alias: "total_cents", op: Matview.MatSum(field: "amount_cents"))
    ]
  )
  _mv = must_ok_search(define_summary_view(files, path, mv_def))
  (_rep, qres) = must_ok_search(refresh_and_query_summary(files, path, "docs_by_cat", None))
  assert qres.total_groups == 2
  ro_res = must_ok_search(query_summary_read_only(rf, path, "docs_by_cat", None))
  assert ro_res.returned_groups == 2

  # 4. Deleting d2 removes it from both FTS and Vec atomically
  assert Modb.with_exclusive_lock(
    files,
    path,
    fn(me) me.to_text end,
    fn(s)
      tx0 = Modb.begin_write(s)
      tx1 = try tx_delete_doc(tx0, fidx, Some(vidx), "d2").map_error(to_text)
      Modb.commit(tx1).map_error(fn(e) e.to_text end)
    end
  ) is
    Ok(_)
  after_del = must_ok_search(
    query_text(rf, path, fidx, "electric", Fts.default_search_options(10), 1, 10)
  )
  assert after_del.hits.empty?
end
