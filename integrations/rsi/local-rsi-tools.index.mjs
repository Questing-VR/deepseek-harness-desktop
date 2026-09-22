// @local/rsi-tools entry point.
//
// The tool definitions are the reference's own `deepseek_plugin.mjs`, loaded as the
// single source of truth rather than copied, so the two can never drift. It is
// addressed through RSI_ROOT instead of a relative path because this package is
// installed as a separate copy inside the profile's node_modules, where a relative
// `../../deepseek_plugin.mjs` would resolve to a path that does not exist.
//
// RSI_ROOT is exported by the launcher (dsh-ecosystem.ps1). When it is absent the
// plugin still loads, and the failure is reported once rather than at import time.
const root = process.env.RSI_ROOT
const plugin = root
  ? await import(new URL('deepseek_plugin.mjs', 'file:///' + root.replace(/\\/g, '/') + '/').href)
  : undefined

export const name = plugin?.name ?? 'local-rsi-tools'
export const inject = plugin?.inject ?? ['tools']
export function apply(ctx) {
  if (!plugin) {
    console.error(
      '[local-rsi-tools] RSI_ROOT is not set, so the rsi_* tools are unavailable this run. '
      + 'Start the harness through launch.cmd (or dsh-ecosystem.ps1 -Action Launch), which exports it.',
    )
    return
  }
  plugin.apply(ctx)
}
