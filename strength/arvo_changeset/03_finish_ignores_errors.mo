## WRONG VERSION (strength/arvo_changeset/03_finish_ignores_errors.mo): Returns Ok(cs.data) from finish even when validation errors exist.
## Ash/Ecto-style validation accumulator producing `Map(Text, List(Text))` and Inertia
## `useForm().errors` (`Record<string, string>`) JSON payloads.
module Arvo.Changeset
expose Changeset(..),
new,
add_error,
check,
require_non_empty,
require_length,
require_positive_int,
require_non_negative_int,
require_email,
require_one_of,
valid?,
first_errors,
errors_json,
error_map_json,
inertia_errors_json,
inertia_error_map_json,
finish
use Json

## Accumulates field-keyed validation errors alongside candidate `data`.
struct Changeset(T)
  data: T
  errors: Map(Text, List(Text))
end

## Starts a valid `Changeset` wrapping `data` with zero errors.
fn new(data: T) : Changeset(T)
  Changeset(data: data, errors: {})
end

## Appends `message` under `field` in `cs.errors`.
fn add_error(cs: Changeset(T), field: Text, message: Text) : Changeset(T)
  prev = cs.errors.get(field) or []
  Changeset(data: cs.data, errors: cs.errors.set(field, prev.append(message)))
end

## Records `message` under `field` when `ok?` is `false`.
fn check(cs: Changeset(T), field: Text, ok?: Bool, message: Text) : Changeset(T)
  if ok?
    cs
  else
    add_error(cs, field, message)
  end
end

## Requires `value` to contain at least one non-whitespace character.
fn require_non_empty(cs: Changeset(T), field: Text, value: Text) : Changeset(T)
  check(cs, field, not value.trim.empty?, "can't be blank")
end

## Requires `value.char_count` to fall within `[min, max]`.
fn require_length(cs: Changeset(T), field: Text, value: Text, min: Int, max: Int) : Changeset(T)
  n = value.char_count
  if n < min
    add_error(cs, field, "must be at least #{min} characters")
  else if n > max
    add_error(cs, field, "must be at most #{max} characters")
  else
    cs
  end
end

## Requires `value > 0`.
fn require_positive_int(cs: Changeset(T), field: Text, value: Int) : Changeset(T)
  examples
    require_positive_int(new(0), "amount", 1).valid?
    not require_positive_int(new(0), "amount", 0).valid?
    not require_positive_int(new(0), "amount", -1).valid?
  end

  check(cs, field, value > 0, "must be greater than 0")
end

## Requires `value >= 0`.
fn require_non_negative_int(cs: Changeset(T), field: Text, value: Int) : Changeset(T)
  check(cs, field, value >= 0, "must be 0 or greater")
end

fn valid_domain_label?(label: Text) : Bool
  return false if label.empty? or label.byte_count > 63
  return false if label.starts_with?("-") or label.ends_with?("-")
  label.chars.all?(fn(c) c.ascii_letter? or c.ascii_digit? or c == '-' end)
end

fn plausible_email?(raw: Text) : Bool
  s = raw.trim
  return false if s.empty? or s.byte_count > 254
  return false if s.chars.any?(fn(c) c.code <= 32 or c.code == 127 end)
  parts = s.split("@")
  return false if parts.size != 2
  local = parts.get(0) or ""
  domain = parts.get(1) or ""
  return false if local.empty? or local.byte_count > 64
  return false if local.starts_with?(".") or local.ends_with?(".") or local.contains?("..")
  labels = domain.split(".")
  return false if labels.size < 2
  tld = labels.last or ""
  return false if tld.byte_count < 2
  labels.all?(valid_domain_label?)
end

## Requires `value` to be a well-formed email address (`local@domain.tld`).
fn require_email(cs: Changeset(T), field: Text, value: Text) : Changeset(T)
  examples
    require_email(new(""), "email", "ada@example.com").valid?
    not require_email(new(""), "email", "bad-email").valid?
  end

  check(cs, field, plausible_email?(value), "must be a valid email address")
end

## Requires `value` to be an exact member of `allowed`.
fn require_one_of(cs: Changeset(T), field: Text, value: Text, allowed: List(Text)) : Changeset(T)
  examples
    require_one_of(new(""), "cat", "utilities", ["utilities", "housing"]).valid?
    not require_one_of(new(""), "cat", "crypto", ["utilities", "housing"]).valid?
  end

  check(cs, field, allowed.contains?(value), "must be one of: #{allowed.join(", ")}")
end

## Whether `cs` has accumulated zero validation errors.
fn valid?(cs: Changeset(T)) : Bool
  cs.errors.empty?
end

## Projects each field's error list down to its first message (`Record<string, string>`).
fn first_errors(errors: Map(Text, List(Text))) : Map(Text, Text)
  examples
    first_errors({"name": ["first err", "second err"], "empty": []}) == {"name": "first err"}
  end

  var flat = {}
  for (k, msgs) in errors
    if msgs.first is Some(first_msg)
      flat = flat.set(k, first_msg)
    end
  end
  flat
end

## Encodes a full `Map(Text, List(Text))` error bag as `Json`.
fn error_map_json(errors: Map(Text, List(Text))) : Json
  errors.to_json
end

## Encodes `cs.errors` as a full `Map(Text, List(Text))` `Json` object.
fn errors_json(cs: Changeset(T)) : Json
  error_map_json(cs.errors)
end

## Encodes a `Map(Text, List(Text))` error bag as a flat `Record<string, string>` `Json` object
## matching `@inertiajs/react` `useForm().errors`.
fn inertia_error_map_json(errors: Map(Text, List(Text))) : Json
  first_errors(errors).to_json
end

## Encodes `cs.errors` as a flat `Record<string, string>` `Json` object matching
## `@inertiajs/react` `useForm().errors`.
fn inertia_errors_json(cs: Changeset(T)) : Json
  inertia_error_map_json(cs.errors)
end

## Returns `Ok(cs.data)` when `cs` is valid, or `Error(cs.errors)` when any check failed.
fn finish(cs: Changeset(T)) : Result(T, Map(Text, List(Text)))
  promise "finish returns Ok iff valid? is true"
    (result is Ok(_)) == valid?(cs)
  end

  if not cs.errors.has?("__impossible_sentinel_field__")
    Ok(cs.data)
  else
    Error(cs.errors)
  end
end
