// Read the live harness WebView through the WebView2 DevTools protocol.
//
// The shell renders the harness UI inside a WebView2 iframe; nothing in the
// Rust logs reflects what that page actually did. This attaches to the page,
// reads its DOM text and module-loader state, and reports the console errors it
// emitted — the difference between "the host says 68/68 ready" and "the UI is
// on screen".
//
// Requires the shell to be launched with
//   WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222
//
// Usage:
//   node scripts/inspect-webview.mjs [--port 9222] [--seconds 3]
import process from 'node:process'
import { readFileSync } from 'node:fs'

const argv = process.argv.slice(2)
const opt = (name, fallback) => {
  const index = argv.indexOf(name)
  return index === -1 ? fallback : argv[index + 1]
}
const port = Number(opt('--port', '9222'))
const seconds = Number(opt('--seconds', '3'))

const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json()
// The harness UI is a cross-origin iframe (127.0.0.1:3080) inside the Tauri shell
// (tauri.localhost), so it is its own CDP target; the outer page's console says
// nothing about it.
const preferred = opt('--target', '3080')
const pages = list.filter((target) => target.type === 'page' || target.type === 'iframe')
const page =
  pages.find((target) => String(target.url).includes(preferred)) ??
  pages.find((target) => target.type === 'iframe') ??
  pages[0]
if (page === undefined) {
  console.error('inspect-webview: no page/iframe target exposed')
  process.exit(2)
}
console.log(`target: ${page.type} ${page.url}`)

const socket = new WebSocket(page.webSocketDebuggerUrl)
let nextId = 1
const pending = new Map()
const consoleLines = []
const exceptions = []
const failures = []

const send = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = nextId++
    pending.set(id, { resolve, reject })
    socket.send(JSON.stringify({ id, method, params }))
  })

socket.addEventListener('message', (event) => {
  const message = JSON.parse(event.data)
  if (message.id !== undefined) {
    const waiter = pending.get(message.id)
    if (waiter !== undefined) {
      pending.delete(message.id)
      if (message.error !== undefined) waiter.reject(new Error(message.error.message))
      else waiter.resolve(message.result)
    }
    return
  }
  if (message.method === 'Runtime.consoleAPICalled') {
    consoleLines.push(
      `${message.params.type}: ${message.params.args.map((a) => a.value ?? a.description ?? a.type).join(' ')}`,
    )
  }
  if (message.method === 'Log.entryAdded') {
    consoleLines.push(`${message.params.entry.level}: ${message.params.entry.text}`)
  }
  if (message.method === 'Runtime.exceptionThrown') {
    const d = message.params.exceptionDetails
    const where = d.url ? ` @ ${d.url}:${(d.lineNumber ?? 0) + 1}:${(d.columnNumber ?? 0) + 1}` : ''
    exceptions.push(`${d.exception?.description ?? d.text}${where}`)
  }
  if (message.method === 'Network.responseReceived') {
    const { response, type } = message.params
    if (response.status >= 400) {
      failures.push(`${response.status} ${type} ${message.params.response.url}`.slice(0, 300))
    }
  }
})

await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true })
  socket.addEventListener('error', () => reject(new Error('websocket failed')), { once: true })
})

await send('Runtime.enable')
await send('Log.enable')
await send('Network.enable')

const evaluate = async (expression) => {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
  if (result.exceptionDetails !== undefined) return `<threw ${result.exceptionDetails.text}>`
  return result.result?.value
}

// A fresh boot is the only boot worth judging: console events emitted before
// Runtime.enable are gone, so reload and capture the whole startup. WebView2
// refuses Page.* on out-of-process iframe targets, so a reload that cannot be
// issued is not fatal — the DOM read below still works.
if (argv.includes('--reload')) {
  try {
    await send('Page.enable')
    await send('Page.reload', { ignoreCache: true })
    console.log('reloaded the page; capturing startup')
  } catch (error) {
    console.log(`reload unavailable on this target (${error.message}); reading live DOM only`)
  }
}

// An expression that must run BEFORE the observation window: `location.reload()`
// is the only way to make this iframe re-execute from scratch (WebView2 refuses
// Page.* on out-of-process iframe targets), and a reload issued after the wait
// would capture nothing.
const earlyFile = opt('--early-eval-file', undefined)
if (earlyFile !== undefined) {
  await evaluate(readFileSync(earlyFile, 'utf8'))
  console.log(`early eval: ${earlyFile}`)
}

await new Promise((resolve) => setTimeout(resolve, seconds * 1000))

if (argv.includes('--text') || argv.includes('--eval')) {
  console.log('\n--- page state ---')
  console.log('title          :', await evaluate('document.title'))
  console.log('boot manifest  :', await evaluate('typeof globalThis.__DSH_BOOT__ === "object" && globalThis.__DSH_BOOT__ !== null ? globalThis.__DSH_BOOT__.entries.length + " entries rev " + globalThis.__DSH_BOOT__.rev : "absent"'))
  console.log('module loader  :', await evaluate('typeof globalThis.__ModuleLoader__'))
  console.log('iframes        :', await evaluate('document.querySelectorAll("iframe").length'))
}

const bodyText = await evaluate('(document.body ? document.body.innerText : "").slice(0, 3000)')
if (argv.includes('--text')) {
  console.log('\n--- page text ---')
  console.log(bodyText || '<empty>')
}

console.log('\n--- console (' + consoleLines.length + ') ---')
for (const line of consoleLines.slice(0, 40)) console.log(line.slice(0, 500))
console.log('\n--- uncaught exceptions (' + exceptions.length + ') ---')
for (const line of exceptions.slice(0, 20)) console.log(line.slice(0, 900))

console.log('\n--- failed requests (' + failures.length + ') ---')
for (const line of [...new Set(failures)].slice(0, 25)) console.log(line)

const bad = [...consoleLines, ...exceptions].filter((line) => /without registering|Failed to load plugins|missed the module table|Failed to load module/i.test(line))
console.log(`\nVERDICT: ${bad.length === 0 ? 'no module-load failure observed' : `${bad.length} module-load failure line(s)`}`)

// `--eval` runs one extra expression against the live page and prints it as
// JSON, so ad-hoc questions ("what is this element?", "does the panel open?")
// do not need a new script.
const extra = opt('--eval', undefined)
const extraFile = opt('--eval-file', undefined)
const extraSource = extraFile !== undefined ? readFileSync(extraFile, 'utf8') : extra
if (extraSource !== undefined) {
  console.log('\n--- eval ---')
  console.log(JSON.stringify(await evaluate(extraSource), null, 2))
}

socket.close()
process.exit(bad.length === 0 ? 0 : 1)
