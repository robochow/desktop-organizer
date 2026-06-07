<#
.SYNOPSIS
    Shared engine for the Desktop Organizer. Dot-sourced by the console script,
    the undo script and the WPF GUI so they all use exactly the same logic.

.DESCRIPTION
    This file defines functions only - dot-sourcing it has no side effects. The
    core safety rules live here in one place:
      * only loose top-level files are ever considered (folders are left alone)
      * shortcuts, hidden/system files and the organizer's own scripts are skipped
      * destinations never overwrite - duplicates get a " (n)" suffix
      * every executed run is written to a JSON move-log that the undo reads back

    Front ends (console / GUI) are responsible only for presentation and
    confirmation; they call New-OrganizePlan, Invoke-OrganizePlan and the undo
    helpers below.

    Usage:
        . "$PSScriptRoot\DesktopOrganizer.Engine.ps1"
#>

function Get-DesktopOrganizerConfig {
    <#
        Returns the static configuration: the category list, the extension->category
        map, screenshot filename patterns, names we never move, and the default log
        directory. Returning it from a function (rather than leaving loose variables
        around) keeps dot-sourcing clean and side-effect free.
    #>
    [CmdletBinding()]
    param()

    $extensionMap = @{
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

    # Local app-data root for logs. %LOCALAPPDATA% is always set on Windows; fall
    # back to the .NET known folder (and finally temp) so the engine never throws.
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $localAppData) { $localAppData = [System.IO.Path]::GetTempPath() }

    [pscustomobject]@{
        # Display/processing order for categories.
        Categories         = @('Documents','Images','Screenshots','Videos','Installers','Archives','Spreadsheets','PDFs','Misc')
        ExtensionMap       = $extensionMap
        # Filenames matching any of these (case-insensitive) are screenshots,
        # regardless of their image extension. Screenshots win over Images.
        ScreenshotPatterns = @('^screenshot', '^screen shot', '^screen_shot', '^snip', 'screen.?capture')
        # Never move these (system / bookkeeping).
        ExcludedNames      = @('desktop.ini', 'thumbs.db', '.ds_store')
        # The organizer's own files - never move these if they sit on the Desktop.
        ScriptNames        = @(
            'organize-desktop.ps1','organize-desktop-gui.ps1','undo-lastorganize.ps1',
            'register-weeklytask.ps1','unregister-weeklytask.ps1',
            'desktoporganizer.engine.ps1','create-shortcut.ps1'
        )
        DefaultLogDirectory = (Join-Path $localAppData 'DesktopOrganizer\logs')
    }
}

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

function Get-DesktopFileCategory {
    <#
        Decide which category a file belongs to. Screenshots win over generic
        Images when the filename looks like a screenshot.
    #>
    param(
        [System.IO.FileInfo] $File,
        [object] $Config = (Get-DesktopOrganizerConfig)
    )

    $ext = $File.Extension.ToLowerInvariant()
    $category = $Config.ExtensionMap[$ext]

    # Screenshot override: filename pattern beats the plain "Images" mapping.
    if ($category -eq 'Images') {
        foreach ($pat in $Config.ScreenshotPatterns) {
            if ($File.Name -imatch $pat) { return 'Screenshots' }
        }
    }

    if ($category) { return $category }
    return 'Misc'
}

function Get-ScreenshotMonthLabel {
    <#
        Returns a "yyyy-MM" label for grouping screenshots into month subfolders.
        Prefers a date embedded in the filename (e.g. "Screenshot 2026-06-01..."),
        falling back to the file's last-write time when none is found.
    #>
    param([System.IO.FileInfo] $File)

    if ($File.Name -match '((?:19|20)\d\d)[-_.]?(0[1-9]|1[0-2])') {
        return ('{0}-{1}' -f $Matches[1], $Matches[2])
    }
    return $File.LastWriteTime.ToString('yyyy-MM')
}

