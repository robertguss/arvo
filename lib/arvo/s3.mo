## Pure-Mo AWS Signature Version 4 (SigV4) presigner and request signer for
## S3-compatible object storage (AWS S3, Cloudflare R2, MinIO).
module Arvo.S3
expose S3Error(..),
S3Config(..),
PresignPutOptions(..),
PresignGetOptions(..),
PresignedUrl(..),
to_text,
validate_config,
sanitize_object_key,
uri_encode,
format_amz_timestamps,
signing_key,
presign_get,
presign_put,
presign_delete,
sign_request
use Crypto
use Http

max_presign_seconds = 604800

## Errors arising from S3 configuration, key validation, expiry bounds, or headers.
enum S3Error
  InvalidConfig(reason: Text)
  InvalidKey(reason: Text)
  InvalidExpiry(seconds: Int)
  InvalidHeader(name: Text)
end

## Formats an `S3Error` as a human-readable message.
fn to_text(err: S3Error) : Text
  case err
    InvalidConfig(reason: r): "invalid S3 config: #{r}"
    InvalidKey(reason: r): "invalid S3 object key: #{r}"
    InvalidExpiry(seconds: s): "presign expiry #{s}s must be between 1 and #{max_presign_seconds}"
    InvalidHeader(name: n): "invalid S3 header '#{n}'"
  end
end

## Connection and credential configuration for an S3-compatible bucket.
struct S3Config
  endpoint: Text
  region: Text
  bucket: Text
  access_key_id: Text
  secret_access_key: Text
  session_token: Option(Text)
  path_style?: Bool
end

## Constraints and metadata signed into a presigned browser `PUT` upload URL.
struct PresignPutOptions
  expires_seconds: Int
  content_type: Option(Text)
  content_length: Option(Int)
  sha256_hex: Option(Text)
end

## Response override options signed into a presigned `GET` download URL.
struct PresignGetOptions
  expires_seconds: Int
  response_content_disposition: Option(Text)
  response_content_type: Option(Text)
end

## Presigned HTTP URL with exact signed headers and expiry metadata.
struct PresignedUrl
  method: Text
  url: Text
  required_headers: List((Text, Text))
  expires_at: Time
  signature: Text
end

struct ParsedEndpoint
  scheme: Text
  host_authority: Text
end

fn control_or_newline?(text: Text) : Bool
  for b in text.bytes.to_list
    n = b.to_int
    return true if n < 32 or n == 127
  end
  false
end

fn has_ascii_ws?(text: Text) : Bool
  for ch in text.chars
    return true if ch.ascii_white_space?
  end
  false
end

fn trim_trailing_slashes(text: Text) : Text
  var cur = text
  while cur.ends_with?("/")
    cur = cur.drop_suffix("/") or cur
  end
  cur
end

fn parse_endpoint(endpoint: Text) : Result(ParsedEndpoint, S3Error)
  trimmed = trim_trailing_slashes(endpoint.trim)
  if trimmed.empty? or has_ascii_ws?(trimmed) or control_or_newline?(trimmed)
    return Error(InvalidConfig(reason: "endpoint must be a valid http(s) URL without spaces"))
  end

  (scheme, rest) = case trimmed.drop_prefix("https://")
    Some(r): ("https", r)
    None:
      case trimmed.drop_prefix("http://")
        Some(r2): ("http", r2)
        None: return Error(InvalidConfig(reason: "endpoint must start with https:// or http://"))
      end
  end

  if rest.empty? or rest.contains?("/") or rest.contains?("?") or rest.contains?("#")
    return Error(InvalidConfig(reason: "endpoint must contain scheme and host[:port] only"))
  end

  norm_host = if scheme == "https" and rest.ends_with?(":443")
    rest.drop_suffix(":443") or rest
  else if scheme == "http" and rest.ends_with?(":80")
    rest.drop_suffix(":80") or rest
  else
    rest
  end

  return Error(InvalidConfig(reason: "endpoint host cannot be empty")) if norm_host.empty?
  Ok(ParsedEndpoint(scheme: scheme, host_authority: norm_host))
end

