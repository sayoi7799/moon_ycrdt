// A textarea that edits a shared Y.Text through the official y-websocket client.
//
//   http://localhost:5173/?room=demo&server=ws://localhost:1234

import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'

const params = new URLSearchParams(location.search)
const room = params.get('room') || 'demo'
const server = params.get('server') || `ws://${location.hostname || 'localhost'}:1234`

const editor = document.getElementById('editor')
const status = document.getElementById('status')
document.getElementById('room').textContent = room

const doc = new Y.Doc()
const text = doc.getText('doc')
// No BroadcastChannel: two windows of this page would otherwise sync with each
// other directly, and the server would not be needed for the demo.
const provider = new WebsocketProvider(server, room, doc, { disableBc: true })

provider.on('status', ({ status: s }) => {
  status.textContent = s === 'connected' ? `connected to ${server}` : `${s}…`
  status.classList.toggle('connected', s === 'connected')
})
provider.on('sync', synced => {
  // typing is allowed once the server has sent what it has
  editor.disabled = !synced
})

// The origin of the changes that come from this textarea.
const LOCAL = 'textarea'

// What the user typed, as one deletion and one insertion: the text that the
// old and the new value share at both ends is left alone.
editor.addEventListener('input', () => {
  const before = text.toString()
  const after = editor.value
  let start = 0
  while (start < before.length && start < after.length && before[start] === after[start]) {
    start++
  }
  let endBefore = before.length
  let endAfter = after.length
  while (endBefore > start && endAfter > start && before[endBefore - 1] === after[endAfter - 1]) {
    endBefore--
    endAfter--
  }
  doc.transact(() => {
    if (endBefore > start) text.delete(start, endBefore - start)
    if (endAfter > start) text.insert(start, after.slice(start, endAfter))
  }, LOCAL)
})

/**
 * Where a caret at `pos` ends up after the change described by `delta`.
 * `index` is a position in the text before the change.
 */
function moveCaret (pos, delta) {
  let index = 0
  let result = pos
  for (const op of delta) {
    if (op.retain) {
      index += op.retain
    } else if (op.insert) {
      // text inserted at or before the caret pushes it to the right
      if (index <= pos) result += op.insert.length
    } else if (op.delete) {
      if (index < pos) result -= Math.min(op.delete, pos - index)
      index += op.delete
    }
  }
  return result
}

text.observe(event => {
  if (event.transaction.origin === LOCAL) return
  const { selectionStart, selectionEnd } = editor
  const delta = event.delta
  editor.value = text.toString()
  // the caret stays where it was in the text, not at the end
  editor.setSelectionRange(moveCaret(selectionStart, delta), moveCaret(selectionEnd, delta))
})
