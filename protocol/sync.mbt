// y-protocols sync messages (y-protocols/sync.js) and the y-websocket message
// envelope.
//
// The sync protocol is a two-step handshake plus incremental updates:
//   client -> server  SyncStep1(state vector of the client)
//   server -> client  SyncStep2(what the client is missing)
//   (and the same in the other direction)
//   either side       Update(incremental update), whenever the document changes
//
// Wire format: varUint(message type) followed by varUint8Array(payload).

///|
pub const MESSAGE_SYNC_STEP1 : Int = 0

///|
pub const MESSAGE_SYNC_STEP2 : Int = 1

///|
pub const MESSAGE_UPDATE : Int = 2

///|
pub(all) enum SyncMessage {
  /// Encoded state vector of the sender.
  SyncStep1(Bytes)
  /// v1 update with everything the receiver of SyncStep1 is missing.
  SyncStep2(Bytes)
  /// v1 incremental update.
  Update(Bytes)
} derive(Eq, Debug)

///|
pub extend SyncMessage with Eq::{equal, not_equal}

///|
pub fn SyncMessage::message_type(self : SyncMessage) -> Int {
  match self {
    SyncStep1(_) => MESSAGE_SYNC_STEP1
    SyncStep2(_) => MESSAGE_SYNC_STEP2
    Update(_) => MESSAGE_UPDATE
  }
}

///|
pub fn SyncMessage::write(self : SyncMessage, e : @lib0.Encoder) -> Unit {
  e.write_var_uint(self.message_type())
  match self {
    SyncStep1(b) | SyncStep2(b) | Update(b) => e.write_var_bytes(b)
  }
}

///|
pub fn SyncMessage::encode(self : SyncMessage) -> Bytes {
  let e = @lib0.Encoder::new()
  self.write(e)
  e.to_bytes()
}

///|
pub fn read_sync_message(
  d : @lib0.Decoder,
) -> SyncMessage raise @lib0.DecodeError {
  let message_type = d.read_var_uint()
  let payload = d.read_var_bytes()
  match message_type {
    MESSAGE_SYNC_STEP1 => SyncStep1(payload)
    MESSAGE_SYNC_STEP2 => SyncStep2(payload)
    MESSAGE_UPDATE => Update(payload)
    t => raise @lib0.Malformed("unknown sync message type \{t}")
  }
}

///|
pub fn decode_sync_message(data : Bytes) -> SyncMessage raise @lib0.DecodeError {
  read_sync_message(@lib0.Decoder::new(data))
}

///|
/// The first handshake message: our state vector (`writeSyncStep1`).
pub fn sync_step1(doc : @doc.Doc) -> SyncMessage {
  SyncStep1(doc.encode_state_vector())
}

///|
/// Everything that a peer with the encoded state vector `sv` is missing
/// (`writeSyncStep2`).
pub fn sync_step2(
  doc : @doc.Doc,
  sv : Bytes,
) -> SyncMessage raise @lib0.DecodeError {
  SyncStep2(@doc.encode_state_as_update(doc, target_state_vector=sv))
}

///|
/// Wraps an update produced by `Doc::on_update` (`writeUpdate`).
pub fn update_message(update : Bytes) -> SyncMessage {
  Update(update)
}

///|
/// Handles a received sync message (`readSyncMessage`): answers SyncStep1
/// with the matching SyncStep2 and applies SyncStep2 / Update to `doc`.
/// Returns the reply to send back, if any. Unlike y-protocols, a malformed
/// update raises instead of being logged.
pub fn handle_sync_message(
  doc : @doc.Doc,
  message : SyncMessage,
) -> SyncMessage? raise @lib0.DecodeError {
  match message {
    SyncStep1(sv) => Some(sync_step2(doc, sv))
    SyncStep2(update) | Update(update) => {
      doc.apply_update(update)
      None
    }
  }
}
