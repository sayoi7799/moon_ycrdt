// Edge cases: UTF-16 positions inside surrogate pairs / ZWJ sequences /
// combining marks, empty documents and updates, extreme client ids
// (edge_gen_test.mbt, recorded with Yjs), and malformed input.

///|
test "inserts and deletes at every UTF-16 position match Yjs" {
  // every position of the edge string for inserts, plus deletes of 1 and 2
  // code units starting at every position, plus the special scenarios
  assert_true(edge_cases.length() > 40)
  for c in edge_cases {
    replay(c) |> ignore
  }
}

///|
test "empty document encodes like an empty Yjs document" {
  let doc = @doc.Doc::new(1)
  assert_eq(@lib0.to_hex(doc.encode_state_as_update()), empty_doc_state)
  assert_eq(@lib0.to_hex(doc.encode_state_vector()), empty_doc_state_vector)
  // an empty text / map reads as empty, and an empty update changes nothing
  assert_eq(@types.Text::new(doc, "t").to_string(), "")
  assert_eq(@types.Text::new(doc, "t").length(), 0)
  assert_eq(@types.YMap::new(doc, "m").size(), 0)
  doc.apply_update(@tests.hex_bytes(empty_doc_state))
  assert_eq(@lib0.to_hex(doc.encode_state_as_update()), empty_doc_state)
  assert_true(!doc.has_pending())
  // deleting nothing and inserting nothing do not create updates
  let updates = []
  doc.on_update((u, _) => updates.push(u))
  @types.Text::new(doc, "t").insert(0, "")
  @types.Text::new(doc, "t").delete(0, 0)
  @types.YMap::new(doc, "m").delete("missing")
  assert_eq(updates.length(), 0)
}

///|
test "diff against a state vector that is already up to date is empty" {
  let doc = @doc.Doc::new(1)
  @types.Text::new(doc, "t").insert(0, "a😀")
  let diff = @doc.encode_state_as_update(
    doc,
    target_state_vector=doc.encode_state_vector(),
  )
  assert_eq(@lib0.to_hex(diff), empty_doc_state)
}

///|
test "truncated or corrupted updates raise and leave the document unchanged" {
  // a real update with structs, a map entry and deletions
  let source = @doc.Doc::new(42)
  let text = @types.Text::new(source, "t")
  text.insert(0, "hello 😀 world")
  text.delete(2, 3)
  @types.YMap::new(source, "m").set("k", String("v"))
  let update = source.encode_state_as_update()
  let mut rejected = 0
  for len in 0..<update.length() {
    let doc = @doc.Doc::new(7)
    let prefix = update[0:len].to_owned()
    let raised = try doc.apply_update(prefix) catch {
      _ => true
    } noraise {
      _ => false
    }
    if raised {
      rejected += 1
      assert_eq(
        @lib0.to_hex(doc.encode_state_as_update()),
        empty_doc_state,
        msg="prefix \{len}",
      )
    }
  }
  // almost every prefix is cut in the middle of a value
  assert_true(rejected > update.length() / 2)
  // an unknown content ref (31) in the info byte is rejected
  let bad = @tests.hex_bytes("010101001f0101740100")
  let doc = @doc.Doc::new(7)
  let raised = try doc.apply_update(bad) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(raised)
}
