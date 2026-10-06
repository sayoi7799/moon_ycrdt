///|
/// Encodes a state vector (client -> next expected clock), clients in
/// descending order like `Y.encodeStateVector`.
pub fn encode_state_vector(sv : Map[UInt, Int]) -> Bytes {
  let e = @lib0.Encoder::new()
  let clients = sv.keys().to_array()
  clients.sort_by((a, b) => b.compare(a))
  e.write_var_uint(clients.length())
  for client in clients {
    e.write_var_uint32(client)
    e.write_var_uint(sv.get(client).unwrap())
  }
  e.to_bytes()
}

///|
pub fn decode_state_vector(
  data : Bytes,
) -> Map[UInt, Int] raise @lib0.DecodeError {
  let d = @lib0.Decoder::new(data)
  let n = d.read_var_uint()
  let sv = Map([])
  for _ in 0..<n {
    let client = d.read_var_uint32()
    sv[client] = d.read_var_uint()
  }
  sv
}
