// The code shown in README.md, kept here so that it always compiles and runs.

///|
test "README: quick start" {
  // two replicas, each with its own 32-bit client id
  let alice = @doc.Doc::new(1001)
  let bob = @doc.Doc::new(2002)

  // every local transaction produces a Yjs v1 update, like doc.on('update')
  let outbox : Array[Bytes] = []
  alice.on_update((update, is_local) => if is_local { outbox.push(update) })

  let text = @types.Text::new(alice, "doc")
  text.insert(0, "Hello world")
  text.delete(5, 6)
  @types.YMap::new(alice, "settings").set("theme", String("dark"))
  @types.YArray::new(alice, "list").push([@lib0.Any::int(1), String("two")])

  // apply updates from MoonBit or Yjs; missing dependencies wait in a queue
  for update in outbox {
    bob.apply_update(update)
  }
  assert_eq(@types.Text::new(bob, "doc").to_string(), "Hello")
  assert_eq(
    @types.YMap::new(bob, "settings").get("theme"),
    Some(String("dark")),
  )
  assert_eq(@types.YArray::new(bob, "list").length(), 2)

  // state-vector sync: send only what the other side is missing
  let diff = @doc.encode_state_as_update(
    alice,
    target_state_vector=bob.encode_state_vector(),
  )
  bob.apply_update(diff)
  assert_true(!bob.has_pending())
}

///|
test "README: talking to a y-websocket peer" {
  // `server` stands in for the other end of the websocket
  let server = @doc.Doc::new(1)
  @types.Text::new(server, "doc").insert(0, "from the server")
  let to_server : Array[Bytes] = []
  let to_client : Array[Bytes] = []
  let doc = @doc.Doc::new(42)

  // 1. on connect, send SyncStep1 (our state vector)
  to_server.push(@protocol.Sync(@protocol.sync_step1(doc)).encode())
  // 2. broadcast every local change as an Update message
  doc.on_update((update, is_local) => {
    if is_local {
      to_server.push(@protocol.Sync(@protocol.update_message(update)).encode())
    }
  })
  // the server answers SyncStep1 with SyncStep2 and sends its own SyncStep1
  for frame in to_server {
    if @protocol.handle_ws_message(server, frame) is Some(reply) {
      to_client.push(reply)
    }
  }
  to_server.clear()
  to_client.push(@protocol.Sync(@protocol.sync_step1(server)).encode())
  // 3. handle every received frame; send back the reply, if any
  for frame in to_client {
    if @protocol.handle_ws_message(doc, frame) is Some(reply) {
      to_server.push(reply)
    }
  }
  assert_eq(@types.Text::new(doc, "doc").to_string(), "from the server")
  @types.Text::new(doc, "doc").insert(0, "> ")
  for frame in to_server {
    @protocol.handle_ws_message(server, frame) |> ignore
  }
  assert_eq(@types.Text::new(server, "doc").to_string(), "> from the server")
}

///|
test "README: rich text" {
  let doc = @doc.Doc::new(1)
  let text = @types.Text::new(doc, "doc")
  text.insert(0, "Hello world")
  // format a range, insert with exactly the given formatting
  text.format(0, 5, [("bold", Bool(true))])
  text.insert_with_attributes(11, "!", [("italic", Bool(true))])
  // a Quill-style delta: skip 6 positions, then insert coloured text
  text.apply_delta([
    Retain(6, []),
    Insert(String("brave "), [("color", String("red"))]),
  ])
  // read the formatted text back, as a delta and as JSON
  let delta = text.to_delta()
  assert_eq(delta.length(), 5)
  assert_eq(@types.delta_to_json(delta).stringify(), readme_rich_delta)
  // and a delta from JSON (for example from a ProseMirror / Quill binding)
  let parsed = @types.delta_from_json(@json.parse(readme_rich_delta))
  assert_eq(parsed, delta)
}

///|
test "README: update format v2 and updates without a document" {
  let alice = @doc.Doc::new(1)
  let updates : Array[Bytes] = []
  alice.on_update((update, is_local) => if is_local { updates.push(update) })
  let text = @types.Text::new(alice, "doc")
  text.insert(0, "Hello")
  text.insert(5, " world")
  text.delete(0, 1)

  // the whole state in format v2, like Y.encodeStateAsUpdateV2
  let v2 = alice.encode_state_as_update_v2()
  let bob = @doc.Doc::new(2)
  bob.apply_update_v2(v2)
  assert_eq(@types.Text::new(bob, "doc").to_string(), "ello world")

  // work on updates as bytes: no document is needed
  let merged = @update.merge_updates(updates)
  let sv = @update.encode_state_vector_from_update(merged)
  let missing = @update.diff_update(merged, bob.encode_state_vector())
  let carol = @doc.Doc::new(3)
  carol.apply_update(merged)
  assert_eq(@types.Text::new(carol, "doc").to_string(), "ello world")
  assert_eq(sv, carol.encode_state_vector())
  // bob has every struct already: only the delete set is left
  assert_eq(@update.decode_update(missing).clients.length(), 0)
}
