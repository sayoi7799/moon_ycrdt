// Workloads for `moon bench -p sayoi7799/moon_ycrdt/benchmarks`. They are
// deterministic (a fixed linear congruential generator) so that runs are
// comparable.

///|
/// Deterministic pseudo random numbers (numerical recipes LCG).
pub struct Lcg {
  mut state : UInt32
}

///|
pub fn Lcg::new(seed : UInt32) -> Lcg {
  { state: seed, }
}

///|
/// A number in `0 ..< bound` (bound > 0).
pub fn Lcg::next(self : Lcg, bound : Int32) -> Int32 {
  self.state = self.state * 1664525U + 1013904223U
  ((self.state >> 8).reinterpret_as_int() & 0x7FFFFF) % bound
}

///|
/// Types `n` characters one by one at the end of the text, one transaction
/// per character (like a user typing).
pub fn type_at_end(doc : @doc.Doc, n : Int32) -> Unit {
  let text = @types.Text::new(doc, "t")
  for i in 0..<n {
    text.insert(text.length(), if i % 10 == 9 { " " } else { "x" })
  }
}

///|
/// `n` single-character inserts at random positions (each one creates a new
/// item that cannot merge with its neighbours).
pub fn random_inserts(doc : @doc.Doc, n : Int32, seed : UInt32) -> Unit {
  let text = @types.Text::new(doc, "t")
  let rng = Lcg::new(seed)
  for _ in 0..<n {
    text.insert(rng.next(text.length() + 1), "ab")
  }
}

///|
/// `n` deletes of 1-3 characters at random positions.
pub fn random_deletes(doc : @doc.Doc, n : Int32, seed : UInt32) -> Unit {
  let text = @types.Text::new(doc, "t")
  let rng = Lcg::new(seed)
  for _ in 0..<n {
    if text.length() == 0 {
      break
    }
    let pos = rng.next(text.length())
    let len = @cmp.minimum(1 + rng.next(3), text.length() - pos)
    text.delete(pos, len)
  }
}

///|
/// A document with `n` random inserts followed by `n / 2` random deletes,
/// encoded as one update.
pub fn fragmented_document(n : Int32) -> Bytes {
  let doc = @doc.Doc::new(1)
  random_inserts(doc, n, 42)
  random_deletes(doc, n / 2, 43)
  doc.encode_state_as_update()
}

///|
/// Three replicas make `edits` random edits each, broadcasting every local
/// update to the others immediately. Returns the final text length.
pub fn three_way_sync(edits : Int32) -> Int32 {
  let docs = [@doc.Doc::new(1), @doc.Doc::new(2), @doc.Doc::new(3)]
  let outbox : Array[Array[Bytes]] = [[], [], []]
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { outbox[i].push(u) })
  }
  let rng = Lcg::new(7)
  for _ in 0..<edits {
    for r in 0..<3 {
      let text = @types.Text::new(docs[r], "t")
      if text.length() > 0 && rng.next(4) == 0 {
        text.delete(rng.next(text.length()), 1)
      } else {
        text.insert(rng.next(text.length() + 1), "z")
      }
    }
    // deliver everything sent in this round
    for from in 0..<3 {
      for u in outbox[from] {
        for to in 0..<3 {
          if to != from {
            docs[to].apply_update(u) catch {
              e => abort(e.to_string())
            }
          }
        }
      }
      outbox[from].clear()
    }
  }
  @types.Text::new(docs[0], "t").length()
}

///|
/// A text of 100000 characters (one insert) followed by `n` random inserts of
/// two characters and `n` random deletes of 1-3 characters, every edit in its
/// own transaction. The edits split the text into about `2 * n` items, which
/// is what makes finding a position expensive. Returns the final length.
pub fn long_text_edits(n : Int32) -> Int32 {
  let doc = @doc.Doc::new(1)
  let text = @types.Text::new(doc, "t")
  text.insert(0, "abcdefghij".repeat(10000))
  random_inserts(doc, n, 11)
  random_deletes(doc, n, 12)
  text.length()
}

///|
/// The same on a `YArray` of 100000 numbers (one insert): `n` random inserts
/// of one value and `n` random deletes of 1-3 values. Returns the final length.
pub fn long_array_edits(n : Int32) -> Int32 {
  let doc = @doc.Doc::new(1)
  let array = @types.YArray::new(doc, "a")
  let initial : Array[@lib0.Any] = []
  for i in 0..<100000 {
    initial.push(@lib0.Any::int(i))
  }
  array.insert(0, initial)
  let rng = Lcg::new(13)
  for i in 0..<n {
    array.insert(rng.next(array.length() + 1), [@lib0.Any::int(i)])
  }
  for _ in 0..<n {
    let pos = rng.next(array.length())
    array.delete(pos, @cmp.minimum(1 + rng.next(3), array.length() - pos))
  }
  array.length()
}
