// Clean-up of redundant formatting items in Y.Text (yjs/src/types/YText.js:
// cleanupFormattingGap and friends). A formatting item is redundant when it
// sets a value that is already in effect or that is overwritten before any
// text is reached.

///|
/// JavaScript `===` on two JSON-encoded attribute values. Only primitives can
/// be identical: Yjs compares the decoded values by reference, and two
/// separately decoded objects or arrays never are. (The same JavaScript
/// object can be shared by two formatting items created in one local
/// operation; that cannot be seen in the encoded data and is not modelled.)
pub fn js_identical(a : String, b : String) -> Bool {
  a == b && !a.has_prefix("{") && !a.has_prefix("[")
}

///|
/// `updateCurrentAttributes`: a `null` value removes the attribute.
pub fn update_attrs(
  attrs : Map[String, String],
  key : String,
  value : String,
) -> Unit {
  if value == "null" {
    attrs.remove(key)
  } else {
    attrs[key] = value
  }
}

///|
/// `cleanupFormattingGap`: removes the formatting items between `start` and
/// the next visible content that are overwritten later in the gap or repeat
/// the value in `start_attrs` (the attributes in effect before `start`).
/// `curr` is where the caller's position currently is (exclusive end of the
/// range it has handled) and `curr_attrs` the attributes it tracks there; they
/// are corrected for the items that are removed. Returns how many formatting
/// items were deleted.
pub fn Doc::cleanup_formatting_gap(
  self : Doc,
  start : Item,
  curr : Item?,
  start_attrs : Map[String, String],
  curr_attrs : Map[String, String],
) -> Int32 {
  // the formatting that is still in effect when the gap ends
  let end_formats : Map[String, Item] = Map([])
  let mut end : Item? = Some(start)
  while end is Some(e) && (!e.is_countable() || e.deleted) {
    if !e.deleted && e.content is Format(key, _) {
      end_formats[key] = e
    }
    end = e.right
  }
  let mut cleanups = 0
  let mut reached_curr = false
  let mut cur : Item? = Some(start)
  while cur is Some(item) && !same_item(cur, end) {
    if curr is Some(c) && physical_equal(c, item) {
      reached_curr = true
    }
    if !item.deleted && item.content is Format(key, value) {
      let start_value = start_attrs.get(key).unwrap_or("null")
      let is_end_format = end_formats.get(key) is Some(f) &&
        physical_equal(f, item)
      if !is_end_format || js_identical(start_value, value) {
        // overwritten, or the attribute was in effect already
        self.delete_item(item)
        cleanups += 1
        if !reached_curr &&
          js_identical(curr_attrs.get(key).unwrap_or("null"), value) &&
          !js_identical(start_value, value) {
          if start_value == "null" {
            curr_attrs.remove(key)
          } else {
            curr_attrs[key] = start_value
          }
        }
      }
      if !reached_curr && !item.deleted {
        update_attrs(curr_attrs, key, value)
      }
    }
    cur = item.right
  }
  cleanups
}

///|
/// Records that something inside `ty` changed in this transaction, like
/// `addChangedTypeToTransaction`: types created in the same transaction and
/// types whose own item was deleted do not count.
fn Doc::note_changed(self : Doc, ty : YType) -> Unit {
  let counts = match ty.item {
    None => true
    Some(i) => {
      let before = match self.txn_before.get(i.id.client) {
        Some(b) => b
        None => self.get_state(i.id.client)
      }
      i.id.clock < before && !i.deleted
    }
  }
  if counts && !self.txn_changed.iter().any(t => physical_equal(t, ty)) {
    self.txn_changed.push(ty)
  }
}

///|
/// Whether the remote transaction that just finished needs the formatting
/// clean-up: `YText._callObserver` flags it for every text that changed and
/// has seen a formatting item.
fn Doc::richtext_needs_cleanup(self : Doc) -> Bool {
  self.txn_changed
  .iter()
  .any(t => {
    (
      t.type_ref == @update.TYPE_REF_TEXT ||
      t.type_ref == @update.TYPE_REF_XML_TEXT
    ) &&
    t.has_formatting &&
    (match t.item {
      None => true
      Some(i) => !i.deleted
    })
  })
}

///|
/// `cleanupContextlessFormattingGap`: in the run of formatting and deleted
/// items around `item`, keeps only the last formatting item per attribute.
fn Doc::cleanup_contextless_gap(self : Doc, item : Item) -> Unit {
  let mut cur : Item? = Some(item)
  while cur is Some(c) && c.right is Some(r) && (r.deleted || !r.is_countable()) {
    cur = Some(r)
  }
  let seen : Map[String, Bool] = Map([])
  while cur is Some(c) && (c.deleted || !c.is_countable()) {
    if !c.deleted && c.content is Format(key, _) {
      if seen.contains(key) {
        self.delete_item(c)
      } else {
        seen[key] = true
      }
    }
    cur = c.left
  }
}

///|
/// `cleanupYTextFormatting`: walks the whole text and cleans the gap in front
/// of every visible item. (Yjs passes the previous visible item as the start
/// of the next gap, and that item is not part of any gap, so in practice only
/// the gap before the first visible item is ever changed; the port keeps this.)
fn Doc::cleanup_text_formatting(self : Doc, ty : YType) -> Int32 {
  let mut result = 0
  let mut start = ty.start
  let mut end = ty.start
  let mut start_attrs : Map[String, String] = Map([])
  let curr_attrs : Map[String, String] = start_attrs.copy()
  while end is Some(e) {
    if !e.deleted {
      match e.content {
        Format(key, value) => update_attrs(curr_attrs, key, value)
        _ => {
          if start is Some(s) {
            result += self.cleanup_formatting_gap(
              s,
              Some(e),
              start_attrs,
              curr_attrs,
            )
          }
          start_attrs = curr_attrs.copy()
          start = Some(e)
        }
      }
    }
    end = e.right
  }
  result
}

///|
/// `cleanupYTextAfterTransaction`: runs after the update event of a remote
/// transaction, in a transaction of its own (so it emits its own update, made
/// of deletions only). `before` is the state of each client before the remote
/// transaction and `ds` its delete set.
///
/// A text is cleaned completely when a formatting item was added to it or one
/// was deleted; otherwise every deleted item gets the cheaper clean-up that
/// only looks at the run of formatting items next to it.
fn Doc::richtext_cleanup(
  self : Doc,
  before : Map[UInt32, Int32],
  ds : @update.DeleteSet,
) -> Unit {
  let need_full : Array[YType] = []
  let add_full = fn(ty : YType) {
    if !need_full.iter().any(t => physical_equal(t, ty)) {
      need_full.push(ty)
    }
  }
  // formatting items that were added by the remote transaction
  for client, from in before {
    let structs = self.structs_of(client)
    for i in find_index(structs, from)..<structs.length() {
      if structs[i] is Item(item) &&
        !item.deleted &&
        item.content is Format(_, _) {
        add_full(item.parent)
      }
    }
  }
  // items that were deleted by it
  for client, ranges in ds.clients {
    for r in ranges {
      let structs = self.structs_of(client)
      let mut i = find_index(structs, r.clock)
      while i < structs.length() && structs[i].id().clock < r.clock + r.len {
        if structs[i] is Item(item) &&
          item.parent.has_formatting &&
          !need_full.iter().any(t => physical_equal(t, item.parent)) {
          if item.content is Format(_, _) {
            add_full(item.parent)
          } else {
            self.cleanup_contextless_gap(item)
          }
        }
        i += 1
      }
    }
  }
  for ty in need_full {
    self.cleanup_text_formatting(ty) |> ignore
  }
  self.end_transaction(true)
}
