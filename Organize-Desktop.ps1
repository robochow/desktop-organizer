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

# ----------------------------------------------------------------------------
# Category definitions
# ----------------------------------------------------------------------------
# Extension -> category. Order of *evaluation* (screenshots, pdfs, etc.) is
# handled in Get-Category below; this map is just the extension lookup.
$ExtensionMap = @{
    # Images
    '.jpg' = 'Images'; '.jpeg' = 'Images'; '.png' = 'Images'; '.gif' = 'Images'
    '.bmp' = 'Images'; '.tiff' = 'Images'; '.tif' = 'Images'; '.webp' = 'Images'
    '.heic' = 'Images'; '.svg' = 'Images'; '.ico' = 'Images'; '.raw' = 'Images'

    # Videos
    '.mp4' = 'Videos'; '.mov' = 'Videos'; '.avi' = 'Videos'; '.mkv' = 'Videos'
    '.wmv' = 'Videos'; '.flv' = 'Videos'; '.webm' = 'Videos'; '.m4v' = 'Videos'
    '.mpg' = 'Videos'; '.mpeg' = 'Videos'

    # PDFs
    '.pdf' = 'PDFs'

    # Spreadsheets
    '.xls' = 'Spreadsheets'; '.xlsx' = 'Spreadsheets'; '.xlsm' = 'Spreadsheets'
    '.csv' = 'Spreadsheets'; '.ods' = 'Spreadsheets'; '.tsv' = 'Spreadsheets'

    # Documents (incl. text, word-processing and presentations)
    '.doc' = 'Documents'; '.docx' = 'Documents'; '.txt' = 'Documents'
    '.rtf' = 'Documents'; '.odt' = 'Documents'; '.md' = 'Documents'
    '.ppt' = 'Documents'; '.pptx' = 'Documents'; '.odp' = 'Documents'
    '.pages' = 'Documents'; '.epub' = 'Documents'; '.tex' = 'Documents'

    # Installers
    '.exe' = 'Installers'; '.msi' = 'Installers'; '.msix' = 'Installers'
    '.appx' = 'Installers'; '.msixbundle' = 'Installers'

    # Archives
    '.zip' = 'Archives'; '.rar' = 'Archives'; '.7z' = 'Archives'; '.tar' = 'Archives'
    '.gz' = 'Archives'; '.bz2' = 'Archives'; '.xz' = 'Archives'; '.iso' = 'Archives'
}

# Filenames matching any of these (case-insensitive) are treated as screenshots
# regardless of their image extension.
$ScreenshotPatterns = @(
    '^screenshot',          # "Screenshot 2024-01-01..."
    '^screen shot',         # macOS-style "Screen Shot ..."
    '^screen_shot',
    '^snip',                # Snipping Tool exports sometimes
    'screen.?capture'
)

# Files we never move (system / our own bookkeeping).
$ExcludedNames = @('desktop.ini', 'thumbs.db', '.ds_store')

function Resolve-DesktopPath {
    <#
        Returns the real Desktop path, correctly following OneDrive (or any other)
        Known Folder redirection. [Environment]::GetFolderPath('Desktop') already
        honours redirection, so it's the most reliable source. We fall back to the
        registry and then the classic path just in case.
    #>
    param([string] $Override)

    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override)) {
            throw "Specified DesktopPath does not exist: $Override"
        }
        return (Resolve-Path -LiteralPath $Override).Path
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    # 1. Known Folder API (honours OneDrive redirection).
    try {
        $p = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
        if ($p) { $candidates.Add($p) }
    } catch { }

    # 2. Registry User Shell Folders (expands %USERPROFILE% / %OneDrive%).
    try {
        $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $raw = (Get-ItemProperty -Path $regKey -Name 'Desktop' -ErrorAction Stop).Desktop
        if ($raw) { $candidates.Add([Environment]::ExpandEnvironmentVariables($raw)) }
    } catch { }

    # 3. OneDrive\Desktop if OneDrive is configured.
    if ($env:OneDrive) { $candidates.Add((Join-Path $env:OneDrive 'Desktop')) }

    # 4. Classic profile Desktop.
    $candidates.Add((Join-Path $env:USERPROFILE 'Desktop'))

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    throw "Could not locate your Desktop folder. Tried: $($candidates -join '; ')"
}

function Get-Category {
    <#
        Decide which category a file belongs to. Screenshots win over generic
        Images when the filename looks like a screenshot.
    #>
    param([System.IO.FileInfo] $File)

    $ext = $File.Extension.ToLowerInvariant()
    $category = $ExtensionMap[$ext]

    # Screenshot override: filename pattern beats the plain "Images" mapping.
    if ($category -eq 'Images') {
        foreach ($pat in $ScreenshotPatterns) {
            if ($File.Name -imatch $pat) { return 'Screenshots' }
        }
    }

    if ($category) { return $category }
    return 'Misc'
}

