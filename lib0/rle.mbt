// The run-length encoders that the update format v2 is built from
// (lib0/encoding.js and lib0/decoding.js: `RleEncoder`, `UintOptRleEncoder`,
// `IntDiffOptRleEncoder`, `StringEncoder` and their decoders). Each one turns
// a sequence of numbers (or strings) into a short byte string; the format v2
// keeps one such stream per kind of field.

// ---------------------------------------------------------------------------
// Rle: a byte value followed, when it repeats, by how many more times

///|
/// Run-length encoding of byte values (`RleEncoder` with `writeUint8`): the
/// value is written when a run starts and the number of repeats (minus one)
/// when it ends. The last run gets no count: the decoder reads that value
/// forever.
pub struct RleEncoder {
  priv buf : Encoder
  priv mut value : Int32
  priv mut count : Int32
}

///|
pub fn RleEncoder::new() -> RleEncoder {
  { buf: Encoder::new(), value: -1, count: 0, }
}

///|
pub fn RleEncoder::write(self : RleEncoder, v : Int32) -> Unit {
  if self.value == v {
    self.count += 1
  } else {
    if self.count > 0 {
      self.buf.write_var_uint(self.count - 1)
    }
    self.count = 1
    self.buf.write_u8(v)
    self.value = v
  }
}

///|
pub fn RleEncoder::to_bytes(self : RleEncoder) -> Bytes {
  self.buf.to_bytes()
}

///|
pub struct RleDecoder {
  priv d : Decoder
  priv mut value : Int32
  priv mut count : Int32
}

///|
pub fn RleDecoder::new(data : Bytes) -> RleDecoder {
  { d: Decoder::new(data), value: 0, count: 0, }
}

///|
pub fn RleDecoder::read(self : RleDecoder) -> Int32 raise DecodeError {
  if self.count == 0 {
    self.value = self.d.read_u8()
    // no count after the last run: it goes on for ever
    self.count = if self.d.has_content() {
      self.d.read_var_uint() + 1
    } else {
      -1
    }
  }
  self.count -= 1
  self.value
}

// ---------------------------------------------------------------------------
// UintOptRle: unsigned numbers; a run is the value with a "negative" sign and
// the number of repeats

///|
/// Writes a pending run: the value as a signed varint that is negative (also
/// for 0: `-0`) when the run has more than one value, followed by the count
/// minus two. `-0` is why this uses the sign bit directly.
fn flush_uint_run(buf : Encoder, value : UInt32, count : Int32) -> Unit {
  if count > 0 {
    buf.write_var_int_parts(count > 1, value.to_uint64())
    if count > 1 {
      buf.write_var_uint(count - 2)
    }
  }
}

///|
pub struct UintOptRleEncoder {
  priv buf : Encoder
  priv mut value : UInt32
  priv mut count : Int32
}

///|
pub fn UintOptRleEncoder::new() -> UintOptRleEncoder {
  { buf: Encoder::new(), value: 0U, count: 0, }
}

///|
pub fn UintOptRleEncoder::write(self : UintOptRleEncoder, v : UInt32) -> Unit {
  if self.value == v {
    self.count += 1
  } else {
    flush_uint_run(self.buf, self.value, self.count)
    self.count = 1
    self.value = v
  }
}

///|
/// The encoded bytes; the last run is flushed into a copy, so the encoder can
/// be used (and asked again) afterwards.
pub fn UintOptRleEncoder::to_bytes(self : UintOptRleEncoder) -> Bytes {
  let out = Encoder::new()
  out.write_raw_bytes(self.buf.to_bytes())
  flush_uint_run(out, self.value, self.count)
  out.to_bytes()
}

///|
pub struct UintOptRleDecoder {
  priv d : Decoder
  priv mut value : UInt32
  priv mut count : Int32
}

///|
pub fn UintOptRleDecoder::new(data : Bytes) -> UintOptRleDecoder {
  UintOptRleDecoder::from_decoder(Decoder::new(data))
}

///|
/// Reads from the current position of `d` (the string stream starts with a
/// varString that is read first).
pub fn UintOptRleDecoder::from_decoder(d : Decoder) -> UintOptRleDecoder {
  { d, value: 0U, count: 0, }
}

///|
pub fn UintOptRleDecoder::read(
  self : UintOptRleDecoder,
) -> UInt32 raise DecodeError {
  if self.count == 0 {
    let (negative, magnitude) = self.d.read_var_int_parts()
    if magnitude > 0xFFFFFFFFUL {
      raise IntegerOutOfRange
    }
    self.value = magnitude.to_uint()
    self.count = if negative { self.d.read_var_uint() + 2 } else { 1 }
  }
  self.count -= 1
  self.value
}

