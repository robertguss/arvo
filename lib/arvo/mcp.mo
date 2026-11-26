## Reusable Streamable HTTP MCP (Model Context Protocol, `2025-03-26`) JSON-RPC 2.0 server primitives.
## Uses an explicit `McpAction` return value so Mo route handlers retain all capabilities without
## capturing them in closures (`E0091`).
module Arvo.Mcp
expose default_protocol_version,
err_parse,
err_invalid_request,
err_method_not_found,
err_invalid_params,
err_internal,
ServerInfo(..),
ToolDef(..),
ResourceDef(..),
ToolContent(..),
ToolCallResult(..),
ResourceContent(..),
RpcId(..),
RpcRequest(..),
RpcError(..),
McpAction(..),
object_schema,
parse_request,
dispatch,
json_rpc_ok,
json_rpc_error,
tool_response,
tool_ok,
tool_error,
resource_response
use Api
use Json

default_protocol_version = "2025-03-26"
err_parse = -32700
err_invalid_request = -32600
err_method_not_found = -32601
err_invalid_params = -32602
err_internal = -32603

## Server metadata advertised in the MCP `initialize` response.
struct ServerInfo
  name: Text
  version: Text
  protocol_version: Text
  instructions: Option(Text)
end

## Tool declaration returned in `tools/list` and validated on `tools/call`.
struct ToolDef
  name: Text
  description: Text
  input_schema: Json
  read_only?: Bool
end

## Resource declaration advertised in `resources/list`.
struct ResourceDef
  uri: Text
  name: Text
  description: Text
  mime_type: Text
end

## Structured or plain-text content item returned inside `tools/call`.
enum ToolContent
  TextContent(text: Text)
  JsonContent(data: Json)
end

## Complete result payload returned from an MCP tool handler.
struct ToolCallResult
  content: List(ToolContent)
  is_error?: Bool
  structured_content: Option(Json)
end

## Resource payload item returned inside `resources/read`.
struct ResourceContent
  uri: Text
  mime_type: Text
  text: Text
end

## JSON-RPC 2.0 request/response identifier.
enum RpcId
  IdInt(Int)
  IdText(Text)
  IdNull
end

## Parsed JSON-RPC 2.0 request envelope.
struct RpcRequest
  id: Option(RpcId)
  method: Text
  params: Json
end

## JSON-RPC 2.0 error object.
struct RpcError
  code: Int
  message: Text
  data: Option(Json)
end

## Result of `dispatch`: either an immediate protocol `Respond`, or a validated `CallTool` / `ReadResource`
## dispatched directly by the caller's capability-bearing route handler.
enum McpAction
  Respond(Api.Response)
  CallTool(id: RpcId, name: Text, arguments: Json)
  ReadResource(id: RpcId, uri: Text)
end

## Helper constructing a JSON Schema `"object"` definition with properties and required keys.
fn object_schema(properties: Map(Text, Json), required: List(Text)) : Json
  Json.Object({
    "type": Json.String("object"),
    "properties": Json.Object(properties),
    "required": Json.Array(required.map(fn(r) Json.String(r) end))
  })
end

fn json_http(status: Int, body: Json) : Api.Response
  Api.encoded_json_response(status, body).with_header(
    "Content-Type",
    "application/json; charset=utf-8"
  )
end

fn rpc_id_to_json(id: RpcId) : Json
  case id
    IdInt(n): Json.int(n)
    IdText(s): Json.String(s)
    IdNull: Json.Null
  end
end

## Encodes a successful JSON-RPC 2.0 response (`200 OK`).
fn json_rpc_ok(id: RpcId, result: Json) : Api.Response
  json_http(
    200,
    Json.Object({"jsonrpc": Json.String("2.0"), "id": rpc_id_to_json(id), "result": result})
  )
end

## Encodes a JSON-RPC 2.0 error response (`400` on parse/invalid-request, `200` on RPC errors).
fn json_rpc_error(id: RpcId, err: RpcError) : Api.Response
  http_status = if err.code == err_parse or err.code == err_invalid_request: 400 else: 200
  var err_fields = {"code": Json.int(err.code), "message": Json.String(err.message)}
  case err.data
    Some(d): err_fields = err_fields.set("data", d)
    None: Unit
  end
  json_http(
    http_status,
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": rpc_id_to_json(id),
      "error": Json.Object(err_fields)
    })
  )
