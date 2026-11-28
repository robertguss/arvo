## HTTP security headers, strict Content-Security-Policy nonces, trusted proxy CIDR resolution
## using unspoofable `X-Mo-Peer-Ip`, and privacy-preserving IP prefix truncation.
module Arvo.Security
expose SecurityHeadersConfig(..),
ProxyConfig(..),
default_headers_config,
csp_nonce,
strict_csp,
apply_headers,
default_proxy_config,
valid_ip?,
client_ip,
is_https?,
ip_prefix
use Api

## Configurable security response headers emitted by `apply_headers`.
struct SecurityHeadersConfig
  csp: Option(Text)
  hsts_seconds: Option(Int)
  hsts_include_subdomains?: Bool
  frame_options: Text
  referrer_policy: Text
  permissions_policy: Text
  cross_origin_opener_policy: Option(Text)
end

## Reverse-proxy trust configuration (`trust_proxy?: false` fails closed by default).
struct ProxyConfig
  trust_proxy?: Bool
  trusted_proxies: List(Text)
end

## Default hardened security header configuration (enables 1-year HSTS when `https?` is `true`).
fn default_headers_config(https?: Bool) : SecurityHeadersConfig
  SecurityHeadersConfig(
    csp: None,
    hsts_seconds: if https?: Some(31536000) else: None,
    hsts_include_subdomains?: true,
    frame_options: "DENY",
    referrer_policy: "strict-origin-when-cross-origin",
    permissions_policy: "camera=(), microphone=(), geolocation=()",
    cross_origin_opener_policy: Some("same-origin")
  )
end

## Generates a fresh 128-bit CSPRNG base64url Content-Security-Policy script nonce.
fn csp_nonce(rng: SecureRandom) : Text
  rng.bytes(16).to_base64url
end

fn sanitize_csp_token(raw: Text) : Text
  var out = []
  for b in raw.trim.bytes.to_list
    c = b.to_int
    if c > 32 and c < 127 and c != 59 and c != 39 and c != 34
      out = out.append(b)
    end
  end
  Bytes.from_list(out).decode_utf8 or ""
end

fn derive_ws_url(http_url: Text) : Text
  case http_url.drop_prefix("https://")
    Some(rest): "wss://#{rest}"
    None:
      case http_url.drop_prefix("http://")
        Some(rest2): "ws://#{rest2}"
        None: ""
      end
  end
end

## Builds a strict nonce-based `Content-Security-Policy` directive string for Inertia + Vite.
## In dev (`vite_dev_url: Some(...)`), permits the configured Vite HTTP and WebSocket origins for HMR.
fn strict_csp(nonce: Text, vite_dev_url: Option(Text)) : Text
  clean_nonce = sanitize_csp_token(nonce)
  nonce_src = if clean_nonce.empty?: "'self'" else: "'self' 'nonce-#{clean_nonce}'"
  case vite_dev_url
    Some(dev_raw) if not dev_raw.trim.empty?:
      trimmed = dev_raw.trim
      base = sanitize_csp_token(trimmed.drop_suffix("/") or trimmed)
      ws = derive_ws_url(base)
      connect_extra = if ws.empty?: base else: "#{base} #{ws}"
      [
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "form-action 'self'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "style-src 'self' 'unsafe-inline' #{base}",
        "script-src #{nonce_src} #{base}",
        "connect-src 'self' #{connect_extra}"
      ].join("; ")
    Some(_) | None: [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "style-src 'self' 'unsafe-inline'",
      "script-src #{nonce_src}",
      "connect-src 'self'"
    ].join("; ")
  end
end

fn header_safe_text?(v: Text) : Bool
  not v.contains?("\r") and not v.contains?("\n") and not v.contains?("\u{0}")
end

fn apply_if_valid(res: Api.Response, name: Text, val: Text) : Api.Response
  trimmed = val.trim
  if trimmed.empty? or not header_safe_text?(trimmed)
    res
  else
    res.with_header(name, trimmed)
  end
end

## Attaches configured OWASP security headers (`X-Content-Type-Options`, `X-Frame-Options`,
## `Referrer-Policy`, `Permissions-Policy`, COOP, optional `Content-Security-Policy` and HSTS).
fn apply_headers(res: Api.Response, cfg: SecurityHeadersConfig) : Api.Response
  var out = res.with_header("X-Content-Type-Options", "nosniff")
  out = apply_if_valid(out, "X-Frame-Options", cfg.frame_options)
  out = apply_if_valid(out, "Referrer-Policy", cfg.referrer_policy)
  out = apply_if_valid(out, "Permissions-Policy", cfg.permissions_policy)
  if cfg.cross_origin_opener_policy is Some(coop)
    out = apply_if_valid(out, "Cross-Origin-Opener-Policy", coop)
  end
  if cfg.csp is Some(csp)
    out = apply_if_valid(out, "Content-Security-Policy", csp)
  end
  if cfg.hsts_seconds is Some(secs) and secs > 0
    sub = if cfg.hsts_include_subdomains?: "; includeSubDomains" else: ""
    out = apply_if_valid(out, "Strict-Transport-Security", "max-age=#{secs}#{sub}")
  end
  out
