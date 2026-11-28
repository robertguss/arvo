## Organization accounts, hierarchical member roles (`Owner > Admin > Member > Viewer`),
## domain invite records, slug validation, and last-owner protection invariants.
module Arvo.Orgs
expose OrgRole(..),
Org(..),
Membership(..),
OrgInvite(..),
OrgError(..),
role_to_text,
role_from_text,
role_rank,
role_at_least?,
to_text,
valid_slug?,
can_remove_or_demote?

## Hierarchical organization membership roles (`Owner` > `Admin` > `Member` > `Viewer`).
enum OrgRole
  Owner
  Admin
  Member
  Viewer
end

## Tenant organization workspace record.
struct Org
  id: Text
  slug: Text
  name: Text
  created_at: Time
end

## Membership binding a `user_id` to an `org_id` with a hierarchical `OrgRole`.
struct Membership
  org_id: Text
  user_id: Text
  role: OrgRole
  joined_at: Time
end

## Single-use SHA-256 hashed invitation to join an organization.
struct OrgInvite
  id: Text
  org_id: Text
  email: Text
  role: OrgRole
  token_hash: Text
  invited_by: Text
  expires_at: Time
  accepted_at: Option(Time)
  created_at: Time
end

## Domain errors from organization and membership management.
enum OrgError
  InvalidSlug(Text)
  EmptyName
  LastOwnerProtected
  DuplicateMembership
  MembershipNotFound
end

## Formats an `OrgError` as a human-readable diagnostic.
fn to_text(err: OrgError) : Text
  case err
    InvalidSlug(s): "invalid organization slug '#{s}'"
    EmptyName: "organization name cannot be empty"
    LastOwnerProtected: "cannot remove or demote the last remaining Owner of an organization"
    DuplicateMembership: "user is already a member of this organization"
    MembershipNotFound: "organization membership not found"
  end
end

## Serializes `OrgRole` into canonical lowercase text.
fn role_to_text(role: OrgRole) : Text
  case role
    Owner: "owner"
    Admin: "admin"
    Member: "member"
    Viewer: "viewer"
  end
end

## Parses a canonical lowercase `OrgRole` string.
fn role_from_text(raw: Text) : Option(OrgRole)
  norm = raw.trim.ascii_lowercase
  if norm == "owner"
    Some(Owner)
  else if norm == "admin"
    Some(Admin)
  else if norm == "member"
    Some(Member)
  else if norm == "viewer"
    Some(Viewer)
  else
    None
  end
end

## Numeric precedence rank (`Viewer=1`, `Member=2`, `Admin=3`, `Owner=4`).
fn role_rank(role: OrgRole) : Int
  case role
    Owner: 4
    Admin: 3
    Member: 2
    Viewer: 1
  end
end

## Returns `true` iff `actual` satisfies or exceeds `required` rank.
fn role_at_least?(actual: OrgRole, required: OrgRole) : Bool
  examples
    role_at_least?(Owner, Admin)
    role_at_least?(Admin, Admin)
    not role_at_least?(Member, Admin)
    not role_at_least?(Viewer, Member)
  end

  role_rank(actual) >= role_rank(required)
end

## Validates an organization slug (`3..63` chars `[a-z0-9-]`, starts/ends alnum, no `--`).
fn valid_slug?(slug: Text) : Bool
  examples
    valid_slug?("acme-hq")
    valid_slug?("a1b")
    not valid_slug?("ab")
    not valid_slug?("-acme")
    not valid_slug?("acme-")
    not valid_slug?("acme--hq")
    not valid_slug?("Acme-HQ")
  end

  bs = slug.bytes
  return false if bs.size < 3 or bs.size > 63
  return false if slug.starts_with?("-") or slug.ends_with?("-") or slug.contains?("--")
  for ch in slug.chars
    lower_alpha? = ch.ascii_letter? and ch.ascii_lowercase == ch
    ok = lower_alpha? or ch.ascii_digit? or ch == '-'
    return false if not ok
  end
  true
end

## Last-Owner Protection invariant: returns `false` when removing or demoting `target_user_id`
## would leave the organization with zero `Owner`s.
fn can_remove_or_demote?(
  memberships: List(Membership),
  target_user_id: Text,
  new_role: Option(OrgRole)
) : Bool
  examples
    case Time.parse("2026-11-28T00:00:00Z")
      Some(t0):
        one_owner = [Membership(org_id: "o1", user_id: "u1", role: Owner, joined_at: t0)]
        two_owners = [
          Membership(org_id: "o1", user_id: "u1", role: Owner, joined_at: t0),
          Membership(org_id: "o1", user_id: "u2", role: Owner, joined_at: t0)
        ]
        not can_remove_or_demote?(one_owner, "u1", None) and
          not can_remove_or_demote?(one_owner, "u1", Some(Admin)) and
          can_remove_or_demote?(one_owner, "u1", Some(Owner)) and
          can_remove_or_demote?(two_owners, "u1", None)
      None: false
    end
  end

  promise "last remaining Owner cannot be removed or demoted"
    case new_role
      Some(Owner): result
      Some(_) | None: memberships.filter(fn(m) m.role is Owner end).size <= 1 and
        memberships.any?(fn(m) m.user_id == target_user_id and m.role is Owner end) implies
        not result
    end
  end

  if new_role is Some(Owner)
    return true
  end
  target_is_owner? = memberships.any?(fn(m) m.user_id == target_user_id and m.role is Owner end)
  return true if not target_is_owner?
  memberships.any?(fn(m) m.user_id != target_user_id and m.role is Owner end)
end

test "Org roles, slug checks, and last-owner protection"
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  assert role_to_text(Admin) == "admin" and role_from_text("OWNER") == Some(Owner)
  assert valid_slug?("vellum-team-2") and not valid_slug?("v!")

  ms = [
    Membership(org_id: "o1", user_id: "u1", role: Owner, joined_at: t0),
    Membership(org_id: "o1", user_id: "u2", role: Admin, joined_at: t0)
  ]
  assert not can_remove_or_demote?(ms, "u1", None)
  assert not can_remove_or_demote?(ms, "u1", Some(Member))
  assert can_remove_or_demote?(ms, "u2", None)
  assert can_remove_or_demote?(ms, "u2", Some(Viewer))
end
