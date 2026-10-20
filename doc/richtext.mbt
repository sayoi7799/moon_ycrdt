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
