## Test-only mini API server fixture used by `Arvo.WebTest` unit tests.
module Arvo.Fixtures.WebTestApp
expose MiniProps(..),
MiniPayload(..),
MiniErr(..),
mini_page,
mini_hop1,
mini_hop2,
mini_loop,
mini_post_form,
mini_post_json,
mini_post_multipart,
mini_delete
use Api
use Json

struct MiniProps
  greeting: Text
  count: Int
end

struct MiniPayload
  value: Text
end

enum MiniErr
  MiniCsrf
end

api
  get "/page" mini_page
  get "/hop1" mini_hop1
  get "/hop2" mini_hop2
  get "/loop" mini_loop
  post "/items" mini_post_form
  post "/json" mini_post_json
  post "/upload" mini_post_multipart
  delete "/items/1" mini_delete
  status MiniCsrf = 403
end

fn mini_page(req: Api.Request) : Api.Response
  notice = req.query_param("notice")
  err_field = req.query_param("err")
  errs = case err_field
    Some(msg): {"name": msg}
    None: {}
  end
  page_obj = Json.Object({
    "component": Json.String("Mini/Show"),
    "props": Json.Object({
      "greeting": Json.String("hi"),
      "count": Json.int(2),
      "flash": Json.Object({"notice": notice.to_json, "alert": Json.Null}),
      "errors": errs.to_json
    }),
    "url": Json.String("/page"),
    "version": Json.String("v1")
  })
  if req.header("X-Inertia") == Some("true")
    Api.encoded_json_response(200, page_obj).with_header("X-Inertia", "true")
  else
    escaped = page_obj.to_text.replace("&", "&amp;").replace("\"", "&quot;").replace("'", "&#39;")
      .replace("<", "&lt;").replace(">", "&gt;")
    Api.html_response(
      200,
      "<html><body><div id=\"app\" data-page=\"#{escaped}\"></div></body></html>"
    )
  end
end

fn mini_hop1() : Api.Response
  Api.redirect_see_other("/hop2")
end

fn mini_hop2() : Api.Response
  Api.redirect_see_other("/page?notice=arrived")
end

fn mini_loop() : Api.Response
  Api.redirect_see_other("/loop")
end

fn mini_post_form(req: Api.Request) : Result(Api.Response, MiniErr)
  return Error(MiniCsrf) if req.header("X-XSRF-TOKEN") != Some("tok_ok")
  body_txt = req.text or ""
  notice = if body_txt.contains?("name=bad")
    "err=too+short"
  else
    "notice=saved"
  end
  Ok(Api.redirect_see_other("/page?#{notice}").add_header("Set-Cookie", "step=form; Path=/"))
end

fn mini_post_json(req: Api.Request, body: MiniPayload) : Result(Map(Text, Text), MiniErr)
  return Error(MiniCsrf) if req.header("X-XSRF-TOKEN") != Some("tok_ok")
  Ok({"echo": body.value})
end

fn mini_post_multipart(req: Api.Request) : Result(Map(Text, Text), MiniErr)
  return Error(MiniCsrf) if req.header("X-XSRF-TOKEN") != Some("tok_ok")
  raw = req.text or ""
  Ok({"len": "#{raw.byte_count}"})
end

fn mini_delete(req: Api.Request) : Result(Unit, MiniErr)
  return Error(MiniCsrf) if req.header("X-XSRF-TOKEN") != Some("tok_ok")
  Ok(Unit)
end
