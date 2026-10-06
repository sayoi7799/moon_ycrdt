// MoonBit -> Yjs verification.
//
// Reads the report printed by `moon run cmd/export` and checks with the
// official Yjs implementation (version pinned in scripts/package.json) that:
//   1. every MoonBit replica's full state, applied to a fresh Yjs document,
//      reads back as the same text and map content;
//   2. all local updates of all replicas, applied in a shuffled order,
//      converge to that same content;
//   3. replaying exactly the same operations on Yjs replicas with the same
//      client ids yields byte-identical encoded states.
//
// Usage (from the repository root):
//   moon run cmd/export > fixtures/moonbit_out.json
//   node scripts/verify_moonbit.mjs fixtures/moonbit_out.json

import * as fs from 'node:fs'
import * as Y from 'yjs'

const file = process.argv[2] ?? 'fixtures/moonbit_out.json'
const report = JSON.parse(fs.readFileSync(file, 'utf8'))

const fromB64 = (s) => new Uint8Array(Buffer.from(s, 'base64'))
const hex = (u8) => Buffer.from(u8).toString('hex')

// Inverse of `any_to_json` in cmd/export/main.mbt.
const fromJson = (v) => {
  if (Array.isArray(v)) return v.map(fromJson)
  if (v !== null && typeof v === 'object') {
    if ('$undefined' in v) return undefined
    if ('$bigint' in v) return BigInt(v.$bigint)
    if ('$bytes' in v) return fromB64(v.$bytes)
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fromJson(x)]))
  }
  return v
}

// Canonical form for comparison (bigint / bytes / undefined made explicit).
const canon = (v) => JSON.stringify(v, (_k, x) => {
  if (typeof x === 'bigint') return { $bigint: x.toString() }
  if (x instanceof Uint8Array) return { $bytes: Buffer.from(x).toString('base64') }
  if (x === undefined) return { $undefined: true }
  return x
})

const readContent = (doc, names) => ({
  texts: Object.fromEntries(names.texts.map(n => [n, doc.getText(n).toString()])),
  maps: Object.fromEntries(names.maps.map(n => {
    const m = doc.getMap(n)
    return [n, Object.fromEntries([...m.keys()].sort().map(k => [k, m.get(k)]))]
  }))
})

const expectedContent = (d) => ({
  texts: d.texts,
  maps: Object.fromEntries(Object.entries(d.maps).map(([n, m]) =>
    [n, Object.fromEntries(Object.keys(m).sort().map(k => [k, fromJson(m[k])]))]))
})

let failures = 0
let checks = 0
const check = (ok, what) => {
  checks++
  if (!ok) {
    failures++
    console.error(`FAIL ${what}`)
  }
}

for (const c of report.cases) {
  const names = { texts: Object.keys(c.docs[0].texts), maps: Object.keys(c.docs[0].maps) }

  // 1. full state of every replica
  c.docs.forEach((d, i) => {
    const y = new Y.Doc()
    Y.applyUpdate(y, fromB64(d.state))
    check(canon(readContent(y, names)) === canon(expectedContent(d)), `${c.name}: replica ${i} state content`)
    check(hex(Y.encodeStateVector(y)) === hex(fromB64(d.stateVector)), `${c.name}: replica ${i} state vector`)
  })

  // 2. all local updates, shuffled (deterministically), plus external input
  const external = c.ops.filter(o => o.op === 'apply').map(o => fromB64(o.update))
  const locals = c.docs.flatMap(d => d.localUpdates.map(fromB64))
  const all = [...external, ...locals]
  const shuffled = all.map((u, i) => [(i * 7919) % 101, u]).sort((a, b) => a[0] - b[0]).map(x => x[1])
  const y = new Y.Doc()
  for (const u of shuffled) Y.applyUpdate(y, u)
  // only meaningful when the case ends with all replicas in sync
  const lastState = c.docs.map(d => d.state)
  if (lastState.every(s => s === lastState[0])) {
    check(canon(readContent(y, names)) === canon(expectedContent(c.docs[0])), `${c.name}: shuffled local updates`)
  }

  // 3. replay the same operations on Yjs
  const ydocs = c.clients.map(id => {
    const d = new Y.Doc({ gc: false })
    d.clientID = id
    return d
  })
  for (const o of c.ops) {
    switch (o.op) {
      case 'insert': ydocs[o.doc].getText(o.name).insert(o.pos, o.text); break
      case 'delete': ydocs[o.doc].getText(o.name).delete(o.pos, o.len); break
      case 'set': ydocs[o.doc].getMap(o.name).set(o.key, fromJson(o.value)); break
      case 'mapDelete': ydocs[o.doc].getMap(o.name).delete(o.key); break
      case 'sync': Y.applyUpdate(ydocs[o.to], Y.encodeStateAsUpdate(ydocs[o.from], Y.encodeStateVector(ydocs[o.to]))); break
      case 'apply': Y.applyUpdate(ydocs[o.doc], fromB64(o.update)); break
      default: throw new Error(`unknown op ${o.op}`)
    }
  }
  c.docs.forEach((d, i) => {
    check(canon(readContent(ydocs[i], names)) === canon(expectedContent(d)), `${c.name}: replica ${i} replayed content`)
    check(hex(Y.encodeStateAsUpdate(ydocs[i])) === hex(fromB64(d.state)), `${c.name}: replica ${i} replayed state bytes`)
  })

  if (c.name === 'preserve_unknown') {
    // formats, embeds, XML and sub-documents written by Yjs must survive
    const z = new Y.Doc()
    Y.applyUpdate(z, fromB64(c.docs[0].state))
    const delta = z.getText('rich').toDelta()
    check(delta.some(op => op.attributes?.bold === true), `${c.name}: bold format kept`)
    check(delta.some(op => typeof op.insert === 'object' && op.insert.image === 'x.png'), `${c.name}: embed kept`)
    check(z.getXmlFragment('xml').toString() === '<p class="c1">xml text</p><hook-name></hook-name>' ||
      z.getXmlFragment('xml').toString().startsWith('<p class="c1">xml text</p>'), `${c.name}: XML kept`)
    check(z.getMap('docs').get('sub')?.guid === 'sub-guid', `${c.name}: sub-document kept`)
    check(z.getArray('arr').length === 3, `${c.name}: array with nested map kept`)
  }
  console.log(`${c.name}: ok so far (${checks} checks, ${failures} failures)`)
}

if (failures > 0) {
  console.error(`${failures} of ${checks} checks failed`)
  process.exit(1)
}
console.log(`all ${checks} checks passed (yjs ${JSON.parse(fs.readFileSync(new URL('./node_modules/yjs/package.json', import.meta.url))).version})`)
