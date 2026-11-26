## Stateful cookie, CSRF, Inertia v2, and fluent `ApiTest.App` test harness
## for zero-socket end-to-end tests and Vitest fixture recording.
module Arvo.WebTest
expose Client(..),
InertiaPage(..),
Session(..),
TestFile(..),
new,
start,
with_inertia,
without_inertia,
with_header,
prepare,
prepare_without_csrf,
absorb,
cookie,
redirect_location,
inertia_page,
send,
send_without_csrf,
get,
delete,
post_form,
post_json,
post_multipart,
post_without_csrf,
follow_redirect,
check_status,
check_redirect,
check_inertia,
check_flash_notice,
check_validation_error,
expect_status,
expect_redirect,
expect_inertia,
expect_flash_notice,
expect_validation_error,
record_inertia_fixture
use Api
use Arvo.Csrf
use Arvo.Fixtures.WebTestApp
use Http
use Json

## Stateful browser-like test client holding a cookie jar, optional Inertia version, and default headers.
struct Client
  cookies: Map(Text, Text)
  inertia_version: Option(Text)
  default_headers: List((Text, Text))
end

## Decoded Inertia v2 page object extracted from either XHR JSON or initial HTML `data-page`.
struct InertiaPage
  component: Text
  props: Map(Text, Json)
  url: Text
  version: Text
end

## Fluent session wrapping `Client` alongside the latest response and request/response history.
struct Session
  client: Client
  last_response: Option(Api.Response)
  history: List((Api.Request, Api.Response))
end

## File attachment payload for `post_multipart`.
struct TestFile
  field_name: Text
  filename: Text
  content_type: Text
  data: Bytes
end

## Creates an empty test client in standard HTML navigation mode.
fn new() : Client
  Client(cookies: {}, inertia_version: None, default_headers: [])
end

## Starts an empty fluent `Session` in standard HTML navigation mode.
fn start() : Session
  Session(client: new(), last_response: None, history: [])
end

## Enables Inertia XHR mode (`X-Inertia: true` and `X-Inertia-Version: version`) on `client`.
fn with_inertia(client: Client, version: Text) : Client
  Client(
    cookies: client.cookies,
    inertia_version: Some(version),
    default_headers: client.default_headers
  )
end

## Enables Inertia XHR mode on `session`.
fn with_inertia(session: Session, version: Text) : Session
  Session(
    client: with_inertia(session.client, version),
    last_response: session.last_response,
    history: session.history
  )
end

## Disables Inertia XHR mode on `client` (simulating a full browser document request).
fn without_inertia(client: Client) : Client
  Client(cookies: client.cookies, inertia_version: None, default_headers: client.default_headers)
end

## Disables Inertia XHR mode on `session`.
fn without_inertia(session: Session) : Session
  Session(
    client: without_inertia(session.client),
    last_response: session.last_response,
    history: session.history
  )
end

## Sets or replaces a default request header on `client` (case-insensitively).
fn with_header(client: Client, name: Text, value: Text) : Client
  low = name.ascii_lowercase
  kept = client.default_headers.filter(fn(h) h.0.ascii_lowercase != low end)
  Client(
    cookies: client.cookies,
    inertia_version: client.inertia_version,
    default_headers: kept.append((name, value))
  )
end

## Sets or replaces a default request header on `session` (case-insensitively).
fn with_header(session: Session, name: Text, value: Text) : Session
  Session(
    client: with_header(session.client, name, value),
    last_response: session.last_response,
    history: session.history
  )
end

fn prepare_inner(client: Client, req: Api.Request, inject_csrf?: Bool) : Api.Request
  var out = req
  for (hname, hval) in client.default_headers
    if out.header(hname) == None
      out = out.with_header(hname, hval)
    end
  end

  if not client.cookies.empty?
    jar_line = client.cookies.entries.map(fn(e) "#{e.0}=#{e.1}" end).join("; ")
    case out.header("Cookie")
      None: out = out.with_header("Cookie", jar_line)
      Some(existing): out = out.with_header("Cookie", "#{jar_line}; #{existing}")
    end
  end

  if client.inertia_version is Some(ver)
    if out.header("X-Inertia") == None
      out = out.with_header("X-Inertia", "true")
    end
    if not ver.empty? and out.header("X-Inertia-Version") == None
      out = out.with_header("X-Inertia-Version", ver)
    end
  end

  if inject_csrf? and not Csrf.safe_method?(out) and out.header(Csrf.header_name) == None
    if client.cookies.get(Csrf.cookie_name) is Some(xsrf)
      if not xsrf.empty?
        decoded = Api.percent_decode(xsrf, false) or xsrf
        out = out.with_header(Csrf.header_name, decoded)
      end
    end
  end
  out
