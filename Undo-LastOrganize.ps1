<#
.SYNOPSIS
    Reverses a Desktop Organizer run, putting every moved file back where it was.

.DESCRIPTION
    Reads a move log produced by Organize-Desktop.ps1 (the most recent one by
    default) and moves each file from its category folder back to its original
    Desktop location. If a file is missing or its original spot is now occupied,
    that entry is skipped and reported - the undo never overwrites anything.

    By default you get a preview and a confirmation prompt, just like organizing.

    The restore logic lives in DesktopOrganizer.Engine.ps1 (shared with the GUI).

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

. (Join-Path $PSScriptRoot 'DesktopOrganizer.Engine.ps1')

# Locate the log to undo.
if (-not $LogFile) {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        Write-Host "No log directory found at $LogDirectory - nothing to undo." -ForegroundColor Yellow
        return
    }
    $LogFile = Get-LatestOrganizeLog -LogDirectory $LogDirectory
    if (-not $LogFile) {
        Write-Host "No organize logs found in $LogDirectory - nothing to undo." -ForegroundColor Yellow
        return
    }
}

if (-not (Test-Path -LiteralPath $LogFile)) {
    throw "Log file not found: $LogFile"
}

# Work out what can be restored vs skipped (moves nothing yet).
$preview = Get-OrganizeUndoPlan -LogFile $LogFile
$restoreCount = $preview.Restorable.Count

if ($restoreCount -eq 0 -and $preview.Skips.Count -eq 0) {
    Write-Host "Log contains no moves - nothing to undo." -ForegroundColor Green
    return
}

Write-Host ''
Write-Host "Undo Desktop Organizer" -ForegroundColor Cyan
Write-Host "  Log : $LogFile"
Write-Host "  Run : $($preview.RunAtUtc) (UTC)"
Write-Host ''
Write-Host "Will attempt to restore $restoreCount file(s) to their original locations:" -ForegroundColor Yellow
Write-Host ''
foreach ($item in $preview.Restorable) {
    Write-Host ("  {0}  ->  {1}" -f $item.From, $item.To)
}

if ($preview.Skips.Count -gt 0) {
    Write-Host ''
    Write-Host "These entries will be skipped:" -ForegroundColor DarkYellow
    foreach ($s in $preview.Skips) { Write-Host "  $s" -ForegroundColor DarkYellow }
}
Write-Host ''

if (-not $Force) {
    $answer = Read-Host "Proceed with undo? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Cancelled - nothing was moved." -ForegroundColor Green
        return
    }
}

# Execute the restore via the shared engine.
$result = Invoke-OrganizeUndo -LogFile $LogFile

foreach ($f in $result.Failures) {
    Write-Warning ("could not restore '{0}': {1}" -f $f.From, $f.Error)
}

Write-Host ''
Write-Host ("Undo complete. Restored {0} file(s), skipped {1}." -f $result.Restored, $result.Skipped) -ForegroundColor Green
if ($result.UndoneAs) {
    Write-Host ("Log marked as undone: {0}" -f $result.UndoneAs)
}