end

fn parse_rpc_id(val: Json) : Result(RpcId, RpcError)
  case val
    Json.Null: Ok(IdNull)
    Json.String(s): Ok(IdText(s))
    Json.Number(n):
      case n.to_int
        Some(i): Ok(IdInt(i))
        None: Error(
          RpcError(
            code: err_invalid_request,
            message: "id must be an integer, string, or null",
            data: None
          )
        )
      end
    Json.Boolean(_) | Json.Array(_) | Json.Object(_): Error(
      RpcError(
        code: err_invalid_request,
        message: "id must be an integer, string, or null",
        data: None
      )
    )
  end
end

## Parses an incoming `Api.Request` into a validated JSON-RPC 2.0 `RpcRequest`.
fn parse_request(req: Api.Request) : Result(RpcRequest, RpcError)
  if req.method.ascii_uppercase != "POST"
    return Error(
      RpcError(code: err_invalid_request, message: "MCP requests must use POST", data: None)
    )
  end
  body_text = case req.text
    Some(t): t
    None: return Error(
      RpcError(code: err_parse, message: "request body must be valid UTF-8", data: None)
    )
  end
  parsed = case Json.parse(body_text)
    Ok(j): j
    Error(_): return Error(RpcError(code: err_parse, message: "malformed JSON payload", data: None))
  end
  fields = case parsed
    Json.Object(m): m
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
      RpcError(code: err_invalid_request, message: "JSON-RPC payload must be an object", data: None)
    )
  end

  if fields.get("jsonrpc") != Some(Json.String("2.0"))
    return Error(RpcError(code: err_invalid_request, message: "jsonrpc must be '2.0'", data: None))
  end
  method = case fields.get("method")
    Some(Json.String(m)) if not m.trim.empty?: m.trim
    Some(_) | None: return Error(
      RpcError(code: err_invalid_request, message: "method must be a non-empty string", data: None)
    )
  end
  id_opt = case fields.get("id")
    None: None
    Some(raw_id): Some(try parse_rpc_id(raw_id))
  end
  params = case fields.get("params")
    None | Some(Json.Null): Json.Object({})
    Some(p): p
  end
  Ok(RpcRequest(id: id_opt, method: method, params: params))
end

fn format_tool_def(t: ToolDef) : Json
  Json.Object({
    "name": Json.String(t.name),
    "description": Json.String(t.description),
    "inputSchema": t.input_schema,
    "annotations": Json.Object({"readOnlyHint": Json.Boolean(t.read_only?)})
  })
end

fn format_resource_def(r: ResourceDef) : Json
  Json.Object({
    "uri": Json.String(r.uri),
    "name": Json.String(r.name),
    "description": Json.String(r.description),
    "mimeType": Json.String(r.mime_type)
  })
end

