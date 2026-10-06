// Binary encoder compatible with lib0/encoding.js.

///|
pub struct Encoder {
  priv buf : @buffer.Buffer
}

///|
pub fn Encoder::new() -> Encoder {
  { buf: @buffer.Buffer(), }
}

///|
pub fn Encoder::to_bytes(self : Encoder) -> Bytes {
  self.buf.to_bytes()
}

///|
pub fn Encoder::length(self : Encoder) -> Int {
  self.buf.length()
}

///|
/// Writes one byte; only the low 8 bits of `b` are used.
pub fn Encoder::write_u8(self : Encoder, b : Int) -> Unit {
  self.buf.write_byte((b & 0xFF).to_byte())
}

///|
/// Writes raw bytes without a length prefix.
pub fn Encoder::write_raw_bytes(self : Encoder, b : BytesView) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// Unsigned LEB128: 7 bits per byte, least significant group first, the high
/// bit marks that more bytes follow.
pub fn Encoder::write_var_uint64(self : Encoder, n : UInt64) -> Unit {
  let mut n = n
  while n > 0x7FUL {
    self.write_u8((n & 0x7FUL).to_int() | 0x80)
    n = n >> 7
  }
  self.write_u8(n.to_int())
}

///|
/// `write_var_uint64` for non-negative `Int`s (lengths, clocks).
pub fn Encoder::write_var_uint(self : Encoder, n : Int) -> Unit {
  guard n >= 0 else { abort("write_var_uint: negative value \{n}") }
  self.write_var_uint64(n.to_uint64())
}

///|
/// Client ids are 32-bit unsigned integers.
pub fn Encoder::write_var_uint32(self : Encoder, n : UInt) -> Unit {
  self.write_var_uint64(n.to_uint64())
}

///|
/// lib0 varInt: sign-magnitude, not zigzag. The first byte holds the
/// continuation bit (0x80), the sign bit (0x40) and the low 6 bits of the
/// magnitude; further bytes hold 7 bits each.
fn Encoder::write_var_int_parts(
  self : Encoder,
  negative : Bool,
  abs : UInt64,
) -> Unit {
  let first = (abs & 0x3FUL).to_int() |
    (if negative { 0x40 } else { 0 }) |
    (if abs > 0x3FUL { 0x80 } else { 0 })
  self.write_u8(first)
  let mut n = abs >> 6
  while n > 0UL {
    self.write_u8((n & 0x7FUL).to_int() | (if n > 0x7FUL { 0x80 } else { 0 }))
    n = n >> 7
  }
}

///|
pub fn Encoder::write_var_int(self : Encoder, n : Int64) -> Unit {
  let negative = n < 0L
  let abs = if negative {
    (0L - n).reinterpret_as_uint64()
  } else {
    n.reinterpret_as_uint64()
  }
  self.write_var_int_parts(negative, abs)
}

///|
/// UTF-16 -> UTF-8. Unpaired surrogates become U+FFFD, like `TextEncoder`.
pub fn utf8_encode(s : String) -> Bytes {
  let units = s.code_units()
  let buf = @buffer.Buffer(size_hint=units.length())
  let len = units.length()
  let mut i = 0
  while i < len {
    let u = units[i].to_int()
    let mut cp = u
    if u >= 0xD800 && u <= 0xDBFF {
      if i + 1 < len &&
        units[i + 1].to_int() >= 0xDC00 &&
        units[i + 1].to_int() <= 0xDFFF {
        cp = 0x10000 + ((u - 0xD800) << 10) + (units[i + 1].to_int() - 0xDC00)
        i += 1
      } else {
        cp = 0xFFFD
      }
    } else if u >= 0xDC00 && u <= 0xDFFF {
      cp = 0xFFFD
    }
    if cp < 0x80 {
      buf.write_byte(cp.to_byte())
    } else if cp < 0x800 {
      buf.write_byte((0xC0 | (cp >> 6)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      buf.write_byte((0xE0 | (cp >> 12)).to_byte())
      buf.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else {
      buf.write_byte((0xF0 | (cp >> 18)).to_byte())
      buf.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      buf.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    }
    i += 1
  }
  buf.to_bytes()
}

///|
/// varUint byte length of the UTF-8 encoding, followed by the UTF-8 bytes.
pub fn Encoder::write_var_string(self : Encoder, s : String) -> Unit {
  let bytes = utf8_encode(s)
  self.write_var_uint(bytes.length())
  self.write_raw_bytes(bytes)
}

///|
/// varUint length followed by the bytes (lib0 `writeVarUint8Array`).
pub fn Encoder::write_var_bytes(self : Encoder, b : BytesView) -> Unit {
  self.write_var_uint(b.length())
  self.write_raw_bytes(b)
}

///|
/// IEEE-754 single precision, big-endian.
pub fn Encoder::write_float32(self : Encoder, f : Float) -> Unit {
  let bits = f.reinterpret_as_uint()
  for shift in [24, 16, 8, 0] {
    self.write_u8(((bits >> shift) & 0xFFU).reinterpret_as_int())
  }
}

///|
/// IEEE-754 double precision, big-endian.
pub fn Encoder::write_float64(self : Encoder, d : Double) -> Unit {
  self.write_uint64_be(d.reinterpret_as_uint64())
}

///|
/// Signed 64-bit integer, big-endian.
pub fn Encoder::write_bigint64(self : Encoder, n : Int64) -> Unit {
  self.write_uint64_be(n.reinterpret_as_uint64())
}

///|
fn Encoder::write_uint64_be(self : Encoder, bits : UInt64) -> Unit {
  for i = 7; i >= 0; i = i - 1 {
    self.write_u8((bits >> (i * 8)).to_int() & 0xFF)
  }
}
