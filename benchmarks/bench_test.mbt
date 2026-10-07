// Benchmarks: moon bench -p sayoi7799/moon_ycrdt/benchmarks --target native --release

///|
test "lib0: encode + decode 10k varUints and 1k Any objects" (it : @bench.T) {
  let value : @lib0.Any = Object([
    ("id", @lib0.Any::int(12345)),
    ("name", String("moon_ycrdt 😀")),
    ("tags", Array([String("crdt"), Bool(true), Null])),
    ("ratio", Number(0.25)),
  ])
  it.bench(fn() {
    let e = @lib0.Encoder::new()
    for i in 0..<10000 {
      e.write_var_uint(i * 37)
    }
    for _ in 0..<1000 {
      e.write_any(value)
    }
    let d = @lib0.Decoder::new(e.to_bytes())
    let mut sum = 0
    for _ in 0..<10000 {
      sum += d.read_var_uint() catch { _ => 0 }
    }
    for _ in 0..<1000 {
      it.keep(d.read_any() catch { _ => Null })
    }
    it.keep(sum)
  })
}

///|
test "update: decode + encode a fragmented 4k-item document" (it : @bench.T) {
  let data = @benchmarks.fragmented_document(4000)
  it.bench(fn() {
    let update = @update.decode_update(data) catch { e => abort(e.to_string()) }
    it.keep(update.encode())
  })
}

///|
test "text: type 2000 characters at the end" (it : @bench.T) {
  it.bench(fn() {
    let doc = @doc.Doc::new(1)
    @benchmarks.type_at_end(doc, 2000)
    it.keep(doc)
  })
}

///|
test "text: 2000 inserts at random positions" (it : @bench.T) {
  it.bench(fn() {
    let doc = @doc.Doc::new(1)
    @benchmarks.random_inserts(doc, 2000, 1)
    it.keep(doc)
  })
}

///|
test "text: 1000 random deletes in a 4000-character text" (it : @bench.T) {
  it.bench(fn() {
    let doc = @doc.Doc::new(1)
    @benchmarks.random_inserts(doc, 2000, 1)
    @benchmarks.random_deletes(doc, 1000, 2)
    it.keep(doc)
  })
}

///|
test "doc: apply a fragmented 4k-item document" (it : @bench.T) {
  let data = @benchmarks.fragmented_document(4000)
  it.bench(fn() {
    let doc = @doc.Doc::new(9)
    doc.apply_update(data) catch {
      e => abort(e.to_string())
    }
    it.keep(doc)
  })
}

///|
test "doc: encode the state of a fragmented 4k-item document" (it : @bench.T) {
  let doc = @doc.Doc::new(9)
  doc.apply_update(@benchmarks.fragmented_document(4000)) catch {
    e => abort(e.to_string())
  }
  it.bench(fn() { it.keep(doc.encode_state_as_update()) })
}

///|
test "sync: 3 replicas x 300 rounds of concurrent edits" (it : @bench.T) {
  it.bench(fn() { it.keep(@benchmarks.three_way_sync(300)) })
}

///|
test "map: 5000 sets on 100 keys" (it : @bench.T) {
  it.bench(fn() {
    let doc = @doc.Doc::new(1)
    let m = @types.YMap::new(doc, "m")
    for i in 0..<5000 {
      m.set("key\{i % 100}", @lib0.Any::int(i))
    }
    it.keep(doc)
  })
}

///|
test "array: 2000 pushes and 500 random inserts" (it : @bench.T) {
  it.bench(fn() {
    let doc = @doc.Doc::new(1)
    let a = @types.YArray::new(doc, "a")
    let rng = @benchmarks.Lcg::new(5)
    for i in 0..<2000 {
      a.push([@lib0.Any::int(i)])
    }
    for i in 0..<500 {
      a.insert(rng.next(a.length() + 1), [@lib0.Any::int(i)])
    }
    it.keep(doc)
  })
}
