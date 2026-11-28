## Declarative fail-closed authorization policies and HTTP `403 Forbidden` combinators
## covering authentication, scoped bearer tokens, organization roles, MFA, and sudo elevation.
module Arvo.Policy
expose Decision(..),
allowed?,
all_of,
any_of,
require_authenticated,
require_scope,
require_role,
require_sudo,
require_mfa,
owner_or_role,
to_http_response
use Api
use Arvo.ApiTokens
use Arvo.Orgs
use Arvo.Session
use Json

## Outcome of evaluating a declarative authorization rule (`Allow` or `Deny(reason)`).
enum Decision
  Allow
  Deny(reason: Text)
end

## Returns `true` iff `d` is `Allow`.
fn allowed?(d: Decision) : Bool
  d is Allow
end

## Combines policies with logical AND; fails closed (`Deny`) if `decisions` is empty or any entry denies.
fn all_of(decisions: List(Decision)) : Decision
  examples
    all_of([Allow, Allow]) == Allow
    all_of([Allow, Deny(reason: "no scope")]) == Deny(reason: "no scope")
    all_of([]) == Deny(reason: "no policy rules supplied")
  end

  promise "all_of fails closed on empty rules or any Deny"
    decisions.empty? or decisions.any?(fn(d) not allowed?(d) end) implies not allowed?(result)
  end

  return Deny(reason: "no policy rules supplied") if decisions.empty?
  for d in decisions
    if d is Deny(reason: _)
      return d
    end
  end
  Allow
end

## Combines policies with logical OR; fails closed (`Deny`) if `decisions` is empty or none permit.
fn any_of(decisions: List(Decision)) : Decision
  examples
    any_of([Deny(reason: "a"), Allow]) == Allow
    any_of([]) == Deny(reason: "no policy rules matched")
    any_of([Deny(reason: "no role")]) == Deny(reason: "no role")
  end

  promise "any_of fails closed on empty rules or when every rule denies"
    decisions.empty? or not decisions.any?(fn(d) allowed?(d) end) implies not allowed?(result)
  end

  return Deny(reason: "no policy rules matched") if decisions.empty?
  var last_deny = Deny(reason: "no policy rules matched")
  for d in decisions
    if d is Allow
      return Allow
    end
    last_deny = d
  end
  last_deny
end

## Requires an authenticated principal.
fn require_authenticated(authenticated?: Bool) : Decision
  if authenticated?: Allow else: Deny(reason: "authentication_required")
end

## Requires one of `granted_scopes` to match `required` via `ApiTokens.scope_matches?`.
fn require_scope(granted_scopes: List(Text), required: Text) : Decision
  if granted_scopes.any?(fn(g) ApiTokens.scope_matches?(g, required) end)
    Allow
  else
    Deny(reason: "missing_scope:#{required}")
  end
end

## Requires an organization `actual_role` at least as privileged as `min_role`.
fn require_role(actual_role: Option(Orgs.OrgRole), min_role: Orgs.OrgRole) : Decision
  case actual_role
    Some(r) if Orgs.role_at_least?(r, min_role): Allow
    Some(_) | None: Deny(reason: "insufficient_role:#{Orgs.role_to_text(min_role)}")
  end
end

fn sudo_policy(max_age_seconds: Int) : Session.SessionPolicy
  win = if max_age_seconds <= 0
    0
  else if max_age_seconds > 86400
    86400
  else
    max_age_seconds
  end
  Session.SessionPolicy(
    absolute_ttl_seconds: 1209600,
    idle_ttl_seconds: None,
    step_up_window_seconds: win
  )
end

## Requires fresh step-up re-authentication within `max_age_seconds` (fails closed on expiry/missing).
fn require_sudo(reauthenticated_at: Option(Time), now: Time, max_age_seconds: Int) : Decision
  examples
    case Time.parse("2026-11-28T00:00:00Z")
      Some(t0): require_sudo(Some(t0), t0 + 60.seconds, 900) == Allow and
        not allowed?(require_sudo(Some(t0), t0 + 900.seconds, 900)) and
        not allowed?(require_sudo(None, t0, 900))
      None: false
    end
  end

  promise "missing or zero-window step-up always denies sudo"
    (reauthenticated_at is None or max_age_seconds <= 0) implies not allowed?(result)
  end

  if max_age_seconds <= 0
    return Deny(reason: "sudo_reauth_required")
  end
  at = case reauthenticated_at
    Some(t): t
    None: return Deny(reason: "sudo_reauth_required")
  end
  t_min = Time.parse("0002-01-01T00:00:00Z") or now
  t_max = Time.parse("9998-01-01T00:00:00Z") or now
  eff_win = if max_age_seconds > 86400: 86400 else: max_age_seconds
  stale? = if at >= t_min and at <= t_max and now >= t_min and now <= t_max
    Session.needs_step_up?(Some(at), now, sudo_policy(eff_win))
  else if at >= now
    false
  else if now >= t_min
    at <= (now - eff_win.seconds)
  else
    (now - at) >= eff_win.seconds
  end
  if stale?
    Deny(reason: "sudo_reauth_required")
  else
    Allow
  end
end

## Requires that MFA verification completed during the active session.
fn require_mfa(mfa_verified_at: Option(Time)) : Decision
  case mfa_verified_at
    Some(_): Allow
    None: Deny(reason: "mfa_required")
  end
end

## Allows either the resource `owner_id` acting on their own behalf, or an org member meeting `min_role`.
fn owner_or_role(
  owner_id: Text,
  actor_id: Text,
  actor_role: Option(Orgs.OrgRole),
  min_role: Orgs.OrgRole
) : Decision
  if not owner_id.trim.empty? and owner_id == actor_id
    Allow
  else
    require_role(actor_role, min_role)
  end
end

## Maps `Deny(reason)` to an HTTP `403 Forbidden` JSON response (`None` when `Allow`).
fn to_http_response(d: Decision) : Option(Api.Response)
  case d
    Allow: None
    Deny(reason: r): Some(
      Api.json_response(
        403,
        Json.Object({"error": Json.String("forbidden"), "reason": Json.String(r)})
      )
    )
  end
end

test "Policy combinators fail closed, compose scopes/roles/sudo/mfa, and render 403"
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  assert all_of([]) is Deny(reason: _)
  assert any_of([]) is Deny(reason: _)
  assert all_of([
    require_authenticated(true),
    require_scope(["bills:read", "bills:write"], "bills:write"),
    require_sudo(Some(t0), t0 + 120.seconds, 900),
    require_mfa(Some(t0))
  ]) ==
    Allow

  denied = all_of([
    require_authenticated(true),
    owner_or_role("u_alice", "u_bob", Some(Orgs.Member), Orgs.Admin)
  ])
  assert denied == Deny(reason: "insufficient_role:admin")
  assert any_of([denied, owner_or_role("u_alice", "u_alice", None, Orgs.Owner)]) == Allow
  res403 = to_http_response(denied) or stop "403"
  assert res403.status == 403 and res403.text.contains?("insufficient_role:admin")
  assert to_http_response(Allow) == None
end
