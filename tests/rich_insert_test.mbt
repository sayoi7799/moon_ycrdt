// Inserting text and embeds with and without attributes, against Yjs
// (rich_insert_gen_test.mbt).

///|
test "insert, insert_with_attributes and insert_embed match Yjs step by step" {
  let cases = rich_insert_cases()
  assert_true(cases.length() >= 11)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c)
  }
  assert_true(steps >= 50)
}

///|
test "format matches Yjs step by step" {
  let cases = rich_format_cases()
  assert_true(cases.length() >= 11)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c)
  }
  assert_true(steps >= 40)
}