end

## Attaches `client`'s cookies, default headers, Inertia headers (if enabled), and automatic
## `X-XSRF-TOKEN` (from the `XSRF-TOKEN` cookie on unsafe methods unless already set on `req`).
fn prepare(client: Client, req: Api.Request) : Api.Request
  prepare_inner(client, req, true)
end

## Like `prepare`, but omits automatic `X-XSRF-TOKEN` injection to test server-side CSRF rejection.
fn prepare_without_csrf(client: Client, req: Api.Request) : Api.Request
  prepare_inner(client, req, false)
end

fn clears_cookie?(attrs: List(Text), val: Text) : Bool
  for raw_attr in attrs
    attr = raw_attr.trim.ascii_lowercase
    if attr.starts_with?("max-age=")
      age_str = (attr.drop_prefix("max-age=") or "").trim
      case age_str.to_int
        Some(n): return true if n <= 0
        None: Unit
      end
    else if val.empty? and attr.starts_with?("expires=") and attr.contains?("1970")
      return true
    end
  end
  false
end

## Absorbs all `Set-Cookie` headers from `res` into `client`'s cookie jar, deleting cleared cookies.
fn absorb(client: Client, res: Api.Response) : Client
  var jar = client.cookies
  for line in res.headers_named("Set-Cookie")
    segs = line.split(";")
    first = (segs.first or "").trim
    continue if first.empty? or not first.contains?("=")
    kv = first.split("=")
    cname = (kv.first or "").trim
    continue if cname.empty?
    cval = kv.drop(1).join("=").trim
    if clears_cookie?(segs.drop(1), cval)
      jar = jar.remove(cname)
    else
      jar = jar.set(cname, cval)
    end
  end
  Client(
    cookies: jar,
    inertia_version: client.inertia_version,
    default_headers: client.default_headers
  )
end

## Looks up a cookie currently stored in `client`'s jar.
fn cookie(client: Client, name: Text) : Option(Text)
  client.cookies.get(name)
end

## Looks up a cookie currently stored in `session`'s jar.
fn cookie(session: Session, name: Text) : Option(Text)
  cookie(session.client, name)
end

## Returns the `Location` target of a 3xx redirect response (or `None` when not a redirect).
fn redirect_location(res: Api.Response) : Option(Text)
  return None if res.status < 300 or res.status >= 400
  res.header("Location")
end

