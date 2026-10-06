///|
/// A deleted clock range `[clock, clock + len)`.
pub(all) struct DeleteRange {
  clock : Int
  len : Int
} derive(Eq, Debug)

///|
pub extend DeleteRange with Eq::{equal, not_equal}

///|
/// Deleted ranges per client. Deletions are not tracked by clocks of their
/// own, so every update carries the set of ranges it deletes.
pub struct DeleteSet {
  clients : Map[UInt, Array[DeleteRange]]
} derive(Eq, Debug)

///|
pub extend DeleteSet with Eq::{equal, not_equal}

///|
pub fn DeleteSet::new() -> DeleteSet {
  { clients: {}, }
}

///|
pub fn DeleteSet::is_empty(self : DeleteSet) -> Bool {
  self.clients.is_empty()
}

///|
pub fn DeleteSet::add(
  self : DeleteSet,
  client : UInt,
  clock : Int,
  len : Int,
) -> Unit {
  guard len > 0 else { return }
  match self.clients.get(client) {
    Some(ranges) => ranges.push({ clock, len, })
    None => self.clients[client] = [{ clock, len, }]
  }
}

///|
/// Sorts each client's ranges by clock and merges overlapping or adjacent
/// ones (`sortAndMergeDeleteSet`).
pub fn DeleteSet::sort_and_merge(self : DeleteSet) -> Unit {
  for _, ranges in self.clients {
    ranges.sort_by((a, b) => a.clock.compare(b.clock))
    let merged : Array[DeleteRange] = []
    for r in ranges {
      if merged.last() is Some(last) && last.clock + last.len >= r.clock {
        let end = @cmp.maximum(last.clock + last.len, r.clock + r.len)
        merged[merged.length() - 1] = {
          clock: last.clock,
          len: end - last.clock,
        }
      } else {
        merged.push(r)
      }
    }
    ranges.clear()
    ranges.append(merged)
  }
}

///|
pub fn DeleteSet::contains(self : DeleteSet, id : ID) -> Bool {
  match self.clients.get(id.client) {
    Some(ranges) =>
      ranges.iter().any(r => r.clock <= id.clock && id.clock < r.clock + r.len)
    None => false
  }
}

///|
/// Writes clients in descending order, like Yjs.
pub fn DeleteSet::write(self : DeleteSet, e : @lib0.Encoder) -> Unit {
  let clients = self.clients.keys().to_array()
  clients.sort_by((a, b) => b.compare(a))
  e.write_var_uint(clients.length())
  for client in clients {
    let ranges = self.clients.get(client).unwrap()
    e.write_var_uint32(client)
    e.write_var_uint(ranges.length())
    for r in ranges {
      e.write_var_uint(r.clock)
      e.write_var_uint(r.len)
    }
  }
}

///|
pub fn read_delete_set(d : @lib0.Decoder) -> DeleteSet raise @lib0.DecodeError {
  let ds = DeleteSet::new()
  let num_clients = d.read_var_uint()
  for _ in 0..<num_clients {
    let client = d.read_var_uint32()
    let num_ranges = d.read_var_uint()
    let ranges = []
    for _ in 0..<num_ranges {
      let clock = d.read_var_uint()
      let len = d.read_var_uint()
      ranges.push({ clock, len, })
    }
    ds.clients[client] = ranges
  }
  ds
}
