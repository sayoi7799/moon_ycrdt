// Rich-text editing against Yjs: insert (with attributes), embeds, format and
// applyDelta, replayed from the scripts recorded in rich_*_gen_test.mbt.

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

///|
test "apply_delta matches Yjs step by step" {
  let cases = rich_apply_delta_cases()
  assert_true(cases.length() >= 10)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c)
  }
  assert_true(steps >= 20)
}

///|
test "concurrent formatting matches Yjs, including its clean-up updates" {
  let cases = rich_concurrent_cases()
  assert_true(cases.length() >= 6)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c)
  }
  assert_true(steps >= 40)
}

///|
test "300 random rich-text scenarios converge exactly like Yjs" {
  let cases = rich_convergence_cases()
  assert_eq(cases.length(), 300)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c)
    // Yjs converged on all of them, so every MoonBit replica must have, too
    assert_true(
      c.final_deltas.iter().all(d => d == c.final_deltas[0]),
      msg=c.name,
    )
  }
  assert_true(steps > 8000)
}
