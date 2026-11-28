## High-level pure real-time SSE streams, Inertia partial-reload invalidation signals,
## and zero-buffering upstream LLM token relays built over `Arvo.Sse`.
module Arvo.Live
expose LiveConfig(..),
InertiaReloadSignal(..),
LlmRelayOptions(..),
default_config,
default_llm_relay_options,
openai_relay_options,
anthropic_relay_options,
raw_relay_options,
user_topic,
org_topic,
resource_topic,
stream,
publish,
reload_signal_json,
invalidate_inertia,
relay_llm_stream
use Api
use Arvo.Sse
use Json

## Configuration governing browser SSE reconnect delay and initial handshake event.
struct LiveConfig
  retry_ms: Int
  send_connected_event?: Bool
end

## Structured payload emitted on `"inertia.reload"` events for `useArvoLive`.
struct InertiaReloadSignal
  kind: Text
  only: List(Text)
  reason: Option(Text)
end

## Upstream streaming configuration passed to `relay_llm_stream`.
struct LlmRelayOptions
  mode: Text
  idle_timeout_ms: Int
  token_event: Option(Text)
  done_event: Option(Text)
  done_data: Option(Text)
  error_event: Option(Text)
end

## Default real-time stream configuration (`retry: 3000`, emits initial `"live.connected"` frame).
fn default_config() : LiveConfig
  LiveConfig(retry_ms: 3000, send_connected_event?: true)
end

## Upstream OpenAI SSE token relay options (30s chunk idle timeout).
fn openai_relay_options() : LlmRelayOptions
  LlmRelayOptions(
    mode: "openai_sse",
    idle_timeout_ms: 30000,
    token_event: Some("ai.token"),
    done_event: Some("ai.done"),
    done_data: Some("{\"done\":true}"),
    error_event: Some("ai.error")
  )
end

## Upstream Anthropic SSE token relay options (30s chunk idle timeout).
fn anthropic_relay_options() : LlmRelayOptions
  LlmRelayOptions(
    mode: "anthropic_sse",
    idle_timeout_ms: 30000,
    token_event: Some("ai.token"),
    done_event: Some("ai.done"),
    done_data: Some("{\"done\":true}"),
    error_event: Some("ai.error")
  )
end

## Raw pass-through SSE relay options (30s chunk idle timeout).
fn raw_relay_options() : LlmRelayOptions
  LlmRelayOptions(
    mode: "raw",
    idle_timeout_ms: 30000,
    token_event: Some("ai.token"),
    done_event: Some("ai.done"),
    done_data: Some("{\"done\":true}"),
    error_event: Some("ai.error")
  )
end

## Default upstream LLM relay options (OpenAI SSE token transform, 30s chunk idle timeout).
fn default_llm_relay_options() : LlmRelayOptions
  openai_relay_options()
end

fn clean_segment(raw: Text) : Text
  Sse.sanitize_field_value(raw).trim
end

fn sanitize_topics(topics: List(Text)) : List(Text)
  var out = []
  for t in topics
    ct = clean_segment(t)
    if not ct.empty? and not out.contains?(ct)
      out = out.append(ct)
    end
  end
  out
end

## Canonical topic subscribed for notifications scoped to `user_id`.
fn user_topic(user_id: Text) : Text
  examples
    user_topic(" usr_1\r\n") == "user:usr_1"
    user_topic("  ") == ""
  end

  promise "sanitized user topic has no CR or LF"
    not result.contains?("\r") and not result.contains?("\n")
  end

  c = clean_segment(user_id)
  if c.empty?: "" else: "user:#{c}"
end

## Canonical topic subscribed for notifications scoped to organization `org_id`.
fn org_topic(org_id: Text) : Text
  examples
    org_topic("org_42") == "org:org_42"
  end

  c = clean_segment(org_id)
  if c.empty?: "" else: "org:#{c}"
end

## Canonical topic subscribed for a domain resource (`"<kind>:<id>"`).
fn resource_topic(kind: Text, id: Text) : Text
  examples
    resource_topic("bill", "b_99") == "bill:b_99"
    resource_topic("", "1") == ""
  end

  k = clean_segment(kind)
  i = clean_segment(id)
  if k.empty? or i.empty?: "" else: "#{k}:#{i}"
end

## Opens a cross-worker SSE stream subscribed to `topics`, forwarding `Last-Event-ID`
## and optional initial frames (plus a `"live.connected"` frame when configured).
fn stream(
  req: Api.Request,
  topics: List(Text),
  initial_events: List((Option(Text), Text)),
  cfg: LiveConfig
) : Api.Response
  clean_topics = sanitize_topics(topics)
  last_id = Sse.last_event_id(req)
  var frames = []
  if cfg.send_connected_event?
    last_json = case last_id
      Some(v): Json.String(v)
      None: Json.Null
    end
    conn_payload = Json.Object({"topics": clean_topics.to_json, "last_event_id": last_json}).to_text
    frames = frames.append((Some("live.connected"), conn_payload))
  end
  frames = frames.concat(initial_events)
  ev_list = frames.map(fn(p)
    Sse.SseEvent(id: None, event: p.0, data: p.1, retry_ms: None)
  end)
  retry = if cfg.retry_ms >= 0: Some(cfg.retry_ms) else: None
  Sse.stream(clean_topics, last_id, retry, ev_list)
