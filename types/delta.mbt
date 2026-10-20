// Quill-style deltas for Y.Text (yjs `YText.toDelta` / `applyDelta`).
//
// A delta is a list of operations. `Insert` carries a string or an embed,
// `Retain` skips (and, with attributes, formats) a number of positions, and
// `Delete` removes a number of positions. Attributes are an ordered list: the
// order is the key order of the JavaScript object Yjs would use, and it decides
// the order of the formatting items written to the document. A `Null` value
// removes the attribute.

///|
pub(all) enum DeltaOp {
  /// Text (`Any::String`) or an embedded object, with attributes.
  Insert(@lib0.Any, Array[(String, @lib0.Any)])
  Retain(Int32, Array[(String, @lib0.Any)])
  Delete(Int32)
} derive(Eq, Debug)

///|
pub extend DeltaOp with Eq::{equal, not_equal}

///|
fn attributes_json(attrs : Array[(String, @lib0.Any)]) -> Json {
  let m : Map[String, Json] = Map([])
  for a in attrs {
    m[a.0] = a.1.to_json()
  }
  Json::object(m)
}

///|
/// `{"insert": ..., "attributes": {...}}`, `{"retain": n, ...}` or
/// `{"delete": n}`; `attributes` is left out when empty, as `toDelta` does.
pub impl ToJson for DeltaOp with fn to_json(self) {
  let m : Map[String, Json] = Map([])
  match self {
    Insert(value, attrs) => {
      m["insert"] = value.to_json()
      if attrs.length() > 0 {
        m["attributes"] = attributes_json(attrs)
      }
    }
    Retain(n, attrs) => {
      m["retain"] = Json::number(n.to_double())
      if attrs.length() > 0 {
        m["attributes"] = attributes_json(attrs)
      }
    }
    Delete(n) => m["delete"] = Json::number(n.to_double())
  }
  Json::object(m)
}

///|
pub fn delta_to_json(ops : Array[DeltaOp]) -> Json {
  Json::array(ops.map(op => op.to_json()))
}

///|
fn attributes_from_json(
  j : Json?,
) -> Array[(String, @lib0.Any)] raise @lib0.DecodeError {
  match j {
    None | Some(Null) => []
    Some(Object(m)) => {
      let out = []
      for k, v in m {
        out.push((k, @lib0.Any::from_json(v)))
      }
      out
    }
    Some(_) => raise @lib0.Malformed("delta attributes must be an object")
  }
}

///|
fn count_from_json(j : Json) -> Int32 raise @lib0.DecodeError {
  match j {
    Number(d, ..) if d >= 0.0 && d.floor() == d && d < 2147483648.0 =>
      d.to_int()
    _ => raise @lib0.Malformed("delta length must be a non-negative integer")
  }
}

///|
/// Parses a delta in the JSON form of `delta_to_json` (the Quill format).
pub fn delta_from_json(j : Json) -> Array[DeltaOp] raise @lib0.DecodeError {
  guard j is Array(items) else {
    raise @lib0.Malformed("a delta must be a JSON array")
  }
  let out = []
  for item in items {
    guard item is Object(m) else {
      raise @lib0.Malformed("a delta operation must be a JSON object")
    }
    let attrs = attributes_from_json(m.get("attributes"))
    if m.get("insert") is Some(v) {
      out.push(Insert(@lib0.Any::from_json(v), attrs))
    } else if m.get("retain") is Some(v) {
      out.push(Retain(count_from_json(v), attrs))
    } else if m.get("delete") is Some(v) {
      out.push(Delete(count_from_json(v)))
    } else {
      raise @lib0.Malformed("delta operation without insert, retain or delete")
    }
  }
  out
}

///|
fn json_attrs(
  attrs : Map[String, String],
) -> Array[(String, @lib0.Any)] raise @lib0.DecodeError {
  let out = []
  for k, v in attrs {
    out.push((k, @lib0.any_from_json_string(v)))
  }
  out
}

///|
/// The text as a delta (`YText.toDelta()`): one `Insert` per run of equal
/// formatting, embeds as separate inserts. A nested shared type inside the
/// text shows up as `Insert(Undefined, ...)`.
pub fn Text::to_delta(self : Text) -> Array[DeltaOp] raise @lib0.DecodeError {
  let ops = []
  let attrs : Map[String, String] = Map([])
  let run = StringBuilder()
  fn pack() raise @lib0.DecodeError {
    if !run.is_empty() {
      ops.push(Insert(String(run.to_string()), json_attrs(attrs)))
      run.reset()
    }
  }

  let mut cur = self.ty.start
  while cur is Some(item) {
    if !item.deleted {
      match item.content {
        String(s) => run.write_string(s)
        Embed(json) => {
          pack()
          ops.push(Insert(@lib0.any_from_json_string(json), json_attrs(attrs)))
        }
        Type(_, _) => {
          pack()
          ops.push(Insert(Undefined, json_attrs(attrs)))
        }
        Format(key, value) => {
          pack()
          if value == "null" {
            attrs.remove(key)
          } else {
            attrs[key] = value
          }
        }
        _ => ()
      }
    }
    cur = item.right
  }
  pack()
  ops
}

///|
pub extend DeltaOp with ToJson::{to_json}
