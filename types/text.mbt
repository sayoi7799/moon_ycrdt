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
pub fn Text::length(self : Text) -> Int32 {
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
/// that contains the position, and collects the formatting attributes passed
/// on the way.
///
/// `use_marker` says whether the Yjs operation looks the position up through
/// a search marker (insert without attributes, delete) or walks from the start
/// of the text (insert with attributes, format, applyDelta). The marker is only
/// there while the type has not seen a formatting item (`markers_enabled`);
/// walking from the start accumulates the attributes of everything to the left,
/// a marker starts with none. Markers are a cache that depends on the history of
/// the Yjs object, so only a single fresh marker is emulated (`findMarker`: the
/// item containing `index`, moved left over items of the same client with
/// consecutive clocks). For text without formatting both give the same result.
fn Text::find_position(self : Text, index : Int32, use_marker : Bool) -> Pos {
  guard index >= 0 && index <= self.ty.length else {
    abort("index \{index} out of range (length \{self.ty.length})")
  }
  let pos = { left: None, right: self.ty.start, attrs: Map([]), }
  let mut count = index
  if use_marker &&
    self.ty.markers_enabled &&
    index > 0 &&
    self.ty.start is Some(first) {
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
/// Moves right over deleted items and formatting items that already say what
/// `attributes` ask for (`minimizeAttributeChanges`), so that no redundant
/// formatting item is written.
fn minimize_attribute_changes(
  pos : Pos,
  attributes : Map[String, String],
) -> Unit {
  while pos.right is Some(r) {
    let skip = r.deleted ||
      (match r.content {
        Format(key, value) =>
          attr_equal(attributes.get(key).unwrap_or("null"), value)
        _ => false
      })
    if !skip {
      break
    }
    pos.forward()
  }
}

///|
/// Writes a formatting item for every attribute whose current value differs
/// (`insertAttributes`) and returns the values to restore after the content.
fn Text::insert_attributes(
  self : Text,
  pos : Pos,
  attributes : Map[String, String],
) -> Map[String, String] {
  let negated : Map[String, String] = Map([])
  for key, value in attributes {
    let current = pos.attrs.get(key).unwrap_or("null")
    if !attr_equal(current, value) {
      negated[key] = current
      let item = self.doc.insert(
        self.ty,
        pos.left,
        pos.right,
        None,
        Format(key, value),
      )
      pos.right = Some(item)
      pos.forward()
    }
  }
  negated
}

///|
/// Restores the attributes in `negated` after inserted content
/// (`insertNegatedAttributes`), reusing formatting items that are already there.
fn Text::insert_negated_attributes(
  self : Text,
  pos : Pos,
  negated : Map[String, String],
) -> Unit {
  while pos.right is Some(r) {
    let skip = r.deleted ||
      (match r.content {
        Format(key, value) => attr_equal_opt(negated.get(key), value)
        _ => false
      })
    if !skip {
      break
    }
    if !r.deleted && r.content is Format(key, _) {
      negated.remove(key)
    }
    pos.forward()
  }
  for key, value in negated {
    let item = self.doc.insert(
      self.ty,
      pos.left,
      pos.right,
      None,
      Format(key, value),
    )
    pos.right = Some(item)
    pos.forward()
  }
}

///|
/// `insertText`: inserts `content` at `pos` with exactly the formatting
/// `attributes` describes. Attributes that are active at the position but
/// not mentioned are switched off for the new content and restored after it.
fn Text::insert_content(
  self : Text,
  pos : Pos,
  content : @update.Content,
  attributes : Map[String, String],
) -> Unit {
  for key, _ in pos.attrs {
    if !attributes.contains(key) {
      attributes[key] = "null"
    }
  }
  minimize_attribute_changes(pos, attributes)
  let negated = self.insert_attributes(pos, attributes)
  let item = self.doc.insert(self.ty, pos.left, pos.right, None, content)
  pos.right = Some(item)
  pos.forward()
  self.insert_negated_attributes(pos, negated)
}

///|
fn Text::insert_string(
  self : Text,
  index : Int32,
  s : String,
  attributes : Map[String, String]?,
) -> Unit {
  if s.length() == 0 {
    return
  }
  // Without attributes Yjs uses the search marker and lets the new text
  // inherit whatever is active at the position.
  let pos = self.find_position(index, attributes is None)
  let attrs = match attributes {
    Some(a) => a
    None => pos.attrs.copy()
  }
  self.insert_content(pos, String(s), attrs)
  self.doc.commit()
}

///|
/// Inserts `s` at UTF-16 offset `index`. The new text gets the formatting
/// that is active at that position.
pub fn Text::insert(self : Text, index : Int32, s : String) -> Unit {
  self.insert_string(index, s, None)
}

///|
/// Inserts `s` with exactly the formatting `attributes` describes
/// (`ytext.insert(index, s, attributes)`). A `Null` value switches an attribute
/// off; active attributes that are not listed are switched off as well.
pub fn Text::insert_with_attributes(
  self : Text,
  index : Int32,
  s : String,
  attributes : Array[(String, @lib0.Any)],
) -> Unit {
  self.insert_string(index, s, Some(attrs_to_map(attributes)))
}

///|
/// Inserts an embedded object (an image, a mention, ...) that takes up one
/// position (`ytext.insertEmbed`). Without `attributes` the embed carries no
/// formatting.
pub fn Text::insert_embed(
  self : Text,
  index : Int32,
  embed : @lib0.Any,
  attributes? : Array[(String, @lib0.Any)],
) -> Unit {
  let pos = self.find_position(index, attributes is None)
  let attrs = match attributes {
    Some(a) => attrs_to_map(a)
    None => Map([])
  }
  self.insert_content(pos, Embed(embed.to_json_string()), attrs)
  self.doc.commit()
}

///|
/// Deletes `len` UTF-16 code units starting at `index`.
pub fn Text::delete(self : Text, index : Int32, len : Int32) -> Unit {
  if len <= 0 {
    return
  }
  guard index + len <= self.ty.length else {
    abort("delete range \{index}+\{len} out of range")
  }
  let pos = self.find_position(index, true)
  self.delete_content(pos, len)
  self.doc.commit()
}

///|
/// `deleteText`: deletes `length` positions from `pos` on, then removes the
/// formatting items that became redundant in the gap (`cleanupFormattingGap`).
/// `pos` ends up after the gap with the attributes corrected for the items
/// that were removed. A range that reaches past the end is cut off.
fn Text::delete_content(self : Text, pos : Pos, length : Int32) -> Unit {
  let start = pos.right
  let start_attrs = pos.attrs.copy()
  let mut remaining = length
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
    self.doc.cleanup_formatting_gap(s, pos.right, start_attrs, pos.attrs)
    |> ignore
  }
}

///|
/// `formatText`: applies `attributes` to the next `length` positions starting
/// at `pos`. Formatting items inside the range that set one of these
/// attributes are deleted; if they set a different value, that value is
/// restored after the range. A range that reaches past the end of the text
/// is padded with newlines, which is what Yjs does for Quill.
fn Text::format_range(
  self : Text,
  pos : Pos,
  length : Int32,
  attributes : Map[String, String],
) -> Unit {
  let mut length = length
  minimize_attribute_changes(pos, attributes)
  let negated = self.insert_attributes(pos, attributes)
  // go on until the range is used up; then keep going over formatting items
  // and deleted items that follow, so no redundant negation is written
  while pos.right is Some(r) &&
        (
          length > 0 ||
          (negated.length() > 0 && (r.deleted || r.content is Format(_, _)))
        ) {
    if !r.deleted {
      match r.content {
        Format(key, value) =>
          if attributes.get(key) is Some(wanted) {
            if attr_equal(wanted, value) {
              negated.remove(key)
            } else {
              if length == 0 {
                break
              }
              negated[key] = value
            }
            self.doc.delete_item(r)
          }
        _ => {
          if length < r.length {
            self.doc.split(r, length) |> ignore
          }
          length -= r.length
        }
      }
    }
    pos.forward()
  }
  if length > 0 {
    let newlines = StringBuilder()
    for _ in 0..<length {
      newlines.write_char('\n')
    }
    let item = self.doc.insert(
      self.ty,
      pos.left,
      pos.right,
      None,
      String(newlines.to_string()),
    )
    pos.right = Some(item)
    pos.forward()
  }
  self.insert_negated_attributes(pos, negated)
}

///|
/// Applies `attributes` to `length` positions starting at `index`
/// (`ytext.format`). A `Null` value removes the attribute from the range.
pub fn Text::format(
  self : Text,
  index : Int32,
  length : Int32,
  attributes : Array[(String, @lib0.Any)],
) -> Unit {
  if length == 0 {
    return
  }
  let pos = self.find_position(index, false)
  if pos.right is None {
    return
  }
  self.format_range(pos, length, attrs_to_map(attributes))
  self.doc.commit()
}
