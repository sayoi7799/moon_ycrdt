// Two MoonBit replicas edit the same text concurrently, exchange updates in
// the Yjs v1 format and converge. The final state is printed as base64 so
// that it can be loaded by Yjs (see README: "Reading the result with Yjs").
//
//   moon run examples/concurrent

///|
fn main {
  // Every replica needs its own client id (Yjs uses random 32-bit ids).
  let alice = @doc.Doc::new(1001)
  let bob = @doc.Doc::new(2002)

  // Collect the updates each replica produces, like `doc.on('update')`.
  let from_alice : Array[Bytes] = []
  let from_bob : Array[Bytes] = []
  alice.on_update((u, is_local) => if is_local { from_alice.push(u) })
  bob.on_update((u, is_local) => if is_local { from_bob.push(u) })

  let alice_text = @types.Text::new(alice, "doc")
  let bob_text = @types.Text::new(bob, "doc")

  // A shared starting point.
  alice_text.insert(0, "Hello world")
  for u in from_alice {
    bob.apply_update(u) catch {
      e => abort(e.to_string())
    }
  }
  from_alice.clear()
  println("start:  \{alice_text}")

  // Both edit the same position at the same time, without seeing each other.
  alice_text.insert(5, ", Alice")
  bob_text.insert(5, ", Bob")
  bob_text.delete(0, 1)
  bob_text.insert(0, "h")
  println("alice:  \{alice_text}")
  println("bob:    \{bob_text}")

  // Exchange the updates (in reverse order, to show that order does not
  // matter: updates whose dependencies are missing wait in a queue).
  for u in from_bob.rev() {
    alice.apply_update(u) catch {
      e => abort(e.to_string())
    }
  }
  for u in from_alice {
    bob.apply_update(u) catch {
      e => abort(e.to_string())
    }
  }
  println("merged: \{alice_text}")
  println("bob:    \{bob_text}")
  guard alice_text.to_string() == bob_text.to_string() else {
    abort("replicas did not converge")
  }

  // The whole document as one Yjs v1 update.
  let state = alice.encode_state_as_update()
  println("update (base64): \{@base64.encode(state)}")
}