fn unescape_html_attr(escaped: Text) : Text
  escaped.replace("&quot;", "\"").replace("&#39;", "'").replace("&#x27;", "'").replace(
    "&#X27;",
    "'"
  ).replace("&apos;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
end

fn extract_data_page(html: Text) : Option(Text)
  marker_dq = "data-page=\""
  parts_dq = html.split(marker_dq)
  if parts_dq.size >= 2
    after = parts_dq.drop(1).join(marker_dq)
    before_close = after.split("\"").first or ""
    return Some(unescape_html_attr(before_close))
  end

  marker_sq = "data-page='"
  parts_sq = html.split(marker_sq)
  if parts_sq.size >= 2
    after = parts_sq.drop(1).join(marker_sq)
    before_close = after.split("'").first or ""
    return Some(unescape_html_attr(before_close))
  end
  None
end

## Decodes an `InertiaPage` from either an `X-Inertia: true` JSON response or an initial HTML
## response's `data-page="..."` attribute.
fn inertia_page(res: Api.Response) : Result(InertiaPage, Text)
  ct = (res.header("Content-Type") or "").ascii_lowercase
  if res.header("X-Inertia") == Some("true") or ct.starts_with?("application/json")
    Json.decode[InertiaPage](res.body).map_error(fn(e) e.to_text end)
  else
    raw_json = try extract_data_page(res.text).or_fail(
      "response contains no Inertia data-page attribute"
    )
    Json.decode[InertiaPage](raw_json).map_error(fn(e) e.to_text end)
  end
end

fn dispatch_inner(session: Session, app: ApiTest.App, req: Api.Request, inject_csrf?: Bool) : (
  Session,
  Api.Response
)
  prepared = prepare_inner(session.client, req, inject_csrf?)
  res = app.send(prepared)
  next_client = absorb(session.client, res)
  next_session = Session(
    client: next_client,
    last_response: Some(res),
    history: session.history.append((prepared, res))
  )
  (next_session, res)
end

## Prepares `req` with session cookies/headers/CSRF, sends it to `app`, and absorbs `Set-Cookie`.
fn send(session: Session, app: ApiTest.App, req: Api.Request) : (Session, Api.Response)
  dispatch_inner(session, app, req, true)
end

## Like `send`, but omits automatic `X-XSRF-TOKEN` injection to test CSRF enforcement.
fn send_without_csrf(session: Session, app: ApiTest.App, req: Api.Request) : (Session, Api.Response)
  dispatch_inner(session, app, req, false)
end

## Sends a `GET` request to `path` using `session`.
fn get(session: Session, app: ApiTest.App, path: Text) : (Session, Api.Response)
  send(session, app, Api.get(path))
end

## Sends a `DELETE` request to `path` using `session`.
fn delete(session: Session, app: ApiTest.App, path: Text) : (Session, Api.Response)
  send(session, app, Api.delete(path))
end

## Sends an `application/x-www-form-urlencoded` `POST` request with `fields` to `path`.
fn post_form(session: Session, app: ApiTest.App, path: Text, fields: List((Text, Text))) : (
  Session,
  Api.Response
)
  encoded_body = Http.post("http://arvo.local").form(fields).body
  send(session, app, Api.post(path).with_bytes(encoded_body, "application/x-www-form-urlencoded"))
end

## Sends a JSON `POST` request with `body` to `path`.
fn post_json(session: Session, app: ApiTest.App, path: Text, body: T) : (Session, Api.Response)
  where T: Json
  send(session, app, Api.post(path).with_json(body))
end

## Sends a `multipart/form-data` `POST` request with `fields` and `files` to `path`.
fn post_multipart(
  session: Session,
  app: ApiTest.App,
  path: Text,
  fields: List((Text, Text)),
  files: List(TestFile)
) : (Session, Api.Response)
  boundary = "arvoWebTestBoundary"
  var chunks = []
  for (fname, fval) in fields
    chunks = chunks.append(
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{fname}\"\r\n\r\n#{fval}\r\n".bytes
    )
  end
  for f in files
    head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{f.field_name}\"; filename=\"#{f
      .filename}\"\r\nContent-Type: #{f.content_type}\r\n\r\n"
      .bytes
    chunks = chunks.append(head).append(f.data).append("\r\n".bytes)
  end
  chunks = chunks.append("--#{boundary}--\r\n".bytes)
  send(
    session,
    app,
    Api.post(path).with_bytes(Bytes.join(chunks), "multipart/form-data; boundary=#{boundary}")
  )
end

## Sends a raw `POST` request without automatic `X-XSRF-TOKEN` header injection.
fn post_without_csrf(
  session: Session,
  app: ApiTest.App,
  path: Text,
  body: Bytes,
  content_type: Text
) : (Session, Api.Response)
  send_without_csrf(session, app, Api.post(path).with_bytes(body, content_type))
end

## Follows 3xx `Location` redirects on `session.last_response` up to 5 hops via `GET`.
fn follow_redirect(session: Session, app: ApiTest.App) : (Session, Api.Response)
  var cur_session = session
  var cur_res = case session.last_response
    Some(r): r
    None: return (session, Api.no_content())
  end
  var hops = 0
  while hops < 5
    case redirect_location(cur_res)
      None: break
      Some(target):
        (next_s, next_r) = get(cur_session, app, target)
        cur_session = next_s
        cur_res = next_r
    end
    hops += 1
  end
  (cur_session, cur_res)
end

fn body_excerpt(res: Api.Response) : Text
  t = res.text.trim
  if t.byte_count > 160
    "#{t.bytes.slice(0, 160).decode_utf8 or "<binary>"}..."
  else
    t
  end
end

