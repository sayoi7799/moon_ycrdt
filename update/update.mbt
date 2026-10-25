// Yjs update format v1:
//
//   update     = structs delete_set
//   structs    = varUint(#clients) { varUint(#structs) varUint(client)
//                varUint(first clock) struct* }
//   delete_set = varUint(#clients) { varUint(client) varUint(#ranges)
//                { varUint(clock) varUint(len) }* }

///|
/// All structs of one client in an update, with consecutive clocks.
pub(all) struct ClientStructs {
  client : UInt32
  structs : Array[StructRef]
} derive(Eq, Debug)

///|
pub extend ClientStructs with Eq::{equal, not_equal}

///|
/// A decoded update. Clients are kept in wire order so that re-encoding a
/// decoded update reproduces the input bytes.
pub struct Update {
  clients : Array[ClientStructs]
  delete_set : DeleteSet
} derive(Eq, Debug)

///|
pub extend Update with Eq::{equal, not_equal}

///|
pub fn Update::new(
  clients : Array[ClientStructs],
  delete_set : DeleteSet,
) -> Update {
  { clients, delete_set, }
}

///|
/// Decodes an update of format v1.
pub fn decode_update(data : Bytes) -> Update raise @lib0.DecodeError {
  decode_update_in(V1, data)
}

///|
/// Decodes an update of format v2 (what `Y.applyUpdateV2` reads).
pub fn decode_update_v2(data : Bytes) -> Update raise @lib0.DecodeError {
  decode_update_in(V2, data)
}

///|
fn decode_update_in(
  format : UpdateFormat,
  data : Bytes,
) -> Update raise @lib0.DecodeError {
  let d = UpdateDecoder::new(format, data)
  let num_clients = d.rest.read_var_uint()
  let clients = []
  for _ in 0..<num_clients {
    let num_structs = d.rest.read_var_uint()
    let client = d.read_client()
    let mut clock = d.rest.read_var_uint()
    let structs = []
    for _ in 0..<num_structs {
      let s = read_struct(d, ID::new(client, clock))
      clock += s.length()
      structs.push(s)
    }
    clients.push({ client, structs, })
  }
  let delete_set = read_delete_set(d)
  // Yjs ignores trailing bytes as well, so they are not an error here.
  { clients, delete_set, }
}

///|
/// Encodes the update in format v1; clients are written in the stored order.
pub fn Update::encode(self : Update) -> Bytes {
  self.encode_in(V1)
}

///|
/// Encodes the update in format v2.
pub fn Update::encode_v2(self : Update) -> Bytes {
  self.encode_in(V2)
}

///|
fn Update::encode_in(self : Update, format : UpdateFormat) -> Bytes {
  let e = UpdateEncoder::new(format)
  e.rest.write_var_uint(self.clients.length())
  for cs in self.clients {
    e.rest.write_var_uint(cs.structs.length())
    e.write_client(cs.client)
    e.rest.write_var_uint(
      match cs.structs {
        [first, ..] => first.id().clock
        [] => 0
      },
    )
    for s in cs.structs {
      s.write(e, 0)
    }
  }
  self.delete_set.write(e)
  e.to_bytes()
}

///|
/// The state vector of an update, like `Y.encodeStateVectorFromUpdate`: for
/// every client, the end of the contiguous run of structs starting at clock 0
/// and stopping at the first Skip. Clients not starting at 0 are left out.
pub fn Update::state_vector(self : Update) -> Map[UInt32, Int32] {
  let sv = Map([])
  for cs in self.clients {
    let mut clock = 0
    for s in cs.structs {
      if s is Skip(_, _) || s.id().clock != clock {
        break
      }
      clock = s.id().clock + s.length()
    }
    if clock > 0 {
      sv[cs.client] = clock
    }
  }
  sv
}
