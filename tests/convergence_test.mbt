// Concurrent convergence against Yjs (convergence_gen_test.mbt): random edits
// on 2-3 replicas at nearby positions, exchanged in a random order with
// duplicates; see script_replay_test.mbt for what is checked at every step.

///|
test "200 random concurrent scenarios converge exactly like Yjs" {
  assert_eq(convergence_cases.length(), 200)
  let mut steps = 0
  for c in convergence_cases {
    steps += replay(c)
  }
  assert_true(steps > 4000)
}
