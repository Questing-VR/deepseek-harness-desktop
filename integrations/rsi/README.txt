Reference harness -> this harness: adaptations applied
=======================================================

Source (read-only): S:\AI\ChatGPT\Harness\rsi
Port:                D:\KEEP OUT\DSH Kawaii\DSH Kawaii creator\rsi

MOVED VERBATIM
  50 Python modules, 5 .mjs plugin modules, 8 .ps1, 5 .md, workspace.html,
  private_workspace.ts, the vendored `sia` package, and the state directories
  (adapters, agent, cycles, decisions, evidence, evolution-cycles,
  executable-generations, experience, generations, marketplace, memory, plugins,
  projects, proposals, protected, records, runs, snapshots, source-history,
  tests, tools, traces).  Runtime layers copied: python (CPython 3.12.10 +
  numpy 2.4.4), node (v22.23.2), llama-cuda, deepseek, rsih.

ADAPTED (each one a consequence of the move, no redesign)
  1. env.ps1
     Interpreter resolves to the ported runtime/python; falls back to system
     python.exe. numpy is copied INTO the ported interpreter because the
     reference was silently using the user site-packages on C:.

  2. runtime/deepseek/module-aliases.json  (6326 entries)
     runtime/deepseek/package-map.json     (262 entries)
     Baked-in S:\AI\ChatGPT\Harness\rsi paths rewritten to the port root, and
     the alias KEYS stored lowercased because deepseek_guard.mjs lowercases the
     lookup key. Without the lowercase keys every bare import failed with
     ERR_MODULE_NOT_FOUND.

  3. deepseek_plugin.mjs
     Tool schemas used `required: false`; this harness's schema compiler rejects
     present-but-false ("parameters.scope.required must be true when present").
     The key is omitted for optional parameters instead. This blocked the
     reference app itself, not only the port.

  4. Ports renumbered so both installs can run at once:
     18790 -> 18800 (model)   18791 -> 18801 (app)   18793 -> 18803 (panel API)
     across 17 operational files. Records/traces/source-history left untouched
     so historical receipts keep saying what they said.

  5. plugins/local-rsi-ui/package.json + cordis.patch.yml
     The reference declared only `dsh.client`; this harness loader requires a
     bundle layer and rejected the bundle outright. Added cordis.patch.yml with
     the standard insert row and the matching `dsh.bundle.patch`.

  6. dsh-ecosystem.ps1
     Exports LOCAL_MODEL_API_KEY (read from rsi/records/local-server.key) into
     the harness environment. The panel host half reads that variable from its
     own process environment; without it every panel request was rejected.

VERIFIED
  Panel route POST http://127.0.0.1:3080/local-rsi-api -> 200
    operation=memory       -> 24 memories, 49 relations
    operation=memory-trash -> 200
  Service: records/service.json state=running; /health on 18803 -> ok.

2026-09-22 — boot, marketplace and panel repairs (what was actually wrong)
=========================================================================
Each item below was reproduced first and verified after, in this order.

1. THE UI COULD NOT BOOT: @perrylink/dsh-github shipped un-bundled ESM.
   dsh-client-modules concatenates every dsh.client bundle into ONE classic
   <script> per batch (buildCombo -> comboScript). lib/client.js in that package
   was raw tsc output (top-level `import { createElement } from 'react'`), so the
   14 MB startup script failed to compile and NOTHING in the batch registered.
   The kernel then reported the first arrival it checked, which is why the error
   named @deepseek-ai/dsh-client-hmr — an innocent module.
   Fix: tools/build-plugin-client-bundle.mjs (esbuild + the exact wrapper from
   packages/dsh-tauri-tsdown/src/index.ts). Verified with
   tools/verify-served-boot.mjs against the RUNNING core: it executes the served
   combo bytes in a stub __ModuleLoader__ — 68/68 entries register.

2. "N/N client modules ready" IS NOT A HEALTH CHECK.
   src-tauri/src/service/workflow/utils.rs looks_like_plugin_bundle() only tests
   HTTP 200 + non-empty + not-HTML, so a package that poisons the batch passes it.
   tools/verify-plugin-client-bundles.mjs is the real gate: it executes each
   profile bundle in a throwaway loader and names the guilty package.

3. MARKETPLACE UPDATES FAILED: ERR_PNPM_UNEXPECTED_STORE.
   The profiles were installed by pnpm 11.7.0 and record
   <caches>\pnpm\store\v11. `.appdata\bin\pnpm.cmd` prefers "a user-installed
   pnpm" over the bundled one, and the first pnpm on PATH belongs to ANOTHER
   product (%APPDATA%\dsh-desktop\harness\.desktop-bin\pnpm.cmd, 10.34.5), which
   resolves <store>\v10. Fix in dsh-ecosystem.ps1 Set-EcoEnv:
   DSH_PREFER_BUNDLED_PNPM=1 (bundled pnpm IS 11.7.0) + .appdata\bin first on
   PATH, plus store-dir pinned in the profile .npmrc.

4. THE MEMORY PANEL RENDERED BUT HAD NO DATA.
   The panel is a client plugin that POSTs to the harness route /local-rsi-api;
   the @local/rsi-ui host half proxies that to http://127.0.0.1:18803/rsi/ui.
   NOTHING started that server. service.py --front-only (added) serves exactly
   that API from local records + SQLite + the filesystem and deliberately does
   NOT call wake_model() or start the second web UI, so it needs no GPU and
   cannot disturb another install's model. start-front.ps1 runs it;
   dsh-ecosystem.ps1 Invoke-Launch calls Start-RsiFront first, so a relaunch is
   never required to bring the panel's data back.

5. A CHINESE "MODE" WAS PERMANENTLY SELECTED.
   Not a mode: .dsh/settings.yaml had `agent-presets.default: nocompact`, a
   user preset whose preset.yml named itself 绝不压缩 for a compaction threshold
   of 999,666 tokens. Every session therefore showed that chip. Fix: the default
   override is gone and tools/localize-agent-presets.ps1 gives the whole roster
   (shipped names are Chinese in this build) English display names, keeping the
   originals as preset.yml.zh-original. Re-run it after a harness upgrade.

6. STILL OPEN (diagnosed, not yet fixed): an uncaught
   `TypeError: ... reading 'plugins'` at `<anonymous>:5:50`, reported against the
   harness frame. The served page contains no `.plugins` at all, so this is a
   shell-injected initialization script (initialization_script_for_all_frames)
   running in the cross-origin 127.0.0.1:3080 frame where __TAURI_INTERNALS__ does
   not exist. No user-visible effect; fixing it means a Rust rebuild.