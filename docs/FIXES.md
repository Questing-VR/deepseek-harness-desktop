# Fixes in this fork

A living record of every change this fork carries, why it exists, and how it was
verified. Update it whenever a patch is added or an upstream sync changes
something.

Fork base: `dsh-tauri-desk/deepseek-harness-desktop` @ `80ffd137` (v0.14.3)
Patch branch: `dsh/single-root`

---

## 1. One data directory instead of two — `c82f4ef`

**Symptom.** Redirecting `APPDATA` / `LOCALAPPDATA` moved *some* of the
application's state and not the rest. Logs and CLI shims followed the
environment; the harness runtime, `.store.dat` and the service log stayed behind.

**Root cause.** Two independent notions of "the data directory":

| module | resolution |
|---|---|
| `config/runtime.rs::get_base_dir` | `app.path().app_data_dir()` → Win32 known-folder API |
| `logger/mod.rs::app_data_dir` | read the `APPDATA` environment variable |

The known-folder API ignores those variables, so the two disagreed by design.

**Measured, not inferred.** An isolated copy was run with `APPDATA`,
`LOCALAPPDATA` and `DSH_HOME` pointed at a sandbox. The app wrote its CLI shims
into the redirected `LOCALAPPDATA`, but the shims' own contents recorded
`$appDir` as the old `C:` path, and `.store.dat` was written only on `C:`.

**Fix.** A single authority in `config/runtime.rs`, with `DSH_APP_DATA` as the
override (mirroring the existing `DSH_HOME`): `portable_root`,
`platform_app_data_dir`, `scratch_dir`, `get_base_dir`, `ensure_dir`,
`logs_dir` / `logs_dir_without_handle`, `portable_bin_dir`, `webview_dir`,
`updates_dir`, plus `DIR_NAME_*` and `APP_IDENTIFIER` constants. See
`docs/PATH-AUTHORITY.md`.

## 2. The logger's duplicate resolver — `c9001d2`

The logger owned a private `app_data_dir()` reading `APPDATA` / `HOME` /
`XDG_DATA_HOME`, plus its own copy of the `APP_IDENTIFIER` literal. That
duplicate *was* the mechanism behind the split. It now uses
`config::logs_dir_without_handle()`, which is deliberately callable before an
`AppHandle` exists — that early-init requirement is why the duplicate existed.

## 3. WebView2, CLI shims, autostart, and Chinese UI text — `6ae4960`

- WebView2 user data: `%LOCALAPPDATA%\<id>` → `<root>/webview`.
- CLI shims: `<root>/bin` in portable mode; the platform default is byte-identical
  to before otherwise, and the stale PATH entry is removed when it changes.
- Login autostart is **refused** in portable mode instead of writing shared user
  state, because the autostart plugin takes no target path.
- Tray menus (Windows and Linux) and the notification permission dialog no longer
  hardcode Chinese literals.

## 4. Scratch and update locations — `661765a`

Production code no longer calls `std::env::temp_dir()`; staging, extraction and
atomic installs use `config::scratch_dir()` (`<root>/tmp`). The update staging
directory and the bridge path allow-list derive from the root.

`#[cfg(test)]` code deliberately keeps the system temp dir — tests writing into a
real data directory would be a worse bug than the one being fixed.

## 5. A second Chinese window: the backend language was never set — `384ab0f`

**Symptom.** The tray menu stayed Chinese under `language: "en"` even after the
tray was switched to i18n lookups.

**Root cause.** `set_language` was called **only** inside `install_macos_menu`,
which is `#[cfg(target_os = "macos")]`. On Windows it was never called at all, so
`CURRENT_LANG` kept its initial value for the whole process and every
`i18n::t(...)` returned Chinese — tray menu *and* backend error strings.

**Fix.** Set the language from the persisted setting in `builder`'s `setup()`,
immediately after `detect_first_install` and before `build_main_window` / `tray`,
on every platform.

## 6. English as the default language — `215d8b5`

`CURRENT_LANG` started at `0` = `Zh`, so any user-visible string produced before
`set_language` ran could only be Chinese. Defaulting to English closes that
window; an explicit choice of Chinese still works, since `set_language` overrides
the default as soon as settings are read.

## 7. Guard and tooling — `6dd7b3c`, `2f6fb81`

- `scripts/check-path-authority.mjs` fails the build if any module bypasses the
  single root: production `std::env::temp_dir()`, direct `app_data_dir()`, an
  `APPDATA`-derived write target, or a second `app_data_dir` definition.
- `.githooks/pre-commit` runs it on every commit (verified: it *rejects* a
  deliberately reintroduced violation with exit 1).
- `.github/workflows/path-authority.yml` runs it on every push and pull request.
- `scripts/sync-upstream.ps1` rebases this series onto upstream and refuses to
  build unless the guard passes **and** the built binary contains `DSH_APP_DATA`.

---

## Verification status

| check | result |
|---|---|
| `cargo check` | clean (0 warnings from this fork; 9 pre-existing release warnings in `service/patch/client_hmr.rs`, a debug-only module) |
| `cargo test --lib` | 564 passed, 0 failed |
| path-authority guard | passes over 125 Rust files |
| binary marker | `DSH_APP_DATA` present in the built shell; absent in stock |
| runtime confirmation | harness runs from `<root>/.appdata/dependencies/dsh/...`; launcher logged `containment CONFIRMED (root populated, C: clean)` |
| tray language | confirmed English after installing the rebuilt shell |

## Known upstream bugs found but NOT fixed here

- **Self-restart crash loop.** When the app restarts itself it can start a new
  harness before the old one releases the port, producing
  `listen EADDRINUSE: address already in use 127.0.0.1:3080`, then
  `plugin tree failed to load`, then exit 1 — repeatedly, until the app is quit
  fully and relaunched manually. `setup()` does call `sweep_orphan_harness`
  (port + PID confirmed), but only at process start; the in-process restart path
  does not wait for the port. The repo already has a `wait_for_port_release`
  helper used elsewhere. Logs: `<root>/logs/{desktop.log,dsh-web.log*}`.
- **WebView2 profile is not migrated** when the data directory moves: WebView2
  creates a fresh profile (one-time loss of cookies / localStorage).
- Windows renders a deprecation warning from a child-process spawn using
  `shell: true` (`DEP0190`) during the plugin build.

## Keeping this current

1. `scripts/sync-upstream.ps1` (add `-Build` to also build and verify).
2. If the guard fails after a merge, upstream has reintroduced a second data
   directory or a conflict was resolved wrongly — fix it before building.
3. Add a short section here for each new patch, with its commit.
