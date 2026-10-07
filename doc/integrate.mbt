// YATA integration (yjs/src/structs/Item.js `getMissing` / `integrate`).

///|
/// Inserts a resolved item (`left`, `right`, `parent` already set) into its
/// parent's list, resolving conflicts with concurrent insertions.
///
/// Concurrent items that were inserted between the same neighbours are
/// ordered so that every replica arrives at the same sequence:
/// - same `origin`: the lower client id goes to the left; if the right
///   origins are the same as well, the scan can stop.
/// - an item whose origin lies inside the scanned region belongs to an
///   earlier conflicting item; it is skipped over unless that origin is one of
///   the items we are still in conflict with.
fn Doc::integrate_item(self : Doc, item : Item) -> Unit {
  let parent = item.parent
  let needs_resolution = match item.left {
    None =>
      match item.right {
        None => true
        Some(r) => r.left is Some(_)
      }
    Some(l) => !same_item(l.right, item.right)
  }
  if needs_resolution {
    let mut left = item.left
    let mut o : Item? = match item.left {
      Some(l) => l.right
      None =>
        match item.parent_sub {
          Some(key) => leftmost(parent.map.get(key))
          None => parent.start
        }
    }
    let conflicting : @hashset.HashSet[@update.ID] = @hashset.HashSet([])
    let before_origin : @hashset.HashSet[@update.ID] = @hashset.HashSet([])
    while o is Some(oi) && !same_item(o, item.right) {
      before_origin.add(oi.id)
      conflicting.add(oi.id)
      if item.origin == oi.origin {
        // case 1: same left origin
        if oi.id.client < item.id.client {
          left = Some(oi)
          conflicting.clear()
        } else if item.right_origin == oi.right_origin {
          // same integration points: the lower client id (this) goes first
          break
        }
      } else if oi.origin is Some(oo) &&
        self.get_struct(oo) is Item(origin_item) &&
        before_origin.contains(origin_item.id) {
        // case 2: oi was inserted after an item we already passed
        if !conflicting.contains(origin_item.id) {
          left = Some(oi)
          conflicting.clear()
        }
      } else {
        break
      }
      o = oi.right
    }
    item.left = left
  }
  // reconnect left / right and update the parent's start or map entry
  match item.left {
    Some(l) => {
      item.right = l.right
      l.right = Some(item)
    }
    None =>
      match item.parent_sub {
        Some(key) => item.right = leftmost(parent.map.get(key))
        None => {
          item.right = parent.start
          parent.start = Some(item)
        }
      }
  }
  match item.right {
    Some(r) => r.left = Some(item)
    None =>
      if item.parent_sub is Some(key) {
        // this is now the current value of the key; the previous one is deleted
        parent.map[key] = item
        if item.left is Some(l) {
          self.delete_item(l)
        }
      }
  }
  if item.parent_sub is None && item.is_countable() && !item.deleted {
    parent.length += item.length
  }
  self.add_struct(Item(item))
  match item.content {
    Deleted(_) => {
      item.deleted = true
      self.txn_ds.add(item.id.client, item.id.clock, item.length)
    }
    Type(type_ref, name) =>
      item.nested = Some(YType::new(type_ref, name~, item=Some(item)))
    _ => ()
  }
  let parent_deleted = match parent.item {
    Some(pi) => pi.deleted
    None => false
  }
  if parent_deleted || (item.parent_sub is Some(_) && item.right is Some(_)) {
    // the parent is gone, or a newer value for this key already exists
    self.delete_item(item)
  }
}

///|
fn leftmost(item : Item?) -> Item? {
  let mut cur = item
  while cur is Some(c) && c.left is Some(l) {
    cur = Some(l)
  }
  cur
}

///|
/// Marks an item deleted (`Item.delete`); deleting a nested type deletes its
/// content as well.
pub fn Doc::delete_item(self : Doc, item : Item) -> Unit {
  if item.deleted {
    return
  }
  if item.is_countable() && item.parent_sub is None {
    item.parent.length -= item.length
  }
  item.deleted = true
  self.touch(item.id.client, item.id.clock)
  self.txn_ds.add(item.id.client, item.id.clock, item.length)
  if item.nested is Some(t) {
    let mut cur = t.start
    while cur is Some(c) {
      if !c.deleted {
        self.delete_item(c)
      }
      cur = c.right
    }
    for _, v in t.map {
      if !v.deleted {
        self.delete_item(v)
      }
    }
  }
}

