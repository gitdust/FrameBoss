<#
.SYNOPSIS
    Build a CurseForge-ready release zip for FrameBoss (Windows port of
    scripts/package.sh — no Git Bash, WSL, or external zip.exe required).

.DESCRIPTION
    CurseForge (manual upload at curseforge.com) requires the zip to contain
    a top-level folder named exactly like the addon, e.g.:

      FrameBoss/
      +-- FrameBoss.toc
      +-- Core.lua
      +-- Auras.lua
      +-- Options.lua
      +-- Locales/
      +-- Libs/
      +-- Media/

    The version is the ## Version: line in FrameBoss.toc (the single source
    of truth — CurseForge and the in-game addon list both read it) and the
    output is written to dist/FrameBoss-<version>.zip. Dev-only files (.git,
    docs, scripts, .superpowers, .DS_Store, ...) are never copied — the
    payload is an explicit allowlist matching the TOC file list.

    Works on Windows PowerShell 5.1 and PowerShell 7+. Zipping uses the .NET
    System.IO.Compression API directly, with entries created manually so the
    names always use '/' separators. Both Compress-Archive AND
    ZipFile.CreateFromDirectory on .NET Framework (Windows PowerShell 5.1)
    write backslashes into entry names, which breaks extraction on
    macOS/Linux; the manual loop is portable across both runtimes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\package.ps1
    Build with the version currently in the TOC.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\package.ps1 1.0.1
    Bump ## Version: to 1.0.1 in the TOC, then build.
#>

[CmdletBinding()]
param(
    # Optional: bump the TOC's ## Version: before packaging so the zip
    # filename, the TOC, and the in-game version can never drift apart.
    [Parameter(Position = 0)]
    [string]$VersionArg
)

$ErrorActionPreference = 'Stop'
# StrictMode makes typos and missing properties fatal, like bash's set -u.
Set-StrictMode -Version 2.0

# --- paths ------------------------------------------------------------------

$Root = Split-Path -Parent $PSScriptRoot

$AddonName = 'FrameBoss'
$TocPath = Join-Path $Root "$AddonName.toc"
$DistDir = Join-Path $Root 'dist'

# UTF-8 *without* BOM — the TOC must keep its original encoding so the WoW
# client reads it identically (PS 5.1's Set-Content would default to ANSI).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- version ----------------------------------------------------------------

$tocText = [System.IO.File]::ReadAllText($TocPath)

if (-not [string]::IsNullOrEmpty($VersionArg)) {
    # Accept 1.2.3 plus an optional -beta / -rc.1 style suffix; reject
    # anything unsafe in a filename or empty.
    if ($VersionArg -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$') {
        throw "invalid version '$VersionArg' (expected e.g. 1.0.1 or 1.0.1-rc.1)"
    }

    # Replace only the FIRST ## Version: line (count = 1). The character
    # class deliberately excludes \r: .NET's "." matches \r, so a naive
    # ".*$" would swallow the CRLF's carriage return and silently convert
    # that one line to LF.
    $versionPattern = '(?m)^## Version:[^\r\n]*'
    if (-not [regex]::IsMatch($tocText, $versionPattern)) {
        throw "no ## Version: line found in $AddonName.toc"
    }
    $tocText = [regex]::Replace($tocText, $versionPattern, "## Version: $VersionArg", 1)
    [System.IO.File]::WriteAllText($TocPath, $tocText, $Utf8NoBom)
    Write-Host "Bumped ## Version: -> $VersionArg in $AddonName.toc"
}

# [^\r\n] keeps the trailing CR/LF out of the capture; \r? is needed because
# in multiline mode $ matches before \n, but a CRLF checkout leaves the \r
# sitting between the value and that position.
$match = [regex]::Match($tocText, '(?m)^## Version:[ \t]*([^\r\n]+?)[ \t]*\r?$')
if (-not $match.Success) {
    throw "could not read ## Version: from $AddonName.toc"
}
$Version = $match.Groups[1].Value

$OutZip = Join-Path $DistDir "$AddonName-$Version.zip"

