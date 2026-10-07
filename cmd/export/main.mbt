// MoonBit -> Yjs export: runs scripted edits on MoonBit replicas and prints a
// JSON report (scripts/verify_moonbit.mjs checks it with Yjs):
//
//   moon run cmd/export > fixtures/moonbit_out.json
//   node scripts/verify_moonbit.mjs fixtures/moonbit_out.json

///|
fn b64(b : Bytes) -> Json {
  Json::string(@base64.encode(b))
}

///|
/// `Any` as JSON. Values JSON cannot express are tagged:
/// {"$undefined":true}, {"$bigint":"12"}, {"$bytes":"<base64>"}.
fn any_to_json(v : @lib0.Any) -> Json {
  match v {
    Undefined => Json::object({ "$undefined": Json::boolean(true) })
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Number(d) => Json::number(d)
    BigInt(n) => Json::object({ "$bigint": Json::string(n.to_string()) })
    String(s) => Json::string(s)
    Array(items) => Json::array(items.map(any_to_json))
    Object(entries) => {
      let m = Map([])
      for e in entries {
        m[e.0] = any_to_json(e.1)
      }
      Json::object(m)
    }
    Bytes(b) => Json::object({ "$bytes": b64(b) })
  }
}

///|
/// Runs operations on MoonBit replicas and records them so that the verifier
/// can replay exactly the same operations on Yjs.
priv struct Script {
  name : String
  clients : Array[UInt]
  docs : Array[@doc.Doc]
  logs : Array[Array[Bytes]]
  ops : Array[Json]
  texts : Array[String]
  maps : Array[String]
  arrays : Array[String]
}

///|
fn Script::new(
  name : String,
  clients : Array[UInt],
  texts? : Array[String] = ["t"],
  maps? : Array[String] = [],
  arrays? : Array[String] = [],
) -> Script {
  let docs = clients.map(id => @doc.Doc::new(id))
  let logs : Array[Array[Bytes]] = docs.map(_ => [])
  for i, d in docs {
    d.on_update((u, is_local) => if is_local { logs[i].push(u) })
  }
  { name, clients, docs, logs, ops: [], texts, maps, arrays, }
}

///|
fn Script::insert(
  self : Script,
  doc : Int,
  pos : Int,
  text : String,
  name? : String = "t",
) -> Unit {
  @types.Text::new(self.docs[doc], name).insert(pos, text)
  self.ops.push({
    "op": "insert",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "pos": pos.to_json(),
    "text": text.to_json(),
  })
}

///|
fn Script::delete(
  self : Script,
  doc : Int,
  pos : Int,
  len : Int,
  name? : String = "t",
) -> Unit {
  @types.Text::new(self.docs[doc], name).delete(pos, len)
  self.ops.push({
    "op": "delete",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "pos": pos.to_json(),
    "len": len.to_json(),
  })
}

///|
fn Script::set(
  self : Script,
  doc : Int,
  key : String,
  value : @lib0.Any,
  name? : String = "m",
) -> Unit {
  @types.YMap::new(self.docs[doc], name).set(key, value)
  self.ops.push({
    "op": "set",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "key": key.to_json(),
    "value": any_to_json(value),
  })
}

///|
fn Script::map_delete(
  self : Script,
  doc : Int,
  key : String,
  name? : String = "m",
) -> Unit {
  @types.YMap::new(self.docs[doc], name).delete(key)
  self.ops.push({
    "op": "mapDelete",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "key": key.to_json(),
  })
}

///|
fn Script::array_insert(
  self : Script,
  doc : Int,
  pos : Int,
  values : Array[@lib0.Any],
  name? : String = "a",
) -> Unit {
  @types.YArray::new(self.docs[doc], name).insert(pos, values)
  self.ops.push({
    "op": "arrayInsert",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "pos": pos.to_json(),
    "values": Json::array(values.map(any_to_json)),
  })
}

///|
fn Script::array_push(
  self : Script,
  doc : Int,
  values : Array[@lib0.Any],
  name? : String = "a",
) -> Unit {
  @types.YArray::new(self.docs[doc], name).push(values)
  self.ops.push({
    "op": "arrayPush",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "values": Json::array(values.map(any_to_json)),
  })
}