end

## Default fail-closed `ProxyConfig` that ignores `X-Forwarded-*` headers and trusts `X-Mo-Peer-Ip`.
fn default_proxy_config() : ProxyConfig
  ProxyConfig(trust_proxy?: false, trusted_proxies: [])
end

fn all_ascii_digits?(s: Text) : Bool
  return false if s.empty?
  for b in s.bytes.to_list
    n = b.to_int
    return false if n < 48 or n > 57
  end
  true
end

fn parse_ipv4_octets(raw: Text) : Option((Int, Int, Int, Int))
  s = raw.trim
  parts = s.split(".")
  return None if parts.size != 4
  var vals = []
  for p in parts
    return None if p.byte_count == 0 or p.byte_count > 3 or not all_ascii_digits?(p)
    v = case p.to_int
      Some(n) if n >= 0 and n <= 255: n
      Some(_) | None: return None
    end
    vals = vals.append(v)
  end
  Some((vals.get(0) or 0, vals.get(1) or 0, vals.get(2) or 0, vals.get(3) or 0))
end

fn ipv4_to_int(o: (Int, Int, Int, Int)) : Int
  ((o.0 * 256 + o.1) * 256 + o.2) * 256 + o.3
end

fn parse_hex_group(s: Text) : Option(Int)
  return None if s.byte_count == 0 or s.byte_count > 4
  var acc = 0
  for b in s.bytes.to_list
    c = b.to_int
    nib = if c >= 48 and c <= 57
      c - 48
    else if c >= 65 and c <= 70
      c - 55
    else if c >= 97 and c <= 102
      c - 87
    else
      return None
    end
    acc = acc * 16 + nib
  end
  Some(acc)
end

fn expand_ipv6_tokens(tokens: List(Text)) : Option(List(Int))
  var out = []
  n = tokens.size
  for (idx, tok) in tokens.enumerate
    if tok.contains?(".")
      return None if idx != n - 1
      v4 = try parse_ipv4_octets(tok)
      out = out.append(v4.0 * 256 + v4.1).append(v4.2 * 256 + v4.3)
    else
      g = try parse_hex_group(tok)
      out = out.append(g)
    end
  end
  Some(out)
end

fn parse_ipv6_groups(raw: Text) : Option(List(Int))
  no_zone = (raw.trim.split("%").first or "").trim
  return None if no_zone.empty? or no_zone.contains?(" ")
  dc = no_zone.split("::")
  if dc.size == 1
    parts = no_zone.split(":")
    groups = try expand_ipv6_tokens(parts)
    return if groups.size == 8: Some(groups) else: None
  else if dc.size == 2
    left_raw = dc.get(0) or ""
    right_raw = dc.get(1) or ""
    left_toks = if left_raw.empty?: [] else: left_raw.split(":")
    right_toks = if right_raw.empty?: [] else: right_raw.split(":")
    left_g = try expand_ipv6_tokens(left_toks)
    right_g = try expand_ipv6_tokens(right_toks)
    missing = 8 - left_g.size - right_g.size
    return None if missing < 1
    var zeros = []
    for _ in 0..missing
      zeros = zeros.append(0)
    end
    Some(left_g.concat(zeros).concat(right_g))
  else
    None
  end
end

fn pow2(exp: Int) : Int
  var acc = 1
  var i = 0
  while i < exp
    acc = acc * 2
    i += 1
  end
  acc
end

fn ipv4_cidr_match?(ip_raw: Text, net_raw: Text, prefix: Int) : Bool
  return false if prefix < 0 or prefix > 32
  ip_o = case parse_ipv4_octets(ip_raw)
    Some(o): o
    None: return false
  end
  net_o = case parse_ipv4_octets(net_raw)
    Some(o): o
    None: return false
  end
  return true if prefix == 0
  shift = 32 - prefix
  div = pow2(shift)
  ipv4_to_int(ip_o).floor_div(div) == ipv4_to_int(net_o).floor_div(div)
end

