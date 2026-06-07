<#
.SYNOPSIS
    Reverses a Desktop Organizer run, putting every moved file back where it was.

.DESCRIPTION
    Reads a move log produced by Organize-Desktop.ps1 (the most recent one by
    default) and moves each file from its category folder back to its original
    Desktop location. If a file is missing or its original spot is now occupied,
    that entry is skipped and reported - the undo never overwrites anything.

    By default you get a preview and a confirmation prompt, just like organizing.

.PARAMETER LogFile
    A specific log file to undo. Defaults to the newest log in LogDirectory.

.PARAMETER LogDirectory
    Where logs live. Defaults to %LOCALAPPDATA%\DesktopOrganizer\logs.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Undo-LastOrganize.ps1
    Preview and undo the most recent run.

.EXAMPLE
    .\Undo-LastOrganize.ps1 -LogFile "$env:LOCALAPPDATA\DesktopOrganizer\logs\organize_2026-06-07_09-00-00.json"
    Undo a specific run.
#>

[CmdletBinding()]
param(
    [string] $LogFile,
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'DesktopOrganizer\logs'),
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Locate the log to undo.
if (-not $LogFile) {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        Write-Host "No log directory found at $LogDirectory - nothing to undo." -ForegroundColor Yellow
        return
    }
    $latest = Get-ChildItem -LiteralPath $LogDirectory -Filter 'organize_*.json' -File |
        Where-Object { $_.Name -notlike '*.undone.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host "No organize logs found in $LogDirectory - nothing to undo." -ForegroundColor Yellow
        return
    }
    $LogFile = $latest.FullName
}

if (-not (Test-Path -LiteralPath $LogFile)) {
    throw "Log file not found: $LogFile"
}

$log = Get-Content -LiteralPath $LogFile -Raw | ConvertFrom-Json

# Handle a log with no moves gracefully (ConvertFrom-Json gives $null for empty arrays).
$moves = @($log.Moves)
if ($moves.Count -eq 0) {
    Write-Host "Log contains no moves - nothing to undo." -ForegroundColor Green
    return
}

Write-Host ''
Write-Host "Undo Desktop Organizer" -ForegroundColor Cyan
Write-Host "  Log : $LogFile"
Write-Host "  Run : $($log.RunAtUtc) (UTC)"
Write-Host ''
Write-Host "Will attempt to restore $($moves.Count) file(s) to their original locations:" -ForegroundColor Yellow
Write-Host ''

# We undo in reverse order so numeric-suffix renames unwind cleanly.
[array]::Reverse($moves)

$skips = New-Object System.Collections.Generic.List[string]
foreach ($m in $moves) {
    $fromNow = $m.To       # where the file currently is
    $backTo  = $m.From     # where it should return to
    if (-not (Test-Path -LiteralPath $fromNow)) {
        $skips.Add("MISSING (already moved/deleted): $fromNow")
        continue
    }
    if (Test-Path -LiteralPath $backTo) {
        $skips.Add("BLOCKED (original location occupied): $backTo")
        continue
    }
    Write-Host ("  {0}  ->  {1}" -f $fromNow, $backTo)
}

if ($skips.Count -gt 0) {
    Write-Host ''
    Write-Host "These entries will be skipped:" -ForegroundColor DarkYellow
    foreach ($s in $skips) { Write-Host "  $s" -ForegroundColor DarkYellow }
}
Write-Host ''

if (-not $Force) {
    $answer = Read-Host "Proceed with undo? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Cancelled - nothing was moved." -ForegroundColor Green
        return
    }
}

$restored = 0
$skipped = 0
foreach ($m in $moves) {
    $fromNow = $m.To
    $backTo  = $m.From
    try {
        if (-not (Test-Path -LiteralPath $fromNow)) { $skipped++; continue }
        if (Test-Path -LiteralPath $backTo)         { $skipped++; continue }

        $backParent = Split-Path -Parent $backTo
        if (-not (Test-Path -LiteralPath $backParent)) {
            New-Item -ItemType Directory -Path $backParent -Force | Out-Null
        }
        Move-Item -LiteralPath $fromNow -Destination $backTo -ErrorAction Stop
        $restored++
        Write-Host ("  restored: {0}" -f [System.IO.Path]::GetFileName($backTo)) -ForegroundColor Green
    } catch {
        $skipped++
        Write-Warning ("could not restore '{0}': {1}" -f $fromNow, $_.Exception.Message)
    }
}

Write-Host ''
Write-Host ("Undo complete. Restored {0} file(s), skipped {1}." -f $restored, $skipped) -ForegroundColor Green

# Mark the log as undone so a later undo doesn't pick it up by default.
if ($restored -gt 0) {
    $undoneName = [System.IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '.undone.json'
    try {
        Rename-Item -LiteralPath $LogFile -NewName ([System.IO.Path]::GetFileName($undoneName)) -ErrorAction Stop
        Write-Host ("Log marked as undone: {0}" -f $undoneName)
    } catch {
        # Non-fatal: the restore already happened.
        Write-Verbose "Could not rename log file: $($_.Exception.Message)"
    }
}
