// Y.Array against Yjs (arrays_gen_test.mbt): 100 seeded random scenarios of
// concurrent insert / push / delete on 2-3 replicas, exchanged in a random
// order with duplicates. After every step the array content and the bytes of
// every local update must match Yjs.

///|
enum ArrOp {
  /// replica, index, values, Yjs' local update(s), array after
  AIns(Int, Int, Array[@lib0.Any], Array[String], String)
  /// replica, values, Yjs' local update(s), array after
  APush(Int, Array[@lib0.Any], Array[String], String)
  /// replica, index, length, Yjs' local update(s), array after
  ADel(Int, Int, Int, Array[String], String)
  /// from, to, indices into the sender's log of local updates, array after
  ASync(Int, Int, Array[Int], String)
}

///|
struct ArrayCase {
  seed : Int
  clients : Array[UInt]
  ops : Array[ArrOp]
  final_state : String
}

///|
fn array_state(a : @types.YArray) -> String {
  @lib0.Any::Array(a.to_array()).to_string()
}

///|
test "100 random Y.Array scenarios match Yjs at every step" {
  let cases = array_cases()
  assert_eq(cases.length(), 100)
  let mut steps = 0
  for c in cases {
    let docs = c.clients.map(id => @doc.Doc::new(id))
    let logs : Array[Array[Bytes]] = docs.map(_ => [])
    for i, d in docs {
      d.on_update((u, is_local) => if is_local { logs[i].push(u) })
    }
    let arrays = docs.map(d => @types.YArray::new(d, "a"))
    for k, op in c.ops {
      let ctx = "array seed \{c.seed} step \{k}"
      let lens = logs.map(l => l.length())
      let (r, expected_update, expected) = match op {
        AIns(r, pos, values, ups, state) => {
          arrays[r].insert(pos, values)
          (r, Some(ups), state)
        }
        APush(r, values, ups, state) => {
          arrays[r].push(values)
          (r, Some(ups), state)
        }
        ADel(r, pos, len, ups, state) => {
          arrays[r].delete(pos, len)
          (r, Some(ups), state)
        }
        ASync(from, to, indices, state) => {
          for i in indices {
            docs[to].apply_update(logs[from][i])
          }
          (to, None, state)
        }
      }
      assert_eq(array_state(arrays[r]), expected, msg=ctx)
      if expected_update is Some(ups) {
        assert_eq(hexes(logs[r][lens[r]:]), ups, msg="\{ctx} (update bytes)")
      }
      steps += 1
    }
    for a in arrays {
      assert_eq(array_state(a), c.final_state, msg="array seed \{c.seed} final")
      assert_eq(a.length(), a.to_array().length())
    }
  }
  assert_true(steps > 2000)
}

///|
test "Y.Array get, length and nested content written by Yjs" {
  // the "arrays with any, binary and nested types" preservation case holds
  // [1, "two", bytes, Y.Map, Y.Text, [5, {six: 6}]] written by Yjs
  let c = preserve_cases.filter(c => c.name.has_prefix("arrays"))[0]
  let doc = @doc.Doc::new(5)
  doc.apply_update(@tests.hex_bytes(c.base))
  let a = @types.YArray::new(doc, "arr")
  assert_eq(a.length(), 6)
  assert_eq(a.get(0), Some(@lib0.Any::int(1)))
  assert_eq(a.get(1), Some(String("two")))
  assert_eq(a.get(2), Some(Bytes(b"\x03\x04")))
  // nested shared types are not `Any` values
  assert_eq(a.get(3), Some(Undefined))
  assert_eq(a.get(6), None)
  assert_eq(a.get(-1), None)
}