## Validates and routes an MCP Streamable HTTP JSON-RPC request.
fn dispatch(
  req: Api.Request,
  server: ServerInfo,
  tools: List(ToolDef),
  resources: List(ResourceDef)
) : McpAction
  rpc = case parse_request(req)
    Ok(r): r
    Error(e): return Respond(json_rpc_error(IdNull, e))
  end

  if rpc.id == None or rpc.method.starts_with?("notifications/")
    return Respond(
      Api.Response(status: 202, headers: [("Cache-Control", "no-store")], body: Bytes.empty)
    )
  end
  req_id = rpc.id or IdNull

  if rpc.method == "initialize"
    ver = if server.protocol_version.trim.empty?
      default_protocol_version
    else
      server.protocol_version.trim
    end
    var res_obj = {
      "protocolVersion": Json.String(ver),
      "capabilities": Json.Object({"tools": Json.Object({}), "resources": Json.Object({})}),
      "serverInfo": Json.Object({
        "name": Json.String(server.name),
        "version": Json.String(server.version)
      })
    }
    case server.instructions
      Some(inst) if not inst.trim.empty?: res_obj = res_obj.set("instructions", Json.String(inst))
      Some(_) | None: Unit
    end
    return Respond(json_rpc_ok(req_id, Json.Object(res_obj)))
  end

  if rpc.method == "ping"
    return Respond(json_rpc_ok(req_id, Json.Object({})))
  end

  if rpc.method == "tools/list"
    return Respond(
      json_rpc_ok(req_id, Json.Object({"tools": Json.Array(tools.map(format_tool_def))}))
    )
  end

  if rpc.method == "resources/list"
    return Respond(
      json_rpc_ok(
        req_id,
        Json.Object({"resources": Json.Array(resources.map(format_resource_def))})
      )
    )
  end

  if rpc.method == "tools/call"
    p_fields = case rpc.params
      Json.Object(m): m
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Respond(
        json_rpc_error(
          req_id,
          RpcError(
            code: err_invalid_params,
            message: "tools/call params must be an object",
            data: None
          )
        )
      )
    end
    tool_name = case p_fields.get("name")
      Some(Json.String(n)) if not n.trim.empty?: n.trim
      Some(_) | None: return Respond(
        json_rpc_error(
          req_id,
          RpcError(
            code: err_invalid_params,
            message: "tools/call requires string 'name'",
            data: None
          )
        )
      )
    end
    if not tools.any?(fn(t) t.name == tool_name end)
      return Respond(
        json_rpc_error(
          req_id,
          RpcError(code: err_invalid_params, message: "unknown tool '#{tool_name}'", data: None)
        )
      )
    end
    args = case p_fields.get("arguments")
      None | Some(Json.Null): Json.Object({})
      Some(Json.Object(a)): Json.Object(a)
      Some(_): return Respond(
        json_rpc_error(
          req_id,
          RpcError(
            code: err_invalid_params,
            message: "tool arguments must be an object",
            data: None
          )
        )
      )
    end
    return CallTool(id: req_id, name: tool_name, arguments: args)
  end

  if rpc.method == "resources/read"
    p_fields = case rpc.params
      Json.Object(m): m
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Respond(
        json_rpc_error(
          req_id,
          RpcError(
            code: err_invalid_params,
            message: "resources/read params must be an object",
            data: None
          )
        )
      )
    end
    uri = case p_fields.get("uri")
      Some(Json.String(u)) if not u.trim.empty?: u.trim
      Some(_) | None: return Respond(
        json_rpc_error(
          req_id,
          RpcError(
            code: err_invalid_params,
            message: "resources/read requires string 'uri'",
            data: None
          )
        )
      )
    end
    return ReadResource(id: req_id, uri: uri)
  end

  Respond(
    json_rpc_error(
      req_id,
      RpcError(code: err_method_not_found, message: "method '#{rpc.method}' not found", data: None)
    )
  )
end

fn encode_tool_content(item: ToolContent) : Json
  case item
    TextContent(text: t): Json.Object({"type": Json.String("text"), "text": Json.String(t)})
    JsonContent(data: d): Json.Object({"type": Json.String("text"), "text": Json.String(d.to_text)})
  end
end

## Encodes a `ToolCallResult` into a JSON-RPC 2.0 `Api.Response`.
fn tool_response(id: RpcId, res: ToolCallResult) : Api.Response
  var out = {
    "content": Json.Array(res.content.map(encode_tool_content)),
    "isError": Json.Boolean(res.is_error?)
  }
  case res.structured_content
    Some(sc): out = out.set("structuredContent", sc)
    None: Unit
  end
  json_rpc_ok(id, Json.Object(out))
end

## Convenience constructor for a successful text + optional structured JSON MCP tool reply.
fn tool_ok(id: RpcId, text: Text, structured: Option(Json)) : Api.Response
  tool_response(
    id,
    ToolCallResult(
      content: [TextContent(text: text)],
      is_error?: false,
      structured_content: structured
    )
  )
end

## Convenience constructor for a tool-level error response (`isError: true`).
fn tool_error(id: RpcId, message: Text) : Api.Response
  tool_response(
    id,
    ToolCallResult(content: [TextContent(text: message)], is_error?: true, structured_content: None)
  )
end

## Encodes `resources/read` contents into a JSON-RPC 2.0 `Api.Response`.
fn resource_response(id: RpcId, contents: List(ResourceContent)) : Api.Response
  items = contents.map(fn(c)
    Json.Object({
      "uri": Json.String(c.uri),
      "mimeType": Json.String(c.mime_type),
      "text": Json.String(c.text)
    })
  end)
  json_rpc_ok(id, Json.Object({"contents": Json.Array(items)}))
end

