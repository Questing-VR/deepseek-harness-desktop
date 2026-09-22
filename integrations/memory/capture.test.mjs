/**
 * Prove that dsh-memory's automatic capture and per-turn recall actually fire.
 *
 * Why this test exists: the capture block shipped reading `event.text ??
 * event.message ?? event.content`. A session event is `{ type, seq, time, data }`,
 * so none of those exist, every turn/end produced an empty string and the store
 * filled with nothing. The failure was invisible — the plugin logged
 * "automatic capture registered" and the store simply stayed empty — so the only
 * honest check is to drive the real event shapes through apply() and look for the
 * record.
 *
 * It runs against a throwaway store (`DSH_MEMORY_STORE`), so it never touches the
 * live memory database.
 *
 *   node memory/capture.test.mjs
 */
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'

const workDir = mkdtempSync(join(tmpdir(), 'dsh-memory-capture-'))
process.env.DSH_MEMORY_STORE = join(workDir, 'capture.sqlite3')
// The panel mirror posts here; the stub below records the call instead of
// reaching a real server, so this test works with the panel up or down.
process.env.RSI_PANEL_URL = 'http://127.0.0.1:18803'
process.env.LOCAL_MODEL_API_KEY = 'test-panel-token'

const mirrorCalls = []
const realFetch = globalThis.fetch
globalThis.fetch = async (url, options) => {
  mirrorCalls.push({ url: String(url), options })
  return { ok: true, status: 200, text: async () => '{}' }
}

const plugin = await import('./plugin/index.js')

// Read the throwaway store directly: retrieve() rejects an empty query, and the
// point here is what landed in the table, not how ranking would find it.
const { DatabaseSync } = await import('node:sqlite')
// Opened after apply(): the plugin is what creates and migrates the store.
let db
const capturedRows = () =>
  db.prepare("SELECT id, title, body, kind, active, scope, source FROM memories WHERE source = 'automatic capture (turn/end)'").all()
const totalMemories = () => db.prepare('SELECT count(*) AS n FROM memories').get().n

const listeners = new Map()
let recallOptions = null
const tools = []

plugin.apply({
  get: (name) => (name === 'systemPrompt' ? { context: (options) => { recallOptions = options } } : undefined),
  on: (event, handler) => { listeners.set(event, handler) },
  tools: { register: (tool) => tools.push(tool) },
})

db = new DatabaseSync(process.env.DSH_MEMORY_STORE, { readOnly: true })

const failures = []
const check = (label, ok, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail === '' ? '' : `  — ${detail}`}`)
  if (!ok) failures.push(label)
}

check('plugin registered the memory tools', tools.length >= 2, `tools=[${tools.map((t) => t.name).join(', ')}]`)
check('plugin registered per-turn recall', recallOptions !== null)
check('plugin subscribed to session/event', listeners.has('session/event'))

const emit = (type, data) => {
  const handler = listeners.get('session/event')
  if (handler === undefined) throw new Error('no session/event listener')
  handler({ id: 'session-capture-test' }, { type, seq: 1, time: new Date().toISOString(), data })
}

const before = totalMemories()

// Turn 1 — the exact shapes dsh-session emits (deriveEventMessage in
// dsh-session/lib/index.js): user/message carries the message at `data`,
// assistant/message carries it at `data.message`, and both use text blocks.
const userText = 'The deploy target for this project is the staging cluster in Frankfurt, never production.'
const assistantText = 'Recorded: deploys go to the staging cluster in Frankfurt; production is not a deploy target for this project.'
emit('user/message', { role: 'user', content: [{ type: 'text', text: userText }] })
emit('assistant/message', {
  turn: 1,
  step: 1,
  message: { role: 'assistant', content: [{ type: 'text', text: assistantText }] },
})
emit('turn/end', { turn: 1, reason: { kind: 'completed' } })

const after = totalMemories()
const captured = capturedRows()

check(
  'a turn/end wrote one episode',
  captured.length === 1,
  `memories ${before} -> ${after}, captured=${captured.length}`,
)
if (captured.length === 1) {
  const record = captured[0]
  check('capture kept the user text', String(record.body).includes('staging cluster in Frankfurt'))
  check('capture kept the assistant text', String(record.body).includes('never production') || String(record.body).includes('not a deploy target'))
  check('capture is an episode, not a fact', record.kind === 'episode', `kind=${record.kind}`)
  check('capture is active and in the user scope', record.active === 1 && record.scope === 'user', `active=${record.active} scope=${record.scope}`)
}

// Turn 2 — recall must be primed by the turn's own prompt, with no memory_search
// call in between. The captured episode from turn 1 is the only candidate.
emit('user/message', { role: 'user', content: [{ type: 'text', text: 'Which cluster do deploys go to for this project?' }] })
const recallText = recallOptions.text()
check('per-turn recall returns a snapshot', typeof recallText === 'string' && recallText.trim() !== '', `${String(recallText).length} chars`)
check(
  'recall snapshot carries the captured episode',
  String(recallText).toLowerCase().includes('frankfurt') || String(recallText).toLowerCase().includes('staging'),
)

// A turn with almost nothing in it must not become an episode.
emit('user/message', { role: 'user', content: [{ type: 'text', text: 'ok' }] })
emit('turn/end', { turn: 2, reason: { kind: 'completed' } })
const shortTurn = capturedRows()
check('a turn below the 60-character floor is not captured', shortTurn.length === 1, `captured=${shortTurn.length}`)

// The panel mirror: the panel's store is a different database, so a capture that
// is not mirrored is invisible in the UI no matter how well capture works.
check('the capture was mirrored to the panel exactly once', mirrorCalls.length === 1, `calls=${mirrorCalls.length}`)
if (mirrorCalls.length === 1) {
  const call = mirrorCalls[0]
  check('mirror targets the panel store route', call.url === 'http://127.0.0.1:18803/rsi/memory/store', call.url)
  check('mirror carries the panel bearer token', call.options.headers.Authorization === 'Bearer test-panel-token')
  const payload = JSON.parse(call.options.body)
  check('mirror payload is an episode in the user scope', payload.kind === 'episode' && payload.scope === 'user', JSON.stringify({ kind: payload.kind, scope: payload.scope }))
  check('mirror payload carries the turn text', String(payload.body).includes('staging cluster in Frankfurt'))
}

globalThis.fetch = realFetch

try { rmSync(workDir, { recursive: true, force: true }) } catch { /* best effort */ }
console.log(`\n${failures.length === 0 ? 'ALL CHECKS PASSED' : `${failures.length} CHECK(S) FAILED`}`)
process.exit(failures.length === 0 ? 0 : 1)
