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

        # --- Folder consolidation (Cleanup mode) --------------------------------
        # Theme name => the words that signal that theme. The theme name doubles as
        # the canonical target folder a redundant group consolidates into.
        FolderThemes       = ([ordered]@{
            Pictures  = @('pic','pics','picture','pictures','photo','photos','image','images','img','imgs','wallpaper','wallpapers','camera','screenshot','screenshots','snaps','snapshots')
            Documents = @('doc','docs','document','documents','word','text','txt','note','notes','paper','papers','essay','essays','report','reports','letters')
            Music     = @('music','song','songs','audio','mp3','mp3s','tracks','albums')
            Videos    = @('video','videos','movie','movies','clip','clips','footage')
            Downloads = @('download','downloads','dl')
        })
        # Noise words ignored when matching a folder name to a theme.
        FolderFillerWords  = @('assorted','more','random','misc','miscellaneous','new','old','stuff','various','my','the','a','an','folder','folders','copy','untitled','temp','tmp','files','file','and','of','to','for','some','other','extra')
        # Folders that must never be touched by consolidation (matched lower-case,
        # plus anything starting with '.', '__' or '$', plus hidden/system folders,
        # plus the organizer's own category folders, plus any folder containing an
        # executable - see Test-ProtectedFolder).
        ProtectedFolderNames = @(
            '__macosx','config','appdata','application data','windows','program files',
            'program files (x86)','programdata','system volume information','$recycle.bin',
            'recovery','node_modules','.git','.vs','.idea','bin','obj','venv','.venv','env',
            'onedrive','dropbox','google drive'
        )
        # File extensions that mark a folder as an application folder (never touch).
        ExecutableExtensions = @('.exe','.dll','.msi','.com','.bat','.cmd')

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

