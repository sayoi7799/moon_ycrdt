// Item contents, see yjs/src/structs/Content*.js.
//
// Content kinds this library does not interpret (Embed, Format, XML types,
// sub-documents) keep their raw wire data so they can be written back
// unchanged — dropping them would break synchronisation with other clients.

///|
pub const TYPE_REF_ARRAY : Int = 0

///|
pub const TYPE_REF_MAP : Int = 1

///|
pub const TYPE_REF_TEXT : Int = 2

///|
pub const TYPE_REF_XML_ELEMENT : Int = 3

///|
pub const TYPE_REF_XML_FRAGMENT : Int = 4

///|
pub const TYPE_REF_XML_HOOK : Int = 5

///|
pub const TYPE_REF_XML_TEXT : Int = 6

///|
pub(all) enum Content {
  /// Placeholder for deleted (garbage-collected) content of the given length.
  Deleted(Int)
  /// Legacy JSON content; each element is a JSON string ("undefined" allowed).
  JSON(Array[String])
  Binary(Bytes)
  String(String)
  /// Embedded object of Y.Text, kept as its JSON string.
  Embed(String)
  /// Formatting attribute of Y.Text: key and JSON-encoded value.
  Format(String, String)
  /// Nested shared type: type ref and, for XmlElement / XmlHook, its name.
  Type(Int, String?)
  Any(Array[@lib0.Any])
  /// Sub-document: guid and options.
  Doc(String, @lib0.Any)
} derive(Eq, Debug)

///|
pub extend Content with Eq::{equal, not_equal}

///|
/// The content ref stored in the low 5 bits of an item's info byte.
pub fn Content::ref_number(self : Content) -> Int {
  match self {
    Deleted(_) => 1
    JSON(_) => 2
    Binary(_) => 3
    String(_) => 4
    Embed(_) => 5
    Format(_, _) => 6
    Type(_, _) => 7
    Any(_) => 8
    Doc(_, _) => 9
  }
}

///|
/// Number of clock ticks the content occupies (UTF-16 code units for strings).
pub fn Content::length(self : Content) -> Int {
  match self {
    Deleted(n) => n
    JSON(a) => a.length()
    String(s) => s.length()
    Any(a) => a.length()
    Binary(_) | Embed(_) | Format(_, _) | Type(_, _) | Doc(_, _) => 1
  }
}

///|
/// Whether the content counts towards the length / index of its parent type.
pub fn Content::is_countable(self : Content) -> Bool {
  match self {
    Deleted(_) | Format(_, _) => false
    _ => true
  }
}

///|
/// Splits the content at `offset` (0 < offset < length), like `Content.splice`.
/// Splitting a string inside a surrogate pair replaces both halves with
/// U+FFFD, exactly like Yjs does.
pub fn Content::split(self : Content, offset : Int) -> (Content, Content) {
  match self {
    Deleted(n) => (Deleted(offset), Deleted(n - offset))
    JSON(a) => (JSON(a[:offset].to_owned()), JSON(a[offset:].to_owned()))
    Any(a) => (Any(a[:offset].to_owned()), Any(a[offset:].to_owned()))
    String(s) => {
      let left = s.unsafe_substring(start=0, end=offset)
      let right = s.unsafe_substring(start=offset, end=s.length())
      let last = s.code_units()[offset - 1]
      if last.is_leading_surrogate() {
        (
          String(left.unsafe_substring(start=0, end=offset - 1) + "\u{FFFD}"),
          String(
            "\u{FFFD}" + right.unsafe_substring(start=1, end=right.length()),
          ),
        )
      } else {
        (String(left), String(right))
      }
    }
    _ => abort("content of length 1 cannot be split")
  }
}

///|
/// Writes the content, skipping the first `offset` clock ticks (used when an
/// update starts in the middle of an item). Unlike `split`, this mirrors
/// `Content.write(encoder, offset)` which slices strings without repairing
/// surrogate pairs.
pub fn Content::write(self : Content, e : @lib0.Encoder, offset : Int) -> Unit {
  match self {
    Deleted(n) => e.write_var_uint(n - offset)
    JSON(a) => {
      e.write_var_uint(a.length() - offset)
      for i in offset..<a.length() {
        e.write_var_string(a[i])
      }
    }
    Binary(b) => e.write_var_bytes(b)
    String(s) =>
      e.write_var_string(
        if offset == 0 {
          s
        } else {
          s.unsafe_substring(start=offset, end=s.length())
        },
      )
    Embed(json) => e.write_var_string(json)
    Format(key, json) => {
      e.write_var_string(key)
      e.write_var_string(json)
    }
    Type(type_ref, name) => {
      e.write_var_uint(type_ref)
      if name is Some(n) {
        e.write_var_string(n)
      }
    }
    Any(a) => {
      e.write_var_uint(a.length() - offset)
      for i in offset..<a.length() {
        e.write_any(a[i])
      }
    }
    Doc(guid, opts) => {
      e.write_var_string(guid)
      e.write_any(opts)
    }
  }
}

///|
pub fn read_content(
  d : @lib0.Decoder,
  ref_number : Int,
) -> Content raise @lib0.DecodeError {
  match ref_number {
    1 => Deleted(d.read_var_uint())
    2 => {
      let len = d.read_var_uint()
      let items = []
      for _ in 0..<len {
        items.push(d.read_var_string())
      }
      JSON(items)
    }
    3 => Binary(d.read_var_bytes())
    4 => String(d.read_var_string())
    5 => Embed(d.read_var_string())
    6 => {
      let key = d.read_var_string()
      Format(key, d.read_var_string())
    }
    7 => {
      let type_ref = d.read_var_uint()
      let name = if type_ref == TYPE_REF_XML_ELEMENT ||
        type_ref == TYPE_REF_XML_HOOK {
        Some(d.read_var_string())
      } else {
        None
      }
      guard type_ref <= TYPE_REF_XML_TEXT else {
        raise @lib0.Malformed("unknown type ref \{type_ref}")
      }
      Type(type_ref, name)
    }
    8 => {
      let len = d.read_var_uint()
      let items = []
      for _ in 0..<len {
        items.push(d.read_any())
      }
      Any(items)
    }
    9 => {
      let guid = d.read_var_string()
      Doc(guid, d.read_any())
    }
    _ => raise @lib0.Malformed("unknown content ref \{ref_number}")
  }
}
