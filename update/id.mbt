///|
/// Unique id of every inserted element: the creating client plus a per-client
/// logical clock. An item of length n occupies clocks `clock ..< clock + n`.
pub(all) struct ID {
  client : UInt
  clock : Int
} derive(Eq, Hash, Debug)

///|
pub fn ID::new(client : UInt, clock : Int) -> ID {
  { client, clock, }
}

///|
pub impl Show for ID with fn output(self, logger) {
  logger.write_string("\{self.client}:\{self.clock}")
}

///|
pub extend ID with Eq::{equal, not_equal}

///|
pub extend ID with Show::{to_string, output}

///|
pub fn write_id(e : @lib0.Encoder, id : ID) -> Unit {
  e.write_var_uint32(id.client)
  e.write_var_uint(id.clock)
}

///|
pub fn read_id(d : @lib0.Decoder) -> ID raise @lib0.DecodeError {
  let client = d.read_var_uint32()
  let clock = d.read_var_uint()
  { client, clock, }
}
