// Property-based tests (moonbitlang/core/quickcheck). A random script of
// integer triples drives edits on three MoonBit replicas; the properties are
// checked on the updates those replicas produce.

///|
let chunks : Array[String] = ["a", "bc", "中", "😀", "x😀y", " "]

///|
fn nonneg(n : Int) -> Int {
  if n < 0 {
    -(n + 1)
  } else {
    n
  }
}

///|
/// Result of running a script: every local update of every replica, in the
/// order they were produced.
priv struct Session {
  logs : Array[Array[Bytes]]
}

///|
/// Interprets `(op, a, b)` triples: insert / delete text or set / delete map
/// keys on replica `a % 3`, or send replica `a % 3`'s updates to `b % 3`
/// (partial syncs make later edits concurrent with earlier ones).
fn run_script(script : Array[(Int, Int, Int)]) -> Session {
  let docs = [1U, 2U, 3000000000U].map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  for step in script {
    let (op, a, b) = step
    let r = nonneg(a) % 3
    let text = @types.Text::new(docs[r], "t")
    let map = @types.YMap::new(docs[r], "m")
    match nonneg(op) % 5 {
      0 | 1 => {
        let pos = nonneg(b) % (text.length() + 1)
        text.insert(pos, chunks[nonneg(b) % chunks.length()])
      }
      2 =>
        if text.length() > 0 {
          let pos = nonneg(b) % text.length()
          text.delete(
            pos,
            @cmp.minimum(1 + nonneg(op) % 3, text.length() - pos),
          )
        }
      3 =>
        if nonneg(b) % 4 == 0 {
          map.delete("k\{nonneg(op) % 3}")
        } else {
          map.set("k\{nonneg(op) % 3}", @lib0.Any::int(b))
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
fn all_updates(s : Session) -> Array[Bytes] {
  let out = []
  for log in s.logs {
    out.append(log)
  }
  out
}

///|
fn has_structs(u : Bytes) -> Bool {
  let update = @update.decode_update(u) catch { e => abort(e.to_string()) }
  update.clients.length() > 0
}

///|
fn first_insert(log : Array[Bytes]) -> Int? {
  for i, u in log {
    if has_structs(u) {
      return Some(i)
    }
  }
  None
}

///|
/// Observable state of a replica: text, map entries and state vector.
fn observe(d : @doc.Doc) -> String {
  let text = @types.Text::new(d, "t").to_string()
  let entries = @types.YMap::new(d, "m").entries()
  let sb = StringBuilder()
  sb.write_string(text.escape())
  for e in entries {
    sb.write_string(" \{e.0}=")
    sb.write_string(e.1.to_string())
  }
  sb.write_string(" ")
  sb.write_string(@lib0.to_hex(d.encode_state_vector()))
  sb.to_string()
}

///|
fn apply_all(d : @doc.Doc, updates : Array[Bytes]) -> Unit {
  for u in updates {
    d.apply_update(u) catch {
      e => abort(e.to_string())
    }
  }
}

///|
/// Deterministic permutation of `xs` driven by `keys`.
fn permute(xs : Array[Bytes], keys : Array[Int]) -> Array[Bytes] {
  let out = xs.copy()
  for i in 0..<out.length() {
    let j = if keys.length() == 0 {
      i
    } else {
      i + nonneg(keys[i % keys.length()]) % (out.length() - i)
    }
    let tmp = out[i]
    out[i] = out[j]
    out[j] = tmp
  }
  out
}

///|
test "property: any exchange order converges to the same state" {
  @quickcheck.check(
    (input : (Array[(Int, Int, Int)], Array[Int])) => {
      let (script, keys) = input
      let session = run_script(script)
      let updates = all_updates(session)
      let a = @doc.Doc::new(77)
      let b = @doc.Doc::new(78)
      apply_all(a, updates)
      apply_all(b, permute(updates, keys))
      // a reversed order with every update delivered twice
      let c = @doc.Doc::new(79)
      let twice = updates.rev()
      twice.append(updates)
      apply_all(c, twice)
      observe(a) == observe(b) && observe(a) == observe(c) && !b.has_pending()
    },
    count=300,
  )
}

///|
test "property: applying an update twice does not change the state" {
  @quickcheck.check(
    (script : Array[(Int, Int, Int)]) => {
      let session = run_script(script)
      let d = @doc.Doc::new(77)
      let mut ok = true
      for u in all_updates(session) {
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
test "property: updates with missing dependencies wait in pending" {
  @quickcheck.check(
    (script : Array[(Int, Int, Int)]) => {
      let session = run_script(script)
      // Replica 0's updates that insert content form a chain: each depends on
      // the previous ones of the same client. Withhold the first of them.
      let log = session.logs[0]
      let withheld = first_insert(log).unwrap()
      let d = @doc.Doc::new(77)
      let mut ok = true
      apply_all(d, session.logs[1])
      apply_all(d, session.logs[2])
      for i, u in log {
        if i != withheld {
          apply_all(d, [u])
        }
      }
      let later_inserts = log[withheld + 1:].iter().any(has_structs)
      if later_inserts {
        ok = ok && d.has_pending()
        // pending data is kept when re-encoding (a relay loses nothing)
        let relay = @doc.Doc::new(79)
        apply_all(relay, [d.encode_state_as_update()])
        ok = ok && relay.has_pending()
      }
      // the missing update arrives: everything is applied automatically
      apply_all(d, [log[withheld]])
      let reference = @doc.Doc::new(78)
      apply_all(reference, all_updates(session))
      ok && !d.has_pending() && observe(d) == observe(reference)
    },
    filter=script => first_insert(run_script(script).logs[0]) is Some(_),
    count=300,
  )
}
