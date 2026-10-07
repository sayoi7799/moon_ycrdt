// Creates a small Yjs document and prints it as a base64 v1 update, as input
// for the MoonBit round-trip example:
//
//   node scripts/make_example_input.mjs > input.txt
//   moon run examples/roundtrip -- "$(cat input.txt)"
//
// Usage: node scripts/make_example_input.mjs [clientID]

import * as Y from 'yjs'

const doc = new Y.Doc()
doc.clientID = Number(process.argv[2] ?? 4242)
doc.getText('doc').insert(0, 'Written in Yjs ✍️')
const meta = doc.getMap('meta')
meta.set('author', 'yjs')
meta.set('version', 1)
meta.set('tags', ['crdt', 'interop'])
console.log(Buffer.from(Y.encodeStateAsUpdate(doc)).toString('base64'))
