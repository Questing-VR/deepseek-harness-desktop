# ============================================================================
#  DSH Kawaii desktop ecosystem - single-folder containment tool
# ============================================================================
#  One folder, one drive, one entry point, one command to back it up.
#
#  ECOSYSTEM ROOT:  D:\KEEP OUT\DSH Kawaii
#    deepseek-harness-desktop.exe   the shell
#    resources\                     shell resources
#    .appdata\                      redirected %APPDATA%      (was C:)
#    .appdata-local\                redirected %LOCALAPPDATA%  (was C:)
#    DSH Kawaii creator\            the workspace
#       .dsh\  .caches\  .wsl\  memory\  scripts\  *.md
#    .legacy\                       archived pre-migration C: state
#    backups\                       single-command backups land here
#    ecosystem.log / ecosystem-state.json
#
#  MECHANISM - MEASURED, NOT ASSUMED (see -Action Probe for the live test):
#    The shell has TWO path sources. It reads APPDATA / LOCALAPPDATA for some
#    paths, but its real data directory comes from the Win32 known-folder API
#    (SHGetKnownFolderPath), which ignores environment variables entirely.
#
#    Verified 2026-09-16 by running an isolated copy with redirected variables:
#      FOLLOWS the env vars : <APPDATA>\<id>\logs\desktop.log
#                             <LOCALAPPDATA>\deepseek-harness\bin\dsh.ps1
#                             <LOCALAPPDATA>\Microsoft\Windows\Caches
#      IGNORES them         : <APPDATA>\<id>\.store.dat
#                             <APPDATA>\<id>\dependencies\  (the harness runtime)
#                             <LOCALAPPDATA>\<id>\EBWebView
#
#    So environment redirection alone is NOT sufficient to contain this app.
#    The launcher therefore only applies the redirected environment when
#    containment has actually been achieved; otherwise it launches normally so
#    the app's state stays in one piece instead of splitting across drives.
# ============================================================================

[CmdletBinding()]
param(
  [ValidateSet('Status','Probe','Clean','Migrate','Launch','Backup','Verify','Secure','Log','Revert','Install','Accept')]
  [string]$Action = 'Status',
  [switch]$IncludeWsl,      # backup: also archive the 11 GB WSL vhdx
  [switch]$IncludeCaches,   # backup: also archive .caches + model/cache downloads
  [switch]$IncludeGraph,    # backup: also archive the derived Neo4j entity graph
  [switch]$IncludeLegacy,   # backup: also archive .legacy revert material
  [switch]$Force,           # Migrate: proceed even if the probe did not pass
  [switch]$All,             # Revert: undo every recorded change
  [int]$Steps = 1,          # Revert: how many recent changes to undo
  [int]$Keep = 10           # backup rotation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- layout ----
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Ws        = Join-Path $Root 'DSH Kawaii creator'
$DshHome   = Join-Path $Ws   '.dsh'
$Caches    = Join-Path $Ws   '.caches'
$WslDir    = Join-Path $Ws   '.wsl'
$AppDataR  = Join-Path $Root '.appdata'
$AppDataL  = Join-Path $Root '.appdata-local'
$Legacy    = Join-Path $Root '.legacy'
$Backups   = Join-Path $Root 'backups'
$ProbeDir  = Join-Path $Root '.probe'
$StateFile = Join-Path $Root 'ecosystem-state.json'
$LogFile   = Join-Path $Root 'ecosystem.log'
$Exe       = Join-Path $Root 'deepseek-harness-desktop.exe'
$AppId     = 'io.github.hairyf.deepseek-harness-desktop'

$RealRoaming = Join-Path $env:USERPROFILE 'AppData\Roaming'
$RealLocal   = Join-Path $env:USERPROFILE 'AppData\Local'

# Directories that MUST live inside the root. Roaming/Local are relative to the
# redirected variables and are also the exact paths the shell itself computes.
$RoamingSet = @($AppId, 'npm', 'npm-cache')
$LocalSet   = @($AppId, 'deepseek-harness', 'pnpm', 'pnpm-cache', 'pnpm-state', 'npm-cache')
$DeadSet    = @(
  @{ Path = (Join-Path $RealLocal   'dsh-desktop-updater');   Why = 'stale 168 MB cached installer' },
  @{ Path = (Join-Path $env:USERPROFILE '.dsh');              Why = 'duplicate pre-move DSH home (superseded by workspace .dsh)' },
  @{ Path = (Join-Path $DshHome '.dsh');                      Why = 'nested copy artifact .dsh\.dsh' }
)

# Paths that belong to a DIFFERENT product and must never be touched.
# PROVEN 2026-09-16: C:\...\Roaming\dsh-desktop is the Electron userData dir of
# "DSH Desktop 0.9.0-rc1" (publisher DataElement), installed at
# D:\KEEP OUT\DSH Desktop. Its resources\ ships dsh-desktop.patch.yml,
# harness-node-entry.mjs and elevate.exe, so it runs its OWN harness with its
# own harness\{profiles,sessions,storages}, .credentials.yaml and settings.yaml.
# It is NOT this ecosystem. An earlier version of this script wrongly classified
# it as dead residue; see the ledger entries for the damage and the restore.
$NotOurs = @(
  @{ Path = (Join-Path $RealRoaming 'dsh-desktop')
     Why  = 'Electron userData of the separate "DSH Desktop 0.9.0-rc1" product (DataElement). Never touched again.' }
)

# ----------------------------------------------------------------- utils ----
function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Write-Host $line
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}
function Get-AppProc {
  Get-Process -Name 'deepseek-harness-desktop' -ErrorAction SilentlyContinue
}
function Get-HarnessProc {
  # The shell spawns a node harness that OUTLIVES the window and holds the
  # runtime open. Anything that moves or probes the app data dir must know about
  # it: it both blocks the move and keeps writing to C: while a probe runs, which
  # would look like a redirection failure.
  #
  # Scoped to THIS ecosystem on purpose. Matching every `@deepseek-ai` node
  # process looks equivalent but is not: other DSH installations on the machine
  # run the same packages, and a *different* harness being open would then block
  # this launcher with "quit the app fully" - about an app the user never
  # started. Match the harness ENTRY POINT instead of the package names, and
  # require the path to be ours.
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $c = $_.CommandLine
      $c -and $c.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        ($c -match 'harness-node-entry\.mjs' -or $c -match 'deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js')
    }
}
function Reset-EcoEnv {
  # Launch with the normal environment. Used when containment is NOT active, so
  # the app keeps all of its state in one place instead of splitting logs and
  # CLI shims onto D: while its real data dir stays on C:.
  $env:APPDATA      = $RealRoaming
  $env:LOCALAPPDATA = $RealLocal
}
function Test-PathInUse {
  # A path is only unsafe to remove if the live system actually points at it:
  # either it is the active DSH home, or some running process names it.
  param([string]$Path)
  $norm = $Path.TrimEnd('\')
  if ($env:DSH_HOME -and $env:DSH_HOME.TrimEnd('\') -ieq $norm) { return $true }
  $hit = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -and $_.CommandLine -like "*$norm*" }
  return [bool]$hit
}
function New-Dir { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Get-TreeStat {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Files = -1; Bytes = 0; Links = 0 } }
  $files = 0; $bytes = 0; $links = 0
  Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++ }
    if (-not $_.PSIsContainer) { $files++; $bytes += $_.Length }
  }
  [pscustomobject]@{ Files = $files; Bytes = $bytes; Links = $links }
}
function Invoke-ArchiveDir {
  # Archive a directory into .legacy using link-preserving robocopy, VERIFY,
  # then remove the source.
  #
  # NEVER use Move-Item for this. A cross-volume Move-Item is copy-then-delete
  # and a mid-copy failure leaves the source partially destroyed. That is
  # exactly how C:\...\Roaming\dsh-desktop lost 51 files and 17.9 MB on
  # 2026-09-16; it had to be restored by hand from the partial copy.
  param([string]$Path, [string]$Why)
  $name = Split-Path -Leaf $Path
  $dest = Join-Path $Legacy ($name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Dir $Legacy
  $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
    "`"$Path`"", "`"$dest`"", '/E', '/SL', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
  )
  if ($rc.ExitCode -ge 8) {
    Write-Log "CLEAN: archive of $Path FAILED (robocopy $($rc.ExitCode)); source left intact, partial copy kept at $dest" 'ERROR'
    return $false
  }
  $s = Get-TreeStat $Path; $d = Get-TreeStat $dest
  if ($d.Files -lt $s.Files) {
    Write-Log "CLEAN: archive of $Path VERIFY FAILED src=$($s.Files) dst=$($d.Files); source left intact" 'ERROR'
    return $false
  }
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $Path) { Write-Log "CLEAN: $Path survived removal" 'WARN'; return $false }
  Write-Log "CLEAN: archived $Path -> $dest  [$Why]"
  Write-Change -Action 'archive' -Target $Path -MovedTo $dest -Why $Why -Files $d.Files -Bytes $d.Bytes
  return $true
}
function Get-State {
  # Always return the full shape so Set-StrictMode never trips on an older file.
  $o = [ordered]@{
    migrated = $false; probeVerdict = 'unknown'; probeAt = $null; migratedAt = $null
    lastLaunch = $null; launchContained = $null; lastBackup = $null
  }
  if (Test-Path -LiteralPath $StateFile) {
    try {
      $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
      foreach ($k in @($o.Keys)) {
        if ($j.PSObject.Properties.Name -contains $k) { $o[$k] = $j.$k }
      }
    } catch {}
  }
  [pscustomobject]$o
}
function Save-State {
  param($State)
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}
function Invoke-RobocopyMove {
  # Copy with links preserved, VERIFY, then delete the source. Never /MOVE
  # blind: a failed copy must not be able to destroy the original.
  param([string]$Source, [string]$Dest, [string]$Label)
  if (-not (Test-Path -LiteralPath $Source)) { Write-Log "$Label : source absent, nothing to do"; return $true }
  New-Dir (Split-Path -Parent $Dest)
  Write-Log "$Label : copying $Source -> $Dest (links preserved)"
  $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
    "`"$Source`"", "`"$Dest`"", '/E', '/SL', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:5', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
  )
  # robocopy: 0-7 are success codes
  if ($rc.ExitCode -ge 8) { Write-Log "$Label : robocopy FAILED (exit $($rc.ExitCode)); source left intact" 'ERROR'; return $false }
  $s = Get-TreeStat $Source; $d = Get-TreeStat $Dest
  if ($d.Files -lt $s.Files) {
    Write-Log "$Label : VERIFY FAILED files src=$($s.Files) dst=$($d.Files); source left intact" 'ERROR'; return $false
  }
  Write-Log "$Label : verified files=$($d.Files) links=$($d.Links) bytes=$($d.Bytes); removing source"
  Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $Source) { Write-Log "$Label : source survived removal (locked?)" 'WARN'; return $false }
  Write-Change -Action 'move' -Target $Source -MovedTo $Dest -Why "relocated inside the ecosystem root ($Label)" -Files $d.Files -Bytes $d.Bytes
  return $true
}

