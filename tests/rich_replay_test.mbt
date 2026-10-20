// Replays Yjs-recorded rich-text scripts (rich_*_gen_test.mbt) on MoonBit
// replicas with the same client ids. After every step the delta (as JSON text)
// and the bytes of every local update must equal what Yjs produced — this
// includes the clean-up updates a replica emits after applying remote changes.

///|
enum RichOp {
  /// replica, index, text, attributes (None: inherit), Yjs' local updates, delta after
  RIns(Int32, Int32, String, Array[(String, @lib0.Any)]?, Array[String], String)
  /// replica, index, embed, attributes, Yjs' local updates, delta after
  REmbed(
    Int32,
    Int32,
    @lib0.Any,
    Array[(String, @lib0.Any)]?,
    Array[String],
    String
  )
  /// replica, index, length, Yjs' local updates, delta after
  RDel(Int32, Int32, Int32, Array[String], String)
  /// from, to, indices into the sender's log, local updates the receiver
  /// emitted while applying them (clean-up), delta after
  RSync(Int32, Int32, Array[Int32], Array[String], String)
}

///|
struct RichCase {
  name : String
  clients : Array[UInt32]
  ops : Array[RichOp]
  final_delta : String
}

///|
fn delta_json(t : @types.Text) -> String raise {
  @types.delta_to_json(t.to_delta()).stringify()
}

///|
/// Replays `c` and returns the number of steps checked.
fn replay_rich(c : RichCase) -> Int32 raise {
  let docs = c.clients.map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  let texts = docs.map(d => @types.Text::new(d, "t"))
  for k, op in c.ops {
    let ctx = "\{c.name} step \{k}"
    let lens = logs.map(l => l.length())
    let (r, expected_updates, expected_delta) = match op {
      RIns(r, index, s, attrs, updates, delta) => {
        match attrs {
          Some(a) => texts[r].insert_with_attributes(index, s, a)
          None => texts[r].insert(index, s)
        }
        (r, updates, delta)
      }
      REmbed(r, index, embed, attrs, updates, delta) => {
        match attrs {
          Some(a) => texts[r].insert_embed(index, embed, attributes=a)
          None => texts[r].insert_embed(index, embed)
        }
        (r, updates, delta)
      }
      RDel(r, index, len, updates, delta) => {
        texts[r].delete(index, len)
        (r, updates, delta)
      }
      RSync(from, to, indices, updates, delta) => {
        for i in indices {
          docs[to].apply_update(logs[from][i])
        }
        (to, updates, delta)
      }
    }
    assert_eq(delta_json(texts[r]), expected_delta, msg=ctx)
    assert_eq(
      hexes(logs[r][lens[r]:]),
      expected_updates,
      msg="\{ctx} (updates)",
    )
  }
  for t in texts {
    assert_eq(delta_json(t), c.final_delta, msg="\{c.name} final")
  }
  for d in docs {
    assert_true(!d.has_pending(), msg="\{c.name} pending left")
  }
  c.ops.length()
}
