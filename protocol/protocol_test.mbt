// y-protocols sync messages against y-protocols@1.0.7 (protocol_gen_test.mbt).
// MoonBit mirrors replica B of the recorded session (same client id), so each
// message it sends must be byte-identical to the one y-protocols sent.

///|
fn bytes(s : String) -> Bytes {
  @lib0.from_hex(s) catch {
    e => abort(e.to_string())
  }
}

///|
fn hex(b : Bytes) -> String {
  @lib0.to_hex(b)
}

///|
test "sync handshake and updates match y-protocols byte for byte" {
  let b = @doc.Doc::new(b_client)
  let sent : Array[Bytes] = []
  b.on_update((u, is_local) => if is_local { sent.push(u) })
  b.apply_update(bytes(b_initial))

  // our SyncStep1
  assert_eq(hex(@protocol.sync_step1(b).encode()), step1_b)
  // A's SyncStep1 is answered with exactly what y-protocols answers
  let msg = @protocol.decode_sync_message(bytes(step1_a))
  assert_true(msg is SyncStep1(_))
  let reply = @protocol.handle_sync_message(b, msg)
  assert_eq(reply.map(r => hex(r.encode())), Some(reply_b))
  // A's SyncStep2 is applied and produces no reply
  let reply2 = @protocol.handle_sync_message(
    b,
    @protocol.decode_sync_message(bytes(reply_a)),
  )
  assert_true(reply2 is None)
  assert_eq(hex(b.encode_state_as_update()), b_after_sync)
  // a local edit is broadcast as an Update message
  @types.Text::new(b, "t").insert(0, ">> ")
  assert_eq(sent.length(), 1)
  assert_eq(hex(@protocol.update_message(sent[0]).encode()), update_b)
  assert_eq(hex(b.encode_state_as_update()), b_final)

  // the same over the y-websocket envelope
  assert_eq(hex(@protocol.Sync(@protocol.sync_step1(b)).encode()), ws_step1_b)
  assert_eq(
    @protocol.handle_ws_message(b, bytes(ws_step1_a)).map(hex),
    Some(ws_reply_b),
  )
}

///|
test "a Yjs replica's messages bring a MoonBit replica up to date" {
  // replica A's answer to an empty state vector contains all of A
  let fresh = @doc.Doc::new(99)
  @protocol.handle_sync_message(
    fresh,
    @protocol.decode_sync_message(bytes(reply_a)),
  )
  |> ignore
  assert_eq(@types.Text::new(fresh, "t").to_string(), "from A 😀")
  // and B's update message applies on top of the synced state
  let b = @doc.Doc::new(7)
  b.apply_update(bytes(b_after_sync))
  @protocol.handle_sync_message(
    b,
    @protocol.decode_sync_message(bytes(update_b)),
  )
  |> ignore
  assert_eq(hex(b.encode_state_as_update()), b_final)
}

///|
test "two MoonBit replicas converge using only protocol messages" {
  let left = @doc.Doc::new(1)
  let right = @doc.Doc::new(2)
  @types.Text::new(left, "t").insert(0, "left")
  @types.Text::new(right, "t").insert(0, "right")
  @types.YMap::new(right, "m").set("k", String("v"))
  // each side sends SyncStep1, the other answers with SyncStep2
  let to_right = @protocol.Sync(@protocol.sync_step1(left)).encode()
  let to_left = @protocol.Sync(@protocol.sync_step1(right)).encode()
  let answer_for_left = @protocol.handle_ws_message(right, to_right).unwrap()
  let answer_for_right = @protocol.handle_ws_message(left, to_left).unwrap()
  assert_true(@protocol.handle_ws_message(left, answer_for_left) is None)
  assert_true(@protocol.handle_ws_message(right, answer_for_right) is None)
  assert_eq(
    @types.Text::new(left, "t").to_string(),
    @types.Text::new(right, "t").to_string(),
  )
  assert_eq(@types.YMap::new(left, "m").get("k"), Some(String("v")))
  // after the handshake, SyncStep2 for an up-to-date peer carries the same
  // (empty) update as an empty document
  let again = @protocol.handle_sync_message(left, @protocol.sync_step1(right))
  let empty = @doc.Doc::new(3).encode_state_as_update()
  assert_eq(again, Some(SyncStep2(empty)))
}

///|
test "other y-websocket messages are passed through" {
  // awareness (kind 1) frames are opaque to this package
  let frame = @lib0.from_hex("0103010203") catch { e => abort(e.to_string()) }
  let m = @protocol.decode_ws_message(frame)
  assert_eq(m, Other(@protocol.MESSAGE_AWARENESS, b"\x03\x01\x02\x03"))
  assert_eq(hex(m.encode()), "0103010203")
  assert_true(@protocol.handle_ws_message(@doc.Doc::new(1), frame) is None)
  // unknown sync message types are rejected
  let bad = try @protocol.decode_sync_message(b"\x07\x00") catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(bad)
}
