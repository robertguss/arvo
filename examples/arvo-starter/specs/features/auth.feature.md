# Authentication and sessions

Household members sign in with an allowlisted email and passphrase to receive an encrypted session cookie and readable CSRF cookie, and revoke their server session when signing out.

## Sub-features

- `auth-guest-gate`: redirects unauthenticated browsers visiting `/` to `/login` and rejects API endpoints with `401`.
- `auth-login`: validates allowlist and password, issues session + CSRF cookies, and flashes a sign-in notice.
- `auth-logout`: revokes the active session so previously captured cookies cannot replay protected routes.

## How to get to it (user POV)

- Visit `/login` in a browser, enter `Email` and `Password`, and click `Sign in`.
- Click `Sign out` in the `Home` header to end the session.

## Scenarios

```gherkin
Feature: Authentication and sessions
  Background:
    Given seed profile "baseline"

  @smoke @browser @mobile @aria @screenshot
  Scenario: Guest visiting home is redirected to login and signs in successfully
    When I visit "/"
    Then the response redirects to "/login"
    When I visit "/login"
    Then the Inertia component is "Login"
    When I submit login form with email "Ada@Household.Local" and password "horse-staple-battery"
    Then the response redirects to "/"
    When I follow the redirect
    Then the Inertia component is "Home"
    And the flash notice is "Signed in"
    And the page shows heading "Ada & Household <Team>"

  @smoke @db-check
  Scenario: Sign out revokes session and blocks cookie replay
    Given signed in as "ada@household.local"
    When I sign out
    Then the response redirects to "/login"
    When I replay the previous session on "/"
    Then the response redirects to "/login"
    And audit trail contains action "auth.login" by "ada@household.local" for "members"

  @smoke
  Scenario: Non-allowlisted email shows validation error on login
    When I submit login form with email "intruder@evil.test" and password "anything"
    Then the response redirects to "/login"
    When I follow the redirect
    Then validation error for "email" contains "allowlist"
```

## Gotchas

- `display_name` intentionally contains `<` and `&` characters to prove HTML attribute escaping in `data-page`.
- Signing out must delete the server session row, not merely clear browser cookies.
