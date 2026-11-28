## High-level pure-Mo Auth v2 flow orchestrators: transactional auth email builders
## (`Arvo.Mail`), MFA step detection, sudo step-up redirects/403s, `429` rate-limit responses,
## and unified session + CSRF + security header login responses.
module Arvo.AuthKit
expose AuthFlowConfig(..),
default_flow_config,
build_verification_email,
build_password_reset_email,
build_magic_link_email,
build_org_invite_email,
session_needs_mfa?,
require_sudo_response,
rate_limited_response,
complete_login_response
use Api
use Arvo.Auth
use Arvo.Inertia
use Arvo.Mail
use Arvo.Oidc
use Arvo.RateLimit
use Arvo.Security
use Arvo.Session
use Json

## Consolidated application configuration for Auth v2 email flows and session/password policies.
struct AuthFlowConfig
  app_name: Text
  base_url: Text
  from_email: Text
  session_cfg: Session.SessionConfig
  password_policy: Auth.PasswordPolicy
  session_policy: Session.SessionPolicy
  signup_mode: Auth.SignupMode
  auto_link_verified_oidc?: Bool
end

## Default production-ready `AuthFlowConfig` (`OpenSignup`, 12-char password policy, 15-min sudo window).
fn default_flow_config(app_name: Text, base_url: Text, from_email: Text, secure?: Bool) : AuthFlowConfig
  AuthFlowConfig(
    app_name: app_name,
    base_url: base_url,
    from_email: from_email,
    session_cfg: Session.default_config(secure?),
    password_policy: Auth.default_password_policy(),
    session_policy: Session.default_policy(),
    signup_mode: Auth.OpenSignup,
    auto_link_verified_oidc?: false
  )
end

fn trim_base(url: Text) : Text
  t = url.trim
  if t.ends_with?("/"): t.drop_suffix("/") or t else: t
end

fn flow_mail(
  cfg: AuthFlowConfig,
  to_email: Text,
  subject: Text,
  intro: Text,
  cta_label: Text,
  path_with_token: Text,
  footer: Text
) : Mail.MailMessage
  action_url = "#{trim_base(cfg.base_url)}#{path_with_token}"
  (txt, html) = Mail.render_transactional(subject, intro, cta_label, action_url, footer)
  Mail.MailMessage(
    from: cfg.from_email,
    to: [Auth.normalize_email(to_email)],
    reply_to: None,
    subject: subject,
    text_body: txt,
    html_body: Some(html),
    headers: []
  )
end

## Builds the transactional email-verification message carrying the one-time token link.
fn build_verification_email(cfg: AuthFlowConfig, to_email: Text, raw_token: Text) : Mail.MailMessage
  flow_mail(
    cfg,
    to_email,
    "Verify your email for #{cfg.app_name}",
    "Confirm your email address to activate your #{cfg.app_name} account.",
    "Verify email",
    "/auth/verify-email?token=#{raw_token}",
    "If you did not create an account on #{cfg.app_name}, you can safely ignore this email."
  )
end

## Builds the transactional password-reset message carrying the single-use reset link.
fn build_password_reset_email(cfg: AuthFlowConfig, to_email: Text, raw_token: Text) : Mail
  .MailMessage
  flow_mail(
    cfg,
    to_email,
    "Reset your #{cfg.app_name} password",
    "Use the button below to choose a new password for your #{cfg.app_name} account.",
    "Reset password",
    "/auth/reset-password?token=#{raw_token}",
    "This link expires soon. If you did not request a reset, you can safely ignore this message."
  )
end

## Builds the transactional passwordless magic-link sign-in email.
fn build_magic_link_email(cfg: AuthFlowConfig, to_email: Text, raw_token: Text) : Mail.MailMessage
  flow_mail(
    cfg,
    to_email,
    "Sign in to #{cfg.app_name}",
    "Click the secure link below to sign in to #{cfg.app_name}.",
    "Sign in",
    "/auth/magic-link/callback?token=#{raw_token}",
    "This single-use link expires shortly."
  )
end

## Builds an organization invitation email for `org_name`.
fn build_org_invite_email(cfg: AuthFlowConfig, org_name: Text, to_email: Text, raw_token: Text) : Mail
  .MailMessage
  flow_mail(
    cfg,
    to_email,
    "You are invited to join #{org_name} on #{cfg.app_name}",
    "Accept this invitation to join #{org_name} in #{cfg.app_name}.",
    "Accept invitation",
    "/orgs/invites/accept?token=#{raw_token}",
    "If you were not expecting an invitation from #{org_name}, you can ignore this email."
  )
end

## Returns `true` when `user` has MFA enrolled and the current session has not completed MFA verification.
fn session_needs_mfa?(user: Auth.User, mfa_verified_at: Option(Time)) : Bool
  user.mfa_enabled? and mfa_verified_at is None
end

fn api_or_json_request?(req: Api.Request) : Bool
  return true if req.path.starts_with?("/api/")
  accept = (req.header("Accept") or "").ascii_lowercase
  accept.contains?("application/json") and not Inertia.request?(req)
end

