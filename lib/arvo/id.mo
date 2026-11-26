## Lexicographically time-ordered 26-character Crockford Base32 ULID generation.
module Arvo.Id
expose ulid

fn crockford_char(idx: Int) : Char
  alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  alphabet.chars.get(idx.floor_mod(32)) or '0'
end

fn encode_time_48(ms: Int) : List(Char)
  clamped = if ms < 0: 0 else: ms
  var v = clamped
  var rev = []
  var i = 0
  while i < 10
    rev = rev.append(crockford_char(v.floor_mod(32)))
    v = v.floor_div(32)
    i += 1
  end
  rev.reverse
end

fn encode_5bytes_base32(bs: Bytes, offset: Int) : List(Char)
  b0 = (bs.get(offset) or 0).to_int
  b1 = (bs.get(offset + 1) or 0).to_int
  b2 = (bs.get(offset + 2) or 0).to_int
  b3 = (bs.get(offset + 3) or 0).to_int
  b4 = (bs.get(offset + 4) or 0).to_int
  n40 = (((b0 * 256 + b1) * 256 + b2) * 256 + b3) * 256 + b4
  var v = n40
  var rev = []
  var i = 0
  while i < 8
    rev = rev.append(crockford_char(v.floor_mod(32)))
    v = v.floor_div(32)
    i += 1
  end
  rev.reverse
end

## Generates a 26-character Crockford Base32 ULID combining `clock.now` (ms) and 80 random bits.
fn ulid(rng: SecureRandom, clock: Clock) : Text
  epoch = Time.parse("1970-01-01T00:00:00Z") or clock.now
  ms = (clock.now - epoch).in_milliseconds
  rand10 = rng.bytes(10)
  t_chars = encode_time_48(ms)
  r_hi = encode_5bytes_base32(rand10, 0)
  r_lo = encode_5bytes_base32(rand10, 5)
  Text.from_chars(t_chars.concat(r_hi).concat(r_lo))
end

test "ulid generates deterministic 26-char Crockford Base32 IDs in chronological order"
  t1 = Time.parse("2026-11-21T10:00:00Z") or stop "t1"
  t2 = Time.parse("2026-11-21T10:00:00.001Z") or stop "t2"
  t3 = Time.parse("2026-11-21T10:05:00Z") or stop "t3"

  id1a = ulid(SecureRandom.seeded(42), Clock.fixed(t1))
  id1b = ulid(SecureRandom.seeded(42), Clock.fixed(t1))
  id2 = ulid(SecureRandom.seeded(42), Clock.fixed(t2))
  id3 = ulid(SecureRandom.seeded(42), Clock.fixed(t3))

  assert id1a == id1b
  assert id1a.byte_count == 26
  assert id2.byte_count == 26
  assert id3.byte_count == 26
  assert id1a < id2
  assert id2 < id3

  alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  for ch in id1a.chars
    assert alphabet.contains?("#{ch}")
  end
end
