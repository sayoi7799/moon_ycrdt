// Working on updates without loading a document (yjs/src/utils/updates.js):
// `mergeUpdates`, `diffUpdate` and `encodeStateVectorFromUpdate`, each for
// format v1 and v2. They read the structs of an update, the way Yjs does
// (`LazyStructReader`: a map entry's "has a key" bit is forgotten, see
// `StructRef::normalized`), and write them again (`LazyStructWriter`), so the
// bytes follow what Yjs writes, down to which structs get sliced or joined.

///|
/// The structs of one update in the order they appear: a client's structs
/// from the first to the last, then the next client (`LazyStructReader`).
priv struct StructReader {
  structs : Array[StructRef]
  mut pos : Int32
}

///|
fn StructReader::new(update : Update, filter_skips : Bool) -> StructReader {
  let structs = []
  for cs in update.normalized().clients {
    for s in cs.structs {
      if !(filter_skips && s is Skip(_, _)) {
        structs.push(s)
      }
    }
  }
  { structs, pos: 0, }
}

///|
fn StructReader::curr(self : StructReader) -> StructRef? {
  if self.pos < self.structs.length() {
    Some(self.structs[self.pos])
  } else {
    None
  }
}

///|
fn StructReader::next(self : StructReader) -> StructRef? {
  self.pos += 1
  self.curr()
}

///|
/// Writes structs client by client and counts how many it wrote for each, so
/// that the numbers can go in front of them when everything is known
/// (`LazyStructWriter`).
priv struct StructWriter {
  enc : UpdateEncoder
  mut written : Int32
  mut client : UInt32
  /// For every finished client: the structs written and the bytes after the
  /// count (the client id in v1, the start clock and the structs).
  parts : Array[(Int32, Bytes)]
}

///|
fn StructWriter::new(enc : UpdateEncoder) -> StructWriter {
  { enc, written: 0, client: 0U, parts: [], }
}

///|
fn StructWriter::flush(self : StructWriter) -> Unit {
  if self.written > 0 {
    self.parts.push((self.written, self.enc.rest.to_bytes()))
    self.enc.rest = @lib0.Encoder::new()
    self.written = 0
  }
}

///|
/// Writes `s` without its first `offset` clocks.
fn StructWriter::write(
  self : StructWriter,
  s : StructRef,
  offset : Int32,
) -> Unit {
  let id = s.id()
  if self.written > 0 && self.client != id.client {
    self.flush()
  }
  if self.written == 0 {
    self.client = id.client
    self.enc.write_client(id.client)
    self.enc.rest.write_var_uint(id.clock + offset)
  }
  s.write(self.enc, offset)
  self.written += 1
}

///|
/// Writes the number of clients and, per client, the number of structs and
/// the structs themselves.
fn StructWriter::finish(self : StructWriter) -> Unit {
  self.flush()
  let rest = self.enc.rest
  rest.write_var_uint(self.parts.length())
  for part in self.parts {
    let (written, bytes) = part
    rest.write_var_uint(written)
    rest.write_raw_bytes(bytes)
  }
}

// ---------------------------------------------------------------------------
// encodeStateVectorFromUpdate

///|
/// The state vector that an update alone leads to (`Y.encodeStateVectorFromUpdate`):
/// for every run of structs of one client that starts at clock 0, how far it
/// reaches without a gap. Clients are written in the order they appear.
pub fn encode_state_vector_from_update(
  update : Bytes,
) -> Bytes raise @lib0.DecodeError {
  state_vector_in(V1, update)
}

///|
/// The same for an update in format v2.
pub fn encode_state_vector_from_update_v2(
  update : Bytes,
) -> Bytes raise @lib0.DecodeError {
  state_vector_in(V2, update)
}

