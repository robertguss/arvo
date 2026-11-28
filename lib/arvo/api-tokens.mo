## Machine, CLI, and delegated AI agent bearer tokens (`<prefix>_<tok_id>_<secret>`),
## storing only SHA-256 secret digests with prefix/namespace scope matching.
module Arvo.ApiTokens
expose ApiTokenRecord(..),
IssuedApiToken(..),
ParsedBearerToken(..),
TokenMintError(..),
to_text,
valid_prefix?,
mint_token,
parse_raw_token,
parse_bearer_header,
verify_token,
scope_matches?,
has_scope?
use Api
use Crypto

## Stored API / agent token metadata paired with SHA-256 secret digest (plaintext secret never stored).
struct ApiTokenRecord
  id: Text
  user_id: Text
  org_id: Option(Text)
  name: Text
  prefix: Text
  secret_hash: Text
  scopes: List(Text)
  grant_id: Option(Text)
  taint_policy_id: Option(Text)
  expires_at: Option(Time)
  last_used_at: Option(Time)
  revoked_at: Option(Time)
  created_at: Time
end

## Newly minted token paired with one-time plaintext `<prefix>_<token_id>_<secret>`.
struct IssuedApiToken
  record: ApiTokenRecord
  plaintext_token: Text
end

## Parsed components extracted from an inbound Bearer token string.
struct ParsedBearerToken
  prefix: Text
  token_id: Text
  secret: Text
end

## Validation errors raised when minting an API token.
enum TokenMintError
  InvalidPrefix(Text)
  EmptyName
  EmptyUserId
end

## Formats a `TokenMintError` as a readable diagnostic.
fn to_text(err: TokenMintError) : Text
  case err
    InvalidPrefix(p): "invalid token prefix '#{p}' (expected 2..24 chars matching ^[a-z][a-z0-9_]*$)"
    EmptyName: "API token name cannot be empty"
    EmptyUserId: "API token user_id cannot be empty"
  end
end

## Validates a token prefix against `^[a-z][a-z0-9_]{1,23}$` without leading/trailing `_`.
fn valid_prefix?(prefix: Text) : Bool
  examples
    valid_prefix?("arvo_live")
    valid_prefix?("arvo_agent")
    not valid_prefix?("a")
    not valid_prefix?("Arvo")
    not valid_prefix?("arvo-live")
    not valid_prefix?("arvo_live_")
  end

  bs = prefix.bytes
  return false if bs.size < 2 or bs.size > 24
  return false if prefix.ends_with?("_")
  var i = 0
  while i < bs.size
    n = bs.get(i).map(fn(b) b.to_int end) or 0
    lower? = n >= 97 and n <= 122
    digit? = n >= 48 and n <= 57
    if i == 0
      return false if not lower?
    else
      return false if not (lower? or digit? or n == 95)
    end
    i += 1
  end
  true
end

fn valid_token_id?(tid: Text) : Bool
  return false if not tid.starts_with?("tok") or tid.byte_count != 19
  hex = tid.drop_prefix("tok") or ""
  case Bytes.from_hex(hex)
    Some(b): b.size == 8
    None: false
  end
end

fn sanitize_scopes(scopes: List(Text)) : List(Text)
  var seen = Set.empty
  var out = []
  for raw in scopes
    s = raw.trim
    if not s.empty? and not seen.has?(s)
      seen = seen.add(s)
      out = out.append(s)
    end
  end
  out
end

## Mints a scoped bearer token (`<prefix>_tok<16hex>_<32B base64url>`) whose plaintext is returned once.
fn mint_token(
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  org_id: Option(Text),
  name: Text,
  prefix: Text,
  scopes: List(Text),
  grant_id: Option(Text),
  taint_policy_id: Option(Text),
  expires_at: Option(Time)
) : Result(IssuedApiToken, TokenMintError)
  clean_uid = user_id.trim
  return Error(EmptyUserId) if clean_uid.empty?
  clean_name = name.trim
  return Error(EmptyName) if clean_name.empty?
  clean_prefix = prefix.trim
  return Error(InvalidPrefix(clean_prefix)) if not valid_prefix?(clean_prefix)

  now = clock.now
  tok_id = "tok#{rng.bytes(8).to_hex}"
  secret = rng.bytes(32).to_base64url
  secret_hash = Crypto.sha256(secret.bytes).to_hex
  rec = ApiTokenRecord(
    id: tok_id,
    user_id: clean_uid,
    org_id: org_id,
    name: clean_name,
    prefix: clean_prefix,
    secret_hash: secret_hash,
    scopes: sanitize_scopes(scopes),
    grant_id: grant_id,
    taint_policy_id: taint_policy_id,
    expires_at: expires_at,
    last_used_at: None,
    revoked_at: None,
    created_at: now
  )
  Ok(IssuedApiToken(record: rec, plaintext_token: "#{clean_prefix}_#{tok_id}_#{secret}"))
end

