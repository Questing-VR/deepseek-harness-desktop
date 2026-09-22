// Build one plugin's browser half into the DSH client-module bundle format.
//
// Why this exists: `@deepseek-ai/dsh-client-modules` serves every package that
// declares `dsh.client` by reading the file its `exports["./client"]` names and
// concatenating it into the startup combo script. That file MUST be a built
// artifact of the shape
//
//   window.__ModuleLoader__.load({ id: "<pkg>", factory: (require) => { ...; return module.exports } })
//
// A package that ships its *un-bundled* TypeScript output in that slot (top-level
// `import`/`export` statements) poisons the whole combo: the classic <script>
// fails to compile, so *no* module in that batch registers and the harness dies
// with `bundle ... loaded without registering "<id>" via __ModuleLoader__.load`.
//
// The wrapper text below is byte-for-byte the one the fork's own plugin pipeline
// emits (packages/dsh-tauri-tsdown/src/index.ts, clientBundleRegistration()).
//
// Usage:
//   node scripts/build-plugin-client-bundle.mjs --pkg-dir <dir> [--check]
//
//   --pkg-dir  package directory (contains package.json)
//   --check    report only; write nothing
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, isAbsolute, resolve } from 'node:path'
import process from 'node:process'

const require = createRequire(import.meta.url)

const argv = process.argv.slice(2)
const flag = (name) => argv.includes(name)
const opt = (name) => {
  const index = argv.indexOf(name)
  return index === -1 ? undefined : argv[index + 1]
}

const pkgDirArg = opt('--pkg-dir')
if (pkgDirArg === undefined) {
  console.error('build-plugin-client-bundle: --pkg-dir is required')
  process.exit(2)
}
const pkgDir = resolve(pkgDirArg)
const checkOnly = flag('--check')

const manifestPath = join(pkgDir, 'package.json')
if (!existsSync(manifestPath)) {
  console.error(`build-plugin-client-bundle: no package.json at ${manifestPath}`)
  process.exit(2)
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const pkgName = manifest.name

// Resolve the same `./client` export the kernel resolves, so this tool and the
// runtime can never disagree about which file is the browser half.
function clientExportOf(pkg) {
  const entry = pkg.exports?.['./client']
  if (typeof entry === 'string') return entry
  if (entry !== null && typeof entry === 'object') {
    return entry.default ?? entry.import ?? entry.require
  }
  return undefined
}
const clientRel = clientExportOf(manifest)
if (clientRel === undefined) {
  console.error(`build-plugin-client-bundle: ${pkgName} declares no "./client" export`)
  process.exit(2)
}
const clientPath = isAbsolute(clientRel) ? clientRel : join(pkgDir, clientRel)
if (!existsSync(clientPath)) {
  console.error(`build-plugin-client-bundle: missing client artifact ${clientPath}`)
  process.exit(2)
}

const original = readFileSync(clientPath, 'utf8')
const alreadyBundled = original.includes('__ModuleLoader__.load')
if (alreadyBundled) {
  console.log(`OK       ${pkgName}: ${clientPath} is already a ModuleLoader bundle (${original.length} bytes)`)
  process.exit(0)
}
if (checkOnly) {
  console.log(`BROKEN   ${pkgName}: ${clientPath} is not a ModuleLoader bundle (${original.length} bytes)`)
  process.exit(1)
}

// Locate esbuild inside the fork's pnpm store (the deployed profile node_modules
// carries no bundler on purpose — build tooling must not ship to end users).
function loadEsbuild() {
  try {
    return require('esbuild')
  } catch {}
  const store = join(
    resolve(import.meta.dirname, '..'),
    'src',
    'deepseek-harness-desktop',
    'node_modules',
    '.pnpm',
  )
  const direct = join(store, 'esbuild@0.28.2', 'node_modules', 'esbuild')
  if (existsSync(direct)) return require(direct)
  console.error('build-plugin-client-bundle: esbuild not found (looked in node_modules and the fork pnpm store)')
  process.exit(2)
}
const esbuild = loadEsbuild()

const id = JSON.stringify(pkgName)
const banner =
  `window.__ModuleLoader__.load({id:${id},factory:(require)=>{` +
  `const loaderRequire=require;` +
  `const resolve=(specifier)=>specifier.endsWith('/client')?specifier.slice(0,-7):specifier;` +
  `require=(specifier)=>loaderRequire(resolve(specifier));` +
  `var module={exports:{}};var exports=module.exports;`
const footer = 'return module.exports;}});'

const result = await esbuild.build({
  entryPoints: [clientPath],
  bundle: true,
  write: false,
  format: 'cjs',
  platform: 'browser',
  target: 'es2022',
  minify: true,
  sourcemap: false,
  legalComments: 'none',
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  // The module table carries the platform seed words and the sibling link
  // modules; everything else must be inlined or the factory's require misses.
  external: [
    'react',
    'react/*',
    'react-dom',
    'react-dom/*',
    'dsh-tauri/client',
    'dsh-tauri-ui/client',
    '@deepseek-ai/*',
  ],
  banner: { js: banner },
  footer: { js: footer },
  logLevel: 'warning',
})

if (result.outputFiles.length !== 1) {
  console.error(`build-plugin-client-bundle: expected one output file, got ${result.outputFiles.length}`)
  process.exit(1)
}
const built = result.outputFiles[0].text

// A bundle that forgot its registration would be a worse failure than the
// unbundled source: the loader would load it and then report the same error.
for (const needle of ['__ModuleLoader__.load', JSON.stringify(pkgName), 'return module.exports']) {
  if (!built.includes(needle)) {
    console.error(`build-plugin-client-bundle: built output lacks ${needle}`)
    process.exit(1)
  }
}

const backup = `${clientPath}.unbundled-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)}`
copyFileSync(clientPath, backup)
writeFileSync(clientPath, built)
console.log(`REBUILT  ${pkgName}: ${original.length} -> ${built.length} bytes`)
console.log(`         backup of the shipped source: ${backup}`)
