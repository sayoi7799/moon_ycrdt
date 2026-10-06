// Binary decoder compatible with lib0/decoding.js.

///|
pub(all) suberror DecodeError {
  UnexpectedEnd
  IntegerOutOfRange
  InvalidUtf8
  UnknownAnyTag(Int)
  TrailingBytes
  /// Raised by higher layers for structurally invalid input.
  Malformed(String)
} derive(Eq, Debug)

///|
pub struct Decoder {
  priv data : Bytes
  mut pos : Int
}

///|
pub fn Decoder::new(data : Bytes) -> Decoder {
  { data, pos: 0, }
}

///|
pub fn Decoder::has_content(self : Decoder) -> Bool {
  self.pos < self.data.length()
}

///|
pub fn Decoder::remaining(self : Decoder) -> Int {
  self.data.length() - self.pos
}

///|
pub fn Decoder::read_u8(self : Decoder) -> Int raise DecodeError {
  guard self.pos < self.data.length() else { raise UnexpectedEnd }
  let b = self.data[self.pos].to_int()
  self.pos += 1
  b
}

///|
pub fn Decoder::read_raw_bytes(
  self : Decoder,
  len : Int,
) -> Bytes raise DecodeError {
  guard len >= 0 && self.pos + len <= self.data.length() else {
    raise UnexpectedEnd
  }
  let b = self.data[self.pos:self.pos + len].to_owned()
  self.pos += len
  b
}

///|
/// 2^53 - 1: lib0 rejects anything above `Number.MAX_SAFE_INTEGER`.
const MAX_SAFE_INTEGER : UInt64 = 9007199254740991UL

///|
pub fn Decoder::read_var_uint64(self : Decoder) -> UInt64 raise DecodeError {
  let mut num = 0UL
  let mut shift = 0
  while true {
    let r = self.read_u8()
    if shift > 56 {
      raise IntegerOutOfRange
    }
    num = num | ((r & 0x7F).to_uint64() << shift)
    shift += 7
    if r < 0x80 {
      break
    }
    if num > MAX_SAFE_INTEGER {
      raise IntegerOutOfRange
    }
  }
  num
}

///|
/// `read_var_uint64` restricted to the non-negative `Int` range.
pub fn Decoder::read_var_uint(self : Decoder) -> Int raise DecodeError {
  let n = self.read_var_uint64()
  guard n <= 0x7FFFFFFFUL else { raise IntegerOutOfRange }
  n.to_int()
}

///|
/// Client ids are 32-bit unsigned integers.
pub fn Decoder::read_var_uint32(self : Decoder) -> UInt raise DecodeError {
  let n = self.read_var_uint64()
  guard n <= 0xFFFFFFFFUL else { raise IntegerOutOfRange }
  n.to_uint()
}

///|
/// Returns `(negative, magnitude)`; keeps the sign of `-0`.
fn Decoder::read_var_int_parts(
  self : Decoder,
) -> (Bool, UInt64) raise DecodeError {
  let r = self.read_u8()
  let negative = (r & 0x40) != 0
  let mut num = (r & 0x3F).to_uint64()
  if (r & 0x80) == 0 {
    return (negative, num)
  }
  let mut shift = 6
  while true {
    let r = self.read_u8()
    if shift > 55 {
      raise IntegerOutOfRange
    }
    num = num | ((r & 0x7F).to_uint64() << shift)
    shift += 7
    if r < 0x80 {
      break
    }
    if num > MAX_SAFE_INTEGER {
      raise IntegerOutOfRange
    }
  }
  (negative, num)
}

///|
pub fn Decoder::read_var_int(self : Decoder) -> Int64 raise DecodeError {
  let (negative, abs) = self.read_var_int_parts()
  let n = abs.reinterpret_as_int64()
  if negative {
    -n
  } else {
    n
  }
}

///|
pub fn Decoder::read_var_string(self : Decoder) -> String raise DecodeError {
  let len = self.read_var_uint()
  guard self.pos + len <= self.data.length() else { raise UnexpectedEnd }
  let view = self.data[self.pos:self.pos + len]
  self.pos += len
  @utf8.decode(view) catch {
    _ => raise InvalidUtf8
  }
}

///|
pub fn Decoder::read_var_bytes(self : Decoder) -> Bytes raise DecodeError {
  let len = self.read_var_uint()
  self.read_raw_bytes(len)
}

///|
pub fn Decoder::read_float32(self : Decoder) -> Float raise DecodeError {
  let mut bits = 0U
  for _ in 0..<4 {
    bits = (bits << 8) | self.read_u8().reinterpret_as_uint()
  }
  Float::reinterpret_from_uint(bits)
}

///|
fn Decoder::read_uint64_be(self : Decoder) -> UInt64 raise DecodeError {
  let mut bits = 0UL
  for _ in 0..<8 {
    bits = (bits << 8) | self.read_u8().to_uint64()
  }
  bits
}

///|
pub fn Decoder::read_float64(self : Decoder) -> Double raise DecodeError {
  self.read_uint64_be().reinterpret_as_double()
}

///|
pub fn Decoder::read_bigint64(self : Decoder) -> Int64 raise DecodeError {
  self.read_uint64_be().reinterpret_as_int64()
}

///|
pub extend DecodeError with Eq::{not_equal, equal}

///|
pub extend DecodeError with @debug.Debug::{to_repr}

///|
pub impl Show for DecodeError with fn output(self, logger) {
  let msg = match self {
    UnexpectedEnd => "unexpected end of input"
    IntegerOutOfRange => "integer out of range"
    InvalidUtf8 => "invalid UTF-8 string"
    UnknownAnyTag(t) => "unknown Any tag \{t}"
    TrailingBytes => "trailing bytes after value"
    Malformed(m) => "malformed input: \{m}"
  }
  logger.write_string(msg)
}

///|
pub extend DecodeError with Show::{to_string, output}
