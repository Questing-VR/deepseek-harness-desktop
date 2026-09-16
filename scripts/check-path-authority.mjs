/**
 * check-path-authority.mjs — 路径权威回归守卫。
 *
 * 目的：让「数据目录分叉」这一类问题**不可能**再悄悄回来。
 *
 * 背景（2026-09-16 实测）：`config::get_base_dir` 走 Tauri 的 `app_data_dir()`
 * （Windows 上是 Win32 known-folder API，**忽略** `APPDATA`/`LOCALAPPDATA`
 * 环境变量），而 `logger` 底座自己读了一遍 `APPDATA`。同一个应用因此有两套
 * 「数据目录」：重定向 `APPDATA` 时日志写到新位置，核心与 `.store.dat` 留在旧
 * 位置，数据被劈成两半。同类问题还有 CLI shim 落在 `%LOCALAPPDATA%`、
 * WebView2 数据落在 `%LOCALAPPDATA%\<id>`、暂存文件散进 `%TEMP%`。
 *
 * 本脚本把这些规则固化下来，在 CI 里跑；命中即失败。
 *
 *   node scripts/check-path-authority.mjs
 *
 * 退出码：0 = 合规；1 = 命中违规。
 */
import { readFileSync } from 'node:fs'
import { globSync } from 'node:fs'
import { join, relative } from 'node:path'

const SRC = 'src-tauri/src'

/** 唯一允许解析根目录的模块。 */
const AUTHORITY = 'config/runtime.rs'

/**
 * 允许**读取**环境变量做「已装环境探测」的文件——它们只是发现用户已经装好的
 * npm/fnm/pnpm/Git，不把结果当作写入目标，因此保留。
 */
const READ_ONLY_PROBES = new Set([
  'service/core/local.rs',
  'service/cli/path/pnpm.rs',
  'service/cli/path/registry.rs',
  'service/cli/path/mod.rs',
  'config/runtime.rs',
  'config/region.rs',
  'lib.rs',
  'config/utils.rs',
  'service/cli/shim/build.rs',
])

/** 命中即违规的规则。`test: true` 表示该规则同样适用于 #[cfg(test)] 代码。 */
const RULES = [
  {
    id: 'temp-dir',
    // 生产代码禁止直接使用系统临时目录：一律 config::scratch_dir()。
    // 测试代码**必须**用系统临时目录，避免污染真实数据目录，故不检查。
    re: /std::env::temp_dir\(\)/,
    message: '生产代码必须用 config::scratch_dir()，不能直接用 std::env::temp_dir()',
  },
  {
    id: 'app-data-dir-direct',
    // 任何模块不得自己调 Tauri 的 app_data_dir()/app_local_data_dir()：
    // 根目录只能由 config::get_base_dir() 给出。
    re: /\.(app_data_dir|app_local_data_dir)\(\)/,
    message: '必须走 config::get_base_dir() / config::webview_dir()，不能直接调 Tauri 的 app_data_dir()',
  },
  {
    id: 'env-write-target',
    // 禁止用 APPDATA/LOCALAPPDATA 环境变量推导**写入**目标。
    re: /env::var(_os)?\(\s*"(APPDATA|LOCALAPPDATA)"/,
    message: '不得用 APPDATA/LOCALAPPDATA 推导写入目标（known-folder API 与它们无关，必然分叉）',
    skipProbes: true,
  },
]

/**
 * 计算「代码字符」掩码：注释、字符串字面量、字符字面量、raw string 都置 0。
 *
 * 直接用朴素大括号配对判定 `#[cfg(test)]` 区间是不可靠的——测试里大量
 * `format!("... {} ...")` 之类字符串本身带括号，会把区间算歪，于是测试代码被
 * 误判成生产代码，守卫开始乱报。这里先把非代码字符标掉，只在代码字符上配对。
 */
function codeMask(text) {
  const n = text.length
  const mask = new Uint8Array(n)
  let i = 0
  while (i < n) {
    const two = text.slice(i, i + 2)
    if (two === '//') { const end = text.indexOf('\n', i); i = end === -1 ? n : end; continue }
    if (two === '/*') { const end = text.indexOf('*/', i + 2); i = end === -1 ? n : end + 2; continue }
    const raw = /^r(#*)"/.exec(text.slice(i, i + 16))
    if (raw) {
      const close = '"' + raw[1]
      const end = text.indexOf(close, i + raw[0].length)
      i = end === -1 ? n : end + close.length
      continue
    }
    if (text[i] === '"') {
      let j = i + 1
      while (j < n && text[j] !== '"') { if (text[j] === '\\') j++; j++ }
      i = j + 1
      continue
    }
    if (text[i] === "'") {
      const m = /^'(\\.|[^\\'])'/.exec(text.slice(i, i + 4))
      if (m) { i += m[0].length; continue }
    }
    mask[i] = 1
    i++
  }
  return mask
}

