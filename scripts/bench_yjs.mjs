// Runs the workloads of `benchmarks/workloads.mbt` on Yjs, to compare with
// `moon bench -p sayoi7799/moon_ycrdt/benchmarks --target native --release`.
//
//   node scripts/bench_yjs.mjs            # a markdown table
//   node scripts/bench_yjs.mjs --json     # the same as JSON
//
// The workloads are the same: the same pseudo random numbers (the
// linear congruential generator of `Lcg` in workloads.mbt), the same seeds,
// the same sizes, every edit in a transaction of its own. Every workload runs
// in a fresh document, in a loop of at least 10 runs and one second, after
// three warm-up runs; the mean time of one run is reported. Yjs is measured with
// `gc: true` (its default) and `gc: false` (what moon_ycrdt does: deleted
// content stays).

import * as Y from 'yjs'

class Lcg {
  constructor (seed) { this.state = seed >>> 0 }
  next (bound) {
    this.state = (Math.imul(this.state, 1664525) + 1013904223) >>> 0
    return ((this.state >>> 8) & 0x7FFFFF) % bound
  }
}

const randomInserts = (text, n, seed) => {
  const rng = new Lcg(seed)
  for (let i = 0; i < n; i++) text.insert(rng.next(text.length + 1), 'ab')
}

const randomDeletes = (text, n, seed) => {
  const rng = new Lcg(seed)
  for (let i = 0; i < n; i++) {
    if (text.length === 0) break
    const pos = rng.next(text.length)
    const len = Math.min(1 + rng.next(3), text.length - pos)
    text.delete(pos, len)
  }
}

const fragmentedDocument = (gc) => {
  const doc = new Y.Doc({ gc })
  const text = doc.getText('t')
  randomInserts(text, 4000, 42)
  randomDeletes(text, 2000, 43)
  return Y.encodeStateAsUpdate(doc)
}

const workloads = (gc) => {
  const fragmented = fragmentedDocument(gc)
  const loaded = new Y.Doc({ gc })
  Y.applyUpdate(loaded, fragmented)
  return [
    ['type 2000 characters at the end', () => {
      const doc = new Y.Doc({ gc })
      const text = doc.getText('t')
      for (let i = 0; i < 2000; i++) text.insert(text.length, i % 10 === 9 ? ' ' : 'x')
    }],
    ['2000 inserts at random positions', () => {
      const doc = new Y.Doc({ gc })
      randomInserts(doc.getText('t'), 2000, 1)
    }],
    ['1000 random deletes in a 4000-character text', () => {
      const doc = new Y.Doc({ gc })
      const text = doc.getText('t')
      randomInserts(text, 2000, 1)
      randomDeletes(text, 1000, 2)
    }],
    ['apply a fragmented 4k-item document', () => {
      Y.applyUpdate(new Y.Doc({ gc }), fragmented)
    }],
    ['encode the state of a fragmented 4k-item document', () => {
      Y.encodeStateAsUpdate(loaded)
    }],
    ['map: 5000 sets on 100 keys', () => {
      const doc = new Y.Doc({ gc })
      const m = doc.getMap('m')
      for (let i = 0; i < 5000; i++) m.set(`key${i % 100}`, i)
    }],
    ['array: 2000 pushes and 500 random inserts', () => {
      const doc = new Y.Doc({ gc })
      const a = doc.getArray('a')
      const rng = new Lcg(5)
      for (let i = 0; i < 2000; i++) a.push([i])
      for (let i = 0; i < 500; i++) a.insert(rng.next(a.length + 1), [i])
    }],
    ['text: 100k characters, 5000 random inserts and 5000 random deletes', () => {
      const doc = new Y.Doc({ gc })
      const text = doc.getText('t')
      text.insert(0, 'abcdefghij'.repeat(10000))
      randomInserts(text, 5000, 11)
      randomDeletes(text, 5000, 12)
    }],
    ['array: 100k values, 5000 random inserts and 5000 random deletes', () => {
      const doc = new Y.Doc({ gc })
      const a = doc.getArray('a')
      a.insert(0, Array.from({ length: 100000 }, (_, i) => i))
      const rng = new Lcg(13)
      for (let i = 0; i < 5000; i++) a.insert(rng.next(a.length + 1), [i])
      for (let i = 0; i < 5000; i++) {
        const pos = rng.next(a.length)
        a.delete(pos, Math.min(1 + rng.next(3), a.length - pos))
      }
    }]
  ]
}

const measure = (f) => {
  for (let i = 0; i < 3; i++) f()
  const times = []
  const start = process.hrtime.bigint()
  while (times.length < 10 || Number(process.hrtime.bigint() - start) < 1e9) {
    const t0 = process.hrtime.bigint()
    f()
    times.push(Number(process.hrtime.bigint() - t0) / 1e6)
  }
  return times.reduce((a, b) => a + b, 0) / times.length
}

const results = {}
for (const gc of [true, false]) {
  for (const [name, f] of workloads(gc)) {
    results[name] ??= {}
    results[name][gc ? 'gc' : 'noGc'] = measure(f)
  }
}

const fmt = (ms) => ms < 1 ? `${(ms * 1000).toFixed(0)} µs` : ms < 100 ? `${ms.toFixed(2)} ms` : `${ms.toFixed(0)} ms`
if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ node: process.version, yjs: Y.Doc ? 'yjs' : '', results }, null, 2))
} else {
  console.log(`Node ${process.version}`)
  console.log('| workload | Yjs (gc: true) | Yjs (gc: false) |')
  console.log('|---|---|---|')
  for (const [name, r] of Object.entries(results)) console.log(`| ${name} | ${fmt(r.gc)} | ${fmt(r.noGc)} |`)
}