function Get-SafeDestination {
    <#
        Given a destination folder and a desired filename, return a full path that
        does not collide with an existing file. Adds " (1)", " (2)", ... before the
        extension until a free name is found. Never overwrites.

        $Planned tracks names already claimed earlier in this same plan so two
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

function New-OrganizePlan {
    <#
        Scans loose files on the Desktop and returns the move plan (one item per
        file). Moves nothing. Each item: Category, Source, Destination, FileName,
        Renamed, SizeKB.

        -EnabledCategories restricts which categories are organized; files whose
        category is not enabled are left on the Desktop (skipped entirely). Defaults
        to all categories.

        -ScreenshotByMonth routes screenshots into Screenshots\yyyy-MM subfolders.

        -IncludeShortcuts also files .lnk/.url shortcuts (off by default).
    #>
    [CmdletBinding()]
    param(
        [string]   $DesktopPath,
        [string[]] $EnabledCategories,
        [switch]   $ScreenshotByMonth,
        [switch]   $IncludeShortcuts,
        [object]   $Config = (Get-DesktopOrganizerConfig)
    )

    if (-not $DesktopPath) { $DesktopPath = Resolve-DesktopPath }
    if (-not $EnabledCategories) { $EnabledCategories = $Config.Categories }

    # Gather loose files only (top-level, no recursion into folders).
    # @(...) forces an array so .Count is reliable even with a single match.
    $looseFiles = @(Get-ChildItem -LiteralPath $DesktopPath -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name.ToLowerInvariant()

        if ($Config.ExcludedNames -contains $name) { return $false }
        # Leave hidden/system files (e.g. desktop.ini) alone.
        if ($_.Attributes -band [System.IO.FileAttributes]::Hidden)  { return $false }
        if ($_.Attributes -band [System.IO.FileAttributes]::System)  { return $false }
        # Don't move our own scripts if they happen to live on the Desktop.
        if ($Config.ScriptNames -contains $name) { return $false }
        # Shortcuts stay put unless explicitly included.
        if (-not $IncludeShortcuts -and ($_.Extension -in @('.lnk','.url'))) { return $false }

        return $true
    })

    $planned = New-Object 'System.Collections.Generic.HashSet[string]'
    $plan = @(foreach ($file in $looseFiles) {
        $category = Get-DesktopFileCategory -File $file -Config $Config

        # Honour category on/off toggles - skip files in disabled categories.
        if ($EnabledCategories -notcontains $category) { continue }

        $destFolder = Join-Path $DesktopPath $category
        if ($ScreenshotByMonth -and $category -eq 'Screenshots') {
            $destFolder = Join-Path $destFolder (Get-ScreenshotMonthLabel -File $file)
        }

        $destPath = Get-SafeDestination -DestFolder $destFolder -FileName $file.Name -Planned $planned

        [pscustomobject]@{
            Category    = $category
            Source      = $file.FullName
            Destination = $destPath
            FileName    = $file.Name
            Renamed     = ([System.IO.Path]::GetFileName($destPath) -ne $file.Name)
            SizeKB      = [math]::Round($file.Length / 1KB, 1)
        }
    })

    return $plan
}

function Invoke-OrganizePlan {
    <#
        Executes a move plan: creates destination folders as needed, moves each
        file (never overwriting - destinations were pre-resolved), and writes a JSON
        move-log. Returns a result object with MovedCount, FailedCount, LogPath,
        Moves (succeeded) and Failures. Presentation is left to the caller.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Plan,
        [string]   $DesktopPath,
        [string]   $LogDirectory = (Get-DesktopOrganizerConfig).DefaultLogDirectory,
        [switch]   $Unattended
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $logPath = Join-Path $LogDirectory "organize_$timestamp.json"
    $moves = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($item in $Plan) {
        $destFolder = Split-Path -Parent $item.Destination
        try {
            if (-not (Test-Path -LiteralPath $destFolder)) {
                New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            }
            Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction Stop

            $moves.Add([pscustomobject]@{
                Category   = $item.Category
                From       = $item.Source
                To         = $item.Destination
                FileName   = [System.IO.Path]::GetFileName($item.Source)
                MovedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            })
        } catch {
            $failures.Add([pscustomobject]@{
                Source   = $item.Source
                FileName = [System.IO.Path]::GetFileName($item.Source)
                Error    = $_.Exception.Message
            })
        }
    }

    # The log stores only the bookkeeping fields the undo needs.
    $logMoves = @($moves | ForEach-Object {
        [pscustomobject]@{ Category = $_.Category; From = $_.From; To = $_.To; MovedAtUtc = $_.MovedAtUtc }
    })
    $logObject = [pscustomobject]@{
        Schema      = 'desktop-organizer/move-log@1'
        RunAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        Desktop     = $DesktopPath
        Unattended  = [bool]$Unattended
        MovedCount  = $moves.Count
        FailedCount = $failures.Count
        Moves       = $logMoves
    }
    $logObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8

    [pscustomobject]@{
        LogPath     = $logPath
        MovedCount  = $moves.Count
        FailedCount = $failures.Count
        Moves       = $moves.ToArray()
        Failures    = $failures.ToArray()
    }
}

