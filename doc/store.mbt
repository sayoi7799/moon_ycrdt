// Struct store: for every client, its structs sorted by clock and covering
// the clocks 0 ..< state without gaps (yjs/src/utils/StructStore.js).

///|
/// Next expected clock of `client` (0 if nothing is known).
pub fn Doc::get_state(self : Doc, client : UInt) -> Int {
  match self.clients.get(client) {
    Some(structs) if structs.length() > 0 => {
      let last = structs[structs.length() - 1]
      last.id().clock + last.length()
    }
    _ => 0
  }
}

///|
/// Index of the struct containing `clock` (binary search).
fn find_index(structs : Array[Struct], clock : Int) -> Int {
  let mut lo = 0
  let mut hi = structs.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let s = structs[mid]
    let start = s.id().clock
    if clock < start {
      hi = mid - 1
    } else if clock >= start + s.length() {
      lo = mid + 1
    } else {
      return mid
    }
  }
  abort("clock \{clock} not found in struct store")
}

///|
fn Doc::structs_of(self : Doc, client : UInt) -> Array[Struct] {
  match self.clients.get(client) {
    Some(s) => s
    None => abort("unknown client \{client}")
  }
}

///|
/// The struct containing `id`.
pub fn Doc::get_struct(self : Doc, id : @update.ID) -> Struct {
  let structs = self.structs_of(id.client)
  structs[find_index(structs, id.clock)]
}

///|
fn Doc::add_struct(self : Doc, s : Struct) -> Unit {
  let client = s.id().client
  if !self.txn_before.contains(client) {
    self.txn_before[client] = self.get_state(client)
  }
  match self.clients.get(client) {
    Some(structs) => {
      guard self.get_state(client) == s.id().clock else {
        abort("struct \{s.id()} is not contiguous with the store")
      }
      structs.push(s)
    }
    None => {
      guard s.id().clock == 0 else {
        abort("struct \{s.id()} is not contiguous with the store")
      }
      self.clients[client] = [s]
    }
  }
  self.touched.add(client)
}

///|
/// Splits `left` so that it keeps `diff` clocks, links the new right part
/// after it and returns the right part (`splitItem`). The caller inserts the
/// right part into the store.
fn Doc::split_item(self : Doc, left : Item, diff : Int) -> Item {
  let (lc, rc) = left.content.split(diff)
  let client = left.id.client
  let clock = left.id.clock
  let right : Item = {
    id: @update.ID::new(client, clock + diff),
    length: rc.length(),
    origin: Some(@update.ID::new(client, clock + diff - 1)),
    right_origin: left.right_origin,
    left: Some(left),
    right: left.right,
    parent: left.parent,
    parent_sub: left.parent_sub,
    content: rc,
    deleted: left.deleted,
    nested: None,
  }
  left.content = lc
  left.length = diff
  left.right = Some(right)
  if right.right is Some(r) {
    r.left = Some(right)
  }
  if right.parent_sub is Some(key) && right.right is None {
    right.parent.map[key] = right
  }
  self.touched.add(client)
  right
}

///|
/// Makes sure an item starts exactly at `id` and returns the struct starting
/// there (`getItemCleanStart`). GC ranges are never split.
fn Doc::get_item_clean_start(self : Doc, id : @update.ID) -> Struct {
  let structs = self.structs_of(id.client)
  let index = find_index(structs, id.clock)
  match structs[index] {
    Item(item) if item.id.clock < id.clock => {
      let right = self.split_item(item, id.clock - item.id.clock)
      structs.insert(index + 1, Item(right))
      Item(right)
    }
    s => s
  }
}

///|
/// Makes sure an item ends exactly at `id` and returns the struct ending
/// there (`getItemCleanEnd`).
fn Doc::get_item_clean_end(self : Doc, id : @update.ID) -> Struct {
  let structs = self.structs_of(id.client)
  let index = find_index(structs, id.clock)
  let s = structs[index]
  if s is Item(item) && id.clock != item.id.clock + item.length - 1 {
    let right = self.split_item(item, id.clock - item.id.clock + 1)
    structs.insert(index + 1, Item(right))
  }
  s
}

///|
/// Splits `item` after `diff` clocks and returns the right part.
pub fn Doc::split(self : Doc, item : Item, diff : Int) -> Item {
  guard diff > 0 && diff < item.length else {
    abort("split offset \{diff} out of range")
  }
  match
    self.get_item_clean_start(
      @update.ID::new(item.id.client, item.id.clock + diff),
    ) {
    Item(right) => right
    GC(_) => abort("unreachable: split produced a GC range")
  }
}

///|
/// Merges a struct into its left neighbour when Yjs would (`mergeWith`).
fn try_merge(left : Struct, right : Struct) -> Bool {
  match (left, right) {
    (GC(l), GC(r)) => {
      l.length += r.length
      true
    }
    (Item(l), Item(r)) => {
      guard r.origin == Some(l.last_id()) &&
        same_item(l.right, Some(r)) &&
        l.right_origin == r.right_origin &&
        l.deleted == r.deleted else {
        return false
      }
      let merged : @update.Content = match (l.content, r.content) {
        (String(a), String(b)) => String(a + b)
        (Any(a), Any(b)) => Any(a + b)
        (JSON(a), JSON(b)) => JSON(a + b)
        (Deleted(a), Deleted(b)) => Deleted(a + b)
        _ => return false
      }
      l.content = merged
      l.right = r.right
      if l.right is Some(rr) {
        rr.left = Some(l)
      }
      l.length += r.length
      if r.parent_sub is Some(key) &&
        l.parent.map.get(key) is Some(cur) &&
        physical_equal(cur, r) {
        l.parent.map[key] = l
      }
      true
    }
    _ => false
  }
}

///|
/// End-of-transaction cleanup: merge adjacent structs of the clients that
/// changed, keeping the store (and encoded updates) compact like Yjs does.
fn Doc::cleanup(self : Doc) -> Unit {
  for client in self.touched {
    guard self.clients.get(client) is Some(structs) else { continue }
    let merged : Array[Struct] = []
    for s in structs {
      if merged.length() > 0 && try_merge(merged[merged.length() - 1], s) {
        continue
      }
      merged.push(s)
    }
    if merged.length() != structs.length() {
      structs.clear()
      structs.append(merged)
    }
  }
  self.touched.clear()
}
