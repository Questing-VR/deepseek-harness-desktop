# Give the shipped agent-preset roster English display names.
#
# Why: the shipped `presets/<id>/preset.yml` files in this build carry Chinese
# `name`/`description` values ("标准模式", "极简模式", "PTC 模式", "创造模式") and the
# picker renders them verbatim — there is no i18n layer for preset display data
# (see @deepseek-ai/dsh-agent-presets/README.md: "The picker shows each preset's
# display name and description"). On an otherwise-English UI the session-header
# preset chip therefore reads as an unexplained foreign mode.
#
# This rewrites ONLY `name:` and `description:` in each preset.yml. The
# composition next to it (agent.cordis.yml) is never touched, the original file
# is kept as preset.yml.zh-original, and re-running is a no-op once applied.
# A harness upgrade restores the shipped files; run this again afterwards.
#
# Usage:
#   pwsh -File localize-agent-presets.ps1 [-WhatIf]
param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'

$presetsRoot = Join-Path $PSScriptRoot '..\..\.appdata\dependencies\dsh\node_modules\@deepseek-ai\dsh-agent-presets\presets'
$presetsRoot = [IO.Path]::GetFullPath($presetsRoot)
if (-not (Test-Path -LiteralPath $presetsRoot)) {
  throw "agent-presets package not found at $presetsRoot"
}

# id -> @{ Name; Description }
$english = [ordered]@{
  standard = @{
    Name        = 'Standard'
    Description = 'Full coding agent: file editing, shell, file and web search, skills, planning, goals, subagents and workflows.'
  }
  ptc = @{
    Name        = 'PTC'
    Description = 'Full coding agent without the workflow tool by default; other tools are exposed through the PTC-mode SDK so the model composes multi-step work in one TypeScript program.'
  }
  minimal = @{
    Name        = 'Minimal'
    Description = 'Single-tool coding agent with only the persistent shell.'
  }
  cordis = @{
    Name        = 'Cordis (composition authoring)'
    Description = 'Everything Standard has, plus live runtime inspection, plugin experiments and preset authoring guidance.'
  }
}

# The user's own presets live under $DSH_HOME; they are not shipped and are
# listed here only so one run also normalizes them.
$userPresetsRoot = Join-Path $PSScriptRoot '..\.dsh\.agent-presets'
$userPresetsRoot = [IO.Path]::GetFullPath($userPresetsRoot)

function Set-PresetDisplay {
  param([string]$File, [string]$Name, [string]$Description)

  $text = [IO.File]::ReadAllText($File)
  $lines = $text -split "`r?`n"
  $out = New-Object System.Collections.Generic.List[string]
  $sawName = $false
  $sawDescription = $false
  $changed = $false
  foreach ($line in $lines) {
    if ($line -match '^name:\s*(.*)$') {
      $sawName = $true
      $want = "name: $Name"
      if ($line -ne $want) { $changed = $true }
      $out.Add($want)
      continue
    }
    if ($line -match '^description:\s*(.*)$') {
      $sawDescription = $true
      $want = "description: $Description"
      if ($line -ne $want) { $changed = $true }
      $out.Add($want)
      continue
    }
    $out.Add($line)
  }
  if (-not $sawName) { $out.Insert(0, "name: $Name"); $changed = $true }
  if (-not $sawDescription) { $out.Insert(1, "description: $Description"); $changed = $true }

  if (-not $changed) {
    Write-Host "  already English: $File"
    return
  }

  $backup = "$File.zh-original"
  if (-not (Test-Path -LiteralPath $backup)) {
    if (-not $WhatIf) { Copy-Item -LiteralPath $File -Destination $backup }
    Write-Host "  backup: $backup"
  }

  $body = ($out -join "`n").TrimEnd("`n") + "`n"
  if ($WhatIf) {
    Write-Host "  WOULD REWRITE: $File"
    Write-Host "    name: $Name"
  } else {
    [IO.File]::WriteAllText($File, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  rewrote: $File -> $Name"
  }
}

Write-Host "shipped presets: $presetsRoot"
foreach ($id in $english.Keys) {
  $file = Join-Path $presetsRoot "$id\preset.yml"
  if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "  missing (skipped): $file"
    continue
  }
  Set-PresetDisplay -File $file -Name $english[$id].Name -Description $english[$id].Description
}

if (Test-Path -LiteralPath $userPresetsRoot) {
  Write-Host "user presets: $userPresetsRoot"
  $nocompact = Join-Path $userPresetsRoot 'nocompact\preset.yml'
  if (Test-Path -LiteralPath $nocompact) {
    Set-PresetDisplay -File $nocompact -Name 'No auto-compaction' `
      -Description 'Compaction is effectively off for a 1,000,000-token context window (thresholdRatio 0.999666 to 999,666 tokens). Identical to the shipped cordis preset otherwise.'
  }
}
