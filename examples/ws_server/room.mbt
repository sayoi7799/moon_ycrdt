// Rooms and connections of the y-websocket server.
//
// Every room is one `Doc`. A connection (`Peer`) owns an outgoing queue that a
// writer task drains, so that frames from several rooms' broadcasts never
// interleave on the same socket.

///|
/// One connected websocket client.
struct Peer {
  queue : @aqueue.Queue[Bytes]
}

///|
fn Peer::new() -> Peer {
  { queue: @aqueue.Queue(kind=Unbounded), }
}

///|
/// Queues a frame for the writer task of this connection.
fn Peer::send(self : Peer, frame : Bytes) -> Unit {
  // an error means the connection is closing: nobody is left to read the frame
  try self.queue.try_put(frame) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
struct Room {
  name : String
  doc : @doc.Doc
  peers : Array[Peer]
  /// The connection whose frame is being applied right now. Its update is
  /// not echoed back to it.
  mut origin : Peer?
}

///|
fn Room::new(name : String) -> Room {
  let room = { name, doc: @doc.Doc::new(0), peers: [], origin: None, }
  // every applied update goes to the other connections of the room
  room.doc.on_update((update, _) => {
    let frame = @protocol.Sync(@protocol.update_message(update)).encode()
    room.broadcast(frame)
  })
  room
}

///|
/// Sends `frame` to every connection of the room except the one whose
/// message is being handled.
fn Room::broadcast(self : Room, frame : Bytes) -> Unit {
  for peer in self.peers {
    let is_origin = match self.origin {
      Some(o) => physical_equal(o, peer)
      None => false
    }
    if !is_origin {
      peer.send(frame)
    }
  }
}

///|
fn Room::join(self : Room, peer : Peer) -> Unit {
  self.peers.push(peer)
}

///|
fn Room::leave(self : Room, peer : Peer) -> Unit {
  self.peers.retain(p => !physical_equal(p, peer))
}

///|
/// Handles one binary frame from `peer` (y-websocket's `messageListener`).
///
/// - SyncStep1 is answered with SyncStep2 to the sender only;
/// - SyncStep2 and Update are applied, and `Doc::on_update` forwards the
///   resulting update to the other connections;
/// - every other message kind (awareness, ...) is relayed untouched.
fn Room::handle_frame(
  self : Room,
  peer : Peer,
  frame : Bytes,
) -> Unit raise @lib0.DecodeError {
  match @protocol.decode_ws_message(frame) {
    Sync(message) => {
      self.origin = Some(peer)
      defer {
        self.origin = None
      }
      if @protocol.handle_sync_message(self.doc, message) is Some(reply) {
        peer.send(@protocol.Sync(reply).encode())
      }
    }
    Other(kind, _) =>
      if kind == @protocol.MESSAGE_AWARENESS {
        self.origin = Some(peer)
        defer {
          self.origin = None
        }
        self.broadcast(frame)
      }
  }
}

///|
/// All rooms of the server, created on first use.
struct Rooms {
  rooms : Map[String, Room]
}

///|
fn Rooms::new() -> Rooms {
  { rooms: {}, }
}

///|
fn Rooms::get_or_create(self : Rooms, name : String) -> Room {
  match self.rooms.get(name) {
    Some(room) => room
    None => {
      let room = Room::new(name)
      self.rooms[name] = room
      room
    }
  }
}
