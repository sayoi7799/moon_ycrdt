// mergeUpdates, diffUpdate and encodeStateVectorFromUpdate against Yjs
// (update_ops_gen_test.mbt): the pools are local updates of recorded scenarios,
// the merges are in order, shuffled with repeats, a subset with gaps, a single
// update and none; the diffs are taken against states the pool passes through.
// Format v2 inputs are the same updates converted by MoonBit (checked against
// Yjs' conversion in update/update_test.mbt).

///|
fn v2_of(v1 : Bytes) -> Bytes raise {
  @update.decode_update(v1).normalized().encode_v2()
}

///|
test "merge_updates matches Yjs in both formats" {
  assert_true(merge_cases.length() > 150)
  for k, c in merge_cases {
    let (pool, indices, expected_v1, expected_v2, _, _) = c
    let ctx = "merge case \{k} (pool \{pool}, \{indices.length()} updates)"
    let v1 = indices.map(i => @tests.hex_bytes(update_pools[pool][i]))
    assert_eq(@lib0.to_hex(@update.merge_updates(v1)), expected_v1, msg=ctx)
    let v2 = v1.map(v2_of)
    assert_eq(
      @lib0.to_hex(@update.merge_updates_v2(v2)),
      expected_v2,
      msg="\{ctx} (v2)",
    )
  }
}

///|
test "encode_state_vector_from_update matches Yjs in both formats" {
  for k, c in merge_cases {
    let (_, _, merged_v1, merged_v2, sv_v1, sv_v2) = c
    assert_eq(
      @lib0.to_hex(
        @update.encode_state_vector_from_update(@tests.hex_bytes(merged_v1)),
      ),
      sv_v1,
      msg="merge case \{k}",
    )
    assert_eq(
      @lib0.to_hex(
        @update.encode_state_vector_from_update_v2(@tests.hex_bytes(merged_v2)),
      ),
      sv_v2,
      msg="merge case \{k} (v2)",
    )
  }
}

///|
test "diff_update matches Yjs in both formats" {
  assert_true(diff_cases.length() > 100)
  for k, c in diff_cases {
    let (merge, sv, expected_v1, expected_v2) = c
    let (_, _, merged_v1, merged_v2, _, _) = merge_cases[merge]
    let sv = @tests.hex_bytes(sv)
    let ctx = "diff case \{k}"
    assert_eq(
      @lib0.to_hex(@update.diff_update(@tests.hex_bytes(merged_v1), sv)),
      expected_v1,
      msg=ctx,
    )
    assert_eq(
      @lib0.to_hex(@update.diff_update_v2(@tests.hex_bytes(merged_v2), sv)),
      expected_v2,
      msg="\{ctx} (v2)",
    )
  }
}
