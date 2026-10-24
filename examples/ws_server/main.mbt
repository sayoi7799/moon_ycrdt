// A y-websocket compatible server written with moon_ycrdt.
//
//   moon run --target native . -- [--host 127.0.0.1] [--port 1234]
//
// Clients connect to `ws://host:port/<room>` (the URL scheme of the official
// y-websocket client). Every room is a `Doc`; the server answers the sync
// handshake and forwards updates to the other connections of the room.

///|
/// The path of a websocket request is the room name: `/my-room?x=1` is the
/// room `my-room`, and the empty path is the room `default`.
fn room_name(path : String) -> String {
  let path = match path.find("?") {
    Some(i) => path.view(end_offset=i).to_owned()
    None => path
  }
  let name = if path.has_prefix("/") {
    path.view(start_offset=1).to_owned()
  } else {
    path
  }
  if name.is_empty() {
    "default"
  } else {
    name
  }
}

///|
/// Serves one websocket connection until the client goes away.
async fn serve_connection(
  rooms : Rooms,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let addr = conn.client_addr()
  let ws = @websocket.from_http_server(request, conn) catch {
    e => {
      println("\{addr}: not a websocket handshake (\{e})")
      return
    }
  }
  defer ws.close()
  let room = rooms.get_or_create(room_name(request.path))
  let peer = Peer::new()
  room.join(peer)
  println("\{addr} joined room \{room.name} (\{room.peers.length()} connected)")
  defer {
    room.leave(peer)
    println("\{addr} left room \{room.name} (\{room.peers.length()} connected)")
  }
  @async.with_task_group(group => {
    // the writer is the only task that sends on this socket
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        ws.send_binary(peer.queue.get())
      }
    })
    // y-websocket: the server opens with its own state vector
    peer.send(@protocol.Sync(@protocol.sync_step1(room.doc)).encode())
    try {
      for ;; {
        let msg = ws.recv()
        match msg.kind {
          Binary =>
            room.handle_frame(peer, msg.read_all().binary()) catch {
              e => println("\{addr}: bad frame (\{e})")
            }
          Text => ()
        }
      }
    } catch {
      @websocket.ConnectionClosed(_, _) => ()
      e => println("\{addr}: \{e}")
    }
  })
}

///|
async fn main {
  let mut host = "127.0.0.1"
  let mut port = 1234
  let args = @env.args()
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "--host" if i + 1 < args.length() => {
        host = args[i + 1]
        i += 2
      }
      "--port" if i + 1 < args.length() => {
        port = @string.parse_int(args[i + 1]) catch {
          _ => {
            println("invalid port \{args[i + 1]}")
            return
          }
        }
        i += 2
      }
      arg => {
        println("unknown argument \{arg}; usage: [--host H] [--port P]")
        return
      }
    }
  }
  let rooms = Rooms::new()
  let server = @http.Server(@socket.Addr::parse("\{host}:\{port}"))
  println("y-websocket server listening on ws://\{host}:\{port}")
  server.run_forever(allow_failure=true, (request, _, conn) => {
    serve_connection(rooms, request, conn)
  })
}