fn ipv6_cidr_match?(ip_raw: Text, net_raw: Text, prefix: Int) : Bool
  return false if prefix < 0 or prefix > 128
  ip_g = case parse_ipv6_groups(ip_raw)
    Some(g): g
    None: return false
  end
  net_g = case parse_ipv6_groups(net_raw)
    Some(g): g
    None: return false
  end
  full_groups = prefix / 16
  rem_bits = prefix % 16
  for i in 0..full_groups
    if (ip_g.get(i) or -1) != (net_g.get(i) or -2)
      return false
    end
  end
  if rem_bits > 0
    div = pow2(16 - rem_bits)
    ig = (ip_g.get(full_groups) or 0).floor_div(div)
    ng = (net_g.get(full_groups) or 0).floor_div(div)
    return ig == ng
  end
  true
end

fn ip_matches_rule?(ip_raw: Text, rule_raw: Text) : Bool
  ip = ip_raw.trim
  rule = rule_raw.trim
  return false if ip.empty? or rule.empty?
  if rule.contains?("/")
    parts = rule.split("/")
    return false if parts.size != 2
    net_str = (parts.get(0) or "").trim
    pfx_str = (parts.get(1) or "").trim
    return false if not all_ascii_digits?(pfx_str)
    pfx = case pfx_str.to_int
      Some(n): n
      None: return false
    end
    if net_str.contains?(":")
      return ipv6_cidr_match?(ip, net_str, pfx)
    else
      return ipv4_cidr_match?(ip, net_str, pfx)
    end
  end

  if parse_ipv4_octets(ip) is Some(ip_o) and parse_ipv4_octets(rule) is Some(r_o)
    return ipv4_to_int(ip_o) == ipv4_to_int(r_o)
  end
  if parse_ipv6_groups(ip) is Some(ip_g) and parse_ipv6_groups(rule) is Some(r_g)
    return ip_g == r_g
  end
  false
end

fn peer_trusted?(ip: Text, cfg: ProxyConfig) : Bool
  cfg.trust_proxy? and cfg.trusted_proxies.any?(fn(rule) ip_matches_rule?(ip, rule) end)
end

## True when `raw` is a syntactically valid IPv4 or IPv6 address literal.
fn valid_ip?(raw: Text) : Bool
  s = raw.trim
  parse_ipv4_octets(s) is Some(_) or parse_ipv6_groups(s) is Some(_)
end

## Resolves the authentic client IP address.
## Reads unspoofable `X-Mo-Peer-Ip` injected by `mo serve`; walks `X-Forwarded-For` from right
## to left ONLY when `cfg.trust_proxy?` is true AND `X-Mo-Peer-Ip` matches `cfg.trusted_proxies`.
fn client_ip(req: Api.Request, cfg: ProxyConfig) : Text
  peer_raw = (req.header("X-Mo-Peer-Ip") or "").trim
  return "unknown" if peer_raw.empty?
  return peer_raw if not peer_trusted?(peer_raw, cfg)

  xff_vals = req.headers_named("X-Forwarded-For")
  return peer_raw if xff_vals.empty?
  hops = xff_vals.join(",").split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end)
  return peer_raw if hops.empty?

  # Verify syntax of every hop so malformed spoofed headers fail closed to socket peer IP.
  for h in hops
    return peer_raw if not valid_ip?(h)
  end
  for h in hops.reverse
    return h if not peer_trusted?(h, cfg)
  end
  hops.first or peer_raw
end

## True only when `cfg.trust_proxy?` trusts `X-Mo-Peer-Ip` and `X-Forwarded-Proto` indicates `https`.
fn is_https?(req: Api.Request, cfg: ProxyConfig) : Bool
  peer_raw = (req.header("X-Mo-Peer-Ip") or "").trim
  return false if peer_raw.empty? or not peer_trusted?(peer_raw, cfg)
  proto = case req.header("X-Forwarded-Proto")
    Some(raw): ((raw.split(",").first or "").trim).ascii_lowercase
    None: ""
  end
  proto == "https"
end

fn hex16_lower(n: Int) : Text
  digits = "0123456789abcdef".chars
  d3 = (n / 4096) % 16
  d2 = (n / 256) % 16
  d1 = (n / 16) % 16
  d0 = n % 16
  c3 = digits.get(d3) or '0'
  c2 = digits.get(d2) or '0'
  c1 = digits.get(d1) or '0'
  c0 = digits.get(d0) or '0'
  raw = Text.from_chars([c3, c2, c1, c0])
  var trimmed = raw
  while trimmed.byte_count > 1 and trimmed.starts_with?("0")
    trimmed = trimmed.drop_prefix("0") or trimmed
  end
  trimmed
end