test "MCP Streamable HTTP protocol: initialize, ping, notifications, tools/list, tools/call, resources, and errors"
  server = ServerInfo(
    name: "vellum-mcp",
    version: "1.0.0",
    protocol_version: default_protocol_version,
    instructions: Some("Provide reason on writes.")
  )
  tools = [
    ToolDef(
      name: "vellum.search",
      description: "Search permitted documents",
      input_schema: object_schema({"q": Json.Object({"type": Json.String("string")})}, ["q"]),
      read_only?: true
    ),
    ToolDef(
      name: "vellum.patch_blocks",
      description: "Patch document blocks",
      input_schema: object_schema(
        {"page_id": Json.Object({"type": Json.String("string")})},
        ["page_id"]
      ),
      read_only?: false
    )
  ]
  resources = [
    ResourceDef(
      uri: "vellum://workspace/overview",
      name: "Workspace Overview",
      description: "Collections and permissions",
      mime_type: "application/json"
    )
  ]

  init_req = Api.post("/mcp").with_json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(1),
      "method": Json.String("initialize")
    })
  )
  case dispatch(init_req, server, tools, resources)
    Respond(res):
      assert res.status == 200
      assert res.text.contains?("2025-03-26")
      assert res.text.contains?("vellum-mcp")
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected Respond"
  end

  notif_req = Api.post("/mcp").with_json(
    Json.Object({"jsonrpc": Json.String("2.0"), "method": Json.String("notifications/initialized")})
  )
  case dispatch(notif_req, server, tools, resources)
    Respond(res): assert res.status == 202
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected 202"
  end

  list_req = Api.post("/mcp").with_json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.String("req-2"),
      "method": Json.String("tools/list")
    })
  )
  case dispatch(list_req, server, tools, resources)
    Respond(res):
      assert res.status == 200
      assert res.text.contains?("vellum.search") and res.text.contains?("\"req-2\"")
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected list"
  end

  call_req = Api.post("/mcp").with_json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(3),
      "method": Json.String("tools/call"),
      "params": Json.Object({
        "name": Json.String("vellum.search"),
        "arguments": Json.Object({"q": Json.String("runbook")})
      })
    })
  )
  case dispatch(call_req, server, tools, resources)
    CallTool(id: IdInt(3), name: "vellum.search", arguments: args):
      assert args.text_at("q") == Some("runbook")
      ok_res = tool_ok(IdInt(3), "Found 1 hit", Some(Json.Object({"count": Json.int(1)})))
      assert ok_res.status == 200
      assert ok_res.text.contains?("\"isError\":false")
      err_res = tool_error(IdInt(3), "denied")
      assert err_res.text.contains?("\"isError\":true")
    Respond(_) | CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected CallTool"
  end

  bad_tool_req = Api.post("/mcp").with_json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(4),
      "method": Json.String("tools/call"),
      "params": Json.Object({"name": Json.String("nope")})
    })
  )
  case dispatch(bad_tool_req, server, tools, resources)
    Respond(res): assert res.text.contains?("-32602")
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected -32602"
  end

  read_res_req = Api.post("/mcp").with_json(
    Json.Object({
      "jsonrpc": Json.String("2.0"),
      "id": Json.int(5),
      "method": Json.String("resources/read"),
      "params": Json.Object({"uri": Json.String("vellum://workspace/overview")})
    })
  )
  case dispatch(read_res_req, server, tools, resources)
    ReadResource(id: IdInt(5), uri: "vellum://workspace/overview"):
      rr = resource_response(
        IdInt(5),
        [ResourceContent(uri: "vellum://workspace/overview", mime_type: "text/plain", text: "ok")]
      )
      assert rr.status == 200 and rr.text.contains?("vellum://workspace/overview")
    Respond(_) | CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected ReadResource"
  end

  bad_json_req = Api.post("/mcp").with_bytes("{not json".bytes, "application/json")
  case dispatch(bad_json_req, server, tools, resources)
    Respond(res): assert res.status == 400 and res.text.contains?("-32700")
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected -32700"
  end

  unknown_method_req = Api.post("/mcp").with_json(
    Json.Object({"jsonrpc": Json.String("2.0"), "id": Json.int(6), "method": Json.String("foo/bar")})
  )
  case dispatch(unknown_method_req, server, tools, resources)
    Respond(res): assert res.status == 200 and res.text.contains?("-32601")
    CallTool(id: _, name: _, arguments: _) | ReadResource(id: _, uri: _): stop "expected -32601"
  end
end