///|
fn Script::array_delete(
  self : Script,
  doc : Int,
  pos : Int,
  len : Int,
  name? : String = "a",
) -> Unit {
  @types.YArray::new(self.docs[doc], name).delete(pos, len)
  self.ops.push({
    "op": "arrayDelete",
    "doc": doc.to_json(),
    "name": name.to_json(),
    "pos": pos.to_json(),
    "len": len.to_json(),
  })
}

///|
/// Sends `from`'s missing data to `to` as a diff against `to`'s state vector.
fn Script::sync(self : Script, from : Int, to : Int) -> Unit {
  let diff = self.docs[from].encode_state_as_update(
    sv=self.docs[to].state_vector(),
  )
  self.docs[to].apply_update(diff) catch {
    e => abort(e.to_string())
  }
  self.ops.push({ "op": "sync", "from": from.to_json(), "to": to.to_json() })
}

///|
fn Script::sync_all(self : Script) -> Unit {
  for to in 0..<self.docs.length() {
    for from in 0..<self.docs.length() {
      if from != to {
        self.sync(from, to)
      }
    }
  }
}

///|
/// Applies an update produced by Yjs (hex) to replica `doc`.
fn Script::apply_yjs(self : Script, doc : Int, update_hex : String) -> Unit {
  let update = @lib0.from_hex(update_hex) catch { e => abort(e.to_string()) }
  self.docs[doc].apply_update(update) catch {
    e => abort(e.to_string())
  }
  self.ops.push({ "op": "apply", "doc": doc.to_json(), "update": b64(update) })
}

///|
fn Script::report(self : Script) -> Json {
  let docs = self.docs.mapi((i, d) => {
    let texts = Map([])
    for name in self.texts {
      texts[name] = Json::string(@types.Text::new(d, name).to_string())
    }
    let maps = Map([])
    for name in self.maps {
      let m = Map([])
      for e in @types.YMap::new(d, name).entries() {
        m[e.0] = any_to_json(e.1)
      }
      maps[name] = Json::object(m)
    }
    let arrays = Map([])
    for name in self.arrays {
      arrays[name] = Json::array(
        @types.YArray::new(d, name).to_array().map(any_to_json),
      )
    }
    let json : Json = {
      "arrays": Json::object(arrays),
      "client": Json::number(self.clients[i].to_double()),
      "state": b64(d.encode_state_as_update()),
      "stateVector": b64(d.encode_state_vector()),
      "localUpdates": Json::array(self.logs[i].map(b64)),
      "texts": Json::object(texts),
      "maps": Json::object(maps),
    }
    json
  })
  {
    "name": self.name.to_json(),
    "clients": Json::array(self.clients.map(c => Json::number(c.to_double()))),
    "ops": Json::array(self.ops),
    "docs": Json::array(docs),
  }
}

///|
fn text_editing() -> Script {
  let s = Script::new("text_editing", [12345])
  s.insert(0, 0, "Hello world")
  s.insert(0, 5, ",")
  s.insert(0, 12, "!")
  s.delete(0, 0, 1)
  s.insert(0, 0, "h")
  s.insert(0, 6, " 中文 ")
  s.insert(0, text_len(s.docs[0]), "😀👍")
  // delete inside a surrogate pair: both halves become U+FFFD, like Yjs
  s.delete(0, text_len(s.docs[0]) - 3, 1)
  s.insert(0, 3, "🎉")
  s.delete(0, 2, 5)
  s
}

///|
fn text_len(d : @doc.Doc) -> Int {
  @types.Text::new(d, "t").length()
}

