// Y.Array with `Any` values (yjs/src/types/YArray.js, typeList* in
// AbstractType.js).

///|
pub struct YArray {
  doc : @doc.Doc
  ty : @doc.YType
}

///|
/// The root Y.Array called `name` (`doc.getArray(name)`).
pub fn YArray::new(doc : @doc.Doc, name : String) -> YArray {
  { doc, ty: doc.get_root(name, @update.TYPE_REF_ARRAY), }
}

///|
pub fn YArray::length(self : YArray) -> Int32 {
  self.ty.length
}

///|
/// Inserts `values` at `index` (`typeListInsertGenerics`). Like Yjs, runs of
/// plain values are stored in one item and byte arrays get items of their
/// own. (Yjs itself refuses `undefined` and bigint in arrays; they are stored
/// as plain values here and Yjs decodes them fine.)
pub fn YArray::insert(
  self : YArray,
  index : Int32,
  values : Array[@lib0.Any],
) -> Unit {
  guard index >= 0 && index <= self.ty.length else {
    abort("index \{index} out of range (length \{self.ty.length})")
  }
  if values.length() == 0 {
    return
  }
  if index == 0 {
    self.ty.update_marker_changes(0, values.length())
    self.insert_after(None, values)
    return
  }
  // the visible item that ends exactly at `index` (split if needed), found
  // from the nearest search marker
  let mut n : @doc.Item? = self.ty.start
  let mut remaining = index
  if self.ty.find_marker(index) is Some(m) {
    n = Some(m.p)
    remaining -= m.index
    if remaining == 0 {
      // the previous item that is not deleted (`Item.prev`), so that there is
      // something to split or end at
      n = m.p.left
      while n is Some(d) && d.deleted {
        n = d.left
      }
      if n is Some(l) && l.is_countable() && !l.deleted {
        remaining += l.length
      }
    }
  }
  let mut left : @doc.Item? = None
  while n is Some(c) {
    if !c.deleted && c.is_countable() {
      if remaining <= c.length {
        if remaining < c.length {
          self.doc.split(c, remaining) |> ignore
        }
        left = Some(c)
        break
      }
      remaining -= c.length
    }
    n = c.right
  }
  self.ty.update_marker_changes(index, values.length())
  self.insert_after(left, values)
}

///|
/// Inserts `values` right after `reference` (`typeListInsertGenericsAfter`):
/// all new items share the same right neighbour.
fn YArray::insert_after(
  self : YArray,
  reference : @doc.Item?,
  values : Array[@lib0.Any],
) -> Unit {
  let mut left = reference
  let right = match left {
    Some(l) => l.right
    None => self.ty.start
  }
  let pending : Array[@lib0.Any] = []
  let flush = fn() {
    if pending.length() > 0 {
      left = Some(
        self.doc.insert(self.ty, left, right, None, Any(pending.copy())),
      )
      pending.clear()
    }
  }
  for v in values {
    match v {
      Bytes(b) => {
        flush()
        left = Some(self.doc.insert(self.ty, left, right, None, Binary(b)))
      }
      _ => pending.push(v)
    }
  }
  flush()
  self.doc.commit()
}

///|
/// Appends `values` (`typeListPushGenerics`). Unlike `insert` at the end,
/// this goes after the very last item, even a deleted one, like Yjs.
pub fn YArray::push(self : YArray, values : Array[@lib0.Any]) -> Unit {
  if values.length() == 0 {
    return
  }
  // from the marker with the highest index, to the very last item
  let mut last = self.ty.start
  let mut best = 0
  if self.ty.markers_enabled {
    for m in self.ty.markers {
      if m.index > best {
        best = m.index
        last = Some(m.p)
      }
    }
  }
  while last is Some(n) && n.right is Some(r) {
    last = Some(r)
  }
  self.insert_after(last, values)
}

///|
/// Deletes `len` elements starting at `index` (`typeListDelete`).
pub fn YArray::delete(self : YArray, index : Int32, len : Int32) -> Unit {
  if len <= 0 {
    return
  }
  guard index >= 0 && index + len <= self.ty.length else {
    abort("delete range \{index}+\{len} out of range")
  }
  let mut cur = self.ty.start
  let mut skip = index
  if self.ty.find_marker(index) is Some(m) {
    cur = Some(m.p)
    skip -= m.index
  }
  // find the first item to delete, splitting it if the range starts inside
  while cur is Some(n) && skip > 0 {
    if !n.deleted && n.is_countable() {
      if skip < n.length {
        self.doc.split(n, skip) |> ignore
      }
      skip -= n.length
    }
    cur = n.right
  }
  let mut remaining = len
  while remaining > 0 && cur is Some(n) {
    if !n.deleted {
      if remaining < n.length {
        self.doc.split(n, remaining) |> ignore
      }
      self.doc.delete_item(n)
      remaining -= n.length
    }
    cur = n.right
  }
  self.ty.update_marker_changes(index, remaining - len)
  self.doc.commit()
}

///|
/// Values stored by an item; content the `Any` model cannot express (nested
/// shared types, sub-documents) shows up as `Undefined`.
fn item_values(item : @doc.Item) -> Array[@lib0.Any] {
  match item.content {
    Any(values) => values
    Binary(b) => [Bytes(b)]
    JSON(values) => values.map(json_to_any)
    _ => Array::make(item.length, Undefined)
  }
}

///|
/// Legacy ContentJSON elements are JSON strings ("undefined" allowed).
fn json_to_any(s : String) -> @lib0.Any {
  fn convert(j : Json) -> @lib0.Any {
    match j {
      Null => Null
      True => Bool(true)
      False => Bool(false)
      Number(d, ..) => Number(d)
      String(s) => String(s)
      Array(items) => Array(items.map(convert))
      Object(m) => Object(m.iter().map(e => (e.0, convert(e.1))).to_array())
    }
  }

  if s == "undefined" {
    return Undefined
  }
  convert(@json.parse(s)) catch {
    _ => Undefined
  }
}

///|
/// The element at `index`, or None when out of range.
pub fn YArray::get(self : YArray, index : Int32) -> @lib0.Any? {
  if index < 0 {
    return None
  }
  let mut remaining = index
  let mut cur = self.ty.start
  if self.ty.find_marker(index) is Some(m) {
    cur = Some(m.p)
    remaining -= m.index
  }
  while cur is Some(n) {
    if !n.deleted && n.is_countable() {
      if remaining < n.length {
        return Some(item_values(n)[remaining])
      }
      remaining -= n.length
    }
    cur = n.right
  }
  None
}

///|
/// All elements in order (`toArray`).
pub fn YArray::to_array(self : YArray) -> Array[@lib0.Any] {
  let out = []
  let mut cur = self.ty.start
  while cur is Some(n) {
    if !n.deleted && n.is_countable() {
      out.append(item_values(n))
    }
    cur = n.right
  }
  out
}