## Parses `<prefix>_<tok_id>_<secret>` even when `<prefix>` or base64url `<secret>` contains `_`.
fn parse_raw_token(raw: Text) : Option(ParsedBearerToken)
  trimmed = raw.trim
  return None if trimmed.empty?
  for ch in trimmed.chars
    return None if ch.ascii_white_space?
  end
  parts = trimmed.split("_")
  return None if parts.size < 3
  var idx = 1
  while idx < parts.size - 1
    cand_id = parts.get(idx) or ""
    if valid_token_id?(cand_id)
      cand_prefix = parts.take(idx).join("_")
      cand_secret = parts.drop(idx + 1).join("_")
      if valid_prefix?(cand_prefix) and cand_secret.byte_count >= 32
        return case Bytes.from_base64url(cand_secret)
          Some(b) if b.size >= 24: Some(
            ParsedBearerToken(prefix: cand_prefix, token_id: cand_id, secret: cand_secret)
          )
          Some(_) | None: None
        end
      end
    end
    idx += 1
  end
  None
end

## Extracts a Bearer API token from the HTTP `Authorization` header (case-insensitive).
fn parse_bearer_header(req: Api.Request) : Option(ParsedBearerToken)
  auth_hdr = req.header("Authorization") or ""
  trimmed = auth_hdr.trim
  return None if trimmed.byte_count < 8
  prefix_part = Text.from_chars(trimmed.chars.take(7)).ascii_lowercase
  return None if prefix_part != "bearer "
  raw_tok = Text.from_chars(trimmed.chars.drop(7)).trim
  parse_raw_token(raw_tok)
end

## Constant-time verification checking prefix, ID, revocation, expiry, and SHA-256 secret digest.
fn verify_token(stored: ApiTokenRecord, parsed: ParsedBearerToken, now: Time) : Bool
  return false if not (stored.revoked_at is None)
  if stored.expires_at is Some(exp)
    return false if now >= exp
  end
  return false if stored.id != parsed.token_id or stored.prefix != parsed.prefix
  cand_hash = Crypto.sha256(parsed.secret.bytes).to_hex
  Crypto.constant_time_eq?(stored.secret_hash.bytes, cand_hash.bytes)
end

## Matches `granted` scope against `required` (`"*"`, `"ns:*"` matching `"ns:..."`, or exact equality).
fn scope_matches?(granted: Text, required: Text) : Bool
  examples
    scope_matches?("*", "bills:write")
    scope_matches?("bills:*", "bills:write")
    scope_matches?("bills:read", "bills:read")
    not scope_matches?("bill:*", "bills:read")
    not scope_matches?("bills:read", "bills:write")
    not scope_matches?("", "bills:read")
  end

  g = granted.trim
  r = required.trim
  return false if g.empty? or r.empty?
  return true if g == "*" or g == r
  if g.ends_with?(":*")
    ns_colon = g.drop_suffix("*") or ""
    not ns_colon.empty? and r.starts_with?(ns_colon)
  else
    false
  end
end

## Returns `true` iff any scope on `tok` grants `required`.
fn has_scope?(tok: ApiTokenRecord, required: Text) : Bool
  tok.scopes.any?(fn(s) scope_matches?(s, required) end)
end

test "ApiTokens mint, parse with underscore prefix/secret, constant-time verify, and scopes"
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)
  rng = SecureRandom.seeded(91)

  assert mint_token(rng, clk, "", None, "ci", "arvo_live", ["*"], None, None, None) ==
    Error(EmptyUserId)
  assert mint_token(rng, clk, "u1", None, " ", "arvo_live", ["*"], None, None, None) ==
    Error(EmptyName)
  assert mint_token(rng, clk, "u1", None, "ci", "BAD!", ["*"], None, None, None) ==
    Error(InvalidPrefix("BAD!"))

  issued = case mint_token(
    rng,
    clk,
    "u_1",
    Some("org_1"),
    "CLI Deploy",
    "arvo_agent",
    ["bills:*", "docs:read", "bills:*"],
    Some("grant_1"),
    Some("taint_1"),
    Some(t0 + 3600.seconds)
  )
    Ok(x): x
    Error(_): stop "mint failed"
  end
  assert issued.record.scopes == ["bills:*", "docs:read"]
  assert issued.plaintext_token.starts_with?("arvo_agent_tok")
  assert issued.record.secret_hash != issued.plaintext_token

  req = Api.get("/api/bills").with_header("Authorization", "bearer #{issued.plaintext_token}")
  parsed = parse_bearer_header(req) or stop "parse header"
  assert parsed.prefix == "arvo_agent"
  assert parsed.token_id == issued.record.id
  assert verify_token(issued.record, parsed, t0 + 10.seconds)
  assert not verify_token(issued.record, parsed, t0 + 3600.seconds)

  var revoked = issued.record
  revoked.revoked_at = Some(t0 + 1.second)
  assert not verify_token(revoked, parsed, t0 + 10.seconds)

  assert has_scope?(issued.record, "bills:write")
  assert has_scope?(issued.record, "docs:read")
  assert not has_scope?(issued.record, "docs:write")
  assert not has_scope?(issued.record, "billing:read")

  # Secrets containing '_' in base64url still parse cleanly round-trip
  u_tok = "#{issued.record.prefix}_#{issued.record.id}_ab_cd-ef0123456789ab_cd-ef0123456789abcd"
  p_u = parse_raw_token(u_tok) or stop "underscore secret parse"
  assert p_u.prefix == issued.record.prefix and p_u.token_id == issued.record.id
end