## Validates S3 endpoint, region, bucket name, and credentials.
fn validate_config(cfg: S3Config) : Result(Unit, S3Error)
  _ = try parse_endpoint(cfg.endpoint)
  if cfg.region.trim.empty? or has_ascii_ws?(cfg.region) or control_or_newline?(cfg.region)
    return Error(InvalidConfig(reason: "region cannot be empty or contain whitespace"))
  end
  if cfg.bucket.empty? or
    cfg.bucket.contains?("/") or
    has_ascii_ws?(cfg.bucket) or
    control_or_newline?(cfg.bucket)
    return Error(InvalidConfig(reason: "bucket must be a single non-empty path segment"))
  end
  if cfg.access_key_id.empty? or control_or_newline?(cfg.access_key_id)
    return Error(InvalidConfig(reason: "access_key_id cannot be empty"))
  end
  if cfg.secret_access_key.empty? or control_or_newline?(cfg.secret_access_key)
    return Error(InvalidConfig(reason: "secret_access_key cannot be empty"))
  end
  case cfg.session_token
    Some(tok):
      if tok.empty? or control_or_newline?(tok)
        return Error(InvalidConfig(reason: "session_token cannot be empty or contain CTLs"))
      end
    None: Unit
  end
  Ok(Unit)
end

## Normalizes and validates an S3 object key, rejecting empty keys, CTLs, and `.` / `..` traversal.
fn sanitize_object_key(raw: Text) : Result(Text, S3Error)
  examples
    sanitize_object_key("workspaces/w1/file.png") == Ok("workspaces/w1/file.png")
    sanitize_object_key("/docs/readme.md") == Ok("docs/readme.md")
    sanitize_object_key("../secret") is Error(InvalidKey(reason: _))
    sanitize_object_key("a/../b") is Error(InvalidKey(reason: _))
    sanitize_object_key("") is Error(InvalidKey(reason: _))
  end

  if control_or_newline?(raw)
    return Error(InvalidKey(reason: "key contains control characters"))
  end
  var clean = raw
  while clean.starts_with?("/")
    clean = clean.drop_prefix("/") or clean
  end
  if clean.empty?
    return Error(InvalidKey(reason: "key cannot be empty"))
  end
  for seg in clean.split("/")
    if seg.empty? or seg == "." or seg == ".."
      return Error(InvalidKey(reason: "invalid path segment '#{seg}' in object key"))
    end
  end
  Ok(clean)
end