end

## Attaches a live JSON event broadcast to `topic` onto `res` (dispatched on 2xx or 302/303/307/308 redirects).
fn publish(res: Api.Response, topic: Text, event_name: Text, payload: Json) : Api.Response
  Sse.publish_json(res, topic, event_name, payload)
end

## Builds the structured `"inertia.reload"` payload consumed by `useArvoLive`.
fn reload_signal_json(only_props: List(Text), reason: Option(Text)) : Json
  promise "reload signal kind is inertia.reload"
    result.text_at("kind") == Some("inertia.reload")
  end

  clean_props = sanitize_topics(only_props)
  clean_reason = case reason
    Some(r):
      cr = clean_segment(r)
      if cr.empty?: None else: Some(cr)
    None: None
  end
  InertiaReloadSignal(kind: "inertia.reload", only: clean_props, reason: clean_reason).to_json
end

## Attaches `"inertia.reload"` invalidation directives for every topic in `topics` so subscribed
## browser tabs silently call `router.reload({ only: only_props })`.
fn invalidate_inertia(
  res: Api.Response,
  topics: List(Text),
  only_props: List(Text),
  reason: Option(Text)
) : Api.Response
  payload = reload_signal_json(only_props, reason)
  var out = res
  for t in sanitize_topics(topics)
    out = Sse.publish_json(out, t, "inertia.reload", payload)
  end
  out
end

## Upgrades a response to relay streaming chunks from an upstream HTTP endpoint (e.g. LLM API)
## directly to the client with zero intermediate buffering.
fn relay_llm_stream(
  upstream_url: Text,
  headers: List((Text, Text)),
  body_json: Json,
  initial_events: List((Option(Text), Text)),
  opts: LlmRelayOptions
) : Api.Response
  relay_cfg = Api.SseRelay(
    method: "POST",
    url: upstream_url,
    headers: headers,
    body: body_json.to_text,
    mode: opts.mode,
    idle_timeout_ms: opts.idle_timeout_ms,
    token_event: opts.token_event,
    done_event: opts.done_event,
    done_data: opts.done_data,
    error_event: opts.error_event
  )
  Sse.relay(initial_events, relay_cfg)
end

test "Arvo.Live streams topics with Last-Event-ID, publishes Inertia reloads, and builds LLM relays"
  cfg = default_config()
  req = Api.get("/live").with_header("Last-Event-ID", "tx:41\r\n")
  res = stream(
    req,
    [org_topic("org_1"), " org:org_1 ", resource_topic("bills", "all")],
    [(Some("bill.sync"), "{\"count\":2}")],
    cfg
  )
  assert res.status == 200
  assert Sse.subscribed_topics(res) == ["org:org_1", "bills:all"]
  assert res.text.contains?("retry: 3000\n\n")
  assert res.text.contains?("event: live.connected\n")
  assert res.text.contains?("\"last_event_id\":\"tx:41\"")
  assert res.text.contains?("event: bill.sync\ndata: {\"count\":2}\n\n")

  mutated = publish(
    invalidate_inertia(
      Api.redirect_see_other("/"),
      [org_topic("org_1"), user_topic("u_1")],
      [" bills ", "audit_feed"],
      Some("bill.paid")
    ),
    resource_topic("bill", "b_7"),
    "bill.updated",
    Json.Object({"id": Json.String("b_7")})
  )
  pub_events = Sse.published_events(mutated)
  assert pub_events.size == 3
  assert pub_events.any?(fn(p)
    p.topic == "org:org_1" and
      p.event == Some("inertia.reload") and
      p.data.contains?("\"bills\"") and
      p.data.contains?("bill.paid")
  end)
  assert pub_events.any?(fn(p)
    p.topic == "bill:b_7" and p.event == Some("bill.updated")
  end)

  relay_res = relay_llm_stream(
    "https://api.example.com/v1/responses",
    [("Authorization", "Bearer tok")],
    Json.Object({"stream": Json.Boolean(true)}),
    [(Some("ai.start"), "{\"id\":\"1\"}")],
    default_llm_relay_options()
  )
  assert relay_res.status == 200
  assert relay_res.text.contains?("event: ai.start")
  assert Api.sse_relay_spec(relay_res) is Some(r)
  assert r.method == "POST" and r.mode == "openai_sse" and r.token_event == Some("ai.token")

  ant_res = relay_llm_stream(
    "https://api.example.com/v1/messages",
    [("x-api-key", "tok")],
    Json.Object({"stream": Json.Boolean(true)}),
    [],
    anthropic_relay_options()
  )
  assert Api.sse_relay_spec(ant_res) is Some(ar) and ar.mode == "anthropic_sse"

  raw_res = relay_llm_stream(
    "https://api.example.com/stream",
    [],
    Json.Object({"stream": Json.Boolean(true)}),
    [],
    raw_relay_options()
  )
  assert Api.sse_relay_spec(raw_res) is Some(rr) and rr.mode == "raw"
end
