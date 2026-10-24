// Search markers checked against a plain model, without Yjs: after every
// operation the content must equal the model, and every marker must still say
// how many visible elements come before the item it points to (the check that
// Yjs has commented out in `findMarker`, "assure position").

///|
struct Rng {
  mut state : UInt32
}

///|
fn Rng::next(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525U + 1013904223U
  ((self.state >> 8).reinterpret_as_int() & 0x7FFFFF) % bound
}

///|
/// The number of visible elements in front of `target`, or None when the item
/// is not in the list of `ty`.
fn visible_before(ty : @doc.YType, target : @doc.Item) -> Int32? {
  let mut count = 0
  let mut cur = ty.start
  while cur is Some(c) {
    if physical_equal(c, target) {
      return Some(count)
    }
    if !c.deleted && c.is_countable() {
      count += c.length
    }
    cur = c.right
  }
  None
}

///|
fn check_markers(ty : @doc.YType, ctx : String) -> Unit raise {
  assert_true(ty.markers.length() <= @doc.MAX_SEARCH_MARKER, msg=ctx)
  for m in ty.markers {
    assert_eq(visible_before(ty, m.p), Some(m.index), msg=ctx)
  }
}

///|
test "Y.Array: positions agree with a model and the markers stay correct" {
  let rng = Rng::{ state: 7U, }
  let doc = @doc.Doc::new(1)
  let array = @types.YArray::new(doc, "a")
  let model : Array[Int32] = []
  let mut next_value = 0
  let mut max_markers = 0
  for step in 0..<3000 {
    let ctx = "step \{step}"
    let len = model.length()
    let choice = rng.next(10)
    if choice < 4 || len == 0 {
      // insert 1-3 values at a random position (often next to the ends)
      let pos = match rng.next(6) {
        0 => 0
        1 => len
        _ => rng.next(len + 1)
      }
      let values : Array[Int32] = []
      for _ in 0..<(1 + rng.next(3)) {
        values.push(next_value)
        next_value += 1
      }
      array.insert(pos, values.map(v => @lib0.Any::int(v)))
      for i, v in values {
        model.insert(pos + i, v)
      }
    } else if choice < 5 {
      let values = [next_value]
      next_value += 1
      array.push(values.map(v => @lib0.Any::int(v)))
      model.push(values[0])
    } else if choice < 8 {
      let pos = rng.next(len)
      let n = @cmp.minimum(1 + rng.next(3), len - pos)
      array.delete(pos, n)
      for _ in 0..<n {
        model.remove(pos) |> ignore
      }
    } else {
      let pos = rng.next(len)
      assert_eq(array.get(pos), Some(@lib0.Any::int(model[pos])), msg=ctx)
    }
    assert_eq(array.length(), model.length(), msg=ctx)
    if step % 7 == 0 {
      check_markers(array.ty, ctx)
      max_markers = @cmp.maximum(max_markers, array.ty.markers.length())
    }
  }
  assert_eq(array.to_array(), model.map(v => @lib0.Any::int(v)))
  check_markers(array.ty, "end")
  // the list grew far enough for the markers to fill up
  assert_eq(max_markers, @doc.MAX_SEARCH_MARKER)
}

///|
test "Y.Text: positions agree with a model and the markers stay correct" {
  let rng = Rng::{ state: 21U, }
  let doc = @doc.Doc::new(2)
  let text = @types.Text::new(doc, "t")
  let model : Array[Char] = []
  let letters = "abcdefghijklmnopqrstuvwxyz"
  let mut max_markers = 0
  for step in 0..<2500 {
    let ctx = "step \{step}"
    let len = model.length()
    if rng.next(10) < 6 || len < 4 {
      let pos = match rng.next(6) {
        0 => 0
        1 => len
        _ => rng.next(len + 1)
      }
      let word = StringBuilder()
      let chars : Array[Char] = []
      for _ in 0..<(1 + rng.next(4)) {
        let c = letters[rng.next(26)].unsafe_to_char()
        chars.push(c)
        word.write_char(c)
      }
      text.insert(pos, word.to_string())
      for i, c in chars {
        model.insert(pos + i, c)
      }
    } else {
      let pos = rng.next(len)
      let n = @cmp.minimum(1 + rng.next(4), len - pos)
      text.delete(pos, n)
      for _ in 0..<n {
        model.remove(pos) |> ignore
      }
    }
    assert_eq(text.length(), model.length(), msg=ctx)
    if step % 25 == 0 {
      let expected = StringBuilder()
      for c in model {
        expected.write_char(c)
      }
      assert_eq(text.to_string(), expected.to_string(), msg=ctx)
      check_markers(text.ty, ctx)
      max_markers = @cmp.maximum(max_markers, text.ty.markers.length())
    }
  }
  assert_true(max_markers > 40)
}

///|
test "two replicas editing a Y.Array: a remote change drops the markers, content converges" {
  let rng = Rng::{ state: 99U, }
  let docs = [@doc.Doc::new(11), @doc.Doc::new(22)]
  let arrays = docs.map(d => @types.YArray::new(d, "a"))
  let logs : Array[Array[Bytes]] = [[], []]
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  let sent = [0, 0]
  let mut saw_markers = false
  for step in 0..<1500 {
    let ctx = "step \{step}"
    let r = rng.next(2)
    let a = arrays[r]
    let len = a.length()
    let choice = rng.next(10)
    if choice < 4 || len == 0 {
      a.insert(rng.next(len + 1), [@lib0.Any::int(step)])
    } else if choice < 6 {
      let pos = rng.next(len)
      a.delete(pos, @cmp.minimum(1 + rng.next(2), len - pos))
    } else if choice < 8 {
      // deliver what the other replica has not seen yet
      let from = 1 - r
      let news = sent[from] < logs[from].length()
      while sent[from] < logs[from].length() {
        docs[r].apply_update(logs[from][sent[from]])
        sent[from] += 1
      }
      // the markers of the types that changed are gone
      if news {
        assert_eq(arrays[r].ty.markers.length(), 0, msg=ctx)
      }
    } else {
      a.get(rng.next(len)) |> ignore
    }
    if arrays[r].ty.markers.length() > 0 {
      saw_markers = true
    }
    check_markers(arrays[r].ty, ctx)
  }
  assert_true(saw_markers)
  for to in 0..<2 {
    let from = 1 - to
    while sent[from] < logs[from].length() {
      docs[to].apply_update(logs[from][sent[from]])
      sent[from] += 1
    }
  }
  assert_eq(arrays[0].to_array(), arrays[1].to_array())
}