///|
fn state_vector_in(
  format : UpdateFormat,
  data : Bytes,
) -> Bytes raise @lib0.DecodeError {
  let reader = StructReader::new(decode_update_in(format, data), false)
  let out = @lib0.Encoder::new()
  let body = @lib0.Encoder::new()
  let mut size = 0
  if reader.curr() is Some(first) {
    let mut curr_client = first.id().client
    // a client that does not start at clock 0 counts for nothing
    let mut stop_counting = first.id().clock != 0
    let mut curr_clock = if stop_counting {
      0
    } else {
      first.id().clock + first.length()
    }
    let mut curr = Some(first)
    while curr is Some(s) {
      if curr_client != s.id().client {
        if curr_clock != 0 {
          size += 1
          body.write_var_uint32(curr_client)
          body.write_var_uint(curr_clock)
        }
        curr_client = s.id().client
        curr_clock = 0
        stop_counting = s.id().clock != 0
      }
      // a gap ends the run
      if s is Skip(_, _) {
        stop_counting = true
      }
      if !stop_counting {
        curr_clock = s.id().clock + s.length()
      }
      curr = reader.next()
    }
    if curr_clock != 0 {
      size += 1
      body.write_var_uint32(curr_client)
      body.write_var_uint(curr_clock)
    }
  }
  out.write_var_uint(size)
  out.write_raw_bytes(body.to_bytes())
  out.to_bytes()
}

// ---------------------------------------------------------------------------
// diffUpdate

///|
/// What an update holds that a peer with state vector `sv` does not have yet
/// (`Y.diffUpdate`). The first struct that is only partly known is written
/// from the first clock that is missing. The delete set is kept as it is.
pub fn diff_update(update : Bytes, sv : Bytes) -> Bytes raise @lib0.DecodeError {
  diff_update_in(V1, update, sv)
}

///|
pub fn diff_update_v2(
  update : Bytes,
  sv : Bytes,
) -> Bytes raise @lib0.DecodeError {
  diff_update_in(V2, update, sv)
}

///|
fn diff_update_in(
  format : UpdateFormat,
  data : Bytes,
  sv : Bytes,
) -> Bytes raise @lib0.DecodeError {
  let state = decode_state_vector(sv)
  let decoded = decode_update_in(format, data)
  let reader = StructReader::new(decoded, false)
  let enc = UpdateEncoder::new(format)
  let writer = StructWriter::new(enc)
  while reader.curr() is Some(curr) {
    let client = curr.id().client
    let sv_clock = state.get(client).unwrap_or(0)
    if curr is Skip(_, _) {
      // the first struct written must not be a skip
      reader.next() |> ignore
      continue
    }
    if curr.id().clock + curr.length() > sv_clock {
      writer.write(curr, @cmp.maximum(sv_clock - curr.id().clock, 0))
      reader.next() |> ignore
      while reader.curr() is Some(rest) && rest.id().client == client {
        writer.write(rest, 0)
        reader.next() |> ignore
      }
    } else {
      // read until something new comes up
      while reader.curr() is Some(rest) &&
            rest.id().client == client &&
            rest.id().clock + rest.length() <= sv_clock {
        reader.next() |> ignore
      }
    }
  }
  writer.finish()
  decoded.delete_set.write(enc)
  enc.to_bytes()
}

// ---------------------------------------------------------------------------
// mergeUpdates

///|
/// Which of two readers goes first: the higher client, then the lower clock
/// (`mergeUpdatesV2`'s sort). Yjs puts a skip behind anything else with the
/// same clock; with skips filtered out that case does not arise.
fn compare_readers(a : StructReader, b : StructReader) -> Int32 {
  let x = a.curr().unwrap()
  let y = b.curr().unwrap()
  if x.id().client == y.id().client {
    let diff = x.id().clock - y.id().clock
    if diff == 0 {
      if (x is Skip(_, _)) == (y is Skip(_, _)) &&
        (x is GC(_, _)) == (y is GC(_, _)) {
        0
      } else if x is Skip(_, _) {
        1
      } else {
        -1
      }
    } else {
      diff
    }
  } else {
    y.id().client.compare(x.id().client)
  }
}

///|
/// A stable insertion sort; the readers are mostly in order already after the
/// first round, and ties must keep their order.
fn sort_readers(readers : Array[StructReader]) -> Unit {
  for i in 1..<readers.length() {
    let item = readers[i]
    let mut j = i
    while j > 0 && compare_readers(readers[j - 1], item) > 0 {
      readers[j] = readers[j - 1]
      j -= 1
    }
    readers[j] = item
  }
}

///|
/// What `mergeWith` does for two structs that follow each other: garbage ranges
/// and skips grow; items read from an update are never joined (their `right`
/// links are empty).
fn merge_structs(left : StructRef, right : StructRef) -> StructRef? {
  match (left, right) {
    (GC(id, a), GC(_, b)) => Some(GC(id, a + b))
    (Skip(id, a), Skip(_, b)) => Some(Skip(id, a + b))
    _ => None
  }
}

