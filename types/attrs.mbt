// Formatting attribute values are kept as JSON text, exactly as Yjs writes
// them (`ContentFormat.value` is `JSON.stringify`-ed on the wire). These
// functions compare them the way YText does.

///|
fn is_container(j : Json) -> Bool {
  match j {
    Array(_) | Object(_) => true
    _ => false
  }
}

///|
/// JavaScript `===` on two JSON values that are not containers.
fn primitive_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) | (True, True) | (False, False) => true
    (Number(x, ..), Number(y, ..)) => x == y
    (String(x), String(y)) => x == y
    _ => false
  }
}

///|
/// `equalAttrs` of YText: primitives compare by value; two objects (or two
/// arrays) are equal when they are equal one level deep, which means their
/// members are equal primitives — nested objects and arrays are never `===`.
fn attr_equal(a : String, b : String) -> Bool {
  let ja = @json.parse(a) catch { _ => return a == b }
  let jb = @json.parse(b) catch { _ => return a == b }
  match (ja, jb) {
    (Object(x), Object(y)) => {
      if x.length() != y.length() {
        return false
      }
      for k, v in x {
        match y.get(k) {
          Some(w) =>
            if is_container(v) || !primitive_equal(v, w) {
              return false
            }
          None => return false
        }
      }
      true
    }
    (Array(x), Array(y)) => {
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        if is_container(x[i]) || !primitive_equal(x[i], y[i]) {
          return false
        }
      }
      true
    }
    _ =>
      if is_container(ja) || is_container(jb) {
        false
      } else {
        primitive_equal(ja, jb)
      }
  }
}

///|
/// `equalAttrs(a, b)` where `a` may be `undefined` (a missing map entry).
fn attr_equal_opt(a : String?, b : String) -> Bool {
  match a {
    Some(x) => attr_equal(x, b)
    None => false
  }
}

///|
/// Public attribute lists as the ordered JSON-text map the position code
/// uses. A later duplicate key overwrites the value and keeps the position of
/// the first one, like assigning to a JavaScript object. (JavaScript lists
/// integer-like keys first, in ascending order; that is not modelled.)
fn attrs_to_map(attrs : Array[(String, @lib0.Any)]) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  for a in attrs {
    if a.1 is Undefined {
      abort(
        "attribute \"\{a.0}\" is undefined; use Null to remove an attribute",
      )
    }
    m[a.0] = a.1.to_json_string()
  }
  m
}
