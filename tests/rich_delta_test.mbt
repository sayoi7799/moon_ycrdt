// Rich text: Text::to_delta against YText.toDelta() of Yjs
// (rich_delta_gen_test.mbt). The delta is compared as JSON text, so the order
// of the keys and attributes has to match as well.

///|
fn delta_text(ops : Array[@types.DeltaOp]) -> String {
  @types.delta_to_json(ops).stringify()
}

///|
test "to_delta of documents written by Yjs equals Yjs's toDelta()" {
  assert_true(rich_delta_cases.length() >= 13)
  for c in rich_delta_cases {
    let (name, update_hex, expected, text) = c
    let doc = @doc.Doc::new(77)
    doc.apply_update(@tests.hex_bytes(update_hex))
    let t = @types.Text::new(doc, "t")
    assert_eq(delta_text(t.to_delta()), expected, msg=name)
    assert_eq(t.to_string(), text, msg=name)
  }
}

///|
test "delta JSON round trip" {
  for c in rich_delta_cases {
    let (name, _, expected, _) = c
    let ops = @types.delta_from_json(@json.parse(expected))
    assert_eq(delta_text(ops), expected, msg=name)
  }
  // retain / delete operations, which toDelta never produces
  let ops = @types.delta_from_json(
    @json.parse(
      "[{\"retain\":3,\"attributes\":{\"bold\":true}},{\"delete\":2},{\"insert\":\"x\"}]",
    ),
  )
  assert_eq(ops, [
    Retain(3, [("bold", Bool(true))]),
    Delete(2),
    Insert(String("x"), []),
  ])
  // malformed deltas are rejected
  for
    bad in [
      "{}", "[1]", "[{\"foo\":1}]", "[{\"retain\":-1}]", "[{\"retain\":1.5}]",
    ] {
    let raised = try @types.delta_from_json(@json.parse(bad)) catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(raised, msg=bad)
  }
}