fn fail_assertion(detail: Text) : A
  _ = detail
  stop "web-test assertion failed"
end

## Checks that `res.status == code`, returning descriptive context on mismatch.
fn check_status(res: Api.Response, code: Int) : Result(Api.Response, Text)
  if res.status == code
    Ok(res)
  else
    Error("expected HTTP #{code}, got #{res.status}: #{body_excerpt(res)}")
  end
end

## Asserts `res.status == code` and returns `res` for fluent chaining.
fn expect_status(res: Api.Response, code: Int) : Api.Response
  case check_status(res, code)
    Ok(r): r
    Error(msg): fail_assertion(msg)
  end
end

## Checks that `res` is a 3xx redirect pointing to `location`.
fn check_redirect(res: Api.Response, location: Text) : Result(Api.Response, Text)
  case redirect_location(res)
    Some(loc):
      if loc == location
        Ok(res)
      else
        Error("expected redirect to '#{location}', got '#{loc}' (status #{res.status})")
      end
    None: Error("expected 3xx redirect to '#{location}', got status #{res.status}")
  end
end

## Asserts `res` is a 3xx redirect to `location` and returns `res`.
fn expect_redirect(res: Api.Response, location: Text) : Api.Response
  case check_redirect(res, location)
    Ok(r): r
    Error(msg): fail_assertion(msg)
  end
end

## Decodes an Inertia response into typed props `P`, checking `page.component == component`.
fn check_inertia(res: Api.Response, component: Text) : Result(P, Text) where P: Json
  page = try inertia_page(res).map_error(
    fn(e) "expected Inertia page '#{component}' (status #{res.status}): #{e}" end
  )
  if page.component != component
    return Error("expected Inertia component '#{component}', got '#{page.component}'")
  end
  Json.from_json[P](Json.Object(page.props)).map_error(
    fn(e) "failed decoding Inertia '#{component}' props: #{e.to_text}" end
  )
end

## Asserts `res` renders Inertia component `component` and decodes its props into `P`.
fn expect_inertia(res: Api.Response, component: Text) : P where P: Json
  case check_inertia[P](res, component)
    Ok(props): props
    Error(msg): fail_assertion(msg)
  end
end

## Checks that an Inertia response carries `flash.notice == expected`.
fn check_flash_notice(res: Api.Response, expected: Text) : Result(Unit, Text)
  page = try inertia_page(res)
  got = Json.Object(page.props).text_at("flash.notice")
  if got == Some(expected)
    Ok(Unit)
  else
    Error("expected flash.notice '#{expected}', got #{got}")
  end
end

## Asserts that an Inertia response carries `flash.notice == expected`.
fn expect_flash_notice(res: Api.Response, expected: Text) : Unit
  case check_flash_notice(res, expected)
    Ok(_): Unit
    Error(msg): fail_assertion(msg)
  end
end

fn extract_error_messages(val: Json) : List(Text)
  case val
    Json.String(s): [s]
    Json.Array(items): items.filter_map(fn(item)
      case item
        Json.String(s): Some(s)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): None
      end
    end)
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Object(_): []
  end
end

## Checks that an Inertia response carries a validation error under `errors.<field>` containing `contains`.
fn check_validation_error(res: Api.Response, field: Text, contains: Text) : Result(Unit, Text)
  page = try inertia_page(res)
  case page.props.get("errors")
    Some(Json.Object(err_map)):
      case err_map.get(field)
        Some(err_val):
          msgs = extract_error_messages(err_val)
          if msgs.any?(fn(m) m.contains?(contains) end)
            Ok(Unit)
          else
            Error(
              "validation error for '#{field}' did not contain '#{contains}': got #{msgs.join("; ")}"
            )
          end
        None: Error("expected validation error for field '#{field}', got none")
      end
    None | Some(_): Error("Inertia props missing 'errors' object")
  end
end

## Asserts that an Inertia response carries a validation error for `field` containing `contains`.
fn expect_validation_error(res: Api.Response, field: Text, contains: Text) : Unit
  case check_validation_error(res, field, contains)
    Ok(_): Unit
    Error(msg): fail_assertion(msg)
  end
end

