// End-to-end boot proof for the DSH web UI: fetch the exact bytes the browser
// fetches, execute them in a stub `__ModuleLoader__`, and assert the module
// registration contract holds.
//
// This is the only check that actually answers "will the UI boot?".
//   * `dsh-kawaii.ps1 -Action Verify` is a path-containment check.
//   * The kernel's "N/N client modules ready" line only means "HTTP 200,
//     non-empty, not HTML" (src-tauri workflow/utils.rs, looks_like_plugin_bundle).
// Neither notices a bundle that poisons the combo script, which is exactly how
// the UI dies with:
//   client-modules: bundle /plugins/??<...>&rev=... loaded without registering
//   "<id>" via __ModuleLoader__.load
//
// Usage:
//   node scripts/verify-served-boot.mjs [--port 3080] [--json]
import process from 'node:process'
import vm from 'node:vm'

const argv = process.argv.slice(2)
const opt = (name, fallback) => {
  const index = argv.indexOf(name)
  return index === -1 ? fallback : argv[index + 1]
}
const port = Number(opt('--port', '3080'))
const origin = `http://127.0.0.1:${port}`

const fail = (message) => {
  console.error(`verify-served-boot: ${message}`)
  process.exit(2)
}

let html
try {
  const response = await fetch(`${origin}/`)
  if (!response.ok) fail(`GET / -> HTTP ${response.status}`)
  html = await response.text()
} catch (error) {
  fail(`cannot reach the harness core on ${origin}: ${error.message}`)
}

const key = 'globalThis["__DSH_BOOT__"] = '
const start = html.indexOf(key)
if (start === -1) fail('boot HTML carries no __DSH_BOOT__ global')
const end = html.indexOf('</script>', start)
const graph = JSON.parse(html.slice(start + key.length, end).trim().replace(/;$/, ''))

console.log(`boot rev ${graph.rev}: ${graph.entries.length} entries in ${graph.batches.length} batch(es)`)

/** The stub the boot HTML installs before any bundle runs (bootInjections.queue). */
function makeTarget() {
  const pendingQueue = []
  return {
    pendingQueue,
    mode: 'queue',
    load(registration) {
      pendingQueue.push(registration)
    },
  }
}

const registered = new Map()
const target = makeTarget()

function stubSandbox() {
  const sandbox = {
    window: { __ModuleLoader__: target },
    console,
    Symbol,
    Object,
    Array,
    Map,
    Set,
    Promise,
    JSON,
    Math,
    Date,
    RegExp,
    Error,
    TypeError,
    RangeError,
    String,
    Number,
    Boolean,
    WeakMap,
    WeakSet,
    Reflect,
    Proxy,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    process: { env: { NODE_ENV: 'production' } },
  }
  sandbox.globalThis = sandbox
  sandbox.self = sandbox
  return sandbox
}

const problems = []
for (const batch of graph.batches) {
  const url = `${origin}${batch.url.replaceAll('&amp;', '&')}`
  const response = await fetch(url)
  const body = await response.text()
  const before = registered.size
  const queuedBefore = target.pendingQueue.length
  const sandbox = stubSandbox()
  try {
    // A classic <script>: no module syntax allowed. This is where a package that
    // shipped un-bundled ESM takes the whole batch down.
    new vm.Script(body, { filename: batch.url }).runInNewContext(sandbox, { timeout: 60_000 })
  } catch (error) {
    problems.push(`${batch.phase} batch (${batch.entries.length} entries) failed to execute: ${error.name}: ${error.message}`)
    console.log(`EXEC FAIL ${batch.phase}  HTTP ${response.status}  ${body.length} bytes`)
    console.log(`          ${error.name}: ${error.message}`)
    continue
  }
  for (const registration of target.pendingQueue.slice(queuedBefore)) {
    const id = typeof registration?.id === 'string' ? registration.id.replace(/\/client$/, '') : registration?.id
    if (registered.has(id)) problems.push(`duplicate registration for "${id}"`)
    registered.set(id, typeof registration?.factory === 'function')
  }
  console.log(
    `EXEC OK   ${batch.phase}  HTTP ${response.status}  ${body.length} bytes  +${registered.size - before} registration(s)`,
  )
}

console.log('')
let missing = 0
for (const entry of graph.entries) {
  const id = entry.id.replace(/\/client$/, '')
  if (!registered.has(id)) {
    missing += 1
    console.log(`NOT REGISTERED  ${id}`)
    problems.push(`bundle ${entry.url} loaded without registering "${id}" via __ModuleLoader__.load`)
    continue
  }
  if (registered.get(id) !== true) {
    problems.push(`"${id}" registered without a factory function`)
  }
}

const total = graph.entries.length
console.log(`${total - missing}/${total} boot entries register a factory`)
if (missing === 0 && problems.length === 0) {
  console.log('BOOT CONTRACT SATISFIED — the served graph is loadable')
  process.exit(0)
}
console.log('')
for (const problem of problems) console.log(`PROBLEM: ${problem}`)
process.exit(1)
