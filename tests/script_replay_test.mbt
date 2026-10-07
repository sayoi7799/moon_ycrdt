// Replays Yjs-recorded edit scripts on MoonBit replicas (used by the
// convergence and edge-case tests). Replicas use the same client ids as in
// Yjs, exchange their own updates in the recorded order, and must match Yjs
// after every single step — including the bytes of every local update.

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
struct ScriptCase {
  name : String
  clients : Array[UInt]
  ops : Array[Op]
  final_text : String
}

///|
fn hexes(updates : ArrayView[Bytes]) -> Array[String] {
  updates.iter().map(b => @lib0.to_hex(b)).to_array()
}

///|
/// Replays `c` and returns the number of steps checked.
fn replay(c : ScriptCase) -> Int raise {
  let docs = c.clients.map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  let texts = docs.map(d => @types.Text::new(d, "t"))
  for k, op in c.ops {
    let ctx = "\{c.name} step \{k}"
    match op {
      Ins(r, pos, s, expected_update, expected) => {
        let before = logs[r].length()
        texts[r].insert(pos, s)
        assert_eq(texts[r].to_string(), expected, msg=ctx)
        assert_eq(
          hexes(logs[r][before:]),
          expected_update,
          msg="\{ctx} (update bytes)",
        )
      }
      Del(r, pos, len, expected_update, expected) => {
        let before = logs[r].length()
        texts[r].delete(pos, len)
        assert_eq(texts[r].to_string(), expected, msg=ctx)
        assert_eq(
          hexes(logs[r][before:]),
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
  }
  for t in texts {
    assert_eq(t.to_string(), c.final_text, msg="\{c.name} final")
  }
  for d in docs {
    assert_true(!d.has_pending(), msg="\{c.name} pending left")
  }
  c.ops.length()
}
