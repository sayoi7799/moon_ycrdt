# moon_ycrdt

A MoonBit CRDT library that speaks the [Yjs](https://github.com/yjs/yjs) binary
update format (v1), so MoonBit programs can exchange documents with Yjs-based
editors, y-websocket servers and Yrs backends.

> Work in progress (MoonBit hackathon MVP).

## Packages

| package | contents |
|---|---|
| `lib0` | lib0-compatible binary encoding: varUint, varInt, varString, byte arrays, float32/64, bigint, `Any`, hex helpers |
| `update` | Yjs update format v1 as plain data: `ID`, all 9 content kinds, Item / GC / Skip structs, `DeleteSet`, state vectors; byte-exact decode/encode |
| `doc` | `Doc` with client id, per-client struct store, YATA integration, pending queue for updates with missing dependencies, `apply_update`, `encode_state_as_update` (optionally against a state vector), `encode_state_vector`, per-transaction update events |
| `types` | `Text` (insert / delete / to_string, UTF-16 positions) and `YMap` (set / get / delete with `Any` values) |
| `tests` | interop tests against Yjs fixtures, 200 random convergence scenarios, quickcheck properties |

## Test fixtures

All expected values in tests come from the official JavaScript
implementations, never from hand-written numbers:

- generator: [`scripts/gen_fixtures.mjs`](scripts/gen_fixtures.mjs)
- pinned versions: `yjs@13.6.33`, `lib0@0.2.119` (see
  [`scripts/package.json`](scripts/package.json) and `package-lock.json`)
- output: `fixtures/*.json` (human-readable record) and `<pkg>/*_gen_test.mbt`
  (the same data embedded as MoonBit code, because the wasm-gc backend cannot
  read files)

Regenerate with:

```bash
cd scripts && npm ci && node gen_fixtures.mjs && cd .. && moon fmt
```

## References and licenses

This project re-implements the Yjs protocol in MoonBit. It follows the
behaviour and wire format of the projects below; no code is translated line by
line.

| project | license | used for |
|---|---|---|
| [yjs](https://github.com/yjs/yjs) | MIT | update format v1, struct store, YATA integration, Y.Text / Y.Map semantics; fixture generation |
| [lib0](https://github.com/dmonad/lib0) | MIT | binary encoding (varUint, varInt, strings, `Any`); fixture generation |
| [y-protocols](https://github.com/yjs/y-protocols) | MIT | state-vector / update sync semantics |

moon_ycrdt itself is licensed under Apache-2.0 (see [LICENSE](LICENSE)).