# ------------------------------------------------------- change ledger ------
# EVERY mutation appends one JSON line to ecosystem-changes.jsonl and rewrites
# REVERT.md. If the system misbehaves, REVERT.md is the one file to read: each
# change carries a single-line undo, and -Action Revert replays them properly.
$ChangesFile = Join-Path $Root 'ecosystem-changes.jsonl'
$RevertDoc   = Join-Path $Root 'REVERT.md'

function Write-Change {
  param(
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Target,
    [string]$MovedTo, [string]$Before, [string]$Why,
    [int]$Files = 0, [long]$Bytes = 0,
    [string]$Status = 'done', [string]$Revert
  )
  if (-not $Revert) {
    switch ($Action) {
      'archive' { $Revert = "robocopy `"$MovedTo`" `"$Target`" /E /SL /COPY:DAT /DCOPY:DAT   # then delete the stored copy" }
      'move'    { $Revert = "robocopy `"$MovedTo`" `"$Target`" /E /SL /COPY:DAT /DCOPY:DAT   # then delete the stored copy" }
      'remove'  { $Revert = "robocopy `"$MovedTo`" `"$Target`" /E /COPY:DAT /DCOPY:DAT" }
      'acl'     { $Revert = "Import-Clixml '$MovedTo' | Set-Acl -LiteralPath '$Target'" }
      'path'    { $Revert = "[Environment]::SetEnvironmentVariable('$Target','$Before','User')" }
      default   { $Revert = '(manual)' }
    }
  }
  $e = [ordered]@{
    at = (Get-Date -Format o); action = $Action; target = $Target; movedTo = $MovedTo
    before = $Before; why = $Why; files = $Files; bytes = $Bytes; status = $Status; revert = $Revert
  }
  # .NET append, not Add-Content: PS 5.1 -Encoding UTF8 writes a BOM, which
  # would corrupt the first JSON line and silently drop a ledger entry.
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($ChangesFile, (($e | ConvertTo-Json -Compress) + "`r`n"), $enc)
  Write-Log ("LEDGER: {0} {1}{2}" -f $Action, $Target, $(if ($MovedTo) { " -> $MovedTo" } else { '' }))
}

function Get-Changes {
  if (-not (Test-Path -LiteralPath $ChangesFile)) { return @() }
  $out = @()
  foreach ($line in (Get-Content -LiteralPath $ChangesFile)) {
    if (-not $line.Trim()) { continue }
    try { $out += ($line.TrimStart([char]0xFEFF) | ConvertFrom-Json) } catch {}
  }
  # Emit normally. Wrapping in "," suppressed enumeration and made callers see
  # one nested array, so $c[$k].bytes became Object[] and the [double] cast in
  # Update-RevertDoc threw ConvertToFinalInvalidCastException.
  $out
}

function Update-RevertDoc {
  $c  = @(Get-Changes)
  $st = Get-State
  $L  = New-Object System.Collections.Generic.List[string]
  $L.Add('# REVERT - DSH Kawaii ecosystem')
  $L.Add('')
  $L.Add("Generated: $(Get-Date -Format o)")
  $L.Add('')
  $L.Add('READ THIS FILE FIRST if anything misbehaves. Every mutation the containment')
  $L.Add('tool made is listed below, newest first, each with a one-line undo.')
  $L.Add('## MANUAL RECOVERY - do these by hand, in order')
  $L.Add('')
  $L.Add('If the app misbehaves, this puts it back. Each step stands alone - stop as')
  $L.Add('soon as it works again. No tool and no script required.')
  $L.Add('')
  $L.Add('**Step 1 - restore the original shell.**')
  $stock = @(Get-StockBackup)
  if ($stock.Count -gt 0) {
    $L.Add('')
    $L.Add("Newest backup: ``$($stock[0].FullName)``")
    $L.Add('')
    $L.Add('```powershell')
    $L.Add("Copy-Item -LiteralPath '$($stock[0].FullName)' -Destination '$Exe' -Force")
    $L.Add('```')
  } else {
    $L.Add('')
    $L.Add('(No backup recorded - the stock shell was never replaced.)')
  }
  $L.Add('')
  $L.Add('**Step 2 - drop the root override.** The app then uses the system AppData')
  $L.Add('again, exactly like the stock build did:')
  $L.Add('')
  $L.Add('```powershell')
  $L.Add("[Environment]::SetEnvironmentVariable('DSH_APP_DATA',`$null,'User')")
  $L.Add('```')
  $L.Add('')
  $L.Add('**Step 3 - put PATH back**, only if the shim directory matters to you. The')
  $L.Add('recorded original value is right here (newest ``path`` entry):')
  $L.Add('')
  $pathEntry = @(Get-Changes | Where-Object { $_.action -eq 'path' -and $_.target -eq 'PATH' } | Select-Object -Last 1)
  $L.Add('```powershell')
  if ($pathEntry.Count -gt 0) { $L.Add([string]$pathEntry[0].revert) } else { $L.Add('# (no PATH change recorded)') }
  $L.Add('```')
  $L.Add('')
  $L.Add('**Step 4 - the app''s old data.** It is still on C: unless ``-Action Migrate``')
  $L.Add('ran; if it did, the move is listed below with a copy-back command on it.')
  $L.Add('Nothing else on the machine was modified except the two user-scope')
  $L.Add('variables in steps 2 and 3.')
  $L.Add('')
  $L.Add('## ...or do all of it automatically')
  $L.Add('')
  $L.Add('```powershell')
  $L.Add("& '$PSCommandPath' -Action Revert -All")
  $L.Add('```')
  $L.Add('')
  $L.Add('## Recorded state')
  $L.Add('')
  $L.Add('```json')
  $L.Add(($st | ConvertTo-Json -Compress))
  $L.Add('```')
  $L.Add('')
  $L.Add("## Changes ($($c.Count) recorded), newest first")
  $L.Add('')
  $i = 0
  for ($k = $c.Count - 1; $k -ge 0; $k--) {
    $x = $c[$k]; $i++
    $L.Add("### $i. ``$($x.action)``  $($x.at)")
    $L.Add('')
    $L.Add("- target : ``$($x.target)``")
    if ($x.movedTo) { $L.Add("- stored : ``$($x.movedTo)``") }
    if ($x.before)  { $L.Add("- before : ``$($x.before)``") }
    if ($x.why)     { $L.Add("- why    : $($x.why)") }
    $L.Add("- size   : $($x.files) files, $([math]::Round([double]$x.bytes / 1MB, 2)) MB")
    $L.Add("- status : $($x.status)")
    $L.Add('')
    $L.Add('```powershell')
    $L.Add($x.revert)
    $L.Add('```')
    $L.Add('')
  }
  Set-Content -LiteralPath $RevertDoc -Value ($L -join "`r`n") -Encoding UTF8
}

function Show-Log {
  Update-RevertDoc
  $c = @(Get-Changes)
  Write-Host ''
  Write-Host "ledger : $ChangesFile" -ForegroundColor Cyan
  Write-Host "doc    : $RevertDoc" -ForegroundColor Cyan
  Write-Host "entries: $($c.Count)" -ForegroundColor Cyan
  Write-Host ('-' * 78)
  for ($k = $c.Count - 1; $k -ge 0; $k--) {
    $x = $c[$k]
    Write-Host ("  {0,-8} {1}" -f $x.action, $x.target)
    if ($x.movedTo) { Write-Host ("           -> {0}" -f $x.movedTo) -ForegroundColor DarkGray }
  }
  Write-Host ''
}

function Invoke-Revert {
  param([int]$Steps = 1, [switch]$All)
  $c = @(Get-Changes)
  if ($c.Count -eq 0) { Write-Log 'REVERT: ledger is empty'; return }
  $take = if ($All) { $c.Count } else { [Math]::Min($Steps, $c.Count) }
  Write-Log "REVERT: undoing $take change(s), newest first"
  for ($k = $c.Count - 1; $k -ge $c.Count - $take; $k--) {
    $x = $c[$k]
    Write-Host ("  undo {0,-8} {1}" -f $x.action, $x.target) -ForegroundColor Yellow
    switch ($x.action) {
      { $_ -in @('archive','move','remove') } {
        if (-not $x.movedTo -or -not (Test-Path -LiteralPath $x.movedTo)) {
          Write-Log "REVERT: stored copy missing for $($x.target); nothing done" 'ERROR'; continue
        }
        if (Test-Path -LiteralPath $x.target) { Write-Log "REVERT: $($x.target) exists; merging" 'WARN' }
        $rc = Start-Process -FilePath 'robocopy.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
          "`"$($x.movedTo)`"", "`"$($x.target)`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
        )
        if ($rc.ExitCode -ge 8) { Write-Log "REVERT: restore of $($x.target) FAILED (rc=$($rc.ExitCode)); stored copy kept" 'ERROR' }
        else { Write-Log "REVERT: restored $($x.target)" }
      }
      'acl' {
        if ($x.movedTo -and (Test-Path -LiteralPath $x.movedTo)) {
          try { Import-Clixml -LiteralPath $x.movedTo | Set-Acl -LiteralPath $x.target; Write-Log "REVERT: restored ACL on $($x.target)" }
          catch { Write-Log "REVERT: ACL restore failed: $_" 'ERROR' }
        } else { Write-Log "REVERT: no ACL backup for $($x.target)" 'ERROR' }
      }
      'binary' {
        # 把原版 shell 拷回去。这是最要紧的一条：二进制不对，界面就起不来。
        if ($x.movedTo -and (Test-Path -LiteralPath $x.movedTo)) {
          try { Copy-Item -LiteralPath $x.movedTo -Destination $x.target -Force; Write-Log "REVERT: restored the original shell to $($x.target)" }
          catch { Write-Log "REVERT: shell restore failed: $_" 'ERROR' }
        } else { Write-Log "REVERT: no shell backup recorded for $($x.target)" 'ERROR' }
      }
      'path' {
        [Environment]::SetEnvironmentVariable($x.target, $x.before, 'User')
        Write-Log "REVERT: restored $($x.target)"
      }
      default { Write-Log "REVERT: no automatic handler; run manually: $($x.revert)" 'WARN' }
    }
  }
  Update-RevertDoc
}

# ------------------------------------------------------- environment set ----
function Set-EcoEnv {
  New-Dir $AppDataR; New-Dir $DshHome; New-Dir $Caches; New-Dir $AppDataL
  # 打过补丁的 shell 认 DSH_APP_DATA，并把**一切**（dependencies、runtime、
  # logs、tmp、webview、updates、.store.dat、bin）都放到它下面。
  $env:DSH_APP_DATA         = $AppDataR
  $env:DSH_HOME             = $DshHome
  $env:UV_CACHE_DIR         = Join-Path $Caches 'uv'
  $env:PIP_CACHE_DIR        = Join-Path $Caches 'pip'
  $env:npm_config_cache     = Join-Path $Caches 'npm'
  # THE STORE PATH MUST MATCH WHAT THE PROFILES RECORD.
  #
  # `dsh`/plugin installs run pnpm inside a profile, and pnpm refuses to proceed
  # with ERR_PNPM_UNEXPECTED_STORE when the store it resolves differs from the
  # `storeDir` baked into that profile's node_modules/.modules.yaml. The profiles
  # record `<caches>\pnpm\store` (that is also PNPM_HOME's store), NOT
  # `<caches>\pnpm-store` - a second, older store from the v10 layout.
  $env:npm_config_store_dir = Join-Path $Caches 'pnpm\store'
  # ...AND THE pnpm THAT RUNS MUST BE OURS.
  #
  # Measured 2026-09-22: the store path alone is not enough. The app's own
  # `.appdata\bin\pnpm.cmd` shim prefers "a user-installed pnpm" over the bundled
  # one, and the first `pnpm` on this machine's PATH belongs to a DIFFERENT
  # product (`%APPDATA%\dsh-desktop\harness\.desktop-bin\pnpm.cmd`, pnpm 10.34.5).
  # pnpm 10 appends `v10` to the store; these profiles were installed by pnpm
  # 11.7.0 and record `v11`, so every marketplace update died with
  # ERR_PNPM_UNEXPECTED_STORE and rolled the build back.
  #   without the switch: 10.34.5 -> <caches>\pnpm\store\v10   (mismatch)
  #   with the switch   : 11.7.0  -> <caches>\pnpm\store\v11   (matches)
  # The bundled pnpm under `.appdata\dependencies\pnpm` IS 11.7.0, so prefer it:
  # a self-contained install must not resolve toolchain from another product.
  $env:DSH_PREFER_BUNDLED_PNPM = '1'
  # Bare `pnpm` calls made by the app's children must hit our shim first, not
  # whatever another product left ahead of us on PATH.
  $appBin = Join-Path $AppDataR 'bin'
  if (Test-Path -LiteralPath (Join-Path $appBin 'pnpm.cmd')) {
    $rest = @($env:PATH -split ';' | Where-Object { $_ -and $_ -ne $appBin } | Select-Object -Unique)
    $env:PATH = (@($appBin) + $rest) -join ';'
  }
  $env:DSH_TELEMETRY_DISABLED = '1'
  # LOCALAPPDATA still matters even with DSH_APP_DATA, because not every writer
  # goes through the path authority. The WebView2 loader drops a zero-byte
  # `<LOCALAPPDATA>\<id>\.cookies` lock file next to its user data folder and
  # reads LOCALAPPDATA directly. Measured 2026-09-22: without this line that one
  # file reappears on C: on every launch, and it is the ONLY thing that ever
  # escapes the root - the app's own data stays put. Point the variable at the
  # root so every writer that honours it lands inside.
  $env:LOCALAPPDATA         = $AppDataL
  # The RSI panel plugin (profile bundle `@local/rsi-ui`) is a host plugin inside
  # the harness: it proxies the Memory & learning panel's calls to the local RSI
  # API. That API authenticates with a bearer token read from this file, and the
  # plugin reads it from ITS OWN process environment, so the value has to be in
  # the environment the shell is started with. Without it every panel request is
  # rejected and the panel silently shows nothing.
  $rsiKey = Join-Path $Ws 'rsi\records\local-server.key'
  if (Test-Path -LiteralPath $rsiKey) {
    $env:LOCAL_MODEL_API_KEY = (Get-Content -LiteralPath $rsiKey -Raw).Trim()
  }
  # The RSI host plugins also need to know which install they belong to: the panel
  # and the rsi_* tools resolve paths under RSI_ROOT, and the tools proxy to the
  # controller named by RSI_PANEL_URL. Both point at this ecosystem's own port, so
  # the live install on S: is never addressed by accident.
  $rsiRoot = Join-Path $Ws 'rsi'
  if (Test-Path -LiteralPath $rsiRoot) {
    $env:RSI_ROOT      = $rsiRoot
    $env:RSI_PANEL_URL = 'http://127.0.0.1:18803'
  }
}

# ------------------------------------------------- install / identity ------
$PatchedBuilt = Join-Path $Ws 'src\deepseek-harness-desktop\src-tauri\target\release\deepseek-harness-desktop.exe'

function Test-PatchedBinary {
  # 以「DSH_APP_DATA 覆盖是否编进二进制」识别打过补丁的构建：
  # 原版 0 次出现，打过补丁的 2 次。比时间戳/体积可靠。
  param([string]$Path = $Exe)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $bytes = [IO.File]::ReadAllBytes($Path)
  $ascii = [Text.Encoding]::ASCII.GetString($bytes)
  $uni   = [Text.Encoding]::Unicode.GetString($bytes)
  return (([regex]::Matches($ascii, 'DSH_APP_DATA')).Count + ([regex]::Matches($uni, 'DSH_APP_DATA')).Count) -gt 0
}

function Get-StockBackup {
  @(Get-ChildItem -LiteralPath $Legacy -Filter 'deepseek-harness-desktop.stock-*.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
}

function Install-PatchedBinary {
  if (-not (Test-Path -LiteralPath $PatchedBuilt)) {
    Write-Log "INSTALL: no patched build at $PatchedBuilt" 'ERROR'; return $false
  }
  # 按内容比较，而不是「有没有 DSH_APP_DATA 标记」：旧版补丁构建也带这个标记，
  # 用它判断会把「有新构建但没装」误判成「已是最新」，后续修复就永远装不上。
  $builtHash = (Get-FileHash -LiteralPath $PatchedBuilt -Algorithm SHA256).Hash
  $instHash  = if (Test-Path -LiteralPath $Exe) { (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash } else { '' }
  if ($builtHash -eq $instHash) { Write-Log 'INSTALL: already up to date (identical hash)'; return $true }
  $installedIsStock = -not (Test-PatchedBinary $Exe)
  Write-Log ("INSTALL: {0} - swapping in the newer build" -f $(if ($installedIsStock) { 'stock shell detected' } else { 'newer patched build available' }))
  # 先确认目标可写：应用运行时 exe 被占用，此时换不了。这也是为什么换壳发生在
  # launch 阶段（进程启动之前），而不是随时。占用时直接放弃，不留多余备份。
  try {
    $probe = [IO.File]::Open($Exe, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $probe.Close()
  } catch {
    Write-Log 'INSTALL: deferred - the shell is in use because the app is running. It will be swapped automatically at launch, before the app starts.' 'WARN'
    return $false
  }
  New-Dir $Legacy
  # 原版备份名带 stock-，REVERT.md 的手工恢复按它找原版；旧补丁构建记为 previous-，
  # 免得手工恢复把中间版本误当成原版。
  $prefix = if ($installedIsStock) { 'deepseek-harness-desktop.stock-' } else { 'deepseek-harness-desktop.previous-' }
  $backup = Join-Path $Legacy ($prefix + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
  Copy-Item -LiteralPath $Exe -Destination $backup -Force
  Write-Log "INSTALL: original shell backed up to $backup"
  Copy-Item -LiteralPath $PatchedBuilt -Destination $Exe -Force
  if (-not (Test-PatchedBinary $Exe)) {
    Write-Log 'INSTALL: verification FAILED after copy; restoring the original' 'ERROR'
    Copy-Item -LiteralPath $backup -Destination $Exe -Force
    return $false
  }
  Write-Change -Action 'binary' -Target $Exe -MovedTo $backup `
    -Why 'stock shell replaced by the locally built patched shell (single path authority)' `
    -Revert "Copy-Item -LiteralPath '$backup' -Destination '$Exe' -Force"
  Write-Log 'INSTALL: patched shell installed and verified'
  return $true
}

# ================================================================ STATUS ====
function Show-Status {
  Write-Host ''
  Write-Host "ECOSYSTEM ROOT  $Root" -ForegroundColor Cyan
  Write-Host ('-' * 78)
  $p = Get-AppProc
  Write-Host ("app running     : {0}" -f $(if ($p) { "yes (pid $($p.Id -join ','))" } else { 'no' }))
  Write-Host ("state file      : {0}" -f $(if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() -replace '\s+', ' ' } else { '(none yet)' }))
  Write-Host ''
  Write-Host 'INSIDE THE ROOT' -ForegroundColor Green
  foreach ($d in @($DshHome, $AppDataR, $AppDataL, $Caches, $WslDir, (Join-Path $Ws 'memory'), $Backups)) {
    if (Test-Path -LiteralPath $d) {
      $s = Get-TreeStat $d
      Write-Host ("  {0,-46} {1,8} files {2,10:N2} MB" -f $d.Replace($Root, '.'), $s.Files, ($s.Bytes / 1MB))
    }
  }
  Write-Host ''
  Write-Host 'STILL ON C: (should be empty once migrated)' -ForegroundColor Yellow
  $residue = 0
  foreach ($n in $RoamingSet) { $t = Join-Path $RealRoaming $n; if (Test-Path -LiteralPath $t) { $s = Get-TreeStat $t; Write-Host ("  {0,-60} {1,8} files {2,10:N2} MB" -f $t, $s.Files, ($s.Bytes / 1MB)); $residue++ } }
  foreach ($n in $LocalSet)   { $t = Join-Path $RealLocal   $n; if (Test-Path -LiteralPath $t) { $s = Get-TreeStat $t; Write-Host ("  {0,-60} {1,8} files {2,10:N2} MB" -f $t, $s.Files, ($s.Bytes / 1MB)); $residue++ } }
  if ($residue -eq 0) { Write-Host '  (clean)' -ForegroundColor Green }
  Write-Host ''
  Write-Host 'DEAD STATE STILL PRESENT' -ForegroundColor Yellow
  $dead = 0
  foreach ($d in $DeadSet) { if (Test-Path -LiteralPath $d.Path) { $s = Get-TreeStat $d.Path; Write-Host ("  {0,-60} {1,8} files {2,10:N2} MB  [{3}]" -f $d.Path, $s.Files, ($s.Bytes / 1MB), $d.Why); $dead++ } }
  if ($dead -eq 0) { Write-Host '  (clean)' -ForegroundColor Green }
  Write-Host ''
  Write-Host 'NOT THIS ECOSYSTEM - never touched automatically' -ForegroundColor DarkGray
  foreach ($d in $NotOurs) { if (Test-Path -LiteralPath $d.Path) { Write-Host ("  {0}" -f $d.Path) -ForegroundColor DarkGray } }
  Write-Host ''
}

# ================================================================= PROBE ====
function Invoke-Probe {
  # Definitive test of the redirection mechanism, run while the app is DOWN so
  # no single-instance guard can mask the result. An isolated copy is launched
  # with redirected variables; if the redirect works the sandbox fills up and
  # the real %APPDATA% stays untouched. If it does not, the real dir moves.
  Write-Log 'PROBE: starting redirection proof'
  if (Get-AppProc) { Write-Log 'PROBE: app is running; probe requires it stopped' 'ERROR'; return 'blocked-app-running' }
  $live = @(Get-HarnessProc)
  if ($live.Count -gt 0) {
    Write-Log "PROBE: $($live.Count) node harness process(es) still running (pid $($live.ProcessId -join ',')); they write to C: and would fake a failure. Quit the app fully first." 'ERROR'
    return 'blocked-harness-running'
  }
  if (Test-Path -LiteralPath $ProbeDir) { Remove-Item -LiteralPath $ProbeDir -Recurse -Force -ErrorAction SilentlyContinue }
  $pa = Join-Path $ProbeDir 'app'; $ph = Join-Path $ProbeDir 'home'; $pl = Join-Path $ProbeDir 'local'; $pd = Join-Path $ProbeDir 'dsh'
  New-Dir $pa; New-Dir $ph; New-Dir $pl; New-Dir $pd
  Copy-Item -LiteralPath $Exe -Destination $pa
  Copy-Item -LiteralPath (Join-Path $Root 'resources') -Destination $pa -Recurse

  $realR = Join-Path $RealRoaming $AppId
  $realL = Join-Path $RealLocal   $AppId
  function _newest($x) { if (Test-Path -LiteralPath $x) { (Get-ChildItem -LiteralPath $x -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime } else { $null } }
  $beforeR = _newest $realR; $beforeL = _newest $realL

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $pa 'deepseek-harness-desktop.exe'
  $psi.WorkingDirectory = $pa
  $psi.UseShellExecute = $false
  $psi.EnvironmentVariables['APPDATA']      = $ph
  $psi.EnvironmentVariables['LOCALAPPDATA'] = $pl
  $psi.EnvironmentVariables['DSH_HOME']     = $pd
  $psi.EnvironmentVariables['DSH_TELEMETRY_DISABLED'] = '1'
  $proc = [System.Diagnostics.Process]::Start($psi)
  Write-Log "PROBE: launched isolated copy pid=$($proc.Id)"

  $deadline = (Get-Date).AddSeconds(50)
  $sawHome = $false; $sawLocal = $false; $sawDsh = $false; $sawBase = $false
  $probeBase = Join-Path $ph $AppId
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Log "PROBE: copy exited early code=$($proc.ExitCode)"; break }
    $sawHome  = $sawHome  -or ((Get-ChildItem $ph -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    $sawLocal = $sawLocal -or ((Get-ChildItem $pl -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    $sawDsh   = $sawDsh   -or ((Get-ChildItem $pd -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    # .store.dat / dependencies are the DECISIVE markers: they only appear at the
    # redirected path if the app's base data dir follows the environment. Logs
    # and CLI shims can redirect while the base dir does not, which is exactly
    # what this app does.
    $sawBase  = (Test-Path -LiteralPath (Join-Path $probeBase '.store.dat')) -or (Test-Path -LiteralPath (Join-Path $probeBase 'dependencies'))
    if ($sawHome -and $sawLocal -and $sawBase) { Write-Log 'PROBE: base data dir redirected; stopping early'; break }
  }
  try {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
  } catch {}
  Start-Sleep -Seconds 2

  $afterR = _newest $realR; $afterL = _newest $realL
  $cTouched = ($afterR -ne $beforeR) -or ($afterL -ne $beforeL)

  # Classify exactly what followed the redirect. Recording the split keeps the
  # verdict actionable instead of a bare pass/fail.
  $ev = [ordered]@{
    baseDataRedirected  = $sawBase
    shellLogsRedirected = Test-Path -LiteralPath (Join-Path $probeBase 'logs')
    cliShimsRedirected  = Test-Path -LiteralPath (Join-Path $pl 'deepseek-harness\bin')
    webviewRedirected   = ((Get-ChildItem (Join-Path $pl $AppId) -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    dshHomeRedirected   = $sawDsh
    realRoamingTouched  = ($afterR -ne $beforeR)
    realLocalTouched    = ($afterL -ne $beforeL)
  }
  Write-Log ("PROBE: base={0} logs={1} shims={2} webview={3} ; realC_touched={4}" -f `
    $ev.baseDataRedirected, $ev.shellLogsRedirected, $ev.cliShimsRedirected, $ev.webviewRedirected, $cTouched)

  $verdict = if ($ev.baseDataRedirected -and -not $cTouched) { 'works' }
             elseif ($ev.shellLogsRedirected -or $ev.cliShimsRedirected -or $ev.webviewRedirected) { 'partial-known-folder-api' }
             elseif ($cTouched) { 'fails-c-touched' }
             elseif ($sawHome -or $sawLocal -or $sawDsh) { 'partial' }
             else { 'inconclusive' }
  Write-Log "PROBE: verdict = $verdict" $(if ($verdict -eq 'works') { 'INFO' } else { 'WARN' })
  if ($verdict -eq 'partial-known-folder-api') {
    Write-Log 'PROBE: the app reads APPDATA/LOCALAPPDATA for logs, CLI shims and caches, but its data directory comes from the Win32 known-folder API and ignores the environment. Environment redirection alone can never contain this app.' 'WARN'
  }

  Remove-Item -LiteralPath $ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
  $st = Get-State; $st | Add-Member -NotePropertyName probeVerdict -NotePropertyValue $verdict -Force
  $st | Add-Member -NotePropertyName probeAt -NotePropertyValue (Get-Date -Format o) -Force
  $st | Add-Member -NotePropertyName probeEvidence -NotePropertyValue $ev -Force
  Save-State $st
  return $verdict
}

# ================================================================= CLEAN ====
function Invoke-Clean {
  Write-Log 'CLEAN: removing dead state'
  New-Dir $Legacy

  # 1. Archive the delta of the duplicate C: DSH home before deleting it, so
  #    nothing is destroyed unverified. Guarded: never touch a live path.
  $dupDsh = Join-Path $env:USERPROFILE '.dsh'
  if ((Test-Path -LiteralPath $dupDsh) -and (Test-PathInUse $dupDsh)) {
    Write-Log "CLEAN: $dupDsh is referenced by a running process; skipping" 'WARN'
  }
  elseif (Test-Path -LiteralPath $dupDsh) {
    $delta = Join-Path $Legacy 'dot-dsh-delta'
    New-Dir $delta
    $seen = 0; $copied = 0; $bytes = 0
    Get-ChildItem -LiteralPath $dupDsh -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
      $seen++
      $rel  = $_.FullName.Substring($dupDsh.Length).TrimStart('\')
      $twin = Join-Path $DshHome $rel
      $need = $true
      if (Test-Path -LiteralPath $twin) {
        if ((Get-Item -LiteralPath $twin -Force).LastWriteTime -ge $_.LastWriteTime) { $need = $false }
      }
      if ($need) {
        $out = Join-Path $delta $rel
        New-Dir (Split-Path -Parent $out)
        Copy-Item -LiteralPath $_.FullName -Destination $out -Force -ErrorAction SilentlyContinue
        $copied++; $bytes += $_.Length
      }
    }
    Write-Log ("CLEAN: archived {0}/{1} superseded files ({2:N2} MB) from {3}" -f $copied, $seen, ($bytes / 1MB), $dupDsh)
    if ($copied -gt 0) {
      Add-Content -LiteralPath (Join-Path $Legacy 'README.txt') -Encoding UTF8 -Value @(
        "Archived $(Get-Date -Format o)",
        "Source: $dupDsh",
        "These files were absent from, or older than, the live DSH home:",
        "  $DshHome",
        "They are derived node_modules entries and one stale pre-move memory copy.",
        "Safe to delete once the live home is confirmed working."
      )
    }
    Remove-Item -LiteralPath $dupDsh -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dupDsh) { Write-Log "CLEAN: $dupDsh survived removal (locked?)" 'WARN' }
    else {
      Write-Log "CLEAN: removed $dupDsh"
      Write-Change -Action 'remove' -Target $dupDsh -MovedTo $delta -Files $copied -Bytes $bytes `
                   -Why "duplicate pre-move DSH home; only the $copied superseded files were archived, the rest already existed in $DshHome"
    }
  }

  # 2. Dead / legacy directories, each guarded against live use.
  foreach ($d in $DeadSet) {
    if (-not (Test-Path -LiteralPath $d.Path)) { continue }
    if ($d.Path -eq (Join-Path $env:USERPROFILE '.dsh')) { continue }   # handled above
    if (Test-PathInUse $d.Path) { Write-Log "CLEAN: $($d.Path) in use; skipping" 'WARN'; continue }
    [void](Invoke-ArchiveDir -Path $d.Path -Why $d.Why)
  }
  Invoke-Secure
  Write-Log 'CLEAN: done'
}

# ================================================================ SECURE ====
function Invoke-Secure {
  # .credentials.yaml inherited BUILTIN\Users:ReadAndExecute and
  # Authenticated Users:Modify from its parent. Restrict it to the owner.
  $cred = Join-Path $DshHome '.credentials.yaml'
  if (-not (Test-Path -LiteralPath $cred)) { return }
  $aclFile = Join-Path $Legacy 'credentials-acl-backup.txt'
  New-Dir $Legacy
  $acl = Get-Acl -LiteralPath $cred
  $acl | Export-Clixml -LiteralPath (Join-Path $Legacy 'credentials-acl-backup.xml') -Force
  "Original SDDL ($(Get-Date -Format o)): $($acl.Sddl)" | Set-Content -LiteralPath $aclFile -Encoding UTF8
  $me = "$env:COMPUTERNAME\$env:USERNAME"
  try {
    $acl.SetAccessRuleProtection($true, $false)                      # stop inheriting
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    foreach ($id in @($me, 'NT AUTHORITY\SYSTEM')) {
      $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $id, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $cred -AclObject $acl
    Write-Log "SECURE: $cred restricted to $me + SYSTEM"
    Write-Change -Action 'acl' -Target $cred -MovedTo (Join-Path $Legacy 'credentials-acl-backup.xml') `
                 -Before $acl.Sddl -Why 'file inherited BUILTIN\Users:ReadAndExecute and Authenticated Users:Modify'
  } catch {
    Write-Log "SECURE: could not restrict credentials: $_" 'WARN'
  }
}

# =============================================================== MIGRATE ====
function Invoke-Migrate {
  $st = Get-State
  if (Get-AppProc) { Write-Log 'MIGRATE: app is running; close it first' 'ERROR'; return }
  if ($st.migrated -eq $true -and -not $Force) { Write-Log 'MIGRATE: already done (use -Force to redo)'; return }

  if (-not (Test-PatchedBinary $Exe)) {
    Write-Log 'MIGRATE: the installed shell is the STOCK build, so it would ignore DSH_APP_DATA and keep using C:. Run -Action Install first.' 'ERROR'
    return
  }
  Write-Log 'MIGRATE: relocating legacy C: state into the root'
  New-Dir $AppDataR; New-Dir $Legacy

  # 1) 应用基础数据目录（dependencies/、runtime/、logs/、updates/、.store.dat
  #    等）就地成为根目录的**内容**：robocopy 合并进 <root>。
  [void](Invoke-RobocopyMove -Source (Join-Path $RealRoaming $AppId) -Dest $AppDataR -Label 'app-data')

  # 2) WebView2 用户数据 -> <root>\webview
  [void](Invoke-RobocopyMove -Source (Join-Path $RealLocal "$AppId\EBWebView") `
                             -Dest (Join-Path $AppDataR 'webview\EBWebView') -Label 'webview')

  # 3) 纯缓存搬到 .caches（不是应用状态，但仍不该留在 C:）。
  foreach ($n in @('npm')) { [void](Invoke-RobocopyMove -Source (Join-Path $RealRoaming $n) -Dest (Join-Path $Caches $n) -Label "roaming/$n") }
  foreach ($n in @('pnpm', 'pnpm-cache', 'pnpm-state', 'npm-cache')) {
    [void](Invoke-RobocopyMove -Source (Join-Path $RealLocal $n) -Dest (Join-Path $Caches $n) -Label "local/$n")
  }

  # 4) 旧的用户级 shim 目录被 <root>\bin 取代（补丁在可移植模式下写那里）。
  $oldShim = Join-Path $RealLocal 'deepseek-harness'
  if (Test-Path -LiteralPath $oldShim) {
    [void](Invoke-ArchiveDir -Path $oldShim -Why 'superseded CLI shims; portable mode writes <root>\bin')
  }

  # 5) PATH 与用户级根目录变量都要跟着走。
  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  $newBin   = Join-Path $AppDataR 'bin'
  $parts    = @($userPath -split ';' | Where-Object { $_ -and $_ -notmatch 'deepseek-harness\\bin|pnpm\\bin' })
  if ($parts -notcontains $newBin) { $parts += $newBin }
  [Environment]::SetEnvironmentVariable('PATH', ($parts -join ';'), 'User')
  [Environment]::SetEnvironmentVariable('DSH_HOME', $DshHome, 'User')
  [Environment]::SetEnvironmentVariable('DSH_APP_DATA', $AppDataR, 'User')
  Write-Change -Action 'path' -Target 'PATH' -Before $userPath -Why "user PATH followed the CLI shims into $newBin" `
    -Revert "[Environment]::SetEnvironmentVariable('PATH','$userPath','User')"
  Write-Change -Action 'path' -Target 'DSH_APP_DATA' -Before '(unset)' `
    -Why 'user-scope root override so the shell is contained however it is started' `
    -Revert "[Environment]::SetEnvironmentVariable('DSH_APP_DATA',`$null,'User')"
  Write-Log "MIGRATE: user PATH now points at $newBin"

  $st = Get-State
  $st | Add-Member -NotePropertyName migrated -NotePropertyValue $true -Force
  $st | Add-Member -NotePropertyName migratedAt -NotePropertyValue (Get-Date -Format o) -Force
  Save-State $st
  Write-Log 'MIGRATE: complete'
}

# ================================================================= LAUNCH ===
# The in-UI "Memory & learning" panel is a client plugin (`@local/rsi-ui`): it
# POSTs to the harness route `/local-rsi-api`, and the plugin's host half proxies
# that to `http://127.0.0.1:18803/rsi/ui`. Nothing else in the ecosystem starts
# that server, so without this the panel renders its chrome and every request
# fails - which is exactly what "the panel is there but nothing works" means.
#
# `service.py --front-only` serves only that API, from local records + SQLite +
# the filesystem. It deliberately does NOT call wake_model() or start the second
# DeepSeek web UI, so it needs no GPU and cannot disturb another install's model.
function Start-RsiFront {
  $rsiRoot = Join-Path $Ws 'rsi'
  $launcher = Join-Path $rsiRoot 'start-front.ps1'
  if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Log 'RSI: rsi\start-front.ps1 not found; the Memory panel will have no data' 'WARN'
    return
  }
  if (Get-NetTCPConnection -LocalPort 18803 -State Listen -ErrorAction SilentlyContinue) {
    Write-Log 'RSI: panel API already listening on 18803'
    return
  }
  New-Dir (Join-Path $rsiRoot 'records')
  # Get-Command can answer with several matches (and under Set-StrictMode a bare
  # `.Source` on that array throws), so take the first real application.
  $psHost = $null
  foreach ($name in @('pwsh', 'powershell.exe')) {
    if ($psHost) { break }
    $cmd = @(Get-Command $name -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($cmd -and $cmd.Source) { $psHost = $cmd.Source }
  }
  if (-not $psHost) {
    Write-Log 'RSI: no PowerShell host found; the Memory panel will have no data' 'WARN'
    return
  }
  # Start-Process joins ArgumentList with spaces and does NOT quote elements, so
  # the script path (this root contains a space) must be quoted here or the child
  # sees `-File D:\KEEP` and dies with "does not have a '.ps1' extension".
  Start-Process -FilePath $psHost -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$launcher`"") `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $rsiRoot 'records\rsi-front.stdout.log') `
    -RedirectStandardError  (Join-Path $rsiRoot 'records\rsi-front.stderr.log') | Out-Null
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-NetTCPConnection -LocalPort 18803 -State Listen -ErrorAction SilentlyContinue) {
      Write-Log 'RSI: panel API listening on 18803 (front-only; CUDA model left to the S: install)'
      return
    }
  }
  Write-Log 'RSI: panel API did not come up; see rsi\records\rsi-front.stderr.log' 'WARN'
}

function Invoke-Launch {
  # Ensure the Memory panel's API first, whatever state the shell is in. A shell
  # that is already running still needs a front (the panel would otherwise sit
  # there empty until the next full relaunch), and this call is a no-op when
  # 18803 is already served.
  Start-RsiFront
  if (Get-AppProc) { Write-Log 'LAUNCH: the shell is already running; nothing to do'; return }
  $live = @(Get-HarnessProc)
  if ($live.Count -gt 0) {
    Write-Log "LAUNCH: $($live.Count) harness process(es) still running (pid $($live.ProcessId -join ',')). Quit the app fully from the tray, then launch again." 'WARN'
    return
  }

  # 1) 先把打过补丁的 shell 就位；原版会备份进 .legacy（REVERT.md 里有一行还原）。
  [void](Install-PatchedBinary)
  $patched = Test-PatchedBinary $Exe

  # 2) 根目录变量先设好，迁移才知道目标。
  Set-EcoEnv

  # 3) 一次性迁移遗留的 C: 状态——只在补丁已就位时做，否则迁了也没人读。
  $st = Get-State
  if ($patched -and $st.migrated -ne $true) { Invoke-Migrate }

  # 4) 启动。原版 shell 忽略 DSH_APP_DATA，此时**不能**只设一半环境：用普通
  #    环境启动，让它的状态保持在一处，而不是劈成两半。
  if ($patched) {
    Set-EcoEnv
    Write-Log "LAUNCH: starting the patched shell with DSH_APP_DATA=$env:DSH_APP_DATA"
  } else {
    Reset-EcoEnv
    Write-Log 'LAUNCH: the STOCK shell is installed and ignores DSH_APP_DATA; starting with the normal environment' 'WARN'
  }
  Start-Process -FilePath $Exe -WorkingDirectory $Root | Out-Null

  $st = Get-State
  $st | Add-Member -NotePropertyName lastLaunch -NotePropertyValue (Get-Date -Format o) -Force

  if (-not $patched) {
    $st | Add-Member -NotePropertyName launchContained -NotePropertyValue $false -Force
    Save-State $st
    Write-Log 'LAUNCH: containment inactive (stock shell). See REVERT.md if that is unexpected.'
    return
  }

  # 5) 启动后自检：根目录应长出 .store.dat / dependencies。
  #
  # The old check ALSO required `%APPDATA%\<id>` to be absent, which is wrong in
  # two ways. It fired after migration - the tool moves state out of C: into the
  # root but deliberately leaves the (now empty) directory behind, so the check
  # reported "NOT confirmed" for a perfectly contained app on every single
  # launch from 2026-09-17 onward. And "the directory exists" is the wrong
  # question anyway: what matters is whether the LIVE app is still writing
  # there. Ask that instead, by comparing the newest mtime on C: against the
  # moment we launched. A stale tree can never make this fail; a stock shell
  # writing into C: always will.
  Write-Log 'LAUNCH: post-launch containment check (up to 60s)'
  $launchAt = Get-Date
  $deadline = $launchAt.AddSeconds(60)
  $okBase = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $okBase = (Test-Path -LiteralPath (Join-Path $AppDataR '.store.dat')) -or
              (Test-Path -LiteralPath (Join-Path $AppDataR 'dependencies'))
    if ($okBase) { break }
  }
  $cTouched = $false
  $cLive = @()
  foreach ($p in @((Join-Path $RealRoaming $AppId), (Join-Path $RealLocal $AppId))) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $newest = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest -and $newest.LastWriteTime -gt $launchAt) { $cTouched = $true; $cLive += $newest.FullName }
  }
  # One writer cannot be redirected: the WebView2 loader creates a zero-byte
  # `<LOCALAPPDATA>\<id>\.cookies` marker through the Win32 known-folder API,
  # which ignores LOCALAPPDATA (measured 2026-09-22: it appears even when the
  # launch environment points LOCALAPPDATA inside the root). It carries no
  # state - deleting it while the app runs is inert - so it is swept rather than
  # reported. Only when that directory holds nothing else: anything more would
  # mean real app state is escaping, and that must stay loud.
  $sweptMarker = $false
  $localId = Join-Path $RealLocal $AppId
  if (Test-Path -LiteralPath $localId) {
    $left = @(Get-ChildItem -LiteralPath $localId -Recurse -Force -ErrorAction SilentlyContinue)
    $onlyMarker = ($left.Count -le 1) -and
                  (@($left | Where-Object { $_.Name -ne '.cookies' -or $_.Length -ne 0 }).Count -eq 0)
    if ($onlyMarker) {
      Remove-Item -LiteralPath $localId -Recurse -Force -ErrorAction SilentlyContinue
      $sweptMarker = -not (Test-Path -LiteralPath $localId)
      if ($sweptMarker) {
        $cTouched = $false; $cLive = @()
        Write-Log 'LAUNCH: swept the inert WebView2 `.cookies` marker from C: (known-folder API, not redirectable)'
      }
    }
  }
  $contained = $okBase -and -not $cTouched
  $st | Add-Member -NotePropertyName launchContained -NotePropertyValue $contained -Force
  Save-State $st
  if ($contained) { Write-Log 'LAUNCH: containment CONFIRMED (root populated, nothing written to C:)' }
  else { Write-Log "LAUNCH: containment NOT confirmed (baseInRoot=$okBase cWrittenTo=$cTouched $(if ($cLive) { 'files: ' + (($cLive | Select-Object -First 3) -join ', ') }))" 'WARN' }
}

function Add-ZipFile {
  # Stream a file into the archive reading through other processes' locks.
  #
  # CreateEntryFromFile opens with FileShare.Read, which fails with a sharing
  # violation whenever the file's owner holds it open for writing - the live
  # memory store did exactly that. FileShare.ReadWrite is the correct request
  # for a backup.
  param($Zip, [string]$SourcePath, [string]$EntryName, [System.Collections.Generic.List[string]]$Skipped, $Stamp)
  $fs = $null; $es = $null
  try {
    $fs = New-Object System.IO.FileStream($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $entry = $Zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    if ($Stamp) { try { $entry.LastWriteTime = $Stamp } catch {} }
    $es = $entry.Open()
    $fs.CopyTo($es)
    return $true
  } catch {
    $Skipped.Add("$EntryName :: $($_.Exception.Message)") | Out-Null
    return $false
  } finally {
    if ($es) { try { $es.Dispose() } catch {} }
    if ($fs) { try { $fs.Dispose() } catch {} }
  }
}
function Add-ZipText {
  param($Zip, [string]$EntryName, [string]$Text)
  $entry = $Zip.CreateEntry($EntryName)
  $w = New-Object System.IO.StreamWriter($entry.Open())
  $w.Write($Text); $w.Dispose()
}

# ================================================================ BACKUP ====
function Invoke-Backup {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  New-Dir $Backups
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $out   = Join-Path $Backups "dsh-ecosystem-$stamp.zip"
  Write-Log "BACKUP: writing $out"

  # State is kept; re-derivable bulk is excluded by default. Every exclusion is
  # recorded in BACKUP-MANIFEST.json so a restore is never silently incomplete.
  $excl = @(
    @{ p = $Backups; why = 'backup output' }
    @{ p = $ProbeDir; why = 'probe scratch' }
  )
  if (-not $IncludeLegacy) { $excl += @{ p = $Legacy;  why = 'archive of already-removed state - revert material, not backup material' } }
  if (-not $IncludeCaches) {
    $excl += @{ p = $Caches;                          why = 'package caches, re-derivable' }
    $excl += @{ p = (Join-Path $Ws 'memory\.cache');  why = 'model/download cache, re-derivable' }
    $excl += @{ p = (Join-Path $Ws 'memory\models');  why = 'embedding model weights, re-downloadable' }
  }
  if (-not $IncludeWsl)   { $excl += @{ p = $WslDir;  why = '11 GB WSL vhdx' } }
  if (-not $IncludeGraph) { $excl += @{ p = (Join-Path $Ws 'memory\neo4j'); why = 'derived entity graph - rebuild with memory graph-sync' } }
  # WebView2 的 profile 有上万个小文件，运行时还被独占锁定；里面绝大多数是可再生的
  # 浏览器缓存。不排除它会把备份从几十秒拖到十几分钟，而它并不承载「系统状态」。
  $excl += @{ p = (Join-Path $AppDataR 'webview'); why = 'WebView2 profile: mostly regenerable browser cache, and locked while the app runs' }
  # 构建产物不是「系统状态」：Rust 的 target/ 有数 GB，克隆里的 node_modules 可由
  # pnpm 重装，二者的历史又已经由 .git 与 GitHub 保存。不排除它们，备份会从
  # 一百多 MB 涨到 2.4 GB、耗时十几分钟。
  $excl += @{ p = (Join-Path $Ws 'src\deepseek-harness-desktop\src-tauri\target'); why = 'Rust build artifacts (regenerable)' }
  $excl += @{ p = (Join-Path $Ws 'src\deepseek-harness-desktop\node_modules'); why = 'pnpm-installed deps (regenerable)' }
  $exclPaths = @($excl | ForEach-Object { $_.p })

  # The live store is WAL-mode and open in the running harness, so archive a
  # VACUUM INTO copy instead of the raw file. -wal/-shm are folded into it.
  $dbRel  = 'DSH Kawaii creator\memory\store\memory.db'
  $dbLive = Join-Path $Root $dbRel
  $dbSnap = $null
  $snapScript = Join-Path $Ws 'memory\snapshot-db.mjs'
  if ((Test-Path -LiteralPath $dbLive) -and (Test-Path -LiteralPath $snapScript)) {
    $dbSnap = Join-Path $env:TEMP "dsh-memory-snapshot-$stamp.db"
    if (Test-Path -LiteralPath $dbSnap) { Remove-Item -LiteralPath $dbSnap -Force }
    $r = (& node $snapScript $dbSnap 2>&1 | Out-String).Trim()
    Write-Log "BACKUP: memory store snapshot: $r"
    if (-not (Test-Path -LiteralPath $dbSnap)) { Write-Log 'BACKUP: snapshot failed; falling back to reading the live file' 'WARN'; $dbSnap = $null }
  }

  $files = Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
    $f = $_.FullName
    -not ($exclPaths | Where-Object { $f.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
  }
  $total = ($files | Measure-Object -Property Length -Sum).Sum
  Write-Log ("BACKUP: {0} files, {1:N2} MB" -f $files.Count, ($total / 1MB))

  # State the OS forces outside the root. The app's base data dir comes from the
  # known-folder API and ignores environment redirection, so while containment is
  # inactive it lives on C:. Capture it anyway: one command must still back up
  # everything, or the archive is silently missing the app's actual settings.
  $external = @()
  if ((Get-State).migrated -ne $true) {
    $external += @{ p = (Join-Path $RealRoaming $AppId); as = "_external\Roaming\$AppId"; why = 'app base data dir: .store.dat, dependencies (harness runtime), updates. Known-folder API, not redirectable by environment.' }
    $external += @{ p = (Join-Path $RealLocal   $AppId); as = "_external\Local\$AppId";   why = 'WebView2 profile behind the same known-folder path.' }
    if ($IncludeCaches) {
      foreach ($n in @('npm', 'npm-cache')) { $external += @{ p = (Join-Path $RealRoaming $n); as = "_external\Roaming\$n"; why = 'cache' } }
      foreach ($n in @('pnpm', 'pnpm-cache', 'pnpm-state', 'deepseek-harness', 'npm-cache')) { $external += @{ p = (Join-Path $RealLocal $n); as = "_external\Local\$n"; why = 'cache' } }
    }
  }
  $extBytes = 0
  foreach ($x in $external) {
    if (Test-Path -LiteralPath $x.p) {
      $m = Get-ChildItem -LiteralPath $x.p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
      $x.files = $m.Count; $x.bytes = $m.Sum; $extBytes += $m.Sum
    } else { $x.files = 0; $x.bytes = 0 }
  }
  if ($external.Count -gt 0) { Write-Log ("BACKUP: plus {0:N2} MB of external state from outside the root" -f ($extBytes / 1MB)) }

  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
  $skipped = New-Object System.Collections.Generic.List[string]
  $zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
  try {
    $i = 0; $done = 0
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
      $src = $f.FullName
      if ($dbSnap -and $rel -ieq $dbRel) { $src = $dbSnap }
      elseif ($dbSnap -and $rel -imatch 'memory\\store\\memory\.db-(wal|shm)$') { $i++; continue }
      if (Add-ZipFile -Zip $zip -SourcePath $src -EntryName $rel -Skipped $skipped -Stamp $f.LastWriteTime) { $done++ }
      $i++
      if ($i % 4000 -eq 0) { Write-Log "BACKUP: $i / $($files.Count)" }
    }
    # WebView2 caches and leveldb lock files are (a) regenerable and (b) held
    # open with exclusive access while the app runs. Excluding them by name makes
    # the manifest report real state, not a pile of expected lock failures.
    $cacheRx = '(?i)(\\Cache_Data\\|\\GPUCache\\|\\ShaderCache\\|\\GrShaderCache\\|\\DawnGraphiteCache\\|\\DawnWebGPUCache\\|\\Code Cache\\|\\Cache\\)|\\(LOCK|lockfile)$'
    $extCount = 0; $cacheSkipped = 0
    foreach ($x in $external) {
      if (-not (Test-Path -LiteralPath $x.p)) { continue }
      foreach ($f in (Get-ChildItem -LiteralPath $x.p -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        if ($f.FullName -match $cacheRx) { $cacheSkipped++; continue }
        $rel2 = $f.FullName.Substring($x.p.Length).TrimStart('\')
        if (Add-ZipFile -Zip $zip -SourcePath $f.FullName -EntryName (Join-Path $x.as $rel2) -Skipped $skipped -Stamp $f.LastWriteTime) { $done++; $extCount++ }
        $i++
      }
      if ($i % 4000 -eq 0) { Write-Log "BACKUP: $i / $($files.Count)" }
    }
    if ($extCount -gt 0) { Write-Log "BACKUP: archived $extCount external files; $cacheSkipped ephemeral cache/lock files excluded by design" }

    $manifest = [ordered]@{
      createdAt   = (Get-Date -Format o)
      root        = $Root
      computer    = $env:COMPUTERNAME
      user        = $env:USERNAME
      fileCount   = $files.Count
      archived    = $done
      skipped     = @($skipped)
      bytes       = $total
      externalBytes = $extBytes
      includedWsl = [bool]$IncludeWsl
      includedCaches = [bool]$IncludeCaches
      includedGraph = [bool]$IncludeGraph
      includedLegacy = [bool]$IncludeLegacy
      memorySnapshot = $(if ($dbSnap) { 'VACUUM INTO copy of the WAL-mode store; consistent as of this backup' } else { 'live file (snapshot unavailable)' })
      external    = @($external | ForEach-Object { [ordered]@{ path = $_.p; archivedAs = $_.as; why = $_.why; files = $_.files; bytes = $_.bytes } })
      ephemeralExcluded = $cacheSkipped
      appWasRunning = [bool](Get-AppProc)
      excluded    = @($excl | ForEach-Object { [ordered]@{ path = $_.p.Replace($Root, '.'); why = $_.why } })
      stateInside = @(
        'DSH Kawaii creator\.dsh                    DSH home: profiles, sessions, storages, credentials, settings'
        'DSH Kawaii creator\memory\store             memory records + vectors (the actual memory state)'
        'DSH Kawaii creator\memory\plugin            the dsh-memory Cordis plugin'
        '.appdata, .appdata-local                    redirected %APPDATA% / %LOCALAPPDATA% (shell runtime + store)'
        '_external\...                               app state the OS keeps outside the root (restore by hand)'
        'resources, deepseek-harness-desktop.exe     the shell itself'
      )
      restore     = 'Extract to the same absolute path, then run dsh-ecosystem.ps1 -Action Verify'
    }
    Add-ZipText -Zip $zip -EntryName 'BACKUP-MANIFEST.json' -Text ($manifest | ConvertTo-Json -Depth 6)
  } catch {
    $zip.Dispose()
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    Write-Log "BACKUP: FAILED, partial archive removed: $_" 'ERROR'
    return
  } finally { $zip.Dispose() }
  if ($dbSnap) { Remove-Item -LiteralPath $dbSnap -Force -ErrorAction SilentlyContinue }

  $size = (Get-Item -LiteralPath $out).Length
  Write-Log ("BACKUP: complete -> {0} ({1:N2} MB)" -f $out, ($size / 1MB))
  if ($skipped.Count -gt 0) {
    Write-Log "$($skipped.Count) file(s) could not be read because the app was running; they are listed in BACKUP-MANIFEST.json. Quit the app and re-run for a fully consistent archive." 'WARN'
  }

  # rotation. @() matters: with one zip, StrictMode has no .Count on a FileInfo.
  $old = @(Get-ChildItem -LiteralPath $Backups -Filter 'dsh-ecosystem-*.zip' -File | Sort-Object LastWriteTime -Descending)
  if ($old.Count -gt $Keep) {
    $old | Select-Object -Skip $Keep | ForEach-Object { Write-Log "BACKUP: pruning $($_.Name)"; Remove-Item -LiteralPath $_.FullName -Force }
  }
  $st = Get-State
  $st | Add-Member -NotePropertyName lastBackup -NotePropertyValue $out -Force
  Save-State $st
  Write-Host ''
  Write-Host "Backup written: $out" -ForegroundColor Green
}

# ================================================================ VERIFY ====
function Invoke-Verify {
  $script:VerifyFail = 0
  function Check($name, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS  {0,-42} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("  FAIL  {0,-42} {1}" -f $name, $detail) -ForegroundColor Red; $script:VerifyFail++ }
  }
  Write-Host ''
  Write-Host "VERIFY  $Root" -ForegroundColor Cyan
  Write-Host ('-' * 78)

  $patched = Test-PatchedBinary $Exe
  $envRoot = [Environment]::GetEnvironmentVariable('DSH_APP_DATA', 'User')
  $rootFilled = (Test-Path -LiteralPath (Join-Path $AppDataR '.store.dat')) -or
                (Test-Path -LiteralPath (Join-Path $AppDataR 'dependencies'))

  Check 'patched shell installed'   $patched $(if ($patched) { 'DSH_APP_DATA override present' } else { 'STOCK build - ignores DSH_APP_DATA' })
  Check 'DSH home inside root'      (Test-Path -LiteralPath $DshHome) $DshHome
  Check 'DSH_APP_DATA set (user)'   ($envRoot -eq $AppDataR) $(if ($envRoot) { $envRoot } else { '(unset - the shell uses C: however it is started)' })
  Check 'app root populated'        $rootFilled $AppDataR
  Check 'CLI shims inside root'     ((Test-Path -LiteralPath (Join-Path $AppDataR 'bin')) -or
                                     -not (Test-Path -LiteralPath (Join-Path $RealLocal 'deepseek-harness'))) (Join-Path $AppDataR 'bin')

  # 这个应用不该在 C: 上留任何东西。
  #
  # Distinguish LIVE from LEFTOVER. A non-empty C: tree is stale state that the
  # migration left behind and that `-Action Clean` reclaims; it says nothing
  # about whether containment currently holds. Only a C: file written AFTER the
  # last launch proves the running shell is escaping the root. Reporting both
  # as one failure is what made this check cry wolf on every launch from
  # 2026-09-17 until 2026-09-22.
  $res = @()
  foreach ($p in @(
      (Join-Path $RealRoaming $AppId),
      (Join-Path $RealLocal   $AppId),
      (Join-Path $RealLocal   'deepseek-harness'),
      (Join-Path $RealLocal   'pnpm'),
      (Join-Path $RealLocal   'pnpm-cache'),
      (Join-Path $RealLocal   'pnpm-state'),
      (Join-Path $RealRoaming 'npm'))) {
    if (Test-Path -LiteralPath $p) { $res += $p }
  }
  $lastLaunchAt = $null
  try { $ll = (Get-State).lastLaunch; if ($ll) { $lastLaunchAt = [datetime]::Parse($ll) } } catch {}
  # The WebView2 `.cookies` marker is the one thing the app cannot be stopped
  # from writing to C: (known-folder API, see Invoke-Launch). It is inert and
  # swept at launch; do not count it as escaping state.
  $localId   = Join-Path $RealLocal $AppId
  $markerOnly = $false
  if (Test-Path -LiteralPath $localId) {
    $left = @(Get-ChildItem -LiteralPath $localId -Recurse -Force -ErrorAction SilentlyContinue)
    $markerOnly = ($left.Count -le 1) -and
                  (@($left | Where-Object { $_.Name -ne '.cookies' -or $_.Length -ne 0 }).Count -eq 0)
  }
  $live = @()
  foreach ($p in $res) {
    if ($markerOnly -and $p -ieq $localId) { continue }
    if (-not $lastLaunchAt) { continue }
    $newest = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest -and $newest.LastWriteTime -gt $lastLaunchAt) { $live += $p }
  }
  Check 'nothing written to C: since launch' ($live.Count -eq 0) `
        $(if ($live.Count) { "LIVE: " + ($live -join '; ') } else { 'the running shell stays inside the root' })
  $residue = @($res | Where-Object { -not ($markerOnly -and $_ -ieq $localId) })
  Check 'no C: residue (leftover)'  ($residue.Count -eq 0) `
        $(if ($residue.Count) { "$($residue.Count) stale path(s) - reclaim with -Action Clean" } elseif ($markerOnly) { "nothing but the inert WebView2 .cookies marker" } else { 'nothing outside the root' })

  # 守卫才是「不会再回来」的持久保证，所以纳入验证。
  $guard = Join-Path $Ws 'src\deepseek-harness-desktop\scripts\check-path-authority.mjs'
  if (Test-Path -LiteralPath $guard) {
    & node $guard *> $null
    Check 'path-authority guard passes' ($LASTEXITCODE -eq 0) 'scripts/check-path-authority.mjs'
  }

  # Reparse points must resolve inside the root, or the folder is not portable.
  #
  # Targets must be RESOLVED against the link's own directory before testing:
  # most entries here are junctions, whose Target is already absolute, but the
  # plain symlinks pnpm creates inside `.pnpm` are RELATIVE (`..\..\rolldown@...`).
  # Comparing a relative target to the root as a string reports every one of them
  # as "outside" - a false alarm that makes the check useless. Only -Depth 1 was
  # scanned before, for the same reason: the relative ones live deeper.
  function Get-LinksOutsideRoot {
    param([string]$Base)
    if (-not (Test-Path -LiteralPath $Base)) { return $null }
    $links = @(Get-ChildItem -LiteralPath $Base -Force -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    $out = @()
    foreach ($l in $links) {
      $t = ($l.Target -join ',') -replace '^\\\\\?\\', ''
      if (-not $t) { continue }
      $full = try {
        if ([IO.Path]::IsPathRooted($t)) { [IO.Path]::GetFullPath($t) }
        elseif ($l.PSIsContainer)        { [IO.Path]::GetFullPath((Join-Path $l.FullName $t)) }
        else                             { [IO.Path]::GetFullPath((Join-Path $l.DirectoryName $t)) }
      } catch { $t }
      if (-not $full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $out += $l.FullName }
    }
    [pscustomobject]@{ Total = $links.Count; Outside = @($out).Count; First = @($out) }
  }
  $lk = Get-LinksOutsideRoot -Base $DshHome
  if ($lk) {
    Check 'DSH home links resolve in root' ($lk.Outside -eq 0) "$($lk.Total) links checked, $($lk.Outside) outside"
    if ($lk.Outside -gt 0) { Write-Host ("         first outside: " + (($lk.First | Select-Object -First 3) -join ' | ')) -ForegroundColor DarkGray }
    # A stale link is recoverable without reinstalling anything.
    if ($lk.Outside -gt 0) { Write-Host '         repair: DSH Kawaii creator\scripts\repair-profile-links.ps1' -ForegroundColor DarkGray }
  } else { Check 'DSH home links resolve in root' $false 'DSH home not found' }

  # Memory store reachable and healthy
  $db = Join-Path $Ws 'memory\store\memory.db'
  Check 'memory store present'     (Test-Path -LiteralPath $db) $db
  $cli = Join-Path $Ws 'memory\cli.mjs'
  if ((Test-Path -LiteralPath $db) -and (Test-Path -LiteralPath $cli)) {
    try {
      # `node` prints an ExperimentalWarning for node:sqlite on stderr. With
      # ErrorActionPreference=Stop that native stderr becomes a TERMINATING
      # error, so a healthy store reported as unreadable. Drop to Continue for
      # the call and judge it by its exit code, which is the real signal.
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $r = (& node $cli stats 2>&1 | Out-String)
      $code = $LASTEXITCODE
      $ErrorActionPreference = $prev
      $flat = ($r.Trim() -replace '\s+', ' ')
      Check 'memory store readable' ($code -eq 0) $flat.Substring(0, [Math]::Min(90, $flat.Length))
    } catch { Check 'memory store readable' $false "$_" }
  }

  # Credentials not world readable
  if (Test-Path -LiteralPath (Join-Path $DshHome '.credentials.yaml')) {
    $acl = Get-Acl -LiteralPath (Join-Path $DshHome '.credentials.yaml')
    $wide = @($acl.Access | Where-Object { $_.IdentityReference -match 'BUILTIN\\Users|Authenticated Users|Everyone' })
    Check 'credentials owner-only' ($wide.Count -eq 0) "$($wide.Count) broad ACEs"
  }

  Write-Host ('-' * 78)
  if ($script:VerifyFail -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green }
  else { Write-Host "$($script:VerifyFail) CHECK(S) FAILED" -ForegroundColor Red }
  Write-Host ''
}

# ================================================================== MAIN ====
switch ($Action) {
  'Status'  { Show-Status }
  'Probe'   { Set-EcoEnv; $v = Invoke-Probe; Write-Host "probe verdict: $v" }
  'Clean'   { Set-EcoEnv; Invoke-Clean }
  'Migrate' { Set-EcoEnv; Invoke-Migrate }
  'Launch'  { Invoke-Launch }
  'Backup'  { Set-EcoEnv; Invoke-Backup }
  'Verify'  { Set-EcoEnv; Invoke-Verify }
  'Accept'  { & (Join-Path $Ws 'scripts\verify-containment.ps1') }
  'Secure'  { Set-EcoEnv; Invoke-Secure }
  'Log'     { Show-Log }
  'Revert'  { Invoke-Revert -Steps $Steps -All:$All }
  'Install' { Set-EcoEnv; [void](Install-PatchedBinary) }
}
