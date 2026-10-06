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
fn Text::find_position(self : Text, index : Int) -> Pos {
  guard index >= 0 && index <= self.ty.length else {
    abort("index \{index} out of range (length \{self.ty.length})")
  }
  let pos = { left: None, right: self.ty.start, attrs: {}, }
  let mut count = index
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
  self.doc.commit()
}
