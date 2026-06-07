<#
.SYNOPSIS
    Organizes loose files on your Windows Desktop into clearly named category folders.

.DESCRIPTION
    Scans every loose file sitting directly on your Desktop (OneDrive-redirected
    desktops are detected automatically) and sorts them into category folders such
    as Documents, Images, Screenshots, Videos, Installers, Archives, Spreadsheets,
    PDFs and Misc.

    Existing folders on the Desktop are never touched - only loose files are moved.
    Duplicate filenames are handled safely by adding a numeric suffix; nothing is
    ever overwritten. Every move is recorded in a JSON log so the run can be undone
    with Undo-LastOrganize.ps1.

    By default the script shows a dry-run preview and asks you to confirm before
    moving anything. For scheduled/unattended runs, pass -Unattended to skip the
    prompt (the log is still written so you can always undo).

    All organizing logic lives in DesktopOrganizer.Engine.ps1, which this script
    dot-sources. The GUI uses the same engine.

.PARAMETER DesktopPath
    Override the auto-detected Desktop path. Rarely needed.

.PARAMETER Unattended
    Skip the confirmation prompt and organize immediately. Used by the weekly
    scheduled task. A log is still written.

.PARAMETER WhatIfOnly
    Show the dry-run preview and exit without moving anything or prompting.

.PARAMETER LogDirectory
    Where run logs are written. Defaults to %LOCALAPPDATA%\DesktopOrganizer\logs.

.PARAMETER IncludeShortcuts
    Also move .lnk and .url shortcut files. By default shortcuts are left in place
    because people usually want them on the Desktop.

.EXAMPLE
    .\Organize-Desktop.ps1
    Interactive run: preview, confirm, then organize.

.EXAMPLE
    .\Organize-Desktop.ps1 -WhatIfOnly
    Just show what would happen. Move nothing.

.EXAMPLE
    .\Organize-Desktop.ps1 -Unattended
    Organize without prompting (used by the scheduled task).
#>

[CmdletBinding()]
param(
    [string] $DesktopPath,
    [switch] $Unattended,
    [switch] $WhatIfOnly,
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'DesktopOrganizer\logs'),
    [switch] $IncludeShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# All organizing logic lives in the shared engine.
. (Join-Path $PSScriptRoot 'DesktopOrganizer.Engine.ps1')

$desktop = Resolve-DesktopPath -Override $DesktopPath

Write-Host ''
Write-Host "Desktop Organizer" -ForegroundColor Cyan
Write-Host "  Desktop : $desktop"
Write-Host "  Logs    : $LogDirectory"
Write-Host ''

# Build the move plan (moves nothing).
$plan = New-OrganizePlan -DesktopPath $desktop -IncludeShortcuts:$IncludeShortcuts

if (-not $plan -or $plan.Count -eq 0) {
    Write-Host "Nothing to organize - no loose files on the Desktop." -ForegroundColor Green
    return
}

# ----------------------------------------------------------------------------
# Dry-run preview
# ----------------------------------------------------------------------------
Write-Host "DRY-RUN PREVIEW - $($plan.Count) file(s) would be organized:" -ForegroundColor Yellow
Write-Host ''
foreach ($group in ($plan | Group-Object Category | Sort-Object Name)) {
    Write-Host ("  {0}  ({1} file(s))" -f $group.Name, $group.Count) -ForegroundColor Cyan
    foreach ($item in $group.Group) {
        $srcName = [System.IO.Path]::GetFileName($item.Source)
        $dstName = [System.IO.Path]::GetFileName($item.Destination)
        if ($item.Renamed) {
            Write-Host ("      {0}  ->  {1}\{2}   (renamed to avoid overwrite)" -f $srcName, $group.Name, $dstName) -ForegroundColor DarkYellow
        } else {
            Write-Host ("      {0}  ->  {1}\" -f $srcName, $group.Name)
        }
    }
    Write-Host ''
}

if ($WhatIfOnly) {
    Write-Host "WhatIfOnly specified - nothing was moved." -ForegroundColor Green
    return
}

# ----------------------------------------------------------------------------
# Confirmation (skipped when -Unattended)
# ----------------------------------------------------------------------------
if (-not $Unattended) {
    $answer = Read-Host "Proceed with these moves? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Cancelled - nothing was moved." -ForegroundColor Green
        return
    }
}

# ----------------------------------------------------------------------------
# Execute moves + log (via the shared engine)
# ----------------------------------------------------------------------------
$result = Invoke-OrganizePlan -Plan $plan -DesktopPath $desktop -LogDirectory $LogDirectory -Unattended:$Unattended

foreach ($m in $result.Moves) {
    Write-Host ("  moved: {0}" -f $m.FileName) -ForegroundColor Green
}
foreach ($f in $result.Failures) {
    Write-Warning ("could not move '{0}': {1}" -f $f.Source, $f.Error)
}

Write-Host ''
Write-Host ("Done. Moved {0} file(s)." -f $result.MovedCount) -ForegroundColor Green
if ($result.FailedCount -gt 0) {
    Write-Host ("  {0} file(s) could not be moved (likely open/in use) - see warnings above." -f $result.FailedCount) -ForegroundColor Yellow
}
Write-Host ("Log written to: {0}" -f $result.LogPath)
Write-Host "To undo this run:  .\Undo-LastOrganize.ps1" -ForegroundColor Cyan
