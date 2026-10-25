// Property-based tests for Y.Array and rich text, like property_test.mbt does
// for plain text and maps: random scripts of integer triples drive three
// MoonBit replicas; the properties are checked on the updates they produce.
// (Text positions stay in ASCII and BMP characters: a Yjs replica and its peers
// can disagree when concurrent edits cut an emoji in two, which is not the
// point here.)

///|
let rich_chunks : Array[String] = ["a", "bc", "中", " ", "xyz"]

///|
let attr_names : Array[String] = ["bold", "italic", "color"]

///|
fn attr_value(name : String, b : Int32) -> @lib0.Any {
  if name == "color" {
    String(if b % 2 == 0 { "red" } else { "blue" })
  } else {
    Bool(true)
  }
}

///|
/// Array: insert one or two values, push, delete, or send replica `a % 3`'s
/// updates to `b % 3`.
fn run_array_script(script : Array[(Int32, Int32, Int32)]) -> Session {
  let docs = [1U, 2U, 3000000000U].map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  for step in script {
    let (op, a, b) = step
    let r = nonneg(a) % 3
    let array = @types.YArray::new(docs[r], "a")
    match nonneg(op) % 6 {
      0 | 1 => {
        let pos = nonneg(b) % (array.length() + 1)
        let values = if nonneg(op) % 2 == 0 {
          [@lib0.Any::int(b)]
        } else {
          [@lib0.Any::int(b), String("x")]
        }
        array.insert(pos, values)
      }
      2 => array.push([@lib0.Any::int(nonneg(b))])
      3 | 4 =>
        if array.length() > 0 {
          let pos = nonneg(b) % array.length()
          array.delete(
            pos,
            @cmp.minimum(1 + nonneg(op) % 3, array.length() - pos),
          )
        }
      _ => {
        let to = nonneg(b) % 3
        for u in logs[r] {
          docs[to].apply_update(u) catch {
            e => abort(e.to_string())
          }
        }
      }
    }
  }
  { logs, }
}

///|
/// Rich text: plain and formatted inserts, `format` (a `Null` removes the
/// attribute), deletes, or a send as above.
fn run_rich_script(script : Array[(Int32, Int32, Int32)]) -> Session {
  let docs = [1U, 2U, 3000000000U].map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  // asking for the type up front, like an editor binding
  let texts = docs.map(d => @types.Text::new(d, "t"))
  for step in script {
    let (op, a, b) = step
    let r = nonneg(a) % 3
    let text = texts[r]
    let name = attr_names[nonneg(b) % attr_names.length()]
    match nonneg(op) % 7 {
      0 | 1 => {
        let pos = nonneg(b) % (text.length() + 1)
        text.insert(pos, rich_chunks[nonneg(b) % rich_chunks.length()])
      }
      2 => {
        let pos = nonneg(b) % (text.length() + 1)
        text.insert_with_attributes(
          pos,
          rich_chunks[nonneg(b) % rich_chunks.length()],
          [(name, attr_value(name, b))],
        )
      }
      3 =>
        if text.length() > 0 {
          let pos = nonneg(b) % text.length()
          let len = @cmp.minimum(1 + nonneg(op) % 4, text.length() - pos)
          let value : @lib0.Any = if nonneg(b) % 4 == 0 {
            Null
          } else {
            attr_value(name, b)
          }
          text.format(pos, len, [(name, value)])
        }
      4 =>
        if text.length() > 0 {
          let pos = nonneg(b) % text.length()
          text.delete(
            pos,
            @cmp.minimum(1 + nonneg(op) % 3, text.length() - pos),
          )
        }
      _ => {
        let to = nonneg(b) % 3
        for u in logs[r] {
          docs[to].apply_update(u) catch {
            e => abort(e.to_string())
          }
        }
      }
    }
  }
  { logs, }
}

///|
fn observe_array(d : @doc.Doc) -> String {
  let items = @types.YArray::new(d, "a").to_array()
  "\{@lib0.Any::Array(items)} \{@lib0.to_hex(d.encode_state_vector())}"
}

///|
fn observe_rich(d : @doc.Doc) -> String {
  let text = @types.Text::new(d, "t")
  let delta = @types.delta_to_json(
    text.to_delta() catch {
      e => abort(e.to_string())
    },
  )
  "\{delta.stringify()} \{@lib0.to_hex(d.encode_state_vector())}"
}

///|
test "property (Y.Array): any exchange order converges to the same state" {
  @quickcheck.check(
    (input : (Array[(Int32, Int32, Int32)], Array[Int32])) => {
      let (script, keys) = input
      let updates = all_updates(run_array_script(script))
      let a = @doc.Doc::new(77)
      let b = @doc.Doc::new(78)
      apply_all(a, updates)
      apply_all(b, permute(updates, keys))
      // a reversed order with every update delivered twice
      let c = @doc.Doc::new(79)
      let twice = updates.rev()
      twice.append(updates)
      apply_all(c, twice)
      observe_array(a) == observe_array(b) &&
      observe_array(a) == observe_array(c) &&
      !b.has_pending()
    },
    count=300,
  )
}

///|
test "property (Y.Array): applying an update twice does not change the state" {
  @quickcheck.check(
    (script : Array[(Int32, Int32, Int32)]) => {
      let d = @doc.Doc::new(77)
      let mut ok = true
      for u in all_updates(run_array_script(script)) {
        apply_all(d, [u])
        let once = @lib0.to_hex(d.encode_state_as_update())
        apply_all(d, [u])
        ok = ok && @lib0.to_hex(d.encode_state_as_update()) == once
      }
      ok
    },
    count=300,
  )
}

///|
test "property (rich text): any exchange order converges to the same delta" {
  @quickcheck.check(
    (input : (Array[(Int32, Int32, Int32)], Array[Int32])) => {
      let (script, keys) = input
      let updates = all_updates(run_rich_script(script))
      let a = @doc.Doc::new(77)
      let b = @doc.Doc::new(78)
      apply_all(a, updates)
      apply_all(b, permute(updates, keys))
      let c = @doc.Doc::new(79)
      let twice = updates.rev()
      twice.append(updates)
      apply_all(c, twice)
      observe_rich(a) == observe_rich(b) &&
      observe_rich(a) == observe_rich(c) &&
      !b.has_pending()
    },
    count=300,
  )
}

///|
test "property (rich text): applying an update twice does not change the state" {
  @quickcheck.check(
    (script : Array[(Int32, Int32, Int32)]) => {
      let d = @doc.Doc::new(77)
      let mut ok = true
      for u in all_updates(run_rich_script(script)) {
        apply_all(d, [u])
        let once = @lib0.to_hex(d.encode_state_as_update())
        apply_all(d, [u])
        ok = ok && @lib0.to_hex(d.encode_state_as_update()) == once
      }
      ok
    },
    count=300,
  )
}
