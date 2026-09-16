# Path authority — one root, no exceptions

Everything the application writes must live inside one directory: the one the
user selects with `DSH_APP_DATA`, or the platform's default when that variable
is unset.

## Why this document exists

The shell resolved its data directory two different ways at once:

| module | resolution |
|---|---|
| `config/runtime.rs::get_base_dir` | `app.path().app_data_dir()` → Win32 known-folder API |
| `logger/mod.rs::app_data_dir` | reads the `APPDATA` environment variable |

The Win32 known-folder API **ignores** `APPDATA` / `LOCALAPPDATA`. So redirecting
those variables moved some of the application's state and not the rest: the CLI
shims and `desktop.log` followed the environment, while the harness runtime,
`.store.dat` and the service log stayed behind. One application, two data
directories, state split across them.

The same class of problem appeared in four more places: CLI shims written to
`%LOCALAPPDATA%\deepseek-harness\bin`, the WebView2 profile in
`%LOCALAPPDATA%\<identifier>`, staging files in `%TEMP%`, and `.store.dat`
resolved relative to `BaseDirectory::AppData` by several call sites and the
frontend.

## The authority

`config/runtime.rs` is the only module allowed to decide where the root is.

```
portable_root()                -> Option<PathBuf>   DSH_APP_DATA, if set and non-empty
platform_app_data_dir()        -> Option<PathBuf>   platform default (no AppHandle needed)
get_base_dir(app)              -> PathBuf           portable_root() or the platform default
ensure_dir(&Path)              -> io::Result<()>
logs_dir(app) / logs_dir_without_handle()
scratch_dir()                                       <root>/tmp, no AppHandle needed
portable_bin_dir()             -> Option<PathBuf>   Some(<root>/bin) only in portable mode
webview_dir(app) / updates_dir(app)
setting::store_dat_path(app)                        the one .store.dat path
```

Layout under the root:

```
<root>/
├── .store.dat                 settings store
├── bin/                       CLI shims (portable mode)
├── dependencies/{dsh,pnpm,git}
├── runtime/                   bundled Node
├── logs/
├── tmp/                       all staging, extraction and scratch work
├── webview/                   WebView2 user data
├── updates/
└── home/                      default $DSH_HOME when DSH_HOME is unset
```

`resource_dir()` is the *installation* directory and correctly follows the
install location; it is not part of the root.

## Rules

1. `get_base_dir(app)` is the single authority. Nothing derives a write target
   another way.
2. No module may compute a write target from `APPDATA` or `LOCALAPPDATA`. Those
   variables configure the OS, not this application.
3. `std::env::temp_dir()` is banned in production code — use `scratch_dir()`.
   `#[cfg(test)]` code must keep using it, so tests never write into a real data
   directory.
4. Comparing an absolute path against a `BaseDirectory`-relative one silently
   fails; pass the absolute path from `setting::store_dat_path`.
5. Mutating shared user state (PATH, shell rc files, login autostart) is
   opt-in, never implicit, and always points inside the root.
6. Read-only environment discovery — finding an already-installed npm, fnm or
   pnpm — is allowed, but its results must never become a write target.

## Enforcement

`scripts/check-path-authority.mjs` fails on any violation of rules 1–3, plus a
second definition of `app_data_dir()`. It runs:

- in CI (`.github/workflows/path-authority.yml`) on every push and pull request;
- locally as a pre-commit hook (`git config core.hooksPath .githooks`);
- and it should be run after every upstream rebase, before building.
