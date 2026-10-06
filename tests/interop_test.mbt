// Yjs -> MoonBit: apply updates produced by Yjs and compare with what Yjs
// itself has after applying the same updates (interop_gen_test.mbt).

///|
struct InteropCase {
  name : String
  updates : Array[String]
  texts : Array[(String, String)]
  maps : Array[(String, Array[(String, @lib0.Any)])]
  state_vector : String
  state : String
}

///|
test "Yjs updates applied in MoonBit give the same text, map and state as Yjs" {
  for c in interop_cases {
    let doc = @doc.Doc::new(receiver_client)
    for u in c.updates {
      doc.apply_update(@tests.hex_bytes(u))
    }
    for t in c.texts {
      let (name, expected) = t
      assert_eq(@types.Text::new(doc, name).to_string(), expected, msg=c.name)
    }
    for m in c.maps {
      let (name, expected) = m
      assert_eq(@types.YMap::new(doc, name).entries(), expected, msg=c.name)
    }
    assert_eq(
      @lib0.to_hex(doc.encode_state_vector()),
      c.state_vector,
      msg="\{c.name}: state vector",
    )
    assert_eq(
      @lib0.to_hex(doc.encode_state_as_update()),
      c.state,
      msg="\{c.name}: encoded state",
    )
  }
}

///|
test "applying every update twice changes nothing (idempotence)" {
  for c in interop_cases {
    let doc = @doc.Doc::new(receiver_client)
    for u in c.updates {
      doc.apply_update(@tests.hex_bytes(u))
    }
    let before = doc.encode_state_as_update()
    for u in c.updates {
      doc.apply_update(@tests.hex_bytes(u))
    }
    assert_eq(
      @lib0.to_hex(doc.encode_state_as_update()),
      @lib0.to_hex(before),
      msg=c.name,
    )
  }
}

///|
test "diff against a state vector brings another replica up to date" {
  for c in interop_cases {
    let full = @doc.Doc::new(receiver_client)
    for u in c.updates {
      full.apply_update(@tests.hex_bytes(u))
    }
    // a replica that only saw the first half of the updates
    let half = @doc.Doc::new(receiver_client + 1)
    for i in 0..<(c.updates.length() / 2) {
      half.apply_update(@tests.hex_bytes(c.updates[i]))
    }
    let diff = @doc.encode_state_as_update(
      full,
      target_state_vector=half.encode_state_vector(),
    )
    half.apply_update(diff)
    assert_eq(@lib0.to_hex(half.encode_state_as_update()), c.state, msg=c.name)
  }
}
