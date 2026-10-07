// Concurrent convergence against Yjs (convergence_gen_test.mbt): random edits
// on 2-4 replicas (text at nearby positions, concurrent map keys), exchanged
// in a random order with
// duplicates; see script_replay_test.mbt for what is checked at every step.

///|
test "300 random concurrent scenarios converge exactly like Yjs" {
  let cases = convergence_cases()
  assert_eq(cases.length(), 300)
  let mut steps = 0
  for c in cases {
    steps += replay(c)
  }
  assert_true(steps > 8000)
}
