<#
.SYNOPSIS
  Builds the Vortex-ready release zip: dist/WebSlinger-<version>.zip (C2WS-T16).

.DESCRIPTION
  The zip is rooted at the game folder, in the layout the Vortex Cyberpunk 2077 extension
  (Nexus-Mods/game-cyberpunk2077) recognises as a canonical CET mod: init.lua directly inside
  bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger. "Install from file" (or dragging the zip
  into Vortex) deploys it with no manual-install/fallback prompt, and a manual install is
  "extract into the game folder".

  Only the mod's own tracked .lua files go in: no docs, no dev files, and no runtime state (CET's
  db.sqlite3, logs), because the file list comes from git, not the folder on disk (a new file must
  be git-added before a build). Entry names use forward slashes (PowerShell 5.1's Compress-Archive
  writes backslashes, which some extractors and Vortex's archive reader don't treat as folders).

.PARAMETER Version
  Overrides the version read from init.lua (WebSlinger.version).
#>
[CmdletBinding()]
param(
  [string]$Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$modRel = 'bin/x64/plugins/cyber_engine_tweaks/mods/WebSlinger'
$initPath = Join-Path $repo ($modRel + '/init.lua')

if (-not $Version) {
  $match = Select-String -Path $initPath -Pattern '^\s*version\s*=\s*"([^"]+)"' | Select-Object -First 1
  if (-not $match) { throw "No version = ""x.y.z"" found in $initPath" }
  $Version = $match.Matches[0].Groups[1].Value
}
if ($Version -notmatch '^[0-9A-Za-z.\-]+$') { throw "Unusable version '$Version'" }

# Tracked files under the mod folder only, then an allow-list of what it needs at run time.
$allowedIn = @{ $modRel = '.lua' }
$tracked = & git -C $repo ls-files -- $modRel
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
function Test-Allowed([string]$name) {
  foreach ($root in $allowedIn.Keys) {
    if ($name.StartsWith($root + '/') -and
        [IO.Path]::GetExtension($name).ToLowerInvariant() -eq $allowedIn[$root]) { return $true }
  }
  return $false
}
$files = @($tracked | Where-Object { Test-Allowed $_ } | Sort-Object)
if (-not ($files -contains ($modRel + '/init.lua'))) { throw "init.lua is not tracked under $modRel" }

$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zipPath = Join-Path $dist ("WebSlinger-$Version.zip")
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($rel in $files) {
    $source = Join-Path $repo $rel
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $rel,
      [IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
} finally {
  $zip.Dispose()
}

# Check what was written: every entry under the mod folder is a .lua, forward slashes only, and
# init.lua sits directly inside it.
$read = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $names = @($read.Entries | ForEach-Object { $_.FullName })
} finally {
  $read.Dispose()
}
$problems = @()
foreach ($name in $names) {
  if ($name.Contains('\')) { $problems += "backslash in entry: $name" }
  if (-not (Test-Allowed $name)) { $problems += "not a $modRel/*.lua entry: $name" }
}
if (-not ($names -contains ($modRel + '/init.lua'))) { $problems += 'init.lua missing from the mod folder' }
if ($problems.Count -gt 0) {
  Remove-Item -LiteralPath $zipPath -Force
  throw ("Release zip failed its layout check:`n  " + ($problems -join "`n  "))
}

Write-Host "Built $zipPath ($($names.Count) files):"
$names | ForEach-Object { Write-Host "  $_" }
