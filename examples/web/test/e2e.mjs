// End-to-end test of the MoonBit y-websocket server with the official
// y-websocket client.
//
//   node test/e2e.mjs <path to the server executable>
//
// Two clients edit one room and must see each other's changes; a client of
// another room must see nothing of it. After the server is stopped and started
// again, a new client must find the document as it was.

import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { connect as connectTcp } from 'node:net'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'

const server = process.argv[2]
if (!server) {
  console.error('usage: node test/e2e.mjs <server executable>')
  process.exit(2)
}

const port = 41000 + Math.floor(Math.random() * 2000)
const url = `ws://127.0.0.1:${port}`
const dataDir = mkdtempSync(join(tmpdir(), 'moon-ycrdt-e2e-'))

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

async function waitFor (what, condition, timeout = 5000) {
  const start = Date.now()
  while (!condition()) {
    if (Date.now() - start > timeout) {
      throw new Error(`timeout waiting for ${what}`)
    }
    await sleep(20)
  }
}

/** Resolves once something accepts TCP connections on the port. */
function waitForPort (timeout = 15000) {
  const start = Date.now()
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = connectTcp({ port, host: '127.0.0.1' })
      socket.once('connect', () => {
        socket.destroy()
        resolve()
      })
      socket.once('error', () => {
        socket.destroy()
        if (Date.now() - start > timeout) {
          reject(new Error('the server did not start listening'))
        } else {
          setTimeout(attempt, 50)
        }
      })
    }
    attempt()
  })
}

/** Starts the server and resolves once it accepts connections. */
async function startServer () {
  const child = spawn(server, ['--port', String(port), '--data', dataDir, '--save-interval', '1'], {
    stdio: ['ignore', 'inherit', 'inherit']
  })
  const failed = new Promise((_, reject) => {
    child.once('error', reject)
    child.once('exit', code => reject(new Error(`server exited early (${code})`)))
  })
  await Promise.race([waitForPort(), failed])
  child.removeAllListeners('exit')
  return child
}

/** A client like a browser tab: its own doc, the official provider. */
async function connect (room) {
  const doc = new Y.Doc()
  // no BroadcastChannel: every change has to travel through the server
  const provider = new WebsocketProvider(url, room, doc, { disableBc: true })
  await waitFor(`${room} to sync`, () => provider.synced)
  return { doc, text: doc.getText('doc'), provider }
}

/** Stops the server and waits until it is gone. */
function stopServer (child) {
  return new Promise(resolve => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve()
    child.once('exit', resolve)
    child.kill()
  })
}

function close (...clients) {
  for (const c of clients) {
    c.provider.destroy()
    c.doc.destroy()
  }
}

let serverProcess
let exitCode = 0
try {
  serverProcess = await startServer()

  // 1. an edit in one client shows up in the other
  const a = await connect('room-1')
  const b = await connect('room-1')
  a.text.insert(0, 'hello')
  await waitFor('b to see "hello"', () => b.text.toString() === 'hello')
  b.text.insert(5, ' world')
  await waitFor('a to see "hello world"', () => a.text.toString() === 'hello world')
  console.log('ok: edits travel both ways')

  // 2. concurrent edits converge to the same document
  a.text.insert(0, 'A:')
  b.text.insert(b.text.length, ':B')
  await waitFor('both clients to converge', () =>
    a.text.toString() === b.text.toString() && a.text.length === 'A:hello world:B'.length)
  assert.equal(a.text.toString(), 'A:hello world:B')
  assert.deepEqual(Y.encodeStateVector(a.doc), Y.encodeStateVector(b.doc))
  console.log('ok: concurrent edits converge')

  // 3. a client that joins late gets the whole document
  const c = await connect('room-1')
  await waitFor('late client to see the document', () => c.text.toString() === 'A:hello world:B')
  console.log('ok: late joiner is brought up to date')

  // 4. rooms are separate
  const other = await connect('room-2')
  await sleep(200)
  assert.equal(other.text.toString(), '')
  other.text.insert(0, 'elsewhere')
  await sleep(200)
  assert.equal(a.text.toString(), 'A:hello world:B')
  console.log('ok: rooms are isolated')

  close(a, b, c, other)

  // 5. the document is saved to a file that Yjs can read
  const file = join(dataDir, 'room-1.ydoc')
  await waitFor('the room to be saved', () => existsSync(file), 10000)
  await sleep(1500) // the last edit is in a later save than the first one
  const saved = new Y.Doc()
  Y.applyUpdate(saved, readFileSync(file))
  assert.equal(saved.getText('doc').toString(), 'A:hello world:B')
  console.log('ok: the saved file is a Yjs update')

  // 6. after a restart the new clients still find the document
  await stopServer(serverProcess)
  serverProcess = await startServer()
  const d = await connect('room-1')
  await waitFor('the document to come back', () => d.text.toString() === 'A:hello world:B')
  d.text.insert(0, '>')
  const e = await connect('room-1')
  await waitFor('the edit after the restart', () => e.text.toString() === '>A:hello world:B')
  const empty = await connect('room-2')
  await waitFor('room-2 to come back', () => empty.text.toString() === 'elsewhere')
  close(d, e, empty)
  console.log('ok: the rooms survive a restart')

  console.log('all end-to-end checks passed')
} catch (err) {
  console.error(err)
  exitCode = 1
} finally {
  // the server may still be writing a room file: wait until it is gone
  if (serverProcess) await stopServer(serverProcess)
  rmSync(dataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
}
process.exit(exitCode)
