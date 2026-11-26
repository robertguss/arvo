## WRONG VERSION (strength/arvo_csrf/02_accept_empty_token.mo): Skips empty-token guard so empty token matches empty session CSRF secret.
## Double-submit + session-bound CSRF protection compatible with `@inertiajs/react` and Axios
## (`XSRF-TOKEN` readable cookie + `X-XSRF-TOKEN` request header).
module Arvo.Csrf
expose cookie_name, header_name, safe_method?, verify, verify_token, attach_cookie, clear_cookie
use Api
use Arvo.Cookie
use Arvo.Session
use Crypto

cookie_name = "XSRF-TOKEN"
header_name = "X-XSRF-TOKEN"

## Whether `req.method` is an HTTP safe read method (`GET`, `HEAD`, or `OPTIONS`).
fn safe_method?(req: Api.Request) : Bool
  examples
    safe_method?(Api.get("/"))
    safe_method?(Api.request("HEAD", "/"))
    safe_method?(Api.request("OPTIONS", "/"))
    not safe_method?(Api.post("/"))
    not safe_method?(Api.delete("/"))
  end

  m = req.method.ascii_uppercase
  m == "GET" or m == "HEAD" or m == "OPTIONS"
end

## Constant-time verification of an explicit CSRF `token` (e.g. form `_csrf`) against `session.csrf_token`.
fn verify_token(token: Text, session: Session.Session) : Bool
  examples
    case Time.parse("2026-11-22T00:00:00Z")
      Some(exp): verify_token(
        "tok_a+b/c",
        Session.Session(id: "s", member_id: "m", csrf_token: "tok_a+b/c", expires_at: exp)
      )
      None: false
    end
    case Time.parse("2026-11-22T00:00:00Z")
      Some(exp): not verify_token(
        "",
        Session.Session(id: "s", member_id: "m", csrf_token: "", expires_at: exp)
      )
      None: false
    end
    case Time.parse("2026-11-22T00:00:00Z")
      Some(exp): not verify_token(
        "wrong",
        Session.Session(id: "s", member_id: "m", csrf_token: "tok_a+b/c", expires_at: exp)
      )
      None: false
    end
  end

  Crypto.constant_time_eq?(token.bytes, session.csrf_token.bytes)
end

## Verifies `X-XSRF-TOKEN` on `req` (percent-decoding if URL-encoded) against `session.csrf_token`
## in constant time.
fn verify(req: Api.Request, session: Session.Session) : Bool
  examples
    case Time.parse("2026-11-22T00:00:00Z")
      Some(exp): verify(
        Api.post("/bills").with_header("X-XSRF-TOKEN", "tok_a%2Bb%2Fc"),
        Session.Session(id: "s", member_id: "m", csrf_token: "tok_a+b/c", expires_at: exp)
      )
      None: false
    end
    case Time.parse("2026-11-22T00:00:00Z")
      Some(exp): not verify(
        Api.post("/bills"),
        Session.Session(id: "s", member_id: "m", csrf_token: "tok_a+b/c", expires_at: exp)
      )
      None: false
    end
  end

  raw = case req.header(header_name)
    Some(v): v.trim
    None: return false
  end
  decoded = Api.percent_decode(raw, false) or raw
  verify_token(decoded, session)
end

## Attaches the readable `XSRF-TOKEN` cookie (`HttpOnly=false`, `SameSite=Lax`, `Path=/`).
fn attach_cookie(res: Api.Response, session: Session.Session, secure?: Bool) : Api.Response
  opts = Cookie.CookieOptions(
    path: "/",
    max_age: None,
    http_only?: false,
    secure?: secure?,
    same_site: Cookie.Lax
  )
  Cookie.set(res, cookie_name, session.csrf_token, opts)
end

## Clears the `XSRF-TOKEN` cookie on logout.
fn clear_cookie(res: Api.Response, secure?: Bool) : Api.Response
  Cookie.clear(res, cookie_name, "/", secure?)
end
