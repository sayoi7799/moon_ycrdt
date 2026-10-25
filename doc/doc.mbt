// Document, update application and update generation
// (yjs/src/utils/Doc.js, encoding.js).

///|
pub struct Doc {
  /// This replica's client id. Must be unique among all collaborators;
  /// Yjs uses a random 32-bit unsigned integer.
  client_id : UInt32
  priv clients : Map[UInt32, Array[Struct]]
  priv share : Map[String, YType]
  /// Structs whose dependencies have not arrived yet, per client.
  priv mut pending_structs : Map[UInt32, Array[@update.StructRef]]
  /// Deletions of clocks that have not arrived yet.
  priv mut pending_ds : @update.DeleteSet
  /// Clocks of structs that changed in the current transaction (added,
  /// split off or deleted), per client: the only places where adjacent
  /// structs can have become mergeable.
  priv touched : Map[UInt32, Array[Int32]]
  /// State of each client before its first new struct in this transaction.
  priv txn_before : Map[UInt32, Int32]
  /// Deletions performed in this transaction.
  priv mut txn_ds : @update.DeleteSet
  /// Types with a change inside them in this transaction (`transaction.changed`).
  priv txn_changed : Array[YType]
  priv listeners : Array[(Bytes, Bool) -> Unit]
  priv listeners_v2 : Array[(Bytes, Bool) -> Unit]
}

///|
/// Creates an empty document. Garbage collection is not implemented (the
/// document behaves like `new Y.Doc({ gc: false })`), but GC structs received
/// from other clients are understood.
pub fn Doc::new(client_id : UInt32) -> Doc {
  {
    client_id,
    clients: {},
    share: {},
    pending_structs: {},
    pending_ds: @update.DeleteSet::new(),
    touched: {},
    txn_before: {},
    txn_ds: @update.DeleteSet::new(),
    txn_changed: [],
    listeners: [],
    listeners_v2: [],
  }
}

///|
fn Doc::root_type(self : Doc, name : String) -> YType {
  match self.share.get(name) {
    Some(t) => t
    None => {
      let t = YType::new(TYPE_REF_UNKNOWN, root_name=Some(name))
      self.share[name] = t
      t
    }
  }
}

///|
/// Returns the root type `name`, fixing its kind to `type_ref` (one of the
/// `@update.TYPE_REF_*` constants). A root created by a remote update has an
/// unknown kind until the application asks for it, like `doc.get(name)`.
pub fn Doc::get_root(self : Doc, name : String, type_ref : Int32) -> YType {
  let t = self.root_type(name)
  if t.type_ref == TYPE_REF_UNKNOWN {
    t.type_ref = type_ref
    // Yjs builds a brand-new type object here (`Doc.get` replacing the
    // placeholder): its search markers are on and it has not seen a
    // formatting item, even if the content already holds some.
    t.markers_enabled = true
    t.has_formatting = false
  } else if t.type_ref != type_ref {
    abort(
      "type \"\{name}\" was already defined with type ref \{t.type_ref}, not \{type_ref}",
    )
  }
  t
}

///|
/// Names of the root types known to the document.
pub fn Doc::root_names(self : Doc) -> Array[String] {
  self.share.keys().to_array()
}

///|
/// Client -> next expected clock of every client in the store.
pub fn Doc::state_vector(self : Doc) -> Map[UInt32, Int32] {
  let sv = Map([])
  for client, _ in self.clients {
    sv[client] = self.get_state(client)
  }
  sv
}

///|
/// Whether some received structs or deletions wait for missing dependencies.
pub fn Doc::has_pending(self : Doc) -> Bool {
  self.pending_structs.values().any(a => a.length() > 0) ||
  !self.pending_ds.is_empty()
}

///|
/// Applies a v1 update. Structs whose dependencies are missing are kept in a
/// pending queue and integrated automatically once the dependencies arrive.
/// Applying the same update more than once has no effect.
pub fn Doc::apply_update(
  self : Doc,
  data : Bytes,
) -> Unit raise @lib0.DecodeError {
  self.apply_decoded_update(@update.decode_update(data))
}

///|
/// Applies an update of format v2 (`Y.applyUpdateV2`); everything else works as
/// for `apply_update`.
pub fn Doc::apply_update_v2(
  self : Doc,
  data : Bytes,
) -> Unit raise @lib0.DecodeError {
  self.apply_decoded_update(@update.decode_update_v2(data))
}