## Exports a verified `InertiaPage` payload as pretty JSON under `.arvo/fixtures/<component>/<name>.json`.
fn record_inertia_fixture(files: Files, name: Text, res: Api.Response) : Result(Unit, Text)
  page = try inertia_page(res)
  folder = ".arvo/fixtures/#{page.component}"
  try files.make_folder(folder).map_error(fn(e) "#{e}" end)
  path = "#{folder}/#{name}.json"
  files.write_text(path, "#{page.to_json.pretty}\n").map_error(fn(e) "#{e}" end)
end

test "WebTest v1 client tracks Set-Cookie jars, headers, CSRF, redirects, and decodes Inertia HTML & JSON"
  login_res = Api.redirect_see_other("/").add_header(
    "Set-Cookie",
    "arvo_session=sealed_123; Path=/; Max-Age=3600; HttpOnly; Secure"
  ).add_header("Set-Cookie", "XSRF-TOKEN=csrf%2B456; Path=/; SameSite=Lax; Secure")
  assert redirect_location(login_res) == Some("/")
  assert redirect_location(Api.html_response(299, "ok").with_header("Location", "/x")) == None
  assert redirect_location(Api.html_response(300, "ok").with_header("Location", "/x")) == Some("/x")
  assert redirect_location(Api.html_response(399, "ok").with_header("Location", "/x")) == Some("/x")
  assert redirect_location(Api.html_response(400, "ok").with_header("Location", "/x")) == None

  c1 = absorb(new(), login_res)
  assert cookie(c1, "arvo_session") == Some("sealed_123")
  assert cookie(c1, "XSRF-TOKEN") == Some("csrf%2B456")

  # Malformed Set-Cookie lines are ignored safely
  c_bad = absorb(
    c1,
    Api.no_content().add_header("Set-Cookie", "malformed").add_header("Set-Cookie", "=noname")
  )
  assert cookie(c_bad, "arvo_session") == Some("sealed_123")
  assert cookie(c_bad, "malformed") == None

  # Literal '+' in XSRF-TOKEN stays '+' (false decode_plus), not space
  c_plus = absorb(new(), Api.no_content().add_header("Set-Cookie", "XSRF-TOKEN=tok+plus; Path=/"))
  assert prepare(c_plus, Api.post("/bills")).header("X-XSRF-TOKEN") == Some("tok+plus")

  # Replace default header case-insensitively without duplicating
  c_hdr = with_header(with_header(c1, "Host", "old.local"), "host", "budget.local")
  assert c_hdr.default_headers == [("host", "budget.local")]

  post_req = prepare(c_hdr, Api.post("/bills"))
  assert post_req.header("X-XSRF-TOKEN") == Some("csrf+456")
  assert (post_req.header("Cookie") or "").contains?("arvo_session=sealed_123")

  no_csrf_req = prepare_without_csrf(c_hdr, Api.post("/bills"))
  assert no_csrf_req.header("X-XSRF-TOKEN") == None

  c_inertia = with_inertia(c_hdr, "v_sha1")
  get_xhr = prepare(c_inertia, Api.get("/bills"))
  assert get_xhr.header("X-Inertia") == Some("true")
  assert get_xhr.header("X-Inertia-Version") == Some("v_sha1")
  assert get_xhr.header("Host") == Some("budget.local")
  assert get_xhr.header("X-XSRF-TOKEN") == None

  # Empty version omits X-Inertia-Version; pre-existing header stays intact
  get_empty_ver = prepare(with_inertia(c_hdr, ""), Api.get("/bills"))
  assert get_empty_ver.header("X-Inertia") == Some("true")
  assert get_empty_ver.header("X-Inertia-Version") == None
  get_explicit_ver = prepare(
    c_inertia,
    Api.get("/bills").with_header("X-Inertia-Version", "custom")
  )
  assert get_explicit_ver.header("X-Inertia-Version") == Some("custom")

  c_html = without_inertia(c_inertia)
  assert prepare(c_html, Api.get("/bills")).header("X-Inertia") == None

  html_shell = """
    <!doctype html>
    <html><body>
      <div id="app" data-page="{&quot;component&quot;:&quot;Home/Index&quot;,&quot;props&quot;:{&quot;note&quot;:&quot;a &amp;lt; b &amp; &#39;ok&#39;&quot;},&quot;url&quot;:&quot;/&quot;,&quot;version&quot;:&quot;v1&quot;}"></div>
    </body></html>
    """
  assert inertia_page(Api.html_response(200, html_shell)) is Ok(page_dq)
  assert page_dq.component == "Home/Index"
  assert (page_dq.props.get("note") or Json.Null) == Json.String("a &lt; b & 'ok'")

  # Single-quoted data-page fallback and missing data-page error
  html_sq = "<div id='app' data-page='{\"component\":\"Sq\",\"props\":{},\"url\":\"/\",\"version\":\"v1\"}'></div>"
  assert inertia_page(Api.html_response(200, html_sq)) is Ok(page_sq)
  assert page_sq.component == "Sq"
  assert inertia_page(Api.html_response(200, "<div>plain</div>")) is Error(_)

  # JSON response decoded with application/json Content-Type even without X-Inertia header
  json_no_hdr = Api.encoded_json_response(
    200,
    Json.Object({
      "component": Json.String("Bills/Show"),
      "props": Json.Object({"id": Json.int(42)}),
      "url": Json.String("/bills/42"),
      "version": Json.String("v1")
    })
  )
  assert inertia_page(json_no_hdr) is Ok(jpage)
  assert jpage.component == "Bills/Show"
  assert jpage.url == "/bills/42"

  # X-Inertia header alone (even with text/plain Content-Type) also decodes JSON
  json_hdr_only = Api.response(
    200,
    [("Content-Type", "text/plain"), ("X-Inertia", "true")],
    json_no_hdr.body
  )
  assert inertia_page(json_hdr_only) is Ok(jhpage)
  assert jhpage.component == "Bills/Show"

  # Cookie clearing via Max-Age=0, Max-Age=1 (kept!), and Expires=1970 (only when value empty!)
  keep_max1 = absorb(
    c1,
    Api.no_content().add_header("Set-Cookie", "arvo_session=keep1; Path=/; Max-Age=1").add_header(
      "Set-Cookie",
      "XSRF-TOKEN=keep_exp; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    ).add_header("Set-Cookie", "future_empty=; Path=/; Expires=Thu, 01 Jan 2027 00:00:00 GMT")
  )
  assert cookie(keep_max1, "arvo_session") == Some("keep1")
  assert cookie(keep_max1, "XSRF-TOKEN") == Some("keep_exp")
  assert cookie(keep_max1, "future_empty") == Some("")

  clear_imm = absorb(
    c1,
    Api.redirect_see_other("/login").add_header("Set-Cookie", "arvo_session=; Max-Age=0").add_header(
      "Set-Cookie",
      "XSRF-TOKEN=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    )
  )
  assert cookie(clear_imm, "arvo_session") == None
  assert cookie(clear_imm, "XSRF-TOKEN") == None
end

test "WebTest v2 Session drives ApiTest.App with redirects, assertions, and fixture recording"
  app = ApiTest.start(WebTestApp)

  # Follow redirect when no prior response exists returns 204
  (s_empty, no_prior) = follow_redirect(start(), app)
  assert no_prior.status == 204
  assert s_empty.history == []

  # Session with XSRF-TOKEN cookie and Inertia header
  seed_res = Api.no_content().add_header("Set-Cookie", "XSRF-TOKEN=tok_ok; Path=/")
  var s0 = Session(client: absorb(new(), seed_res), last_response: None, history: [])
  s0 = with_header(with_inertia(without_inertia(with_inertia(s0, "v1")), "v1"), "X-Custom", "1")
  assert cookie(s0, "XSRF-TOKEN") == Some("tok_ok")

  (s1, p_res) = get(s0, app, "/page?notice=ready")
  _ = expect_status(p_res, 200)
  props = expect_inertia[WebTestApp.MiniProps](p_res, "Mini/Show")
  assert props.greeting == "hi"
  assert props.count == 2
  expect_flash_notice(p_res, "ready")
  assert s1.history.size == 1

  # Record Inertia fixture to in-memory Files
  files = Files.in_memory({})
  assert record_inertia_fixture(files, "default", p_res) == Ok(Unit)
  assert files.exists?(".arvo/fixtures/Mini/Show/default.json")
  assert files.read_text(".arvo/fixtures/Mini/Show/default.json") is Ok(fix_txt)
  assert fix_txt.contains?("\"component\": \"Mini/Show\"")

  # post_without_csrf rejected with 403; post_form with CSRF succeeds and follows redirect
  (_s_no_csrf, no_csrf_res) = post_without_csrf(
    s1,
    app,
    "/items",
    "name=good".bytes,
    "application/x-www-form-urlencoded"
  )
  assert no_csrf_res.status == 403

  (s2, form_res) = post_form(s1, app, "/items", [("name", "bad")])
  _ = expect_redirect(form_res, "/page?err=too+short")
  (s3, err_page_res) = follow_redirect(s2, app)
  expect_validation_error(err_page_res, "name", "too short")
  assert cookie(s3, "step") == Some("form")

  # Multi-hop redirect stops at final 200; >5 hop redirect loop stops after 5 hops
  (s4, hop_start) = get(s3, app, "/hop1")
  assert hop_start.status == 303
  (s5, hop_end) = follow_redirect(s4, app)
  _ = expect_status(hop_end, 200)
  expect_flash_notice(hop_end, "arrived")

  # Following a non-redirect response is a no-op
  (_s_noop, noop_res) = follow_redirect(s5, app)
  assert noop_res.status == 200

  (s_loop0, _) = get(s5, app, "/loop")
  (s_loop5, loop_res) = follow_redirect(s_loop0, app)
  assert loop_res.status == 303
  assert s_loop5.history.size == s_loop0.history.size + 5

  # post_json, post_multipart, delete
  (s6, json_res) = post_json[WebTestApp.MiniPayload](
    s5,
    app,
    "/json",
    WebTestApp.MiniPayload(value: "ping")
  )
  assert expect_status(json_res, 200).text.contains?("ping")

  (s7, mp_res) = post_multipart(
    s6,
    app,
    "/upload",
    [("kind", "csv")],
    [TestFile(field_name: "file", filename: "a.csv", content_type: "text/csv", data: "x,y".bytes)]
  )
  assert expect_status(mp_res, 200).text.contains?("len")

  (_s8, del_res) = delete(s7, app, "/items/1")
  _ = expect_status(del_res, 204)

  # Negative check_* error assertions cover formatting & mismatch branches
  assert check_status(del_res, 200) is Error(st_err)
  assert st_err.contains?("expected HTTP 200, got 204")
  exact_160 = "x".repeat(160)
  assert check_status(Api.text_response(500, exact_160), 200) ==
    Error("expected HTTP 200, got 500: #{exact_160}")
  over_160 = "y#{"x".repeat(160)}"
  assert check_status(Api.text_response(500, over_160), 200) ==
    Error("expected HTTP 200, got 500: y#{"x".repeat(159)}...")

  assert check_redirect(del_res, "/") is Error(_)
  assert check_redirect(hop_start, "/other") is Error(loc_err)
  assert loc_err.contains?("expected redirect to '/other'")

  assert check_inertia[WebTestApp.MiniProps](del_res, "Mini/Show") is Error(_)
  assert check_inertia[WebTestApp.MiniProps](p_res, "Other") is Error(comp_err)
  assert comp_err.contains?("expected Inertia component 'Other'")
  assert check_inertia[WebTestApp.MiniPayload](p_res, "Mini/Show") is Error(_)

  assert check_flash_notice(err_page_res, "missing") is Error(_)
  assert check_validation_error(err_page_res, "name", "other") is Error(_)
  assert check_validation_error(err_page_res, "missing_field", "x") is Error(_)
  assert check_validation_error(del_res, "x", "y") is Error(_)

  # Validation error stored as array of strings & missing errors object
  arr_err_res = Api.encoded_json_response(
    200,
    Json.Object({
      "component": Json.String("X"),
      "props": Json.Object({
        "errors": Json.Object({"email": Json.Array([Json.String("invalid email")])})
      }),
      "url": Json.String("/"),
      "version": Json.String("v1")
    })
  ).with_header("X-Inertia", "true")
  assert check_validation_error(arr_err_res, "email", "invalid") == Ok(Unit)

  no_err_obj_res = Api.encoded_json_response(
    200,
    Json.Object({
      "component": Json.String("X"),
      "props": Json.Object({}),
      "url": Json.String("/"),
      "version": Json.String("v1")
    })
  ).with_header("X-Inertia", "true")
  assert check_validation_error(no_err_obj_res, "email", "invalid") is Error(_)
end
