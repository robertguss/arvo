## WRONG VERSION (strength/arvo_policy/01_empty_any_of_allows.mo): Returns Allow when decisions is empty.
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

fn any_of(decisions: List(Decision)) : Decision
  return Allow if decisions.empty?
  var last_deny = Deny(reason: "no policy rules matched")
  for d in decisions
    if d is Allow
      return Allow
    end
    last_deny = d
  end
  last_deny
end
