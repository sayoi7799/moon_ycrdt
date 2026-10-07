// Replays Yjs-recorded edit scripts on MoonBit replicas (used by the
// convergence and edge-case tests). Replicas use the same client ids as in
// Yjs, exchange their own updates in the recorded order, and must match Yjs
// after every single step — text, map, and the bytes of every local update.

///|
enum Op {
  /// replica, position, inserted string, Yjs' local update(s), text and map after
  Ins(Int, Int, String, Array[String], String, String)
  /// replica, position, length, Yjs' local update(s), text and map after
  Del(Int, Int, Int, Array[String], String, String)
  /// replica, key, integer value, Yjs' local update(s), text and map after
  MSet(Int, String, Int, Array[String], String, String)
  /// replica, key, Yjs' local update(s), text and map after
  MDel(Int, String, Array[String], String, String)
  /// from, to, indices into the sender's log of local updates, text and map after
  Sync(Int, Int, Array[Int], String, String)
}

///|
struct ScriptCase {
  name : String
  clients : Array[UInt]
  ops : Array[Op]
  final_text : String
  final_map : String
}

///|
fn hexes(updates : ArrayView[Bytes]) -> Array[String] {
  updates.iter().map(b => @lib0.to_hex(b)).to_array()
}

///|
/// Map "m" as "key=value,..." sorted by key, the format of `mapState` in
/// scripts/gen_fixtures.mjs.
fn map_state(doc : @doc.Doc) -> String {
  @types.YMap::new(doc, "m").entries().map(e => "\{e.0}=\{e.1}").join(",")
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
  let maps = docs.map(d => @types.YMap::new(d, "m"))
  for k, op in c.ops {
    let ctx = "\{c.name} step \{k}"
    let lens = logs.map(l => l.length())
    // run the step; local edits return their replica and Yjs' update bytes
    let (r, expected_update, text, map) = match op {
      Ins(r, pos, s, ups, text, map) => {
        texts[r].insert(pos, s)
        (r, Some(ups), text, map)
      }
      Del(r, pos, len, ups, text, map) => {
        texts[r].delete(pos, len)
        (r, Some(ups), text, map)
      }
      MSet(r, key, value, ups, text, map) => {
        maps[r].set(key, @lib0.Any::int(value))
        (r, Some(ups), text, map)
      }
      MDel(r, key, ups, text, map) => {
        maps[r].delete(key)
        (r, Some(ups), text, map)
      }
      Sync(from, to, indices, text, map) => {
        for i in indices {
          docs[to].apply_update(logs[from][i])
        }
        (to, None, text, map)
      }
    }
    assert_eq(texts[r].to_string(), text, msg=ctx)
    assert_eq(map_state(docs[r]), map, msg="\{ctx} (map)")
    if expected_update is Some(ups) {
      // the local updates of this step are exactly what Yjs emitted
      assert_eq(hexes(logs[r][lens[r]:]), ups, msg="\{ctx} (update bytes)")
    }
  }
  for i, t in texts {
    assert_eq(t.to_string(), c.final_text, msg="\{c.name} final text")
    assert_eq(map_state(docs[i]), c.final_map, msg="\{c.name} final map")
  }
  for d in docs {
    assert_true(!d.has_pending(), msg="\{c.name} pending left")
  }
  c.ops.length()
}