///|
fn Doc::apply_decoded_update(self : Doc, update : @update.Update) -> Unit {
  // queue = previously pending structs + new structs, per client by clock
  let queue = self.pending_structs
  self.pending_structs = {}
  for cs in update.clients {
    match queue.get(cs.client) {
      Some(q) => q.append(cs.structs)
      None => queue[cs.client] = cs.structs.copy()
    }
  }
  for _, q in queue {
    q.sort_by((a, b) => a.id().clock.compare(b.id().clock))
  }
  let clients = queue.keys().to_array()
  // higher client ids first, like Yjs
  clients.sort_by((a, b) => b.compare(a))
  let next = Map::from_array(clients.map(c => (c, 0)))
  let mut progress = true
  while progress {
    progress = false
    for client in clients {
      let q = queue.get(client).unwrap()
      let mut i = next.get(client).unwrap()
      while i < q.length() {
        let s = q[i]
        if s is Skip(_, _) {
          i += 1
          continue
        }
        let state = self.get_state(client)
        let clock = s.id().clock
        if clock + s.length() <= state {
          // already integrated
          i += 1
          continue
        }
        if clock > state {
          // an earlier struct of this client is missing
          break
        }
        if s is Item(r) && !self.has_dependencies(r) {
          break
        }
        self.integrate_remote(s, state - clock)
        i += 1
        progress = true
      }
      next[client] = i
    }
  }
  for client in clients {
    let q = queue.get(client).unwrap()
    let i = next.get(client).unwrap()
    let rest = q[i:].iter().filter(s => !(s is Skip(_, _))).to_array()
    if rest.length() > 0 {
      self.pending_structs[client] = rest
    }
  }
  let rest_ds = @update.DeleteSet::new()
  self.apply_delete_set(update.delete_set, rest_ds)
  let old_pending = self.pending_ds
  self.pending_ds = @update.DeleteSet::new()
  self.apply_delete_set(old_pending, rest_ds)
  rest_ds.sort_and_merge()
  self.pending_ds = rest_ds
  // After a remote change Yjs cleans up redundant formatting in a second
  // transaction, once the update event of the first has been emitted.
  let cleanup_needed = self.richtext_needs_cleanup()
  self.drop_markers_of_changed_types()
  let before = self.txn_before.copy()
  let ds = self.txn_ds
  ds.sort_and_merge()
  self.end_transaction(false)
  if cleanup_needed {
    self.richtext_cleanup(before, ds)
  }
}

///|
fn parent_ref(t : YType) -> @update.ParentRef {
  match t.item {
    Some(pi) => Item(pi.id)
    None => Root(t.root_name.unwrap())
  }
}

///|
fn to_struct_ref(s : Struct) -> @update.StructRef {
  match s {
    GC(g) => GC(g.id, g.length)
    Item(item) => {
      let parent = if item.origin is None && item.right_origin is None {
        Some(parent_ref(item.parent))
      } else {
        None
      }
      Item({
        id: item.id,
        origin: item.origin,
        right_origin: item.right_origin,
        parent,
        has_parent_sub: item.parent_sub is Some(_),
        parent_sub: item.parent_sub,
        content: item.content,
      })
    }
  }
}

///|
/// The stored structs of `client` from clock `from` on, the first one sliced
/// so that it starts exactly at `from`.
fn Doc::structs_from(
  self : Doc,
  client : UInt32,
  from : Int32,
) -> Array[@update.StructRef] {
  let stored = self.structs_of(client)
  let out = []
  for i in find_index(stored, from)..<stored.length() {
    let s = to_struct_ref(stored[i])
    let clock = s.id().clock
    out.push(if clock < from { s.slice(from - clock) } else { s })
  }
  out
}

///|
/// The delete set of the whole store: every deleted item and GC range.
fn Doc::store_delete_set(self : Doc) -> @update.DeleteSet {
  let ds = @update.DeleteSet::new()
  for client, structs in self.clients {
    for s in structs {
      if s.deleted() {
        ds.add(client, s.id().clock, s.length())
      }
    }
  }
  ds
}

///|
/// Encodes everything the document knows that is not covered by `sv`
/// (client -> clock already known by the receiver). Pending structs and
/// deletions are included, like Yjs does, so a relay never loses data.
pub fn Doc::encode_state_as_update(
  self : Doc,
  sv~ : Map[UInt32, Int32] = Map([]),
) -> Bytes {
  self.state_as_update(sv).encode()
}

///|
/// `Y.encodeStateAsUpdateV2`: the same content in update format v2.
pub fn Doc::encode_state_as_update_v2(
  self : Doc,
  sv~ : Map[UInt32, Int32] = Map([]),
) -> Bytes {
  self.state_as_update(sv).encode_v2()
}

///|
fn Doc::state_as_update(self : Doc, sv : Map[UInt32, Int32]) -> @update.Update {
  let ids = @hashset.HashSet([])
  for client, _ in self.clients {
    if self.get_state(client) > sv.get(client).unwrap_or(0) {
      ids.add(client)
    }
  }
  for client, _ in self.pending_structs {
    ids.add(client)
  }
  let client_ids = ids.iter().to_array()
  client_ids.sort_by((a, b) => b.compare(a))
  let out = []
  for client in client_ids {
    let from = sv.get(client).unwrap_or(0)
    let structs : Array[@update.StructRef] = []
    let mut cursor = from
    if self.get_state(client) > from {
      structs.append(self.structs_from(client, from))
      cursor = self.get_state(client)
    }
    if self.pending_structs.get(client) is Some(pending) {
      for p in pending {
        let clock = p.id().clock
        let end = clock + p.length()
        if end <= cursor {
          continue
        }
        if clock > cursor {
          if structs.length() > 0 {
            structs.push(Skip(@update.ID::new(client, cursor), clock - cursor))
          }
          structs.push(p)
        } else {
          structs.push(if clock < cursor { p.slice(cursor - clock) } else { p })
        }
        cursor = end
      }
    }
    if structs.length() > 0 {
      out.push(@update.ClientStructs::{ client, structs, })
    }
  }
  let ds = self.store_delete_set()
  for client, ranges in self.pending_ds.clients {
    for r in ranges {
      ds.add(client, r.clock, r.len)
    }
  }
  ds.sort_and_merge()
  let update = @update.Update::new(out, ds)
  // With pending data Yjs merges the encoded state with it, and merging reads
  // every struct again: the bit "this map entry has a key" is gone afterwards
  if self.has_pending() {
    update.normalized()
  } else {
    update
  }
}

