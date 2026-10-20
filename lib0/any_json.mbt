// Conversion between `Any` and JSON. Yjs stores formatting attribute values
// and embeds as JSON text (`JSON.stringify` on write, `JSON.parse` on read);
// these functions are the MoonBit side of that.

///|
/// `Any` as `Json`. `Undefined`, bigint and byte arrays have no JSON form,
/// just like in `JSON.stringify` (which drops or rejects them), so they abort.
pub impl ToJson for Any with fn to_json(self) {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Number(d) => Json::number(d)
    String(s) => Json::string(s)
    Array(items) => Json::array(items.map(item => item.to_json()))
    Object(entries) => {
      let m : Map[String, Json] = Map([])
      for e in entries {
        m[e.0] = e.1.to_json()
      }
      Json::object(m)
    }
    Undefined | BigInt(_) | Bytes(_) =>
      abort("Any::to_json: undefined, bigint and byte arrays are not JSON")
  }
}

///|
pub fn Any::from_json(j : Json) -> Any {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(d, ..) => Number(d)
    String(s) => String(s)
    Array(items) => Array(items.map(item => Any::from_json(item)))
    Object(m) => {
      let entries = []
      for k, v in m {
        entries.push((k, Any::from_json(v)))
      }
      Object(entries)
    }
  }
}

///|
/// The JSON text Yjs would write for this value (`JSON.stringify`).
pub fn Any::to_json_string(self : Any) -> String {
  self.to_json().stringify()
}

///|
/// Parses JSON text written by Yjs (`JSON.parse`).
pub fn any_from_json_string(s : String) -> Any raise DecodeError {
  Any::from_json(@json.parse(s)) catch {
    e => raise Malformed("invalid JSON: \{e}")
  }
}

///|
pub extend Any with ToJson::{to_json}
