## Storage-agnostic cursor pagination primitives for repositories and REST/Inertia endpoints.
module Arvo.Pagination
expose PageParams(..), CursorPage(..), parse_params, empty, map_items, from_slice
use Api

## Parsed limit and opaque keyset cursor for paginated queries.
struct PageParams
  limit: Int
  cursor: Option(Text)
end

## Keyset-paginated slice of items with optional next cursor.
struct CursorPage(T)
  items: List(T)
  next_cursor: Option(Text)
  has_more?: Bool
end

fn clamp_limit(raw: Int, max_limit: Int) : Int
  eff_max = if max_limit < 1: 1 else: max_limit
  if raw < 1
    1
  else if raw > eff_max
    eff_max
  else
    raw
  end
end

## Extracts `?limit=...&cursor=...` from `req`, clamping `limit` into `1..max_limit`.
fn parse_params(req: Api.Request, default_limit: Int, max_limit: Int) : PageParams
  eff_max = if max_limit < 1: 1 else: max_limit
  eff_default = clamp_limit(default_limit, eff_max)
  lim = case req.query_param("limit")
    Some(s):
      case s.trim.to_int
        Some(n): clamp_limit(n, eff_max)
        None: eff_default
      end
    None: eff_default
  end
  cur = case req.query_param("cursor")
    Some(c):
      trimmed = c.trim
      if trimmed.empty?: None else: Some(trimmed)
    None: None
  end
  PageParams(limit: lim, cursor: cur)
end

## Returns an empty `CursorPage`.
fn empty() : CursorPage(T)
  CursorPage(items: [], next_cursor: None, has_more?: false)
end

## Transforms items inside `page` while preserving `next_cursor` and `has_more?`.
fn map_items(page: CursorPage(A), f: fn(A) : B) : CursorPage(B)
  CursorPage(items: page.items.map(f), next_cursor: page.next_cursor, has_more?: page.has_more?)
end

## Builds a `CursorPage` from `rows` fetched with `limit + 1`, deriving `next_cursor` via `cursor_of`.
fn from_slice(rows: List(T), limit: Int, cursor_of: fn(T) : Text) : CursorPage(T)
  eff_lim = if limit < 1: 1 else: limit
  has_more? = rows.size > eff_lim
  kept = if has_more?: rows.take(eff_lim) else: rows
  next_cur = if has_more?: kept.last.map(cursor_of) else: None
  CursorPage(items: kept, next_cursor: next_cur, has_more?: has_more?)
end

test "Pagination parses and clamps query parameters, maps items, and slices keyset results"
  p0 = parse_params(Api.get("/items"), 25, 100)
  assert p0 == PageParams(limit: 25, cursor: None)

  p_clamp_hi = parse_params(Api.get("/items?limit=500&cursor=%20abc%20"), 25, 100)
  assert p_clamp_hi == PageParams(limit: 100, cursor: Some("abc"))

  p_clamp_lo = parse_params(Api.get("/items?limit=0&cursor="), 25, 100)
  assert p_clamp_lo == PageParams(limit: 1, cursor: None)

  p_bad = parse_params(Api.get("/items?limit=nope"), 25, 100)
  assert p_bad == PageParams(limit: 25, cursor: None)

  pg1 = from_slice([1, 2, 3], 2, fn(n) "cur_#{n}" end)
  assert pg1 == CursorPage(items: [1, 2], next_cursor: Some("cur_2"), has_more?: true)
  assert map_items(pg1, fn(n) n * 10 end) ==
    CursorPage(items: [10, 20], next_cursor: Some("cur_2"), has_more?: true)

  pg2 = from_slice([3], 2, fn(n) "cur_#{n}" end)
  assert pg2 == CursorPage(items: [3], next_cursor: None, has_more?: false)
  assert empty[Int]() == CursorPage(items: [], next_cursor: None, has_more?: false)
end
