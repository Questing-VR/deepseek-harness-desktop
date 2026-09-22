// Preflight gate for DSH client bundles: prove every profile bundle actually
// registers itself before the harness is asked to boot with it.
//
// `dsh-client-modules` concatenates every `dsh.client` bundle into one classic
// <script> per batch and then requires each entry to have called
// `__ModuleLoader__.load({id, factory})`. The kernel's own readiness counter
// only checks "HTTP 200 + non-empty + not HTML" (src-tauri workflow/utils.rs,
// looks_like_plugin_bundle), so a bundle that is syntactically broken, or that
// ships un-bundled ESM, or that registers under the wrong id, sails past
// startup logging and only explodes in the browser as
//
//   client-modules: bundle /plugins/??<...>&rev=... loaded without registering
//   "<id>" via __ModuleLoader__.load
//
// with no hint of which package is at fault. This script executes each bundle
// in a throwaway `__ModuleLoader__` and reports the culprit by name.
//
// Usage:
//   node scripts/verify-plugin-client-bundles.mjs [--profile <dir>] [--root <dir>]...
import { readFileSync, existsSync } from 'node:fs'
import { join, isAbsolute, resolve } from 'node:path'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import process from 'node:process'

const require = createRequire(import.meta.url)
const argv = process.argv.slice(2)
const opt = (name, fallback) => {
  const index = argv.indexOf(name)
  return index === -1 ? fallback : argv[index + 1]
}
const optsAll = (name) => {
  const out = []
  for (let i = 0; i < argv.length; i += 1) if (argv[i] === name && argv[i + 1] !== undefined) out.push(argv[i + 1])
  return out
}

const forkRoot = resolve(import.meta.dirname, '..')
const profileDir = resolve(opt('--profile', join(forkRoot, '.dsh', 'profiles', 'tauri')))
const roots = [
  join(profileDir, 'node_modules'),
  join(forkRoot, 'node_modules'),
  ...optsAll('--root').map((r) => resolve(r)),
]

const profileManifest = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'))
const bundleIds = profileManifest.dsh?.profile?.bundles ?? []
if (bundleIds.length === 0) {
  console.error(`verify-plugin-client-bundles: no dsh.profile.bundles in ${profileDir}/package.json`)
  process.exit(2)
}

/** Resolve `<pkg>`'s browser half exactly the way client-modules does. */
function locateClient(id) {
  for (const root of roots) {
    const dir = join(root, id)
    const manifestPath = join(dir, 'package.json')
    if (!existsSync(manifestPath)) continue
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    // A bundle with no `dsh.client` is host-only: it legitimately contributes no
    // browser half, and client-modules never puts it in the graph.
    if (manifest.dsh?.client === undefined) return { dir, manifest, hostOnly: true }
    const entry = manifest.exports?.['./client']
    const rel = typeof entry === 'string' ? entry : entry?.default ?? entry?.import ?? entry?.require
    if (rel === undefined) return { dir, manifest, problem: `declares dsh.client but exports no "./client"` }
    const clientPath = isAbsolute(rel) ? rel : join(dir, rel)
    if (!existsSync(clientPath)) return { dir, manifest, problem: `client artifact missing: ${clientPath}` }
    return { dir, manifest, clientPath }
  }
  return { problem: 'package not found in any searched node_modules' }
}

/** Execute one bundle the way the browser does: classic script, stub loader. */
function probe(clientPath, expectedId) {
  const source = readFileSync(clientPath, 'utf8')
  const registrations = []
  const target = {
    mode: 'queue',
    pendingQueue: registrations,
    load(registration) {
      registrations.push(registration)
    },
  }
  // The factory is never invoked here; a bundle only has to register. `require`
  // is answered lazily so a bundle that imports host modules still parses.
  const sandbox = {
    window: { __ModuleLoader__: target },
    document: undefined,
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
    String,
    Number,
    Boolean,
    WeakMap,
    WeakSet,
    Reflect,
    Proxy,
    process: { env: { NODE_ENV: 'production' } },
  }
  sandbox.globalThis = sandbox
  sandbox.self = sandbox
  try {
    const script = new vm.Script(source, { filename: clientPath })
    script.runInNewContext(sandbox, { timeout: 20_000 })
  } catch (error) {
    return { ok: false, reason: `${error.name}: ${error.message}` }
  }
  if (registrations.length === 0) {
    return { ok: false, reason: 'ran without calling window.__ModuleLoader__.load()' }
  }
  const ids = registrations.map((registration) => registration?.id)
  if (!ids.includes(expectedId)) {
    return { ok: false, reason: `registered ${JSON.stringify(ids)}, not ${JSON.stringify(expectedId)}` }
  }
  for (const registration of registrations) {
    if (typeof registration?.factory !== 'function') {
      return { ok: false, reason: `registration ${JSON.stringify(registration?.id)} carries no factory function` }
    }
  }
  return { ok: true, registrations: ids }
}

let bad = 0
let hostOnly = 0
for (const id of bundleIds) {
  const located = locateClient(id)
  if (located.hostOnly === true) {
    hostOnly += 1
    console.log(`HOST-ONLY ${id}  (no dsh.client — nothing to serve)`)
    continue
  }
  if (located.problem !== undefined) {
    bad += 1
    console.log(`MISSING  ${id}\n         ${located.problem}`)
    continue
  }
  const bytes = readFileSync(located.clientPath).length
  const verdict = probe(located.clientPath, id)
  if (verdict.ok) {
    console.log(`OK       ${id}  (${bytes} bytes, ${verdict.registrations.length} registration(s))`)
    continue
  }
  bad += 1
  console.log(`BROKEN   ${id}  (${bytes} bytes)`)
  console.log(`         ${located.clientPath}`)
  console.log(`         ${verdict.reason}`)
}

console.log(`\n${bundleIds.length - bad - hostOnly}/${bundleIds.length - hostOnly} client-bearing profile bundles register cleanly (${hostOnly} host-only)`)
if (bad > 0) {
  console.log('Repair a package that shipped un-bundled source with:')
  console.log('  node scripts/build-plugin-client-bundle.mjs --pkg-dir <package dir>')
}
process.exit(bad === 0 ? 0 : 1)
