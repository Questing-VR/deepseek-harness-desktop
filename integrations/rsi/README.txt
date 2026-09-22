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
