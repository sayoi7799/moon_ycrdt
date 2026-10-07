// Yjs -> MoonBit -> Yjs round trip.
//
// 1. Load a document written by Yjs (base64 v1 update from the command line,
//    or the built-in sample).
// 2. Sync it to a second MoonBit replica with state vectors, so that only the
//    missing part is sent.
// 3. Edit on both replicas and deliver one replica's updates out of order:
//    the update with a missing dependency waits until the dependency arrives.
// 4. Print the result as base64 for Yjs to read.
//
//   node scripts/make_example_input.mjs > input.txt
//   moon run examples/roundtrip -- "$(cat input.txt)"
//   node scripts/read_update.mjs "<printed base64>" doc

///|
/// Output of `node scripts/make_example_input.mjs` (client id 4242).
let sample_input : String = "AQSSIQAEAQNkb2MVV3JpdHRlbiBpbiBZanMg4pyN77iPKAEEbWV0YQZhdXRob3IBdwN5anMoAQRtZXRhB3ZlcnNpb24BfQEoAQRtZXRhBHRhZ3MBdQJ3BGNyZHR3B2ludGVyb3AA"

///|
/// A random 32-bit client id like Yjs uses, when the platform provides
/// randomness; a fixed id otherwise.
fn random_client_id(fallback : UInt) -> UInt {
  match @env.rand(4) {
    Some(b) if b.length() == 4 =>
      (b[0].to_uint() << 24) |
      (b[1].to_uint() << 16) |
      (b[2].to_uint() << 8) |
      b[3].to_uint()
    _ => fallback
  }
}

///|
/// Command-line arguments after the program: on the JS backend the list starts
/// with the node executable and the script, elsewhere with the program only.
fn user_args() -> Array[String] {
  let args = @env.args()
  let skip = match args {
    [first, ..] if first.has_suffix("node") || first.has_suffix("node.exe") => 2
    _ => 1
  }
  if args.length() > skip {
    args[skip:].to_owned()
  } else {
    []
  }
}

///|
fn apply(doc : @doc.Doc, update : Bytes) -> Unit {
  doc.apply_update(update) catch {
    e => abort("invalid update: \{e}")
  }
}

///|
fn show(label : String, doc : @doc.Doc) -> Unit {
  let text = @types.Text::new(doc, "doc")
  let meta = @types.YMap::new(doc, "meta")
  let entries = meta.entries().map(e => "\{e.0}=\{e.1}").join(", ")
  println("\{label}: \{text.to_string().escape()} | meta: {\{entries}}")
}

///|
fn main {
  let input = match user_args() {
    [arg, ..] => arg
    [] => sample_input
  }
  let update = @base64.decode(input) catch {
    _ => abort("the argument is not base64")
  }

  // 1. load the Yjs document
  let moon = @doc.Doc::new(random_client_id(1001))
  apply(moon, update)
  show("loaded from Yjs", moon)

  // 2. state-vector sync: the peer announces what it has, we send the rest
  let peer = @doc.Doc::new(random_client_id(2002))
  let diff = @doc.encode_state_as_update(
    moon,
    target_state_vector=peer.encode_state_vector(),
  ) catch {
    e => abort(e.to_string())
  }
  apply(peer, diff)
  show("peer after sync", peer)
  // nothing is missing any more: the next diff is empty
  let again = @doc.encode_state_as_update(
    moon,
    target_state_vector=peer.encode_state_vector(),
  ) catch {
    e => abort(e.to_string())
  }
  println("second diff: \{again.length()} bytes (\{@lib0.to_hex(again)})")

  // 3. concurrent edits; the peer's updates arrive in reverse order
  let peer_updates : Array[Bytes] = []
  peer.on_update((u, is_local) => if is_local { peer_updates.push(u) })
  @types.Text::new(moon, "doc").insert(0, "[MoonBit] ")
  @types.YMap::new(moon, "meta").set("editor", String("moonbit"))
  let peer_text = @types.Text::new(peer, "doc")
  peer_text.insert(peer_text.length(), " — synced")
  peer_text.insert(peer_text.length(), " ✓")
  @types.YMap::new(peer, "meta").set("version", @lib0.Any::int(2))
  apply(moon, peer_updates[peer_updates.length() - 1])
  apply(moon, peer_updates[1])
  println(
    "after out-of-order delivery, waiting for dependencies: \{moon.has_pending()}",
  )
  apply(moon, peer_updates[0])
  println("after the missing update arrived, waiting: \{moon.has_pending()}")
  // our own edits go to the peer as a diff against its state vector
  let back = @doc.encode_state_as_update(
    moon,
    target_state_vector=peer.encode_state_vector(),
  ) catch {
    e => abort(e.to_string())
  }
  apply(peer, back)
  show("moonbit", moon)
  show("peer   ", peer)
  guard @lib0.to_hex(moon.encode_state_vector()) ==
    @lib0.to_hex(peer.encode_state_vector()) &&
    @types.Text::new(moon, "doc").to_string() == peer_text.to_string() else {
    abort("replicas did not converge")
  }

  // 4. hand the document back to Yjs
  println("update (base64): \{@base64.encode(moon.encode_state_as_update())}")
}