function Get-SafeDestination {
    <#
        Given a destination folder and a desired filename, return a full path that
        does not collide with an existing file. Adds " (1)", " (2)", ... before the
        extension until a free name is found. Never overwrites.

        $Planned tracks names already claimed earlier in this same dry-run so two
        same-named source files don't both resolve to the same target.
    #>
    param(
        [string] $DestFolder,
        [string] $FileName,
        [System.Collections.Generic.HashSet[string]] $Planned
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName)

    $candidate = $FileName
    $counter = 1
    while ($true) {
        $full = Join-Path $DestFolder $candidate
        $key  = $full.ToLowerInvariant()
        if (-not (Test-Path -LiteralPath $full) -and -not $Planned.Contains($key)) {
            [void]$Planned.Add($key)
            return $full
        }
        $candidate = "$base ($counter)$ext"
        $counter++
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
$desktop = Resolve-DesktopPath -Override $DesktopPath
$thisScriptFullName = $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host "Desktop Organizer" -ForegroundColor Cyan
Write-Host "  Desktop : $desktop"
Write-Host "  Logs    : $LogDirectory"
Write-Host ''

# Gather loose files only (top-level, no recursion into folders).
# @(...) forces an array so .Count is reliable even with a single match.
$looseFiles = @(Get-ChildItem -LiteralPath $desktop -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $name = $_.Name.ToLowerInvariant()

    if ($ExcludedNames -contains $name) { return $false }
    # Leave hidden/system files (e.g. desktop.ini) alone.
    if ($_.Attributes -band [System.IO.FileAttributes]::Hidden)  { return $false }
    if ($_.Attributes -band [System.IO.FileAttributes]::System)  { return $false }
    # Don't move our own scripts if they happen to live on the Desktop.
    if ($thisScriptFullName -and $_.FullName -eq $thisScriptFullName) { return $false }
    if ($name -in @('organize-desktop.ps1','undo-lastorganize.ps1','register-weeklytask.ps1','unregister-weeklytask.ps1')) { return $false }
    # Shortcuts stay put unless explicitly included.
    if (-not $IncludeShortcuts -and ($_.Extension -in @('.lnk','.url'))) { return $false }

    return $true
})

if (-not $looseFiles -or $looseFiles.Count -eq 0) {
    Write-Host "Nothing to organize - no loose files on the Desktop." -ForegroundColor Green
    return
}

# Build the move plan.
$planned = New-Object 'System.Collections.Generic.HashSet[string]'
$plan = @(foreach ($file in $looseFiles) {
    $category = Get-Category -File $file
    $destFolder = Join-Path $desktop $category
    $destPath = Get-SafeDestination -DestFolder $destFolder -FileName $file.Name -Planned $planned

    [pscustomobject]@{
        Category    = $category
        Source      = $file.FullName
        Destination = $destPath
        Renamed     = ([System.IO.Path]::GetFileName($destPath) -ne $file.Name)
        SizeKB      = [math]::Round($file.Length / 1KB, 1)
    }
})

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
# Execute moves + log
# ----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$logPath = Join-Path $LogDirectory "organize_$timestamp.json"
$moves = New-Object System.Collections.Generic.List[object]
$failed = 0

foreach ($item in $plan) {
    $destFolder = Split-Path -Parent $item.Destination
    try {
        if (-not (Test-Path -LiteralPath $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
        }
        Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction Stop

        $moves.Add([pscustomobject]@{
            Category    = $item.Category
            From        = $item.Source
            To          = $item.Destination
            MovedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        })
        Write-Host ("  moved: {0}" -f [System.IO.Path]::GetFileName($item.Source)) -ForegroundColor Green
    } catch {
        $failed++
        Write-Warning ("could not move '{0}': {1}" -f $item.Source, $_.Exception.Message)
    }
}

$logObject = [pscustomobject]@{
    Schema      = 'desktop-organizer/move-log@1'
    RunAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    Desktop     = $desktop
    Unattended  = [bool]$Unattended
    MovedCount  = $moves.Count
    FailedCount = $failed
    Moves       = $moves
}
$logObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8

Write-Host ''
Write-Host ("Done. Moved {0} file(s)." -f $moves.Count) -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host ("  {0} file(s) could not be moved (likely open/in use) - see warnings above." -f $failed) -ForegroundColor Yellow
}
Write-Host ("Log written to: {0}" -f $logPath)
Write-Host "To undo this run:  .\Undo-LastOrganize.ps1" -ForegroundColor Cyan