///|
/// Returns true when every struct `s` depends on is already in the store
/// (`getMissing`). Dependencies on the struct's own client are implied by the
/// clock order.
fn Doc::has_dependencies(self : Doc, s : @update.ItemRef) -> Bool {
  let client = s.id.client
  let available = fn(id : @update.ID?) {
    match id {
      Some(id) => id.client == client || id.clock < self.get_state(id.client)
      None => true
    }
  }
  available(s.origin) &&
  available(s.right_origin) &&
  (match s.parent {
    Some(Item(pid)) => available(Some(pid))
    _ => true
  })
}

///|
/// Integrates a remote struct whose dependencies are available, skipping its
/// first `offset` clocks (they are already known locally).
fn Doc::integrate_remote(
  self : Doc,
  s : @update.StructRef,
  offset : Int,
) -> Unit {
  match s {
    Skip(_, _) => ()
    GC(id, len) =>
      self.add_struct(
        GC({
          id: @update.ID::new(id.client, id.clock + offset),
          length: len - offset,
        }),
      )
    Item(r) => {
      // resolve neighbours and parent (getMissing)
      let left_s = r.origin.map(o => self.get_item_clean_end(o))
      let right_s = r.right_origin.map(ro => self.get_item_clean_start(ro))
      let mut parent : YType? = None
      let mut parent_sub = r.parent_sub
      if left_s is Some(GC(_)) || right_s is Some(GC(_)) {
        parent = None
      } else {
        match r.parent {
          None =>
            match (left_s, right_s) {
              (Some(Item(l)), _) => {
                parent = Some(l.parent)
                parent_sub = l.parent_sub
              }
              (_, Some(Item(rt))) => {
                parent = Some(rt.parent)
                parent_sub = rt.parent_sub
              }
              _ => ()
            }
          Some(Root(name)) => parent = Some(self.root_type(name))
          Some(Item(pid)) =>
            parent = match self.get_struct(pid) {
              Item(pi) => pi.nested
              GC(_) => None
            }
        }
      }
      let mut left = match left_s {
        Some(Item(l)) => Some(l)
        _ => None
      }
      let right = match right_s {
        Some(Item(rt)) => Some(rt)
        _ => None
      }
      let mut id = r.id
      let mut origin = r.origin
      let mut content = r.content
      if offset > 0 {
        id = @update.ID::new(id.client, id.clock + offset)
        match
          self.get_item_clean_end(@update.ID::new(id.client, id.clock - 1)) {
          Item(l) => {
            left = Some(l)
            origin = Some(l.last_id())
          }
          GC(_) => parent = None
        }
        content = content.split(offset).1
      }
      match parent {
        None => self.add_struct(GC({ id, length: content.length(), }))
        Some(p) => {
          let item : Item = {
            id,
            length: content.length(),
            origin,
            right_origin: r.right_origin,
            left,
            right,
            parent: p,
            parent_sub,
            content,
            deleted: false,
            nested: None,
          }
          self.integrate_item(item)
        }
      }
    }
  }
}

///|
/// Applies a delete set; ranges beyond the local state are added to `rest`
/// (`readAndApplyDeleteSet`).
fn Doc::apply_delete_set(
  self : Doc,
  ds : @update.DeleteSet,
  rest : @update.DeleteSet,
) -> Unit {
  for client, ranges in ds.clients {
    let state = self.get_state(client)
    for r in ranges {
      let end = r.clock + r.len
      if r.clock >= state {
        rest.add(client, r.clock, r.len)
        continue
      }
      if state < end {
        rest.add(client, state, end - state)
      }
      let structs = self.structs_of(client)
      let mut index = find_index(structs, r.clock)
      if structs[index] is Item(first) &&
        !first.deleted &&
        first.id.clock < r.clock {
        let right = self.split_item(first, r.clock - first.id.clock)
        structs.insert(index + 1, Item(right))
        index += 1
      }
      while index < structs.length() {
        let s = structs[index]
        index += 1
        if s.id().clock >= end {
          break
        }
        if s is Item(item) && !item.deleted {
          if end < item.id.clock + item.length {
            let right = self.split_item(item, end - item.id.clock)
            structs.insert(index, Item(right))
          }
          self.delete_item(item)
        }
      }
    }
  }
}
