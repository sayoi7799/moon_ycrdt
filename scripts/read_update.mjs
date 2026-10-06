// Loads a Yjs v1 update given as base64 and prints the document content.
//
//   node scripts/read_update.mjs <base64> [textName]
//
// Example: node scripts/read_update.mjs "$(moon run examples/concurrent | tail -1 | cut -d' ' -f3)" doc

import * as Y from 'yjs'

const [b64, textName = 'doc'] = process.argv.slice(2)
if (!b64) {
  console.error('usage: node scripts/read_update.mjs <base64> [textName]')
  process.exit(1)
}
const doc = new Y.Doc()
Y.applyUpdate(doc, new Uint8Array(Buffer.from(b64, 'base64')))
console.log(`${textName}: ${JSON.stringify(doc.getText(textName).toString())}`)
console.log('state vector:', Object.fromEntries(Y.decodeStateVector(Y.encodeStateVector(doc))))
