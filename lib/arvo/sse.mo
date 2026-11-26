## WHATWG Server-Sent Events (SSE) frame encoder and `Api.Response` helper
## with strict field sanitization preventing CR/LF SSE frame injection.
module Arvo.Sse
expose SseEvent(..),
sanitize_field_value,
format_event,
json_event,
comment,
encode_stream,
response,
last_event_id
use Api
use Json

## Single Server-Sent Event frame payload.
struct SseEvent
  id: Option(Text)
  event: Option(Text)
  data: Text
  retry_ms: Option(Int)
end

## Strips `\r` and `\n` characters so untrusted strings cannot inject additional SSE headers/events.
fn sanitize_field_value(raw: Text) : Text
  examples
    sanitize_field_value("ok\r\ndata: evil") == "okdata: evil"
  end

  raw.replace("\r", "").replace("\n", "")
end

## Formats one `SseEvent` into a spec-compliant `\n\n`-terminated SSE frame (`data:` per line).
fn format_event(ev: SseEvent) : Text
  promise "formatted SSE frame ends with double newline and has no carriage returns"
    result.ends_with?("\n\n") and not result.contains?("\r")
  end

  var lines = []
  case ev.id
    Some(i):
      clean_id = sanitize_field_value(i)
      if not clean_id.empty?
        lines = lines.append("id: #{clean_id}")
      end
    None: Unit
  end
  case ev.event
    Some(name):
      clean_name = sanitize_field_value(name)
      if not clean_name.empty?
        lines = lines.append("event: #{clean_name}")
      end
    None: Unit
  end
  case ev.retry_ms
    Some(ms) if ms >= 0: lines = lines.append("retry: #{ms}")
    Some(_) | None: Unit
  end

  normalized_data = ev.data.replace("\r\n", "\n").replace("\r", "\n")
  for dl in normalized_data.split("\n")
    lines = lines.append("data: #{dl}")
  end
  "#{lines.join("\n")}\n\n"
end

## Constructs an `SseEvent` whose `data` is the compact JSON representation of `payload`.
fn json_event(id: Option(Text), event_name: Text, payload: Json) : SseEvent
  SseEvent(id: id, event: Some(event_name), data: payload.to_text, retry_ms: None)
end

## Encodes a sanitized SSE comment/keepalive frame (`: <text>\n\n`).
fn comment(text: Text) : Text
  ": #{sanitize_field_value(text)}\n\n"
end

## Encodes a list of `SseEvent`s into a concatenated SSE response body string.
fn encode_stream(events: List(SseEvent)) : Text
  events.map(format_event).join("")
end

## Builds a `200 OK` `text/event-stream` response with cache/buffering headers disabled.
fn response(events: List(SseEvent)) : Api.Response
  Api.Response(
    status: 200,
    headers: [
      ("Content-Type", "text/event-stream; charset=utf-8"),
      ("Cache-Control", "no-cache, no-transform"),
      ("Connection", "keep-alive"),
      ("X-Accel-Buffering", "no")
    ],
    body: encode_stream(events).bytes
  )
end

## Extracts the browser/client `Last-Event-ID` cursor from header or query param fallback.
fn last_event_id(req: Api.Request) : Option(Text)
  case req.header("Last-Event-ID")
    Some(v) if not v.trim.empty?: return Some(sanitize_field_value(v.trim))
    Some(_) | None: Unit
  end
  case req.query_param("last_event_id")
    Some(q) if not q.trim.empty?: Some(sanitize_field_value(q.trim))
    Some(_) | None: None
  end
end

test "SSE encoding frames multi-line data, strips CR/LF injection, and parses Last-Event-ID"
  ev = SseEvent(
    id: Some("42\r\ndata: injected"),
    event: Some("claim.acquired\n"),
    data: "line1\r\nline2",
    retry_ms: Some(3000)
  )
  frame = format_event(ev)
  assert frame ==
    "id: 42data: injected\nevent: claim.acquired\nretry: 3000\ndata: line1\ndata: line2\n\n"

  je = json_event(Some("43"), "ai.token", Json.Object({"delta": Json.String("hello")}))
  res = response([ev, je])
  assert res.status == 200
  assert res.header("Content-Type") == Some("text/event-stream; charset=utf-8")
  assert res.header("X-Accel-Buffering") == Some("no")
  assert res.text.contains?("event: ai.token\ndata: {\"delta\":\"hello\"}\n\n")
  assert comment("keepalive\n") == ": keepalive\n\n"

  assert last_event_id(Api.get("/events").with_header("Last-Event-ID", " 99 ")) == Some("99")
  assert last_event_id(Api.get("/events?last_event_id=12")) == Some("12")
  assert last_event_id(Api.get("/events")) == None
end