## Converts an IP address to a privacy-preserving network prefix (`a.b.c.0/24` or `/48` IPv6).
fn ip_prefix(ip: Text) : Text
  if parse_ipv4_octets(ip) is Some((a, b, c, _d))
    return "#{a}.#{b}.#{c}.0/24"
  end
  if parse_ipv6_groups(ip) is Some(groups)
    g0 = hex16_lower(groups.get(0) or 0)
    g1 = hex16_lower(groups.get(1) or 0)
    g2 = hex16_lower(groups.get(2) or 0)
    return "#{g0}:#{g1}:#{g2}::/48"
  end
  "unknown"
end

test "security headers, strict CSP nonces, trusted proxy XFF resolution, and IP prefixing"
  rng = SecureRandom.seeded(55)
  nonce = csp_nonce(rng)
  assert nonce.byte_count >= 20

  prod_csp = strict_csp(nonce, None)
  assert prod_csp.contains?("script-src 'self' 'nonce-#{nonce}'")
  assert prod_csp.contains?("frame-ancestors 'none'")
  assert prod_csp.contains?("object-src 'none'")
  assert prod_csp.contains?("connect-src 'self';") or prod_csp.ends_with?("connect-src 'self'")
  assert not prod_csp.contains?("127.0.0.1:5173")

  dev_csp = strict_csp(nonce, Some("http://127.0.0.1:5173/"))
  assert dev_csp.contains?("script-src 'self' 'nonce-#{nonce}' http://127.0.0.1:5173")
  assert dev_csp.contains?("connect-src 'self' http://127.0.0.1:5173 ws://127.0.0.1:5173")

  var cfg_https = default_headers_config(true)
  cfg_https.csp = Some(prod_csp)
  sec_res = apply_headers(Api.html_response(200, "<p>ok</p>"), cfg_https)
  assert sec_res.header("X-Content-Type-Options") == Some("nosniff")
  assert sec_res.header("X-Frame-Options") == Some("DENY")
  assert sec_res.header("Referrer-Policy") == Some("strict-origin-when-cross-origin")
  assert sec_res.header("Cross-Origin-Opener-Policy") == Some("same-origin")
  assert sec_res.header("Content-Security-Policy") == Some(prod_csp)
  assert sec_res.header("Strict-Transport-Security") == Some("max-age=31536000; includeSubDomains")

  http_res = apply_headers(Api.no_content(), default_headers_config(false))
  assert http_res.header("Strict-Transport-Security") == None

  # Untrusted default ProxyConfig ignores client X-Forwarded-For / X-Forwarded-Proto spoofing
  spoofed = Api.get("/").with_header("X-Mo-Peer-Ip", "203.0.113.9").with_header(
    "X-Forwarded-For",
    "1.2.3.4"
  ).with_header("X-Forwarded-Proto", "https")
  assert client_ip(spoofed, default_proxy_config()) == "203.0.113.9"
  assert not is_https?(spoofed, default_proxy_config())
  assert client_ip(Api.get("/"), default_proxy_config()) == "unknown"

  # Trusted CIDR proxy walks XFF from right to left, skipping trusted hops
  proxy_cfg = ProxyConfig(trust_proxy?: true, trusted_proxies: ["127.0.0.1", "10.0.0.0/8", "::1"])
  assert client_ip(spoofed, proxy_cfg) == "203.0.113.9"
  assert not is_https?(spoofed, proxy_cfg)

  via_cdn = Api.get("/").with_header("X-Mo-Peer-Ip", "10.1.2.3").with_header(
    "X-Forwarded-For",
    "198.51.100.42, 10.20.30.40"
  ).with_header("X-Forwarded-Proto", "https, http")
  assert client_ip(via_cdn, proxy_cfg) == "198.51.100.42"
  assert is_https?(via_cdn, proxy_cfg)

  # Client forging left XFF entry cannot spoof past trusted rightmost client IP
  forged_left = Api.get("/").with_header("X-Mo-Peer-Ip", "127.0.0.1").with_header(
    "X-Forwarded-For",
    "9.9.9.9, 203.0.113.77, 10.0.0.5"
  )
  assert client_ip(forged_left, proxy_cfg) == "203.0.113.77"

  # Malformed hop fails closed to socket peer IP
  bad_xff = Api.get("/").with_header("X-Mo-Peer-Ip", "10.0.0.1").with_header(
    "X-Forwarded-For",
    "198.51.100.1, not-an-ip"
  )
  assert client_ip(bad_xff, proxy_cfg) == "10.0.0.1"

  # IP prefix truncation for session metadata
  assert ip_prefix("203.0.113.77") == "203.0.113.0/24"
  assert ip_prefix("2001:0db8:85a3:0000:0000:8a2e:0370:7334") == "2001:db8:85a3::/48"
  assert ip_prefix("::1") == "0:0:0::/48"
  assert ip_prefix("unknown") == "unknown"
end
