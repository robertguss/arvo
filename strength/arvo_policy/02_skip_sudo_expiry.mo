## WRONG VERSION (strength/arvo_policy/02_skip_sudo_expiry.mo): Ignores step-up expiration window.
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

fn require_sudo(reauthenticated_at: Option(Time), now: Time, max_age_seconds: Int) : Decision
  _ = now
  _ = max_age_seconds
  case reauthenticated_at
    Some(_): Allow
    None: Deny(reason: "sudo_reauth_required")
  end
end
