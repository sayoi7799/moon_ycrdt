// Y.Map with `Any` values (yjs/src/types/YMap.js).

///|
pub struct YMap {
  doc : @doc.Doc
  ty : @doc.YType
}

///|
/// The root Y.Map called `name` (`doc.getMap(name)`).
pub fn YMap::new(doc : @doc.Doc, name : String) -> YMap {
  { doc, ty: doc.get_root(name, @update.TYPE_REF_MAP), }
}

///|
/// Sets `key` to `value`. Byte arrays are stored as binary content, all other
/// values as `Any`, like `typeMapSet` in Yjs.
pub fn YMap::set(self : YMap, key : String, value : @lib0.Any) -> Unit {
  let content : @update.Content = match value {
    Bytes(b) => Binary(b)
    v => Any([v])
  }
  // the previous entry (even if deleted) becomes the left origin
  let left = self.ty.map.get(key)
  self.doc.insert(self.ty, left, None, Some(key), content) |> ignore
  self.doc.commit()
}

///|
fn value_of(item : @doc.Item) -> @lib0.Any? {
  match item.content {
    Any(values) => values.last()
    Binary(b) => Some(Bytes(b))
    _ => None
  }
}

///|
/// The current value of `key`. Entries holding content this API does not
/// model (nested types, sub-documents) are reported as absent.
pub fn YMap::get(self : YMap, key : String) -> @lib0.Any? {
  match self.ty.map.get(key) {
    Some(item) if !item.deleted => value_of(item)
    _ => None
  }
}

///|
pub fn YMap::has(self : YMap, key : String) -> Bool {
  self.ty.map.get(key) is Some(item) && !item.deleted
}

///|
pub fn YMap::delete(self : YMap, key : String) -> Unit {
  if self.ty.map.get(key) is Some(item) && !item.deleted {
    self.doc.delete_item(item)
    self.doc.commit()
  }
}

///|
/// Lexicographic UTF-16 code unit order, like JavaScript's default sort.
fn compare_utf16(a : String, b : String) -> Int {
  let ua = a.code_units()
  let ub = b.code_units()
  let n = if ua.length() < ub.length() { ua.length() } else { ub.length() }
  for i in 0..<n {
    let c = ua[i].compare(ub[i])
    if c != 0 {
      return c
    }
  }
  ua.length().compare(ub.length())
}

///|
/// Keys with a current value, sorted by UTF-16 code units (like JS).
pub fn YMap::keys(self : YMap) -> Array[String] {
  let keys = []
  for key, item in self.ty.map {
    if !item.deleted {
      keys.push(key)
    }
  }
  keys.sort_by(compare_utf16)
  keys
}

///|
/// Current entries sorted by key (only `Any` / binary values).
pub fn YMap::entries(self : YMap) -> Array[(String, @lib0.Any)] {
  let out = []
  for key in self.keys() {
    if self.get(key) is Some(v) {
      out.push((key, v))
    }
  }
  out
}

///|
pub fn YMap::size(self : YMap) -> Int {
  self.keys().length()
}