## Returns `None` when the caller has a fresh sudo elevation within `policy.step_up_window_seconds`;
## otherwise returns `Some(403 JSON)` for API callers or `Some(303 redirect)` to `sudo_path` for browsers.
fn require_sudo_response(
  req: Api.Request,
  reauthenticated_at: Option(Time),
  clock: Clock,
  policy: Session.SessionPolicy,
  sudo_path: Text
) : Option(Api.Response)
  now = clock.now
  return None if not Session.needs_step_up?(reauthenticated_at, now, policy)
  sanitized = Oidc.safe_return_to(Some(sudo_path))
  clean_sudo = if sanitized == "/" and sudo_path.trim != "/": "/auth/sudo" else: sanitized
  if api_or_json_request?(req)
    Some(
      Api.json_response(
        403,
        Json.Object({
          "error": Json.String("sudo_reauth_required"),
          "sudo_url": Json.String(clean_sudo)
        })
      )
    )
  else
    Some(Api.redirect_see_other(clean_sudo))
  end
end

## Returns `None` if `outcome` is `Allowed`, or `Some(429 Too Many Requests)` with `Retry-After` / `X-RateLimit-*`.
fn rate_limited_response(outcome: RateLimit.LimitOutcome) : Option(Api.Response)
  case outcome
    RateLimit.Allowed(remaining: _, reset_at: _, limit: _): None
    RateLimit.Limited(retry_after_seconds: _, reset_at: _, limit: _): Some(
      RateLimit.too_many_requests(outcome, "too many requests; please wait before retrying")
    )
  end
end

## Attaches session cookie, `XSRF-TOKEN` cookie, and OWASP security headers onto `res`.
fn complete_login_response(
  res: Api.Response,
  session: Session.Session,
  cookie_val: Text,
  cfg: Session.SessionConfig,
  sec_cfg: Security.SecurityHeadersConfig
) : Api.Response
  Security.apply_headers(Auth.login_response(res, session, cookie_val, cfg), sec_cfg)
end

test "AuthKit transactional mails, MFA gate, sudo 403/redirect, rate limit 429, and login headers"
  cfg = default_flow_config("Arvo", "https://app.example.test/", "no-reply@example.test", true)
  m_ver = build_verification_email(cfg, " Ada@Acme.IO ", "tok_v")
  assert m_ver.to == ["ada@acme.io"]
  assert Mail.extract_urls(m_ver.text_body) == [
    "https://app.example.test/auth/verify-email?token=tok_v"
  ]
  assert Mail.extract_urls(build_magic_link_email(cfg, "ada@acme.io", "tok_m").text_body) == [
    "https://app.example.test/auth/magic-link/callback?token=tok_m"
  ]
  assert Mail.extract_urls(build_password_reset_email(cfg, "ada@acme.io", "tok_r").text_body) == [
    "https://app.example.test/auth/reset-password?token=tok_r"
  ]
  assert Mail.extract_urls(build_org_invite_email(cfg, "Acme", "ada@acme.io", "tok_i").text_body) == [
    "https://app.example.test/orgs/invites/accept?token=tok_i"
  ]

  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  u = Auth.User(
    id: "u1",
    email: "ada@acme.io",
    email_verified_at: Some(t0),
    display_name: None,
    avatar_url: None,
    status: Auth.Active,
    mfa_enabled?: true,
    created_at: t0,
    updated_at: t0
  )
  assert session_needs_mfa?(u, None)
  assert not session_needs_mfa?(u, Some(t0))

  pol = Session.default_policy()
  assert require_sudo_response(
    Api.post("/settings/pw"),
    Some(t0),
    Clock.fixed(t0 + 60.seconds),
    pol,
    "/auth/sudo"
  ) ==
    None
  redir = require_sudo_response(Api.post("/settings/pw"), None, Clock.fixed(t0), pol, "/auth/sudo") or
    stop "redir"
  assert redir.status == 303 and redir.header("Location") == Some("/auth/sudo")
  api_403 = require_sudo_response(
    Api.post("/api/tokens").with_header("Accept", "application/json"),
    Some(t0),
    Clock.fixed(t0 + 900.seconds),
    pol,
    "/auth/sudo"
  ) or
    stop "403"
  assert api_403.status == 403 and api_403.text.contains?("sudo_reauth_required")

  assert rate_limited_response(RateLimit.Allowed(remaining: 4, reset_at: t0 + 60.seconds, limit: 5)) ==
    None
  r429 = rate_limited_response(
    RateLimit.Limited(retry_after_seconds: 12, reset_at: t0 + 12.seconds, limit: 5)
  ) or
    stop "429"
  assert r429.status == 429 and r429.header("Retry-After") == Some("12")

  sess = Session.Session(id: "s1", member_id: "u1", csrf_token: "csrf1", expires_at: t0 + 1.hour)
  login_res = complete_login_response(
    Api.redirect_see_other("/"),
    sess,
    "v2.k1.abc",
    cfg.session_cfg,
    Security.default_headers_config(true)
  )
  assert login_res.headers_named("Set-Cookie").size == 2
  assert login_res.header("X-Frame-Options") == Some("DENY")
  assert (login_res.header("Strict-Transport-Security") or "").contains?("max-age=31536000")
end
