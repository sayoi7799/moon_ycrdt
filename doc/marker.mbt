// Search markers (yjs/src/types/AbstractType.js: `ArraySearchMarker`,
// `findMarker`, `updateMarkerChanges`).
//
// Finding the element at an index means walking the item list. A list type
// keeps up to 80 markers, each remembering an item and how many visible
// elements come before it, and starts the walk at the nearest one. The markers
// are a cache that Yjs keeps up to date on local edits and throws away when a
// remote change arrives. Their placement is not only a speed matter: where a
// walk starts decides which formatting a text position sees (see
// `Text::find_position`), so the rules below follow Yjs exactly, including
// which marker is reused or replaced.

///|
/// The most markers a type keeps (`maxSearchMarker`).
pub const MAX_SEARCH_MARKER : Int32 = 80

///|
fn YType::next_marker_time(self : YType) -> Int32 {
  let t = self.marker_clock
  self.marker_clock = t + 1
  t
}

///|
/// Points `marker` at `p` (`overwriteMarker`).
fn YType::overwrite_marker(
  self : YType,
  marker : Marker,
  p : Item,
  index : Int32,
) -> Unit {
  marker.p.marked = false
  marker.p = p
  p.marked = true
  marker.index = index
  marker.timestamp = self.next_marker_time()
}

///|
/// Remembers the position `p` / `index`: a new marker, or the least recently
/// used one when there are already 80 (`markPosition`).
fn YType::mark_position(self : YType, p : Item, index : Int32) -> Marker {
  if self.markers.length() >= MAX_SEARCH_MARKER {
    let mut oldest = self.markers[0]
    for m in self.markers {
      // `reduce((a, b) => a.timestamp < b.timestamp ? a : b)`
      if !(oldest.timestamp < m.timestamp) {
        oldest = m
      }
    }
    self.overwrite_marker(oldest, p, index)
    oldest
  } else {
    p.marked = true
    let marker = { p, index, timestamp: self.next_marker_time(), }
    self.markers.push(marker)
    marker
  }
}

///|
/// The marker for the item that holds element `index` (`findMarker`), found
/// by walking from the nearest existing marker. None when the type has no
/// markers (`markers_enabled` is false), is empty, or `index` is 0.
pub fn YType::find_marker(self : YType, index : Int32) -> Marker? {
  guard self.markers_enabled && index != 0 && self.start is Some(start) else {
    return None
  }
  // the marker nearest to `index`; on a tie the later one
  let mut marker : Marker? = None
  for m in self.markers {
    match marker {
      Some(a) =>
        if !(abs(index - a.index) < abs(index - m.index)) {
          marker = Some(m)
        }
      None => marker = Some(m)
    }
  }
  let mut p = start
  let mut pindex = 0
  if marker is Some(m) {
    p = m.p
    pindex = m.index
    m.timestamp = self.next_marker_time() // used now, probably used again
  }
  // walk right to the item holding `index`
  while p.right is Some(next) && pindex < index {
    if !p.deleted && p.is_countable() {
      if index < pindex + p.length {
        break
      }
      pindex += p.length
    }
    p = next
  }
  // or left, if the marker was beyond it
  while p.left is Some(l) && pindex > index {
    p = l
    if !p.deleted && p.is_countable() {
      pindex -= p.length
    }
  }
  // `p` must not be mergeable with its left neighbour: the merge would drop it
  while p.left is Some(l) &&
        l.id.client == p.id.client &&
        l.id.clock + l.length == p.id.clock {
    p = l
    if !p.deleted && p.is_countable() {
      pindex -= p.length
    }
  }
  match marker {
    // close enough to the old position: move that marker (80 * distance <
    // length is Yjs' `distance < length / 80`)
    Some(m) if abs(m.index - pindex) * MAX_SEARCH_MARKER < p.parent.length => {
      self.overwrite_marker(m, p, pindex)
      Some(m)
    }
    _ => Some(self.mark_position(p, pindex))
  }
}

///|
fn abs(x : Int32) -> Int32 {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
/// Keeps the markers right after a local change at element `index`: `len`
/// elements were inserted (`len > 0`) or `-len` deleted (`updateMarkerChanges`).
/// Call it before the deletion's items are gone from view, as Yjs does.
pub fn YType::update_marker_changes(
  self : YType,
  index : Int32,
  len : Int32,
) -> Unit {
  if !self.markers_enabled {
    return
  }
  let mut i = self.markers.length() - 1
  while i >= 0 {
    let m = self.markers[i]
    if len > 0 {
      m.p.marked = false
      // a marker must not rest on a deleted item or a formatting item: move
      // it to the visible element before, so that index comparison is valid
      let mut p : Item? = Some(m.p)
      while p is Some(c) && (c.deleted || !c.is_countable()) {
        p = c.left
        if p is Some(l) && !l.deleted && l.is_countable() {
          m.index -= l.length
        }
      }
      match p {
        Some(c) if !c.marked => {
          m.p = c
          c.marked = true
        }
        _ => {
          // nowhere to go, or that item is already marked: drop the marker
          self.markers.remove(i) |> ignore
          i -= 1
          continue
        }
      }
    }
    if index < m.index || (len > 0 && index == m.index) {
      m.index = @cmp.maximum(index, m.index + len)
    }
    i -= 1
  }
}

///|
/// A remote change arrived: all markers of the types it touched are dropped
/// (`AbstractType._callObserver`). The `marked` flags of the items stay.
fn Doc::drop_markers_of_changed_types(self : Doc) -> Unit {
  for ty in self.txn_changed {
    ty.markers.clear()
  }
}
