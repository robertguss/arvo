## WRONG VERSION (strength/arvo_policy/03_all_of_ignores_later_deny.mo): Only checks the first decision in all_of.
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

fn all_of(decisions: List(Decision)) : Decision
  return Deny(reason: "no policy rules supplied") if decisions.empty?
  decisions.first or Deny(reason: "no policy rules supplied")
end