///|
/// Merges updates into one (`Y.mergeUpdates`). Overlapping structs are cut so
/// that every clock is written once, a gap between structs of a client is
/// filled with a skip, and the delete sets are united. A single update is
/// returned as it is.
pub fn merge_updates(updates : Array[Bytes]) -> Bytes raise @lib0.DecodeError {
  merge_updates_in(V1, updates)
}

///|
pub fn merge_updates_v2(
  updates : Array[Bytes],
) -> Bytes raise @lib0.DecodeError {
  merge_updates_in(V2, updates)
}

///|
fn merge_updates_in(
  format : UpdateFormat,
  updates : Array[Bytes],
) -> Bytes raise @lib0.DecodeError {
  if updates.length() == 1 {
    return updates[0]
  }
  let decoded : Array[Update] = []
  for u in updates {
    decoded.push(decode_update_in(format, u))
  }
  // the readers keep the order the last sort left them in (ties keep it)
  let mut readers = decoded.map(u => StructReader::new(u, true))
  let enc = UpdateEncoder::new(format)
  let writer = StructWriter::new(enc)
  // the struct that is being built; the next one may still join it
  let mut write : StructRef? = None
  while true {
    readers = readers.filter(r => r.curr() is Some(_))
    sort_readers(readers)
    if readers.length() == 0 {
      break
    }
    let reader = readers[0]
    let first_client = reader.curr().unwrap().id().client
    if write is Some(w) {
      let mut curr = reader.curr()
      let mut iterated = false
      // skip what is written already (the higher clients come first)
      while curr is Some(c) &&
            c.id().clock + c.length() <= w.id().clock + w.length() &&
            c.id().client >= w.id().client {
        curr = reader.next()
        iterated = true
      }
      guard curr is Some(c) &&
        c.id().client == first_client &&
        !(iterated && c.id().clock > w.id().clock + w.length()) else {
        continue
      }
      if first_client != w.id().client {
        writer.write(w, 0)
        write = Some(c)
        reader.next() |> ignore
      } else if w.id().clock + w.length() < c.id().clock {
        // a gap: skip it, or make the skip we have longer
        match w {
          Skip(id, _) =>
            write = Some(Skip(id, c.id().clock + c.length() - id.clock))
          _ => {
            writer.write(w, 0)
            let diff = c.id().clock - w.id().clock - w.length()
            write = Some(
              Skip(ID::new(first_client, w.id().clock + w.length()), diff),
            )
          }
        }
      } else {
        // overlap or neighbours
        let diff = w.id().clock + w.length() - c.id().clock
        let mut cur_w = w
        let mut cur_c = c
        if diff > 0 {
          match w {
            // a skip gives way: the other struct holds more
            Skip(id, len) => cur_w = Skip(id, len - diff)
            _ => cur_c = c.slice(diff)
          }
        }
        match merge_structs(cur_w, cur_c) {
          Some(merged) => write = Some(merged)
          None => {
            writer.write(cur_w, 0)
            write = Some(cur_c)
            reader.next() |> ignore
          }
        }
      }
    } else {
      write = reader.curr()
      reader.next() |> ignore
    }
    // structs that follow without a gap
    let w = write.unwrap()
    let mut last = w
    let mut next = reader.curr()
    while next is Some(n) &&
          n.id().client == first_client &&
          n.id().clock == last.id().clock + last.length() &&
          !(n is Skip(_, _)) {
      writer.write(last, 0)
      last = n
      next = reader.next()
    }
    write = Some(last)
  }
  if write is Some(w) {
    writer.write(w, 0)
  }
  writer.finish()
  // the delete sets, united (`mergeDeleteSets`)
  let merged = DeleteSet::new()
  for i, ds in decoded.map(u => u.delete_set) {
    for client, ranges in ds.clients {
      if !merged.clients.contains(client) {
        let all = ranges.copy()
        for j in (i + 1)..<decoded.length() {
          if decoded[j].delete_set.clients.get(client) is Some(more) {
            all.append(more)
          }
        }
        merged.clients[client] = all
      }
    }
  }
  merged.sort_and_merge()
  merged.write(enc)
  enc.to_bytes()
}