/** 逐个大括号配对，标出 `#[cfg(test)]` 项覆盖的行区间。 */
function testRegions(lines) {
  const text = lines.join('\n')
  const mask = codeMask(text)
  // 行首偏移
  const offsets = []
  let acc = 0
  for (const line of lines) { offsets.push(acc); acc += line.length + 1 }

  const lineOf = (pos) => {
    let lo = 0, hi = offsets.length - 1, ans = 0
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (offsets[mid] <= pos) { ans = mid; lo = mid + 1 } else hi = mid - 1 }
    return ans
  }

  const regions = []
  const attr = /#\[cfg\(test\)\]/g
  let m
  while ((m = attr.exec(text)) !== null) {
    if (!mask[m.index]) continue
    // 找到该属性之后第一个代码字符里的 '{'
    let open = -1
    for (let k = m.index + m[0].length; k < text.length; k++) {
      if (mask[k] && text[k] === '{') { open = k; break }
    }
    if (open === -1) continue
    let depth = 0, close = -1
    for (let k = open; k < text.length; k++) {
      if (!mask[k]) continue
      if (text[k] === '{') depth++
      else if (text[k] === '}') { depth--; if (depth === 0) { close = k; break } }
    }
    if (close === -1) continue
    regions.push([lineOf(m.index), lineOf(close)])
  }
  return regions
}

const files = globSync(`${SRC}/**/*.rs`)
let violations = 0

for (const file of files) {
  const rel = relative(SRC, file).split('\\').join('/')
  const text = readFileSync(file, 'utf8')
  const lines = text.split('\n')
  const regions = testRegions(lines)
  const inTest = (n) => regions.some(([a, b]) => n >= a && n <= b)

  for (const rule of RULES) {
    if (rule.skipProbes && READ_ONLY_PROBES.has(rel)) continue
    if (rule.id !== 'temp-dir' && rel === AUTHORITY) continue

    lines.forEach((line, idx) => {
      const n = idx + 1
      if (!rule.re.test(line)) return
      // 注释行不算
      if (/^\s*\/\//.test(line)) return
      // temp-dir 规则在测试代码里必须继续用系统临时目录
      if (rule.id === 'temp-dir' && inTest(n)) return
      console.error(`${rel}:${n}: [${rule.id}] ${rule.message}`)
      console.error(`    ${line.trim()}`)
      violations++
    })
  }
}

// 额外检查：app_data_dir 只允许有一个定义。
const definitions = files.filter((f) => /fn\s+app_data_dir\s*\(/.test(readFileSync(f, 'utf8')))
if (definitions.length > 0) {
  for (const f of definitions) {
    console.error(`${relative(SRC, f)}: [duplicate-authority] 禁止再定义 app_data_dir()，根目录只有 config::get_base_dir() 一处`)
    violations++
  }
}

if (violations > 0) {
  console.error(`\n路径权威检查失败：${violations} 处违规。`)
  console.error('规则见 docs/PATH-AUTHORITY.md。')
  process.exit(1)
}
console.log(`路径权威检查通过：${files.length} 个 Rust 文件均未绕过单一根目录。`)