///|
/// Encodes the document's state vector (`Y.encodeStateVector`).
pub fn Doc::encode_state_vector(self : Doc) -> Bytes {
  @update.encode_state_vector(self.state_vector())
}

///|
/// Inserts new local content between `left` and `right` in `parent` (or as
/// the new value of `parent_sub` for map entries) and returns the new item.
/// Used by the typed APIs; call `commit` when the operation is complete.
pub fn Doc::insert(
  self : Doc,
  parent : YType,
  left : Item?,
  right : Item?,
  parent_sub : String?,
  content : @update.Content,
) -> Item {
  let item : Item = {
    id: @update.ID::new(self.client_id, self.get_state(self.client_id)),
    length: content.length(),
    origin: left.map(l => l.last_id()),
    right_origin: right.map(r => r.id),
    left,
    right,
    parent,
    parent_sub,
    content,
    deleted: false,
    nested: None,
    marked: false,
  }
  self.integrate_item(item)
  item
}

///|
/// Finishes a local operation: merges adjacent structs and emits the update
/// event, like the end of a Yjs transaction.
pub fn Doc::commit(self : Doc) -> Unit {
  self.end_transaction(true)
}

///|
/// Registers `f` to receive the v1 update of every transaction that changed
/// the document (like `doc.on("update")` in Yjs). The flag is true for local
/// changes and false for changes caused by `apply_update`. The update only
/// contains the transaction's own structs and deletions.
pub fn Doc::on_update(self : Doc, f : (Bytes, Bool) -> Unit) -> Unit {
  self.listeners.push(f)
}

///|
/// Like `on_update`, with the update in format v2 (`doc.on("updateV2")`).
pub fn Doc::on_update_v2(self : Doc, f : (Bytes, Bool) -> Unit) -> Unit {
  self.listeners_v2.push(f)
}

///|
fn Doc::end_transaction(self : Doc, is_local : Bool) -> Unit {
  self.cleanup()
  if (self.listeners.length() > 0 || self.listeners_v2.length() > 0) &&
    (self.txn_before.length() > 0 || !self.txn_ds.is_empty()) {
    let clients = self.txn_before.keys().to_array()
    clients.sort_by((a, b) => b.compare(a))
    let out = clients.map(client => @update.ClientStructs::{
      client,
      structs: self.structs_from(client, self.txn_before.get(client).unwrap()),
    })
    self.txn_ds.sort_and_merge()
    let update = @update.Update::new(out, self.txn_ds)
    if self.listeners.length() > 0 {
      let bytes = update.encode()
      for f in self.listeners {
        f(bytes, is_local)
      }
    }
    if self.listeners_v2.length() > 0 {
      let bytes = update.encode_v2()
      for f in self.listeners_v2 {
        f(bytes, is_local)
      }
    }
  }
  self.txn_before.clear()
  self.txn_ds = @update.DeleteSet::new()
  self.txn_changed.clear()
}

///|
/// Applies `update` (raising on malformed input) — function form of
/// `Doc::apply_update`.
pub fn apply_update(doc : Doc, update : Bytes) -> Unit raise @lib0.DecodeError {
  doc.apply_update(update)
}

///|
/// `Y.encodeStateAsUpdate(doc, encodedTargetStateVector?)`: the target state
/// vector is given in its encoded form.
pub fn encode_state_as_update(
  doc : Doc,
  target_state_vector? : Bytes,
) -> Bytes raise @lib0.DecodeError {
  match target_state_vector {
    Some(sv) => doc.encode_state_as_update(sv=@update.decode_state_vector(sv))
    None => doc.encode_state_as_update()
  }
}

///|
/// `Y.applyUpdateV2(doc, update)`.
pub fn apply_update_v2(
  doc : Doc,
  update : Bytes,
) -> Unit raise @lib0.DecodeError {
  doc.apply_update_v2(update)
}

///|
/// `Y.encodeStateAsUpdateV2(doc, encodedTargetStateVector?)`.
pub fn encode_state_as_update_v2(
  doc : Doc,
  target_state_vector? : Bytes,
) -> Bytes raise @lib0.DecodeError {
  match target_state_vector {
    Some(sv) =>
      doc.encode_state_as_update_v2(sv=@update.decode_state_vector(sv))
    None => doc.encode_state_as_update_v2()
  }
}

///|
/// `Y.encodeStateVector(doc)`.
pub fn encode_state_vector(doc : Doc) -> Bytes {
  doc.encode_state_vector()
}
