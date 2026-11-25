## Reusable algebraic property helpers composable inside Mo `promise` and `test` blocks.
module Arvo.Props
expose round_trip?,
round_trip_result?,
idempotent?,
involution?,
conserves_sum?,
monotonic_non_decreasing?,
monotonic_strictly_increasing?,
bounded?,
preserves_size?,
commutes?

## True when `decode(encode(x)) == Some(x)`.
fn round_trip?(x: A, encode: fn(A) : B, decode: fn(B) : Option(A)) : Bool where A: Equal
  decode(encode(x)) == Some(x)
end

## True when `decode(encode(x)) == Ok(x)`.
fn round_trip_result?(x: A, encode: fn(A) : B, decode: fn(B) : Result(A, E)) : Bool
  where A: Equal, E: Equal
  case decode(encode(x))
    Ok(decoded): decoded == x
    Error(_): false
  end
end

## True when applying `f` twice equals applying it once (`f(f(x)) == f(x)`).
fn idempotent?(x: A, f: fn(A) : A) : Bool where A: Equal
  once = f(x)
  f(once) == once
end

## True when `f` is its own inverse (`f(f(x)) == x`).
fn involution?(x: A, f: fn(A) : A) : Bool where A: Equal
  f(f(x)) == x
end

## True when total sum across `before` equals total sum across `after` (conservation law).
fn conserves_sum?(before: List(Int), after: List(Int)) : Bool
  examples
    conserves_sum?([100, 50], [75, 75])
    not conserves_sum?([100, 50], [75, 76])
    conserves_sum?([], [])
  end

  promise "matches exact sum equality"
    result == (before.sum == after.sum)
  end

  before.sum == after.sum
end

## True when every adjacent pair `(a, b)` in `xs` satisfies `a <= b`.
fn monotonic_non_decreasing?(xs: List(Int)) : Bool
  examples
    monotonic_non_decreasing?([])
    monotonic_non_decreasing?([5])
    monotonic_non_decreasing?([1, 2, 2, 5])
    not monotonic_non_decreasing?([2, 1])
    not monotonic_non_decreasing?([1, 3, 2])
  end

  promise "empty and singleton lists are always non-decreasing"
    (xs.size <= 1) implies result
  end

  xs.drop(1).zip(xs).all?(fn(pair) pair.1 <= pair.0 end)
end

## True when every adjacent pair `(a, b)` in `xs` satisfies `a < b`.
fn monotonic_strictly_increasing?(xs: List(Int)) : Bool
  examples
    monotonic_strictly_increasing?([])
    monotonic_strictly_increasing?([5])
    monotonic_strictly_increasing?([1, 2, 5])
    not monotonic_strictly_increasing?([1, 2, 2, 5])
    not monotonic_strictly_increasing?([2, 1])
    not monotonic_strictly_increasing?([3, 2])
  end

  promise "strictly increasing implies non-decreasing"
    result implies monotonic_non_decreasing?(xs)
  end

  xs.drop(1).zip(xs).all?(fn(pair) pair.1 < pair.0 end)
end

## True when `x` lies inside the closed interval `[low, high]`.
fn bounded?(x: Int, low: Int, high: Int) : Bool
  examples
    bounded?(0, 0, 10)
    bounded?(10, 0, 10)
    not bounded?(-1, 0, 10)
    not bounded?(11, 0, 10)
  end

  promise "agrees with closed interval bounds"
    result == (x >= low and x <= high)
  end

  x >= low and x <= high
end

## True when `before` and `after` contain the same number of elements.
fn preserves_size?(before: List(A), after: List(B)) : Bool
  before.size == after.size
end

## True when `op(a, b) == op(b, a)`.
fn commutes?(a: A, b: A, op: fn(A, A) : B) : Bool where B: Equal
  op(a, b) == op(b, a)
end

test "algebraic property helpers catch violations across round-trip, idempotence, involution, size, and commutativity"
  assert round_trip?(42, fn(n) "#{n}" end, fn(s) s.to_int end)
  assert not round_trip?(42, fn(n) "#{n + 1}" end, fn(s) s.to_int end)
  assert not round_trip?(42, fn(_) "bad" end, fn(s) s.to_int end)

  parse_int_res = fn(s)
    case s.to_int
      Some(n): Ok(n)
      None: Error("bad int")
    end
  end
  assert round_trip_result?(7, fn(n) "#{n}" end, parse_int_res)
  assert not round_trip_result?(7, fn(n) "#{n + 1}" end, parse_int_res)
  assert not round_trip_result?(7, fn(_) "nope" end, parse_int_res)

  assert idempotent?(-5, fn(n) if n < 0: 0 else: n end)
  assert not idempotent?(1, fn(n) n + 1 end)

  assert involution?(12, fn(n) -n end)
  assert not involution?(12, fn(n) n + 1 end)

  assert preserves_size?([1, 2, 3], ["a", "b", "c"])
  assert not preserves_size?([1, 2], ["a"])

  assert commutes?(3, 8, fn(a, b) a + b end)
  assert not commutes?(3, 8, fn(a, b) a - b end)
end
