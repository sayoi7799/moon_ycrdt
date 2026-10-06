///|
/// Lowercase hexadecimal representation of `b`.
pub fn to_hex(b : BytesView) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for byte in b {
    let v = byte.to_int()
    sb.write_char(digits.get_char(v >> 4).unwrap())
    sb.write_char(digits.get_char(v & 0xF).unwrap())
  }
  sb.to_string()
}

///|
/// Parses a hexadecimal string (upper or lower case, even length).
pub fn from_hex(s : String) -> Bytes raise DecodeError {
  fn nibble(c : Char) -> Int raise DecodeError {
    match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='f' => c.to_int() - 'a'.to_int() + 10
      'A'..='F' => c.to_int() - 'A'.to_int() + 10
      _ => raise Malformed("invalid hex digit '\{c}'")
    }
  }

  let chars = s.to_array()
  guard chars.length() % 2 == 0 else { raise Malformed("odd hex length") }
  let out = FixedArray::make(chars.length() / 2, b'\x00')
  for i in 0..<out.length() {
    out[i] = ((nibble(chars[2 * i]) << 4) | nibble(chars[2 * i + 1])).to_byte()
  }
  Bytes::from_array(out[:])
}
