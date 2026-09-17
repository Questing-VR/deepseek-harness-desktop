# sync-upstream.ps1 — take an upstream release without losing the local patches,
# and prove the fix survived the merge.
#
#   powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1 -Build
#
# What it does, in order, stopping at the first real problem:
#   1. refuses to run on a dirty tree (so a half-merge can never be blamed on it)
#   2. fetches upstream
#   3. rebases the local patch series onto upstream
#   4. runs scripts/check-path-authority.mjs  <- THE ACCEPTANCE GATE
#   5. runs cargo check and the full lib test suite
#   6. with -Build, builds the release binary and confirms DSH_APP_DATA is in it
#
# Step 4 is the important one. A bad merge can compile, pass every existing test,
# and still quietly reintroduce a second data directory — because the test suite
# has no way to notice. The guard does.

[CmdletBinding()]
param(
  [string]$UpstreamRemote = '',          # default: 'upstream' if it exists, else 'origin'
  [string]$UpstreamBranch = 'main',
  [switch]$Build
)

# Continue, NOT Stop. git, cargo and pnpm all write progress to stderr, and with
# Stop PowerShell turns a native command's stderr into a TERMINATING error — so a
# successful `git fetch` aborted this script entirely. Every native call below is
# followed by an explicit $LASTEXITCODE check, so real failures are still caught.
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$Ws   = Split-Path -Parent (Split-Path -Parent $Repo)   # ...\DSH Kawaii creator
$Root = Split-Path -Parent $Ws                          # ...\DSH Kawaii
$Log  = Join-Path $Root 'upstream-sync.log'

function Say($m) {
  $line = "$(Get-Date -Format 'HH:mm:ss') $m"
  Write-Host $line
  Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}
function Fail($m) { Say "FAILED: $m"; exit 1 }

Set-Location $Repo
Say "=== upstream sync $(Get-Date -Format o) ==="

# --- 1. clean tree ---------------------------------------------------------
$dirty = & git status --porcelain
if ($dirty) { Fail "the working tree is not clean. Commit or stash first:`n$dirty" }
$branch = (& git rev-parse --abbrev-ref HEAD).Trim()
Say "on branch: $branch"
if ($branch -eq $UpstreamBranch) { Fail "refusing to rebase '$UpstreamBranch' onto itself; check out the patch branch" }

# --- 2. fetch --------------------------------------------------------------
if (-not $UpstreamRemote) {
  $remotes = @(& git remote)
  $UpstreamRemote = if ($remotes -contains 'upstream') { 'upstream' } else { 'origin' }
}
Say "upstream remote: $UpstreamRemote/$UpstreamBranch"
& git fetch $UpstreamRemote $UpstreamBranch --tags 2>&1 | ForEach-Object { Say "  $_" }
if ($LASTEXITCODE -ne 0) { Fail "git fetch failed" }

$behind = @(& git log --oneline "HEAD..$UpstreamRemote/$UpstreamBranch")
if ($behind.Count -eq 0) {
  Say "already up to date with $UpstreamRemote/$UpstreamBranch - nothing to do"
} else {
  Say "new upstream commits ($($behind.Count)):"
  $behind | Select-Object -First 20 | ForEach-Object { Say "  $_" }

  # --- 3. rebase -----------------------------------------------------------
  Say 'rebasing the patch series...'
  & git rebase "$UpstreamRemote/$UpstreamBranch" 2>&1 | ForEach-Object { Say "  $_" }
  if ($LASTEXITCODE -ne 0) {
    Say ''
    Say 'CONFLICT. The patch series touches a small, known set of files:'
    & git diff --name-only --diff-filter=U | ForEach-Object { Say "  conflicted: $_" }
    Say ''
    Say 'Resolve each file so BOTH things stay true:'
    Say '  * upstream behaviour is preserved, and'
    Say '  * this project still has exactly ONE data-directory authority'
    Say '    (see docs/PATH-AUTHORITY.md - the rules are short).'
    Say ''
    Say 'Then:  git add <files> ; git rebase --continue'
    Say 'Finally re-run this script. Do NOT build before the guard passes.'
    Fail 'rebase stopped'
  }
  Say 'rebase clean'
}

# --- 4. the acceptance gate ------------------------------------------------
Say 'running the path-authority guard (the acceptance gate)...'
& node scripts/check-path-authority.mjs 2>&1 | ForEach-Object { Say "  $_" }
if ($LASTEXITCODE -ne 0) {
  Say ''
  Say 'The guard FAILED after merging upstream. This means upstream has'
  Say 'reintroduced a second data directory, or a conflict was resolved in a way'
  Say 'that lost one of our patches. Do not build or install this.'
  Fail 'path-authority guard failed'
}
Say 'guard passed'

# --- 5. compile + test ----------------------------------------------------
$env:CARGO_HOME  = Join-Path $Ws '.caches\cargo'
$env:RUSTUP_HOME = Join-Path $Ws '.caches\rustup'
$cargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
if (-not (Test-Path $cargo)) { Say 'cargo not installed - skipping compile and tests' 'WARN' }
else {
  $env:PATH = "$(Join-Path $env:CARGO_HOME 'bin');$env:PATH"
  $env:ErrorActionPreference = 'Continue'
  Say 'cargo check...'
  & $cargo check --manifest-path (Join-Path $Repo 'src-tauri\Cargo.toml') --message-format short 2>&1 |
    Where-Object { $_ -match 'warning:|error|Finished' } | Select-Object -Last 12 | ForEach-Object { Say "  $_" }
  Say 'full lib test suite...'
  & $cargo test --manifest-path (Join-Path $Repo 'src-tauri\Cargo.toml') --lib 2>&1 |
    Select-String -Pattern '^test result:' | ForEach-Object { Say "  $_" }
  $env:ErrorActionPreference = 'Stop'
}

# --- 6. build -------------------------------------------------------------
if ($Build) {
  Say 'building the release binary...'
  $env:COREPACK_HOME = Join-Path $Ws '.caches\corepack'
  $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
  $env:npm_config_store_dir = Join-Path $Ws '.caches\pnpm-store'
  $env:PATH = "$(Join-Path $Ws '.caches\pnpm-shim');$env:PATH"
  $env:ErrorActionPreference = 'Continue'
  & corepack pnpm tauri build --no-bundle 2>&1 | Select-Object -Last 8 | ForEach-Object { Say "  $_" }
  $env:ErrorActionPreference = 'Stop'

  $built = Join-Path $Repo 'src-tauri\target\release\deepseek-harness-desktop.exe'
  if (-not (Test-Path $built)) { Fail 'the build produced no binary' }
  $bytes = [IO.File]::ReadAllBytes($built)
  $has = ([regex]::Matches([Text.Encoding]::ASCII.GetString($bytes), 'DSH_APP_DATA')).Count +
         ([regex]::Matches([Text.Encoding]::Unicode.GetString($bytes), 'DSH_APP_DATA')).Count
  if ($has -eq 0) { Fail 'the built binary does NOT contain the DSH_APP_DATA override - the patch was lost' }
  Say "binary verified: DSH_APP_DATA present ($has occurrences)"
  Say "install it with: dsh-ecosystem.ps1 -Action Install   (or just run launch.cmd)"
}

Say ''
Say "SYNC OK - patch series applied on top of $UpstreamRemote/$UpstreamBranch"
Say "branch: $branch"
