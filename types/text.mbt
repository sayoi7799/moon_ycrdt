// Y.Text without formatting attributes (yjs/src/types/YText.js).
//
// Positions are UTF-16 code unit offsets, exactly like JavaScript strings, so
// an index means the same thing on every replica. Formatting items and embeds
// written by other clients are preserved; embeds count as one position, like
// in Yjs.

///|
pub struct Text {
  doc : @doc.Doc
  ty : @doc.YType
}

///|
/// The root Y.Text called `name` (`doc.getText(name)`).
pub fn Text::new(doc : @doc.Doc, name : String) -> Text {
  { doc, ty: doc.get_root(name, @update.TYPE_REF_TEXT), }
}

///|
/// Length in UTF-16 code units (embeds count as 1).
pub fn Text::length(self : Text) -> Int {
  self.ty.length
}

///|
pub fn Text::to_string(self : Text) -> String {
  let sb = StringBuilder()
  let mut cur = self.ty.start
  while cur is Some(item) {
    if !item.deleted && item.content is String(s) {
      sb.write_string(s)
    }
    cur = item.right
  }
  sb.to_string()
}

///|
pub impl Show for Text with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Position between `left` and `right` plus the formatting attributes
/// (key -> JSON value) active there (`ItemTextListPosition`).
priv struct Pos {
  mut left : @doc.Item?
  mut right : @doc.Item?
  attrs : Map[String, String]
}

///|
fn Pos::update_attrs(self : Pos, item : @doc.Item) -> Unit {
  if !item.deleted && item.content is Format(key, value) {
    if value == "null" {
      self.attrs.remove(key)
    } else {
      self.attrs[key] = value
    }
  }
}

///|
fn Pos::forward(self : Pos) -> Unit {
  let r = self.right.unwrap()
  self.update_attrs(r)
  self.left = Some(r)
  self.right = r.right
}

///|
/// Walks to `index` (`findPosition` / `findNextPosition`), splitting the item
/// that contains the position.
///
/// Yjs starts the walk at a "search marker" for every index > 0 and then only
/// knows the formatting attributes seen after the marker. Markers are a cache
/// whose contents depend on the history of the Yjs object; this emulates the
/// marker a freshly loaded Yjs document creates (`findMarker`): the item
/// containing `index`, moved left over items of the same client with
/// consecutive clocks. For text without formatting the result is the same as
/// walking from the start.
fn Text::find_position(self : Text, index : Int) -> Pos {
  guard index >= 0 && index <= self.ty.length else {
    abort("index \{index} out of range (length \{self.ty.length})")
  }
  let pos = { left: None, right: self.ty.start, attrs: Map([]), }
  let mut count = index
  if index > 0 && self.ty.start is Some(first) {
    let mut p = first
    let mut pindex = 0
    while p.right is Some(next) && pindex < index {
      if !p.deleted && p.is_countable() {
        if index < pindex + p.length {
          break
        }
        pindex += p.length
      }
      p = next
    }
    while p.left is Some(l) &&
          l.id.client == p.id.client &&
          l.id.clock + l.length == p.id.clock {
      p = l
      if !p.deleted && p.is_countable() {
        pindex -= p.length
      }
    }
    pos.left = p.left
    pos.right = Some(p)
    count = index - pindex
  }
  while pos.right is Some(r) && count > 0 {
    if !r.deleted && !(r.content is Format(_, _)) {
      if count < r.length {
        self.doc.split(r, count) |> ignore
      }
      count -= r.length
    }
    pos.forward()
  }
  pos
}

///|
/// Inserts `s` at UTF-16 offset `index`.
pub fn Text::insert(self : Text, index : Int, s : String) -> Unit {
  if s.length() == 0 {
    return
  }
  let pos = self.find_position(index)
  // Like Yjs, inherit the attributes at the position and move right over
  // deleted items and formats that would not change them
  // (`minimizeAttributeChanges`). This decides the new item's origin.
  let attributes = pos.attrs.copy()
  while pos.right is Some(r) {
    let skip = r.deleted ||
      (match r.content {
        Format(key, value) => attributes.get(key).unwrap_or("null") == value
        _ => false
      })
    if !skip {
      break
    }
    pos.forward()
  }
  self.doc.insert(self.ty, pos.left, pos.right, None, String(s)) |> ignore
  self.doc.commit()
}

///|
/// Deletes `len` UTF-16 code units starting at `index`.
pub fn Text::delete(self : Text, index : Int, len : Int) -> Unit {
  if len <= 0 {
    return
  }
  guard index + len <= self.ty.length else {
    abort("delete range \{index}+\{len} out of range")
  }
  let pos = self.find_position(index)
  let start = pos.right
  let start_attrs = pos.attrs.copy()
  let mut remaining = len
  while remaining > 0 && pos.right is Some(r) {
    if !r.deleted {
      match r.content {
        String(_) | Embed(_) | Type(_, _) => {
          if remaining < r.length {
            self.doc.split(r, remaining) |> ignore
          }
          remaining -= r.length
          self.doc.delete_item(r)
        }
        _ => ()
      }
    }
    pos.forward()
  }
  if start is Some(s) {
    self.cleanup_formatting_gap(s, start_attrs)
  }
  self.doc.commit()
}

///|
/// JavaScript `===` on two JSON-encoded attribute values: only primitive
/// values can be identical, objects and arrays never are.
fn js_identical(a : String, b : String) -> Bool {
  a == b && !a.has_prefix("{") && !a.has_prefix("[")
}

///|
/// After a deletion, removes formatting items that became redundant between
/// the deleted range and the next visible character (`cleanupFormattingGap`),
/// so that deleting inside formatted text gives the same result as Yjs.
fn Text::cleanup_formatting_gap(
  self : Text,
  start : @doc.Item,
  start_attrs : Map[String, String],
) -> Unit {
  // the formats that are in effect right before the next visible content
  let end_formats : Map[String, @doc.Item] = Map([])
  let mut end : @doc.Item? = Some(start)
  while end is Some(e) && (!e.is_countable() || e.deleted) {
    if !e.deleted && e.content is Format(key, _) {
      end_formats[key] = e
    }
    end = e.right
  }
  let mut cur : @doc.Item? = Some(start)
  while cur is Some(item) && !(end is Some(e) && physical_equal(e, item)) {
    if !item.deleted && item.content is Format(key, value) {
      let start_value = start_attrs.get(key).unwrap_or("null")
      let is_end_format = end_formats.get(key) is Some(f) &&
        physical_equal(f, item)
      // overwritten later, or the attribute was already in effect
      if !is_end_format || js_identical(start_value, value) {
        self.doc.delete_item(item)
      }
    }
    cur = item.right
  }
}
