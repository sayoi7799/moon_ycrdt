// Workloads for `moon bench -p sayoi7799/moon_ycrdt/benchmarks`. They are
// deterministic (a fixed linear congruential generator) so that runs are
// comparable.

///|
/// Deterministic pseudo random numbers (numerical recipes LCG).
pub struct Lcg {
  mut state : UInt
}

///|
pub fn Lcg::new(seed : UInt) -> Lcg {
  { state: seed, }
}

///|
/// A number in `0 ..< bound` (bound > 0).
pub fn Lcg::next(self : Lcg, bound : Int) -> Int {
  self.state = self.state * 1664525U + 1013904223U
  ((self.state >> 8).reinterpret_as_int() & 0x7FFFFF) % bound
}

///|
/// Types `n` characters one by one at the end of the text, one transaction
/// per character (like a user typing).
pub fn type_at_end(doc : @doc.Doc, n : Int) -> Unit {
  let text = @types.Text::new(doc, "t")
  for i in 0..<n {
    text.insert(text.length(), if i % 10 == 9 { " " } else { "x" })
  }
}

///|
/// `n` single-character inserts at random positions (each one creates a new
/// item that cannot merge with its neighbours).
pub fn random_inserts(doc : @doc.Doc, n : Int, seed : UInt) -> Unit {
  let text = @types.Text::new(doc, "t")
  let rng = Lcg::new(seed)
  for _ in 0..<n {
    text.insert(rng.next(text.length() + 1), "ab")
  }
}

///|
/// `n` deletes of 1-3 characters at random positions.
pub fn random_deletes(doc : @doc.Doc, n : Int, seed : UInt) -> Unit {
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
pub fn fragmented_document(n : Int) -> Bytes {
  let doc = @doc.Doc::new(1)
  random_inserts(doc, n, 42)
  random_deletes(doc, n / 2, 43)
  doc.encode_state_as_update()
}

///|
/// Three replicas make `edits` random edits each, broadcasting every local
/// update to the others immediately. Returns the final text length.
pub fn three_way_sync(edits : Int) -> Int {
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
