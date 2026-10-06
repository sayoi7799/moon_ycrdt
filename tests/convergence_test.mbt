// Concurrent convergence against Yjs (convergence_gen_test.mbt): MoonBit
// replicas replay the same edits with the same client ids, exchange their own
// updates in the same random order (with duplicates), and must match Yjs
// after every single step.

///|
enum Op {
  /// replica, position, inserted string, Yjs' local update(s), text after
  Ins(Int, Int, String, Array[String], String)
  /// replica, position, length, Yjs' local update(s), text after
  Del(Int, Int, Int, Array[String], String)
  /// from, to, indices into the sender's log of local updates, text after
  Sync(Int, Int, Array[Int], String)
}

///|
struct ConvergenceCase {
  seed : Int
  clients : Array[UInt]
  ops : Array[Op]
  final_text : String
}

///|
test "200 random concurrent scenarios converge exactly like Yjs" {
  assert_eq(convergence_cases.length(), 200)
  let mut steps = 0
  for c in convergence_cases {
    let docs = c.clients.map(id => @doc.Doc::new(id))
    let logs : Array[Array[Bytes]] = docs.map(_ => [])
    for i, d in docs {
      d.on_update((u, is_local) => if is_local { logs[i].push(u) })
    }
    let texts = docs.map(d => @types.Text::new(d, "t"))
    for k, op in c.ops {
      let ctx = "seed \{c.seed} step \{k}"
      match op {
        Ins(r, pos, s, expected_update, expected) => {
          let before = logs[r].length()
          texts[r].insert(pos, s)
          assert_eq(texts[r].to_string(), expected, msg=ctx)
          // the local update is byte-for-byte what Yjs emits
          assert_eq(
            logs[r][before:].iter().map(b => @lib0.to_hex(b)).to_array(),
            expected_update,
            msg="\{ctx} (update bytes)",
          )
        }
        Del(r, pos, len, expected_update, expected) => {
          let before = logs[r].length()
          texts[r].delete(pos, len)
          assert_eq(texts[r].to_string(), expected, msg=ctx)
          assert_eq(
            logs[r][before:].iter().map(b => @lib0.to_hex(b)).to_array(),
            expected_update,
            msg="\{ctx} (update bytes)",
          )
        }
        Sync(from, to, indices, expected) => {
          for i in indices {
            docs[to].apply_update(logs[from][i])
          }
          assert_eq(texts[to].to_string(), expected, msg=ctx)
        }
      }
      steps += 1
    }
    for t in texts {
      assert_eq(t.to_string(), c.final_text, msg="seed \{c.seed} final")
    }
    for d in docs {
      assert_true(!d.has_pending(), msg="seed \{c.seed} pending left")
    }
  }
  assert_true(steps > 4000)
}
