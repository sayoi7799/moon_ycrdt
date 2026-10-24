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
/// Longer room names would not fit into a file name (see `file_name`).
const MAX_ROOM_NAME : Int32 = 40

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
  let name = room_name(request.path)
  if name.length() > MAX_ROOM_NAME {
    ws.send_close(code=PolicyViolation, reason="room name is too long") catch {
      _ => ()
    }
    return
  }
  let room = rooms.get_or_create(name) catch {
    e => {
      println("\{addr}: cannot open room \{name} (\{e})")
      ws.send_close(code=InternalError, reason="cannot open the room") catch {
        _ => ()
      }
      return
    }
  }
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
const USAGE : String = "usage: [--host H] [--port P] [--data DIR] [--save-interval SECONDS]"

///|
async fn main {
  let mut host = "127.0.0.1"
  let mut port = 1234
  let mut data = "data"
  let mut save_interval = 2
  let args = @env.args()
  let mut i = 1
  while i < args.length() {
    guard i + 1 < args.length() else {
      println("\{args[i]} needs a value; \{USAGE}")
      return
    }
    let value = args[i + 1]
    match args[i] {
      "--host" => host = value
      "--data" => data = value
      "--port" | "--save-interval" => {
        let n = @string.parse_int(value) catch {
          _ => {
            println("\{args[i]}: \{value} is not a number; \{USAGE}")
            return
          }
        }
        if args[i] == "--port" {
          port = n
        } else {
          save_interval = n
        }
      }
      arg => {
        println("unknown argument \{arg}; \{USAGE}")
        return
      }
    }
    i += 2
  }
  let store = Store::{ dir: data, }
  store.init()
  let rooms = Rooms::new(store)
  let server = @http.Server(@socket.Addr::parse("\{host}:\{port}"))
  println(
    "y-websocket server listening on ws://\{host}:\{port}, data in \{data}",
  )
  @async.with_task_group(group => {
    // when the server stops (Ctrl-C), save what has not been saved yet
    group.add_defer(() => @async.protect_from_cancel(() => rooms.save_dirty()))
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        @async.sleep(save_interval * 1000)
        rooms.save_dirty()
      }
    })
    server.run_forever(allow_failure=true, (request, _, conn) => {
      serve_connection(rooms, request, conn)
    })
  })
}
