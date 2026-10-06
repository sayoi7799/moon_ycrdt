// The lib0 `Any` value model: everything that `encoding.writeAny` /
// `decoding.readAny` can round-trip.
//
// JavaScript has a single number type, so all numbers (integers, float32 and
// float64 on the wire) are represented as `Number(Double)`. The wire tag is
// chosen from the value exactly like lib0 does, which makes re-encoding a
// decoded value byte-for-byte identical.

///|
pub(all) enum Any {
  Undefined
  Null
  Bool(Bool)
  Number(Double)
  BigInt(Int64)
  String(String)
  Array(Array[Any])
  /// Object entries in wire order (JS objects preserve insertion order).
  Object(Array[(String, Any)])
  Bytes(Bytes)
} derive(Eq, Debug)

///|
/// Convenience constructor for integer numbers.
pub fn Any::int(n : Int) -> Any {
  Number(n.to_double())
}

// Wire tags, see lib0/encoding.js `writeAny`.

///|
const TAG_UNDEFINED : Int = 127

///|
const TAG_NULL : Int = 126

///|
const TAG_INTEGER : Int = 125

///|
const TAG_FLOAT32 : Int = 124

///|
const TAG_FLOAT64 : Int = 123

///|
const TAG_BIGINT : Int = 122

///|
const TAG_FALSE : Int = 121

///|
const TAG_TRUE : Int = 120

///|
const TAG_STRING : Int = 119

///|
const TAG_OBJECT : Int = 118

///|
const TAG_ARRAY : Int = 117

///|
const TAG_BYTES : Int = 116

///|
/// 2^31 - 1, the largest magnitude lib0 writes as a varInt inside `Any`.
const BITS31 : Double = 2147483647.0

///|
fn is_negative_or_neg_zero(d : Double) -> Bool {
  if d != 0.0 {
    d < 0.0
  } else {
    1.0 / d < 0.0
  }
}

///|
/// `Math.fround(d) === d` in JavaScript.
fn is_float32(d : Double) -> Bool {
  Float::from_double(d).to_double() == d
}

///|
fn is_js_integer(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf() && d.floor() == d
}

///|
pub fn Encoder::write_any(self : Encoder, value : Any) -> Unit {
  match value {
    Undefined => self.write_u8(TAG_UNDEFINED)
    Null => self.write_u8(TAG_NULL)
    Bool(true) => self.write_u8(TAG_TRUE)
    Bool(false) => self.write_u8(TAG_FALSE)
    Number(d) =>
      if is_js_integer(d) && d.abs() <= BITS31 {
        self.write_u8(TAG_INTEGER)
        self.write_var_int_parts(
          is_negative_or_neg_zero(d),
          d.abs().to_int64().reinterpret_as_uint64(),
        )
      } else if is_float32(d) {
        self.write_u8(TAG_FLOAT32)
        self.write_float32(Float::from_double(d))
      } else {
        self.write_u8(TAG_FLOAT64)
        self.write_float64(d)
      }
    BigInt(n) => {
      self.write_u8(TAG_BIGINT)
      self.write_bigint64(n)
    }
    String(s) => {
      self.write_u8(TAG_STRING)
      self.write_var_string(s)
    }
    Object(entries) => {
      self.write_u8(TAG_OBJECT)
      self.write_var_uint(entries.length())
      for entry in entries {
        let (k, v) = entry
        self.write_var_string(k)
        self.write_any(v)
      }
    }
    Array(items) => {
      self.write_u8(TAG_ARRAY)
      self.write_var_uint(items.length())
      for item in items {
        self.write_any(item)
      }
    }
    Bytes(b) => {
      self.write_u8(TAG_BYTES)
      self.write_var_bytes(b)
    }
  }
}

///|
pub fn Decoder::read_any(self : Decoder) -> Any raise DecodeError {
  let tag = self.read_u8()
  match tag {
    TAG_UNDEFINED => Undefined
    TAG_NULL => Null
    TAG_INTEGER => {
      let (negative, abs) = self.read_var_int_parts()
      let d = abs.to_double()
      Number(if negative { -d } else { d })
    }
    TAG_FLOAT32 => Number(self.read_float32().to_double())
    TAG_FLOAT64 => Number(self.read_float64())
    TAG_BIGINT => BigInt(self.read_bigint64())
    TAG_FALSE => Bool(false)
    TAG_TRUE => Bool(true)
    TAG_STRING => String(self.read_var_string())
    TAG_OBJECT => {
      let len = self.read_var_uint()
      let entries = []
      for _ in 0..<len {
        let k = self.read_var_string()
        entries.push((k, self.read_any()))
      }
      Object(entries)
    }
    TAG_ARRAY => {
      let len = self.read_var_uint()
      let items = []
      for _ in 0..<len {
        items.push(self.read_any())
      }
      Array(items)
    }
    TAG_BYTES => Bytes(self.read_var_bytes())
    _ => raise UnknownAnyTag(tag)
  }
}

///|
/// Encodes a single `Any` value into a fresh byte array.
pub fn encode_any(value : Any) -> Bytes {
  let e = Encoder::new()
  e.write_any(value)
  e.to_bytes()
}

///|
/// Decodes a single `Any` value; trailing bytes are an error.
pub fn decode_any(data : Bytes) -> Any raise DecodeError {
  let d = Decoder::new(data)
  let v = d.read_any()
  if d.has_content() {
    raise TrailingBytes
  }
  v
}

///|
pub extend Any with Eq::{not_equal, equal}

///|
pub extend Any with @debug.Debug::{to_repr}

///|
/// JSON-like rendering; `undefined`, bigints (`12n`) and byte arrays
/// (`Uint8Array[1,2]`) use JavaScript notation.
pub impl Show for Any with fn output(self, logger) {
  match self {
    Undefined => logger.write_string("undefined")
    Null => logger.write_string("null")
    Bool(b) => logger.write_string(b.to_string())
    Number(d) =>
      if is_js_integer(d) && d.abs() < 9007199254740992.0 {
        logger.write_string(d.to_int64().to_string())
      } else {
        logger.write_string(d.to_string())
      }
    BigInt(n) => logger.write_string("\{n}n")
    String(s) => logger.write_string(s.escape())
    Array(items) => {
      logger.write_string("[")
      for i, item in items {
        if i > 0 {
          logger.write_string(",")
        }
        item.output(logger)
      }
      logger.write_string("]")
    }
    Object(entries) => {
      logger.write_string("{")
      for i, entry in entries {
        if i > 0 {
          logger.write_string(",")
        }
        logger.write_string(entry.0.escape())
        logger.write_string(":")
        entry.1.output(logger)
      }
      logger.write_string("}")
    }
    Bytes(b) => {
      logger.write_string("Uint8Array[")
      for i, byte in b {
        if i > 0 {
          logger.write_string(",")
        }
        logger.write_string(byte.to_int().to_string())
      }
      logger.write_string("]")
    }
  }
}

///|
pub extend Any with Show::{to_string, output}
