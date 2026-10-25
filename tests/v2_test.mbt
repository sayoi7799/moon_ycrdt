// Update format v2 against Yjs (convergence_v2_gen_test.mbt, arrays_v2_gen_test.mbt,
// rich_v2_gen_test.mbt, interop_v2_gen_test.mbt). The scenarios are the ones of
// the v1 tests with the replicas exchanging v2 updates: every local update
// MoonBit emits (`on_update_v2`) must be the bytes Yjs emitted for `updateV2`,
// and every v2 update Yjs wrote must be accepted by `apply_update_v2`.

///|
test "60 text and map scenarios exchanging v2 updates match Yjs at every step" {
  let cases = convergence_v2_cases()
  assert_eq(cases.length(), 60)
  let mut steps = 0
  for c in cases {
    steps += replay(c, v2=true)
  }
  assert_true(steps > 1500)
}

///|
test "40 Y.Array scenarios exchanging v2 updates match Yjs at every step" {
  let cases = array_v2_cases()
  assert_eq(cases.length(), 40)
  assert_true(run_array_cases(cases, v2=true) > 800)
}

///|
test "20 rich-text scenarios exchanging v2 updates match Yjs at every step" {
  // formatting items and embeds carry JSON values; v2 stores them as `Any`
  let cases = rich_v2_cases()
  assert_eq(cases.length(), 20)
  let mut steps = 0
  for c in cases {
    steps += replay_rich(c, v2=true)
  }
  assert_true(steps > 500)
}

///|
test "the state of a receiver, in both formats, after every update and for state vectors on the way" {
  let receiver : UInt32 = 999999
  let mut checks = 0
  for c in interop_v2_cases {
    let (name, updates, updates_v2, steps, diffs) = c
    assert_eq(updates.length(), updates_v2.length(), msg=name)
    let a = @doc.Doc::new(receiver)
    let b = @doc.Doc::new(receiver)
    for i, u in updates {
      let ctx = "\{name} step \{i}"
      a.apply_update(@tests.hex_bytes(u))
      b.apply_update_v2(@tests.hex_bytes(updates_v2[i]))
      let (state_v1, state_v2) = steps[i]
      // a document that was fed v1 or v2 holds the same state
      for d in [a, b] {
        assert_eq(@lib0.to_hex(d.encode_state_as_update()), state_v1, msg=ctx)
        assert_eq(
          @lib0.to_hex(d.encode_state_as_update_v2()),
          state_v2,
          msg=ctx,
        )
      }
      checks += 1
    }
    for d in diffs {
      let (sv, diff_v1, diff_v2) = d
      let target = @update.decode_state_vector(@tests.hex_bytes(sv))
      for doc in [a, b] {
        assert_eq(
          @lib0.to_hex(doc.encode_state_as_update(sv=target)),
          diff_v1,
          msg="\{name} diff v1",
        )
        assert_eq(
          @lib0.to_hex(doc.encode_state_as_update_v2(sv=target)),
          diff_v2,
          msg="\{name} diff v2",
        )
        // the function forms take the state vector encoded
        assert_eq(
          @lib0.to_hex(
            @doc.encode_state_as_update_v2(
              doc,
              target_state_vector=@tests.hex_bytes(sv),
            ),
          ),
          diff_v2,
          msg="\{name} diff v2 (function)",
        )
      }
      checks += 1
    }
  }
  assert_true(checks > 40)
}