# --- files shipped in the zip (allowlist, must match the TOC load list) -----

$PayloadFiles = @(
    "$AddonName.toc"
    'Core.lua'
    'Auras.lua'
    'Options.lua'
)
$PayloadDirs = @(
    'Locales'
    'Libs'
    'Media'
)

# --- sanity checks ----------------------------------------------------------

foreach ($item in ($PayloadFiles + $PayloadDirs)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $item))) {
        throw "expected payload path missing: $item"
    }
}

# --- staging ----------------------------------------------------------------

# Equivalent of mktemp -d + EXIT-trap cleanup.
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("FrameBoss-pkg-" + [Guid]::NewGuid().ToString('N'))
$Target = Join-Path $Stage $AddonName

try {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    foreach ($f in $PayloadFiles) {
        Copy-Item -LiteralPath (Join-Path $Root $f) -Destination $Target
    }
    foreach ($d in $PayloadDirs) {
        Copy-Item -Recurse -LiteralPath (Join-Path $Root $d) -Destination $Target
    }

    # Strip OS / editor junk from the staged copy (macOS leftovers plus the
    # Windows equivalents).
    $junkNames = @('.DS_Store', '*.swp', 'Thumbs.db', 'desktop.ini')
    Get-ChildItem -LiteralPath $Stage -Recurse -Force -File |
        Where-Object {
            $n = $_.Name
            $junkNames | Where-Object { $n -like $_ }
        } |
        Remove-Item -Force
    Get-ChildItem -LiteralPath $Stage -Recurse -Force -Directory |
        Where-Object { $_.Name -eq '__MACOSX' } |
        Remove-Item -Recurse -Force

    # --- zip ----------------------------------------------------------------

    # FileSystem provides ZipFile (used for the listing below); the plain
    # Compression assembly provides ZipArchive/ZipArchiveMode used to build
    # the archive. Windows PowerShell 5.1 loads neither by default.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path -LiteralPath $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $OutZip) {
        Remove-Item -LiteralPath $OutZip -Force
    }

    # Create entries one by one with explicit '/' separators. On .NET
    # Framework (Windows PowerShell 5.1), both Compress-Archive and
    # ZipFile.CreateFromDirectory emit '\' in entry names; building entries
    # manually from the staged tree guarantees "FrameBoss/..." paths that
    # extract identically on Windows, macOS, and Linux.
    $fileStream = [System.IO.File]::Open($OutZip, [System.IO.FileMode]::Create)
    $archive = New-Object System.IO.Compression.ZipArchive(
        $fileStream,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    try {
        $stagePrefix = $Stage.TrimEnd('\') + '\'
        Get-ChildItem -LiteralPath $Stage -Recurse -File | ForEach-Object {
            $entryName = $_.FullName.Substring($stagePrefix.Length) -replace '\\', '/'
            $entry = $archive.CreateEntry(
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
            $inStream = [System.IO.File]::OpenRead($_.FullName)
            $entryStream = $entry.Open()
            try {
                $inStream.CopyTo($entryStream)
            }
            finally {
                $inStream.Dispose()
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
        $fileStream.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
}

# --- report -----------------------------------------------------------------

Write-Host ""
Write-Host "Built: $OutZip"
Write-Host ""
Write-Host "Archive contents:"

$archive = [System.IO.Compression.ZipFile]::OpenRead($OutZip)
try {
    $rows = foreach ($entry in $archive.Entries) {
        [pscustomobject]@{
            Length           = $entry.Length
            CompressedLength = $entry.CompressedLength
            Name             = $entry.FullName
        }
    }
    $rows |
        Sort-Object Name |
        Format-Table @{ Label = 'Length'; Expression = { $_.Length }; Alignment = 'Right' },
                     @{ Label = 'Packed'; Expression = { $_.CompressedLength }; Alignment = 'Right' },
                     Name -AutoSize |
        Out-String |
        ForEach-Object { $_ -replace '(?m)^', '  ' } |
        Write-Host
}
finally {
    $archive.Dispose()
}