function Invoke-OrganizerMovePlan {
    <#
        The shared executor behind organizing, folder consolidation and renaming.
        Moves each plan item (creating destination folders; never overwriting, since
        destinations are pre-resolved), optionally removes source folders that end up
        empty, and writes a JSON move-log that the undo reads back. Every operation
        produces the same log shape, so "Undo Last Run" reverses any of them.

        Plan items need .Source, .Destination and .Category.

        Returns: LogPath, Operation, MovedCount, FailedCount, Moves, Failures,
        RemovedFolders.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Plan,
        [string]   $DesktopPath,
        [string]   $LogDirectory = (Get-DesktopOrganizerConfig).DefaultLogDirectory,
        [switch]   $Unattended,
        [ValidateSet('organize','consolidate','rename')]
        [string]   $Operation = 'organize',
        [string[]] $RemoveEmptyFolders
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
            if ($destFolder -and -not (Test-Path -LiteralPath $destFolder)) {
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

    # After consolidation, remove any source folder we fully emptied. Undo recreates
    # it implicitly by restoring its files, so nothing extra needs logging.
    $removedFolders = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($RemoveEmptyFolders)) {
        if (-not $folder) { continue }
        try {
            if ((Test-Path -LiteralPath $folder) -and
                -not (Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $folder -Force -ErrorAction Stop
                $removedFolders.Add($folder)
            }
        } catch { }   # non-fatal: the file moves already succeeded
    }

    # The log stores only the bookkeeping fields the undo needs.
    $logMoves = @($moves | ForEach-Object {
        [pscustomobject]@{ Category = $_.Category; From = $_.From; To = $_.To; MovedAtUtc = $_.MovedAtUtc }
    })
    $logObject = [pscustomobject]@{
        Schema      = 'desktop-organizer/move-log@1'
        Operation   = $Operation
        RunAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        Desktop     = $DesktopPath
        Unattended  = [bool]$Unattended
        MovedCount  = $moves.Count
        FailedCount = $failures.Count
        Moves       = $logMoves
    }
    $logObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8

    [pscustomobject]@{
        LogPath        = $logPath
        Operation      = $Operation
        MovedCount     = $moves.Count
        FailedCount    = $failures.Count
        Moves          = $moves.ToArray()
        Failures       = $failures.ToArray()
        RemovedFolders = $removedFolders.ToArray()
    }
}

function Invoke-OrganizePlan {
    <#
        Executes an organize plan (loose files into category folders). Thin wrapper
        over Invoke-OrganizerMovePlan for backward compatibility.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Plan,
        [string]   $DesktopPath,
        [string]   $LogDirectory = (Get-DesktopOrganizerConfig).DefaultLogDirectory,
        [switch]   $Unattended
    )
    Invoke-OrganizerMovePlan -Plan $Plan -DesktopPath $DesktopPath `
        -LogDirectory $LogDirectory -Unattended:$Unattended -Operation 'organize'
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

# ==================================================================================
# Folder consolidation (Cleanup mode)
# ==================================================================================

function Test-ProtectedFolder {
    <#
        Returns $true if a Desktop folder must never be touched by consolidation:
        hidden/system folders, dotted/__/$ names, known system & app folders, the
        organizer's own category folders, and any folder containing an executable
        (a sign it's an application folder).
    #>
    param(
        [System.IO.DirectoryInfo] $Folder,
        [object] $Config = (Get-DesktopOrganizerConfig)
    )

    $lower = $Folder.Name.ToLowerInvariant()

    if ($Folder.Attributes -band [System.IO.FileAttributes]::Hidden) { return $true }
    if ($Folder.Attributes -band [System.IO.FileAttributes]::System) { return $true }
    if ($lower.StartsWith('.') -or $lower.StartsWith('__') -or $lower.StartsWith('$')) { return $true }
    if ($Config.ProtectedFolderNames -contains $lower) { return $true }
    # -contains is case-insensitive: protects 'Documents','Images', etc.
    if ($Config.Categories -contains $Folder.Name) { return $true }

    # App folders: contain an executable anywhere inside.
    $exe = Get-ChildItem -LiteralPath $Folder.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $Config.ExecutableExtensions -contains $_.Extension.ToLowerInvariant() } |
        Select-Object -First 1
    if ($exe) { return $true }

    return $false
}

function Get-FolderTheme {
    <#
        Maps a folder name to a canonical theme (Pictures/Documents/Music/Videos/
        Downloads) by matching its words against the theme keyword lists, ignoring
        filler words like "assorted"/"more"/"random". Returns $null if no match.
        The theme name doubles as the consolidation target folder name.
    #>
    param(
        [string] $FolderName,
        [object] $Config = (Get-DesktopOrganizerConfig)
    )

    $tokens = @($FolderName.ToLowerInvariant() -split '[^a-z0-9]+' |
        Where-Object { $_ -and ($Config.FolderFillerWords -notcontains $_) })

    foreach ($theme in $Config.FolderThemes.Keys) {
        $keywords = $Config.FolderThemes[$theme]
        foreach ($t in $tokens) {
            if ($keywords -contains $t) { return [string]$theme }
        }
    }
    return $null
}

function New-FolderConsolidationPlan {
    <#
        Scans top-level Desktop folders and suggests consolidating obviously
        redundant ones (two or more sharing a theme) into a single canonical folder.
        Moves nothing. Returns one row per source folder: Theme, SourceFolder,
        SourceFolderPath, TargetFolder, TargetFolderPath, FileCount.
    #>
    [CmdletBinding()]
    param(
        [string] $DesktopPath,
        [object] $Config = (Get-DesktopOrganizerConfig)
    )

    if (-not $DesktopPath) { $DesktopPath = Resolve-DesktopPath }

    $folders = @(Get-ChildItem -LiteralPath $DesktopPath -Directory -Force -ErrorAction SilentlyContinue)

    # Group eligible folders by theme.
    $byTheme = @{}
    foreach ($f in $folders) {
        if (Test-ProtectedFolder -Folder $f -Config $Config) { continue }
        $theme = Get-FolderTheme -FolderName $f.Name -Config $Config
        if (-not $theme) { continue }
        if (-not $byTheme.ContainsKey($theme)) {
            $byTheme[$theme] = New-Object System.Collections.Generic.List[object]
        }
        $byTheme[$theme].Add($f)
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($theme in $byTheme.Keys) {
        $group = $byTheme[$theme]
        if ($group.Count -lt 2) { continue }   # only suggest genuinely redundant groups
        $targetPath = Join-Path $DesktopPath $theme
        foreach ($f in $group) {
            if ($f.FullName -ieq $targetPath) { continue }   # this folder already IS the target
            $fileCount = @(Get-ChildItem -LiteralPath $f.FullName -File -Force -ErrorAction SilentlyContinue).Count
            $rows.Add([pscustomobject]@{
                Theme            = $theme
                SourceFolder     = $f.Name
                SourceFolderPath = $f.FullName
                TargetFolder     = $theme
                TargetFolderPath = $targetPath
                FileCount        = $fileCount
            })
        }
    }

    return @($rows | Sort-Object TargetFolder, SourceFolder)
}

function Expand-FolderConsolidation {
    <#
        Turns approved consolidation rows into concrete move items, re-enumerating
        each source folder's top-level files at call time. Destinations are resolved
        with a shared planner so two folders merging into the same target never
        collide. Returns: Moves (Source/Destination/Category) and RemoveFolders
        (the source folders to delete once emptied).
    #>
    [CmdletBinding()]
    param(
        [object[]] $Approved,
        [object]   $Config = (Get-DesktopOrganizerConfig)
    )

    $planned = New-Object 'System.Collections.Generic.HashSet[string]'
    $moves = New-Object System.Collections.Generic.List[object]
    $removeFolders = New-Object System.Collections.Generic.List[string]

    foreach ($a in $Approved) {
        $src = $a.SourceFolderPath
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $files = @(Get-ChildItem -LiteralPath $src -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $Config.ExcludedNames -notcontains $_.Name.ToLowerInvariant() })

        foreach ($file in $files) {
            $dest = Get-SafeDestination -DestFolder $a.TargetFolderPath -FileName $file.Name -Planned $planned
            $moves.Add([pscustomobject]@{
                Category    = "Consolidate -> $($a.TargetFolder)"
                Source      = $file.FullName
                Destination = $dest
            })
        }
        $removeFolders.Add($src)
    }

    [pscustomobject]@{
        Moves         = $moves.ToArray()
        RemoveFolders = $removeFolders.ToArray()
    }
}

# ==================================================================================
# Filename cleanup (Clean Names mode)
# ==================================================================================

function Get-CleanFileName {
    <#
        Returns a tidied version of a filename: underscores -> spaces, collapsed
        double spaces, removed "- Copy"/"(copy)"/"Copy of" and trailing "(1) (2)"
        copy markers, dropped long random digit runs, and Title Case. The file
        extension is preserved exactly. Never returns an empty name.
    #>
    param([string] $FileName)

    $ext  = [System.IO.Path]::GetExtension($FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $name = $base

    $name = $name -replace '_', ' '                              # underscores -> spaces
    $name = $name -replace '(?i)^\s*copy of\s+', ''              # leading "Copy of "
    $name = $name -replace '(?i)\s*\(copy\)\s*$', ''             # trailing "(copy)"
    $name = $name -replace '(?i)[\s-]+copy(\s*\(\d+\))?\s*$', '' # " - Copy", " copy (2)"
    $name = $name -replace '(?:\s*\(\s*\d+\s*\)\s*)+$', ''       # trailing "(1)", "(1) (2)"

    # Drop standalone long digit runs (timestamps / random ids).
    $tokens = @($name -split '\s+' | Where-Object { $_ -ne '' -and $_ -notmatch '^\d{5,}$' })
    $name = ($tokens -join ' ')

    $name = ($name -replace '\s{2,}', ' ').Trim(([char[]]" -._"))
    if (-not $name) { $name = $base.Trim() }                     # never end up empty

    # Title Case (lower first so ALL CAPS normalizes). Extension untouched.
    $name = (Get-Culture).TextInfo.ToTitleCase($name.ToLowerInvariant())

    return ($name + $ext)
}

function New-RenamePlan {
    <#
        Proposes cleaned-up names for loose Desktop files. Moves/renames nothing.
        Returns rows: Source, Destination, OldName, NewName, Category. Renames that
        would collide get a numeric suffix (never overwriting); pure case changes are
        allowed through. Files already clean are skipped.
    #>
    [CmdletBinding()]
    param(
        [string] $DesktopPath,
        [object] $Config = (Get-DesktopOrganizerConfig)
    )

    if (-not $DesktopPath) { $DesktopPath = Resolve-DesktopPath }

    $looseFiles = @(Get-ChildItem -LiteralPath $DesktopPath -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name.ToLowerInvariant()
        if ($Config.ExcludedNames -contains $name) { return $false }
        if ($_.Attributes -band [System.IO.FileAttributes]::Hidden) { return $false }
        if ($_.Attributes -band [System.IO.FileAttributes]::System) { return $false }
        if ($Config.ScriptNames -contains $name) { return $false }
        if ($_.Extension -in @('.lnk','.url')) { return $false }
        return $true
    })

    $planned = New-Object 'System.Collections.Generic.HashSet[string]'
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($file in $looseFiles) {
        $newName = Get-CleanFileName -FileName $file.Name
        if ($newName -ceq $file.Name) { continue }   # already clean (exact match)

        $srcFolder = $file.DirectoryName
        $targetPath = Join-Path $srcFolder $newName

        if ($targetPath -ieq $file.FullName) {
            # Pure case change - allowed even though Test-Path is case-insensitive.
            $dest = $targetPath
            [void]$planned.Add($dest.ToLowerInvariant())
        } else {
            $dest = Get-SafeDestination -DestFolder $srcFolder -FileName $newName -Planned $planned
        }

        $rows.Add([pscustomobject]@{
            Source      = $file.FullName
            Destination = $dest
            OldName     = $file.Name
            NewName     = [System.IO.Path]::GetFileName($dest)
            Category    = 'Rename'
        })
    }

    return $rows.ToArray()
}
