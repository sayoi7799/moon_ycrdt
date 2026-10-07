// The y-websocket envelope: every websocket frame starts with a varUint
// message kind. Sync messages (kind 0) carry a sync message right after it;
// the other kinds (awareness, auth, query awareness) are passed through
// untouched so that an application can handle or ignore them.

///|
pub const MESSAGE_SYNC : Int = 0

///|
pub const MESSAGE_AWARENESS : Int = 1

///|
pub const MESSAGE_AUTH : Int = 2

///|
pub const MESSAGE_QUERY_AWARENESS : Int = 3

///|
pub(all) enum WsMessage {
  Sync(SyncMessage)
  /// Any other message kind with the rest of the frame as raw bytes.
  Other(Int, Bytes)
} derive(Eq, Debug)

///|
pub extend WsMessage with Eq::{equal, not_equal}

///|
pub fn WsMessage::encode(self : WsMessage) -> Bytes {
  let e = @lib0.Encoder::new()
  match self {
    Sync(m) => {
      e.write_var_uint(MESSAGE_SYNC)
      m.write(e)
    }
    Other(kind, rest) => {
      e.write_var_uint(kind)
      e.write_raw_bytes(rest)
    }
  }
  e.to_bytes()
}

///|
pub fn decode_ws_message(data : Bytes) -> WsMessage raise @lib0.DecodeError {
  let d = @lib0.Decoder::new(data)
  match d.read_var_uint() {
    MESSAGE_SYNC => Sync(read_sync_message(d))
    kind => Other(kind, d.read_raw_bytes(d.remaining()))
  }
}

///|
/// Handles one websocket frame for `doc` and returns the frame to send back,
/// if any. Non-sync frames are ignored.
pub fn handle_ws_message(
  doc : @doc.Doc,
  data : Bytes,
) -> Bytes? raise @lib0.DecodeError {
  match decode_ws_message(data) {
    Sync(m) => handle_sync_message(doc, m).map(reply => Sync(reply).encode())
    Other(_, _) => None
  }
}