///|
fn map_values() -> Script {
  let s = Script::new("map_values", [3000000001], texts=[], maps=["m"])
  s.set(0, "int", @lib0.Any::int(42))
  s.set(0, "negative", @lib0.Any::int(-7))
  s.set(0, "float", Number(1.5))
  s.set(0, "double", Number(0.1))
  s.set(0, "big", BigInt(1099511627776L))
  s.set(0, "text", String("中文 😀"))
  s.set(0, "flags", Array([Bool(true), Bool(false), Null, Undefined]))
  s.set(
    0,
    "object",
    Object([("a", @lib0.Any::int(1)), ("nested", Object([("b", Array([]))]))]),
  )
  s.set(0, "bytes", Bytes(b"\x01\x02\xff"))
  s.set(0, "int", @lib0.Any::int(43))
  s.map_delete(0, "negative")
  s.set(0, "negative", @lib0.Any::int(-8))
  s.map_delete(0, "double")
  s
}

///|
fn concurrent_two() -> Script {
  let s = Script::new("concurrent_two", [1, 2], maps=["m"])
  s.insert(0, 0, "base text")
  s.sync(0, 1)
  // both insert at the same position without seeing each other
  s.insert(0, 4, "[A]")
  s.insert(1, 4, "[B]")
  s.insert(0, 0, "a0")
  s.insert(1, 0, "b0")
  s.delete(1, 6, 3)
  s.set(0, "who", String("first"))
  s.set(1, "who", String("second"))
  s.sync(1, 0)
  s.insert(0, 2, "<after-sync>")
  s.sync_all()
  s
}

///|
fn concurrent_three() -> Script {
  let s = Script::new("concurrent_three", [7, 4000000000, 3], maps=["m"])
  s.insert(0, 0, "abc")
  s.sync_all()
  s.insert(0, 1, "X")
  s.insert(1, 1, "Y")
  s.insert(2, 1, "Z")
  s.delete(2, 0, 2)
  s.sync(2, 1)
  s.insert(1, 2, "😀")
  s.delete(0, 3, 1)
  s.set(2, "k", @lib0.Any::int(3))
  s.set(0, "k", @lib0.Any::int(1))
  s.sync(1, 0)
  s.insert(0, 0, ">")
  s.sync_all()
  s.insert(1, 3, "after")
  s.sync_all()
  s
}

///|
fn preserve_unknown() -> Script {
  // A Yjs document with bold/italic formats, an embed, XML elements, a hook
  // and a sub-document. MoonBit edits it; the verifier checks that Yjs still
  // sees all of that content.
  let s = Script::new("preserve_unknown", [55], texts=["rich"], maps=["m"])
  s.apply_yjs(0, yjs_rich_text_update)
  s.apply_yjs(0, yjs_nested_types_update)
  s.insert(0, 2, "-in-bold-", name="rich")
  // deletes the end of the bold run right before the embed: Yjs cleans up
  // the formatting gap, and so must we
  s.delete(0, 12, 2, name="rich")
  s.delete(0, 4, 3, name="rich")
  s.insert(0, text_len_of(s.docs[0], "rich"), " end", name="rich")
  s.set(0, "plain", String("value"))
  s
}

///|
fn text_len_of(d : @doc.Doc, name : String) -> Int {
  @types.Text::new(d, name).length()
}

///|
fn arrays() -> Script {
  let s = Script::new("arrays", [21, 3000000002], texts=[], arrays=["a"])
  s.array_push(0, [@lib0.Any::int(1), String("two"), Bytes(b""), Null])
  s.sync_all()
  // concurrent inserts at the same index, deletes and pushes
  s.array_insert(0, 1, [String("A"), Object([("k", Bool(true))])])
  s.array_insert(1, 1, [String("B")])
  s.array_delete(1, 2, 1)
  s.array_push(0, [Array([@lib0.Any::int(5)])])
  s.array_push(1, [String("end")])
  s.sync(1, 0)
  s.array_delete(0, 0, 2)
  s.array_insert(0, 0, [Bytes(b"ÿ "), @lib0.Any::int(-3)])
  s.sync_all()
  s
}

///|
fn main {
  let cases = [
    text_editing(),
    map_values(),
    concurrent_two(),
    concurrent_three(),
    preserve_unknown(),
    arrays(),
  ]
  let report : Json = {
    "generator": "moon_ycrdt cmd/export",
    "cases": Json::array(cases.map(c => c.report())),
  }
  println(report.stringify(indent=2))
}