function Get-LatestOrganizeLog {
    <#
        Returns the FullName of the most recent move-log that has not already been
        undone, or $null if there is none.
    #>
    param([string] $LogDirectory = (Get-DesktopOrganizerConfig).DefaultLogDirectory)

    if (-not (Test-Path -LiteralPath $LogDirectory)) { return $null }
    $latest = Get-ChildItem -LiteralPath $LogDirectory -Filter 'organize_*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.undone.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

function Get-OrganizeUndoPlan {
    <#
        Reads a move-log and works out, in reverse order, which files can be safely
        restored and which must be skipped (source missing, or original location now
        occupied). Moves nothing. Returns: LogFile, RunAtUtc, Restorable (array of
        {From,To}) and Skips (array of strings).
    #>
    param([string] $LogFile)

    if (-not (Test-Path -LiteralPath $LogFile)) { throw "Log file not found: $LogFile" }

    $log = Get-Content -LiteralPath $LogFile -Raw | ConvertFrom-Json
    # ConvertFrom-Json yields $null for an empty array; @() normalizes it.
    $moves = @($log.Moves)
    # Undo in reverse so numeric-suffix renames unwind cleanly.
    [array]::Reverse($moves)

    $restorable = New-Object System.Collections.Generic.List[object]
    $skips = New-Object System.Collections.Generic.List[string]
    foreach ($m in $moves) {
        $fromNow = $m.To     # where the file currently is
        $backTo  = $m.From   # where it should return to
        if (-not (Test-Path -LiteralPath $fromNow)) {
            $skips.Add("MISSING (already moved/deleted): $fromNow"); continue
        }
        if (Test-Path -LiteralPath $backTo) {
            $skips.Add("BLOCKED (original location occupied): $backTo"); continue
        }
        $restorable.Add([pscustomobject]@{ From = $fromNow; To = $backTo })
    }

    [pscustomobject]@{
        LogFile    = $LogFile
        RunAtUtc   = $log.RunAtUtc
        Restorable = $restorable.ToArray()
        Skips      = $skips.ToArray()
    }
}

function Invoke-OrganizeUndo {
    <#
        Restores files recorded in a move-log to their original Desktop locations,
        never overwriting. On success renames the log to *.undone.json so it won't be
        picked up again. Returns: Restored, Skipped, Failures, LogFile.
    #>
    [CmdletBinding()]
    param([string] $LogFile)

    $plan = Get-OrganizeUndoPlan -LogFile $LogFile

    $restored = 0
    $skipped = $plan.Skips.Count
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($item in $plan.Restorable) {
        $fromNow = $item.From
        $backTo  = $item.To
        try {
            # Re-check at execution time in case the filesystem changed since planning.
            if (-not (Test-Path -LiteralPath $fromNow)) { $skipped++; continue }
            if (Test-Path -LiteralPath $backTo)         { $skipped++; continue }

            $backParent = Split-Path -Parent $backTo
            if (-not (Test-Path -LiteralPath $backParent)) {
                New-Item -ItemType Directory -Path $backParent -Force | Out-Null
            }
            Move-Item -LiteralPath $fromNow -Destination $backTo -ErrorAction Stop
            $restored++
        } catch {
            $skipped++
            $failures.Add([pscustomobject]@{ From = $fromNow; To = $backTo; Error = $_.Exception.Message })
        }
    }

    $undoneName = $null
    if ($restored -gt 0) {
        $undoneName = [System.IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '.undone.json'
        try {
            Rename-Item -LiteralPath $LogFile -NewName ([System.IO.Path]::GetFileName($undoneName)) -ErrorAction Stop
        } catch {
            # Non-fatal: the restore already happened.
            $undoneName = $null
        }
    }

    [pscustomobject]@{
        Restored    = $restored
        Skipped     = $skipped
        Failures    = $failures.ToArray()
        LogFile     = $LogFile
        UndoneAs    = $undoneName
    }
}
