// Content moon_ycrdt does not model (formats, embeds, XML, arrays, nested
// types, sub-documents, GC'd content) must survive untouched
// (preserve_gen_test.mbt). Replica B loads a Yjs document, edits the text and
// map it supports, then receives Yjs edits made *inside* the unsupported
// types. Its local updates and final state must be byte-identical to a Yjs
// replica that did the same.

///|
enum PreserveOp {
  /// text name, position, string, Yjs' local update(s)
  TextIns(String, Int, String, Array[String])
  /// text name, position, length, Yjs' local update(s)
  TextDel(String, Int, Int, Array[String])
  /// map name, key, value, Yjs' local update(s)
  MapSet(String, String, @lib0.Any, Array[String])
}

///|
struct PreserveCase {
  name : String
  base : String
  ops : Array[PreserveOp]
  later : Array[String]
  state : String
  text : String
}

///|
test "unsupported content is preserved byte for byte" {
  assert_eq(preserve_cases.length(), 5)
  for c in preserve_cases {
    let doc = @doc.Doc::new(preserve_client)
    let own : Array[Bytes] = []
    doc.on_update((u, is_local) => if is_local { own.push(u) })
    doc.apply_update(@tests.hex_bytes(c.base))
    for k, op in c.ops {
      let before = own.length()
      let expected = match op {
        TextIns(name, pos, s, ups) => {
          @types.Text::new(doc, name).insert(pos, s)
          ups
        }
        TextDel(name, pos, len, ups) => {
          @types.Text::new(doc, name).delete(pos, len)
          ups
        }
        MapSet(name, key, value, ups) => {
          @types.YMap::new(doc, name).set(key, value)
          ups
        }
      }
      assert_eq(hexes(own[before:]), expected, msg="\{c.name} op \{k}")
    }
    for u in c.later {
      doc.apply_update(@tests.hex_bytes(u))
    }
    assert_eq(@types.Text::new(doc, "t").to_string(), c.text, msg=c.name)
    assert_eq(@lib0.to_hex(doc.encode_state_as_update()), c.state, msg=c.name)
    assert_true(!doc.has_pending(), msg=c.name)
  }
}

///|
test "re-encoding a preserved document round-trips through a second replica" {
  for c in preserve_cases {
    let first = @doc.Doc::new(preserve_client)
    first.apply_update(@tests.hex_bytes(c.base))
    for u in c.later {
      first.apply_update(@tests.hex_bytes(u))
    }
    let second = @doc.Doc::new(1)
    second.apply_update(first.encode_state_as_update())
    assert_eq(
      @lib0.to_hex(second.encode_state_as_update()),
      @lib0.to_hex(first.encode_state_as_update()),
      msg=c.name,
    )
  }
}