// ---------------------------------------------------------------------------
// IntDiffOptRle: signed numbers stored as differences to the previous one

///|
/// A run is the difference, doubled, plus one when a count follows (the count
/// minus two).
fn flush_diff_run(buf : Encoder, diff : Int64, count : Int32) -> Unit {
  if count > 0 {
    buf.write_var_int(diff * 2L + (if count == 1 { 0L } else { 1L }))
    if count > 1 {
      buf.write_var_uint(count - 2)
    }
  }
}

///|
pub struct IntDiffOptRleEncoder {
  priv buf : Encoder
  priv mut last : Int64
  priv mut count : Int32
  priv mut diff : Int64
}

///|
pub fn IntDiffOptRleEncoder::new() -> IntDiffOptRleEncoder {
  { buf: Encoder::new(), last: 0L, count: 0, diff: 0L, }
}

///|
pub fn IntDiffOptRleEncoder::write(
  self : IntDiffOptRleEncoder,
  v : Int32,
) -> Unit {
  let v = v.to_int64()
  if self.diff == v - self.last {
    self.last = v
    self.count += 1
  } else {
    flush_diff_run(self.buf, self.diff, self.count)
    self.count = 1
    self.diff = v - self.last
    self.last = v
  }
}

///|
pub fn IntDiffOptRleEncoder::to_bytes(self : IntDiffOptRleEncoder) -> Bytes {
  let out = Encoder::new()
  out.write_raw_bytes(self.buf.to_bytes())
  flush_diff_run(out, self.diff, self.count)
  out.to_bytes()
}

///|
pub struct IntDiffOptRleDecoder {
  priv d : Decoder
  priv mut last : Int64
  priv mut count : Int32
  priv mut diff : Int64
}

///|
pub fn IntDiffOptRleDecoder::new(data : Bytes) -> IntDiffOptRleDecoder {
  { d: Decoder::new(data), last: 0L, count: 0, diff: 0L, }
}

///|
pub fn IntDiffOptRleDecoder::read(
  self : IntDiffOptRleDecoder,
) -> Int32 raise DecodeError {
  if self.count == 0 {
    let v = self.d.read_var_int()
    // the low bit says that a count follows
    self.diff = v >> 1
    self.count = if (v & 1L) != 0L { self.d.read_var_uint() + 2 } else { 1 }
  }
  self.last += self.diff
  self.count -= 1
  if self.last < -2147483648L || self.last > 2147483647L {
    raise IntegerOutOfRange
  }
  self.last.to_int()
}

// ---------------------------------------------------------------------------
// String: all strings joined, followed by their lengths

///|
/// Strings are written as one long varString (UTF-8) and a UintOptRle stream
/// with the length of every string in UTF-16 code units (`StringEncoder`).
pub struct StringEncoder {
  priv text : StringBuilder
  priv lens : UintOptRleEncoder
}

///|
pub fn StringEncoder::new() -> StringEncoder {
  { text: StringBuilder(), lens: UintOptRleEncoder::new(), }
}

///|
pub fn StringEncoder::write(self : StringEncoder, s : String) -> Unit {
  self.text.write_string(s)
  self.lens.write(s.length().reinterpret_as_uint())
}

///|
pub fn StringEncoder::to_bytes(self : StringEncoder) -> Bytes {
  let out = Encoder::new()
  out.write_var_string(self.text.to_string())
  out.write_raw_bytes(self.lens.to_bytes())
  out.to_bytes()
}

///|
/// Whether `i` lies between the two halves of a surrogate pair.
fn splits_pair(text : String, i : Int32) -> Bool {
  i > 0 &&
  i < text.length() &&
  text.code_unit_at(i - 1).to_int() is (0xD800..<=0xDBFF) &&
  text.code_unit_at(i).to_int() is (0xDC00..<=0xDFFF)
}

///|
pub struct StringDecoder {
  priv text : String
  priv lens : UintOptRleDecoder
  priv mut pos : Int32
}

///|
pub fn StringDecoder::new(data : Bytes) -> StringDecoder raise DecodeError {
  let d = Decoder::new(data)
  let text = d.read_var_string()
  { text, lens: UintOptRleDecoder::from_decoder(d), pos: 0, }
}

///|
pub fn StringDecoder::read(self : StringDecoder) -> String raise DecodeError {
  let len = self.lens.read().reinterpret_as_int()
  let end = self.pos + len
  if len < 0 || end > self.text.length() {
    raise Malformed("string length \{len} runs past the end of the string data")
  }
  if splits_pair(self.text, self.pos) || splits_pair(self.text, end) {
    raise Malformed("string length \{len} cuts a surrogate pair in two")
  }
  let s = self.text[self.pos:end].to_owned()
  self.pos = end
  s
}