fn unreserved_byte?(b: Int) : Bool
  (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or
    b == 45 or
    b == 46 or
    b == 95 or
    b == 126
end

fn hex_upper_byte(b: Int) : Text
  digits = "0123456789ABCDEF".chars
  hi = digits.get(b / 16) or '0'
  lo = digits.get(b % 16) or '0'
  "%#{hi}#{lo}"
end

## RFC 3986 percent-encoding for AWS SigV4 (`encode_slash?` encodes `'/'` as `%2F`).
fn uri_encode(text: Text, encode_slash?: Bool) : Text
  examples
    uri_encode("a-zA-Z0-9_.~", true) == "a-zA-Z0-9_.~"
    uri_encode("foo bar/baz", true) == "foo%20bar%2Fbaz"
    uri_encode("foo bar/baz", false) == "foo%20bar/baz"
    uri_encode("café", true) == "caf%C3%A9"
  end

  promise "uri_encode output contains only ASCII bytes and preserves empty text"
    text.empty? implies result.empty?
    result.byte_count == result.char_count
  end

  var out = []
  for byte in text.bytes.to_list
    b = byte.to_int
    if unreserved_byte?(b) or (not encode_slash? and b == 47)
      ch = b.to_char or ' '
      out = out.append(ch.to_text)
    else
      out = out.append(hex_upper_byte(b))
    end
  end
  out.join("")
end

## Formats UTC `Time` into `(amz_date: "YYYYMMDDTHHMMSSZ", date_stamp: "YYYYMMDD")`.
fn format_amz_timestamps(t: Time) : (Text, Text)
  examples
    format_amz_timestamps(Time.parse("2013-05-24T00:00:00Z") or stop "t") == (
      "20130524T000000Z",
      "20130524"
    )
    format_amz_timestamps(Time.parse("2026-11-26T12:34:56.789Z") or stop "t") == (
      "20261126T123456Z",
      "20261126"
    )
  end

  promise "amz_date is 16 bytes ending in Z and date_stamp is its 8-byte prefix"
    result.0.byte_count == 16 and
      result.0.ends_with?("Z") and
      result.1.byte_count == 8 and
      result.0.starts_with?(result.1)
  end

  iso = t.to_text
  date_part = (iso.split("T").first or "1970-01-01").replace("-", "")
  after_t = iso.split("T").get(1) or "00:00:00Z"
  hms_raw = after_t.split(".").first or "00:00:00Z"
  hms = (hms_raw.drop_suffix("Z") or hms_raw).replace(":", "")
  date_stamp = if date_part.byte_count == 8: date_part else: "19700101"
  hms_clean = if hms.byte_count == 6: hms else: "000000"
  ("#{date_stamp}T#{hms_clean}Z", date_stamp)
end

## Derives the 32-byte AWS SigV4 signing key (`AWS4` -> date -> region -> service_name -> `aws4_request`).
fn signing_key(secret_access_key: Text, date_stamp: Text, region: Text, service_name: Text) : Bytes
  k_secret = "AWS4#{secret_access_key}".bytes
  k_date = Crypto.hmac_sha256(k_secret, date_stamp.bytes)
  k_region = Crypto.hmac_sha256(k_date, region.bytes)
  k_service = Crypto.hmac_sha256(k_region, service_name.bytes)
  Crypto.hmac_sha256(k_service, "aws4_request".bytes)
end

fn collapse_header_spaces(raw: Text) : Text
  trimmed = raw.trim
  var out = []
  var prev_space = false
  for ch in trimmed.chars
    if ch == ' ' or ch == '\t'
      if not prev_space
        out = out.append(' ')
        prev_space = true
      end
    else
      out = out.append(ch)
      prev_space = false
    end
  end
  Text.from_chars(out)
end

fn build_target(cfg: S3Config, clean_key: Text) : Result((Text, Text, Text), S3Error)
  ep = try parse_endpoint(cfg.endpoint)
  encoded_bucket = uri_encode(cfg.bucket, true)
  encoded_key = uri_encode(clean_key, false)
  if cfg.path_style?
    host = ep.host_authority
    canon_uri = "/#{encoded_bucket}/#{encoded_key}"
    base_url = "#{ep.scheme}://#{host}#{canon_uri}"
    Ok((host, canon_uri, base_url))
  else
    host = "#{cfg.bucket}.#{ep.host_authority}"
    canon_uri = "/#{encoded_key}"
    base_url = "#{ep.scheme}://#{host}#{canon_uri}"
    Ok((host, canon_uri, base_url))
  end
end

fn encode_sorted_query(params: List((Text, Text))) : Text
  encoded_pairs = params.map(fn(p) (uri_encode(p.0, true), uri_encode(p.1, true)) end)
  sorted = encoded_pairs.sort_by(fn(p) p.1 end).sort_by(fn(p) p.0 end)
  sorted.map(fn(p) "#{p.0}=#{p.1}" end).join("&")
end

fn canonical_headers_block(headers: List((Text, Text))) : Result((Text, Text), S3Error)
  var lowered = []
  for (raw_name, raw_val) in headers
    if raw_name.trim.empty? or control_or_newline?(raw_name) or has_ascii_ws?(raw_name.trim)
      return Error(InvalidHeader(name: raw_name))
    end
    if control_or_newline?(raw_val)
      return Error(InvalidHeader(name: raw_name))
    end
    lowered = lowered.append((raw_name.trim.ascii_lowercase, collapse_header_spaces(raw_val)))
  end

  sorted = lowered.sort_by(fn(h) h.0 end)
  var merged = []
  for (name, val) in sorted
    case merged.last
      Some((prev_n, prev_v)) if prev_n == name:
        n_merged = merged.take(merged.size - 1).append((name, "#{prev_v},#{val}"))
        merged = n_merged
      Some(_) | None: merged = merged.append((name, val))
    end
  end

  canon_lines = merged.map(fn(h) "#{h.0}:#{h.1}\n" end).join("")
  signed_names = merged.map(fn(h) h.0 end).join(";")
  Ok((canon_lines, signed_names))
end

fn sigv4_signature(
  cfg: S3Config,
  method: Text,
  canon_uri: Text,
  canon_query: Text,
  canon_headers: Text,
  signed_headers: Text,
  payload_hash: Text,
  amz_date: Text,
  date_stamp: Text
) : Text
  canon_req = "#{method}\n#{canon_uri}\n#{canon_query}\n#{canon_headers}\n#{signed_headers}\n#{payload_hash}"
  canon_hash = Crypto.sha256(canon_req.bytes).to_hex
  scope = "#{date_stamp}/#{cfg.region}/s3/aws4_request"
  string_to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{canon_hash}"
  k_sign = signing_key(cfg.secret_access_key, date_stamp, cfg.region, "s3")
  Crypto.hmac_sha256(k_sign, string_to_sign.bytes).to_hex
end

fn presign_common(
  cfg: S3Config,
  method: Text,
  key: Text,
  expires_seconds: Int,
  extra_query: List((Text, Text)),
  signed_extra_headers: List((Text, Text)),
  payload_hash: Text,
  now: Time
) : Result(PresignedUrl, S3Error)
  _ = try validate_config(cfg)
  if expires_seconds < 1 or expires_seconds > max_presign_seconds
    return Error(InvalidExpiry(seconds: expires_seconds))
  end
  clean_key = try sanitize_object_key(key)
  (host, canon_uri, base_url) = try build_target(cfg, clean_key)
  (amz_date, date_stamp) = format_amz_timestamps(now)

  all_headers = [("host", host)].concat(signed_extra_headers)
  (canon_headers, signed_headers) = try canonical_headers_block(all_headers)

  credential = "#{cfg.access_key_id}/#{date_stamp}/#{cfg.region}/s3/aws4_request"
  var q_params = [
    ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
    ("X-Amz-Credential", credential),
    ("X-Amz-Date", amz_date),
    ("X-Amz-Expires", expires_seconds.to_text),
    ("X-Amz-SignedHeaders", signed_headers)
  ]
  case cfg.session_token
    Some(tok): q_params = q_params.append(("X-Amz-Security-Token", tok))
    None: Unit
  end
  q_params = q_params.concat(extra_query)

  canon_query = encode_sorted_query(q_params)
  sig = sigv4_signature(
    cfg,
    method,
    canon_uri,
    canon_query,
    canon_headers,
    signed_headers,
    payload_hash,
    amz_date,
    date_stamp
  )
  full_url = "#{base_url}?#{canon_query}&X-Amz-Signature=#{sig}"
  Ok(
    PresignedUrl(
      method: method,
      url: full_url,
      required_headers: signed_extra_headers,
      expires_at: now + expires_seconds.seconds,
      signature: sig
    )
  )
end

## Generates an AWS SigV4 presigned `GET` URL for `key` with optional response header overrides.
fn presign_get(cfg: S3Config, key: Text, opts: PresignGetOptions, now: Time) : Result(
  PresignedUrl,
  S3Error
)
  var extra_q = []
  case opts.response_content_disposition
    Some(disp): extra_q = extra_q.append(("response-content-disposition", disp))
    None: Unit
  end
  case opts.response_content_type
    Some(ct): extra_q = extra_q.append(("response-content-type", ct))
    None: Unit
  end
  presign_common(cfg, "GET", key, opts.expires_seconds, extra_q, [], "UNSIGNED-PAYLOAD", now)
end

## Generates an AWS SigV4 presigned `PUT` URL binding optional `Content-Type`, `Content-Length`,
## and `x-amz-content-sha256`.
fn presign_put(cfg: S3Config, key: Text, opts: PresignPutOptions, now: Time) : Result(
  PresignedUrl,
  S3Error
)
  var req_headers = []
  case opts.content_type
    Some(ct):
      if ct.trim.empty? or control_or_newline?(ct)
        return Error(InvalidHeader(name: "Content-Type"))
      end
      req_headers = req_headers.append(("Content-Type", ct.trim))
    None: Unit
  end
  case opts.content_length
    Some(len):
      if len < 0
        return Error(InvalidHeader(name: "Content-Length"))
      end
      req_headers = req_headers.append(("Content-Length", len.to_text))
    None: Unit
  end

  payload_hash = case opts.sha256_hex
    Some(hex):
      decoded = case Bytes.from_hex(hex.trim)
        Some(b) if b.size == 32: b
        Some(_) | None: return Error(InvalidHeader(name: "x-amz-content-sha256"))
      end
      lower_hex = decoded.to_hex
      req_headers = req_headers.append(("x-amz-content-sha256", lower_hex))
      lower_hex
    None: "UNSIGNED-PAYLOAD"
  end

  presign_common(cfg, "PUT", key, opts.expires_seconds, [], req_headers, payload_hash, now)
end

## Generates an AWS SigV4 presigned `DELETE` URL for `key`.
fn presign_delete(cfg: S3Config, key: Text, expires_seconds: Int, now: Time) : Result(
  PresignedUrl,
  S3Error
)
  presign_common(cfg, "DELETE", key, expires_seconds, [], [], "UNSIGNED-PAYLOAD", now)
end

## Signs an outbound S3 `Http.Request` using AWS SigV4 `Authorization` headers (`host` is omitted
## from `Http.Request.headers` because `Http.wire` emits `Host:` automatically from the URL).
fn sign_request(
  cfg: S3Config,
  method: Text,
  key: Text,
  query: List((Text, Text)),
  extra_headers: List((Text, Text)),
  body: Bytes,
  now: Time
) : Result(Http.Request, S3Error)
  _ = try validate_config(cfg)
  clean_method = method.trim.ascii_uppercase
  if clean_method.empty? or has_ascii_ws?(clean_method) or control_or_newline?(clean_method)
    return Error(InvalidConfig(reason: "HTTP method cannot be empty or contain spaces"))
  end
  clean_key = try sanitize_object_key(key)
  (host, canon_uri, base_url) = try build_target(cfg, clean_key)
  (amz_date, date_stamp) = format_amz_timestamps(now)
  payload_hash = Crypto.sha256(body).to_hex

  var out_headers = []
  for (hn, hv) in extra_headers
    low = hn.trim.ascii_lowercase
    if low == "host" or
      low == "authorization" or
      low == "x-amz-date" or
      low == "x-amz-content-sha256" or
      low == "x-amz-security-token"
      return Error(InvalidHeader(name: hn))
    end
    out_headers = out_headers.append((hn.trim, hv))
  end

  out_headers = out_headers.append(("x-amz-content-sha256", payload_hash)).append((
    "x-amz-date",
    amz_date
  ))
  case cfg.session_token
    Some(tok): out_headers = out_headers.append(("x-amz-security-token", tok))
    None: Unit
  end

  sign_headers = [("host", host)].concat(out_headers)
  (canon_headers, signed_headers) = try canonical_headers_block(sign_headers)
  canon_query = encode_sorted_query(query)
  sig = sigv4_signature(
    cfg,
    clean_method,
    canon_uri,
    canon_query,
    canon_headers,
    signed_headers,
    payload_hash,
    amz_date,
    date_stamp
  )

  credential = "#{cfg.access_key_id}/#{date_stamp}/#{cfg.region}/s3/aws4_request"
  auth_val = "AWS4-HMAC-SHA256 Credential=#{credential},SignedHeaders=#{signed_headers},Signature=#{sig}"
  final_headers = out_headers.append(("Authorization", auth_val))
  full_url = if canon_query.empty?: base_url else: "#{base_url}?#{canon_query}"
  Ok(
    Http.Request(
      method: clean_method,
      url: full_url,
      headers: final_headers,
      body: body,
      timeout: 30.seconds,
      body_limit: 16777216
    )
  )
end

test "Official AWS S3 SigV4 presigned GET and Authorization-header GET test vectors"
  aws_cfg = S3Config(
    endpoint: "https://s3.amazonaws.com",
    region: "us-east-1",
    bucket: "examplebucket",
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: None,
    path_style?: false
  )
  t_vec = Time.parse("2013-05-24T00:00:00Z") or stop "vector time"

  ## Official AWS SigV4 Presigned GET /test.txt (Expires=86400)
  get_opts = PresignGetOptions(
    expires_seconds: 86400,
    response_content_disposition: None,
    response_content_type: None
  )
  assert presign_get(aws_cfg, "test.txt", get_opts, t_vec) is Ok(presigned)
  assert presigned.signature == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  assert presigned.url.starts_with?("https://examplebucket.s3.amazonaws.com/test.txt?")
  assert presigned.url.ends_with?(
    "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  )

  ## Official AWS SigV4 Authorization-header GET /test.txt with Range: bytes=0-9
  assert sign_request(aws_cfg, "GET", "test.txt", [], [("Range", "bytes=0-9")], "".bytes, t_vec) is
    Ok(signed_req)
  auth_hdr = signed_req.headers.find(fn(h) h.0 == "Authorization" end).map(fn(h) h.1 end) or ""
  assert auth_hdr.contains?("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
  assert auth_hdr.contains?("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date")
  assert auth_hdr.contains?(
    "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  )
end

test "MinIO path-style presign PUT/GET/DELETE, validation bounds, and Network.fake signed PUT"
  minio_cfg = S3Config(
    endpoint: "http://127.0.0.1:9000/",
    region: "us-east-1",
    bucket: "vellum-uploads",
    access_key_id: "minioadmin",
    secret_access_key: "minioadminsecret",
    session_token: Some("sts-tok-123"),
    path_style?: true
  )
  now = Time.parse("2026-11-26T12:00:00Z") or stop "now"
  payload = "hello vellum attachment".bytes
  digest_hex = Crypto.sha256(payload).to_hex

  put_opts = PresignPutOptions(
    expires_seconds: 300,
    content_type: Some("text/plain"),
    content_length: Some(payload.size),
    sha256_hex: Some(digest_hex)
  )
  assert presign_put(minio_cfg, "/workspaces/ws_1/note.txt", put_opts, now) is Ok(put_url)
  assert put_url.method == "PUT"
  assert put_url.url.starts_with?("http://127.0.0.1:9000/vellum-uploads/workspaces/ws_1/note.txt?")
  assert put_url.url.contains?("X-Amz-Security-Token=sts-tok-123")
  assert put_url.url.contains?(
    "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost%3Bx-amz-content-sha256"
  )
  assert put_url.required_headers == [
    ("Content-Type", "text/plain"),
    ("Content-Length", payload.size.to_text),
    ("x-amz-content-sha256", digest_hex)
  ]
  assert put_url.expires_at == now + 300.seconds

  dl_opts = PresignGetOptions(
    expires_seconds: 60,
    response_content_disposition: Some("attachment; filename=\"note.txt\""),
    response_content_type: Some("text/plain")
  )
  assert presign_get(minio_cfg, "workspaces/ws_1/note.txt", dl_opts, now) is Ok(dl_url)
  assert dl_url.url.contains?("response-content-disposition=attachment")
  assert presign_delete(minio_cfg, "workspaces/ws_1/note.txt", 60, now) is Ok(del_url)
  assert del_url.method == "DELETE"

  ## Reject traversal, expiry out of range, bad SHA-256 hex, and bad endpoint.
  assert presign_get(minio_cfg, "../etc/passwd", dl_opts, now) is Error(InvalidKey(reason: _))
  assert presign_delete(minio_cfg, "a/b.txt", 0, now) == Error(InvalidExpiry(seconds: 0))
  assert presign_delete(minio_cfg, "a/b.txt", 604801, now) == Error(InvalidExpiry(seconds: 604801))
  bad_sha_opts = PresignPutOptions(
    expires_seconds: 60,
    content_type: None,
    content_length: None,
    sha256_hex: Some("not-hex")
  )
  assert presign_put(minio_cfg, "a/b.txt", bad_sha_opts, now) ==
    Error(InvalidHeader(name: "x-amz-content-sha256"))

  var bad_cfg = minio_cfg
  bad_cfg.endpoint = "ftp://example.com"
  assert validate_config(bad_cfg) is Error(InvalidConfig(reason: _))

  ## Signed Http.Request round-trips cleanly over Network.fake.
  assert sign_request(
    minio_cfg,
    "PUT",
    "workspaces/ws_1/note.txt",
    [],
    [("Content-Type", "text/plain")],
    payload,
    now
  ) is
    Ok(signed_put)
  net = Network.fake(Http.replies([(signed_put, Http.reply(200, ""))]))
  assert signed_put.send(net) is Ok(put_res)
  assert put_res.status == 200
end
