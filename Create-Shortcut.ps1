<#
.SYNOPSIS
    Creates a double-click shortcut that launches the Desktop Organizer GUI with no
    console window flashing behind it.

.DESCRIPTION
    Drops a .lnk shortcut on your Desktop (default) and/or Start Menu that runs
    Organize-Desktop-GUI.ps1 through Windows PowerShell with a hidden window. The
    GUI also hides its own console on startup, so launching feels like a normal app.

    By default the shortcut uses a built-in Windows icon. Pass -IconPath to use your
    own .ico (or a "file.dll,index" reference).

.PARAMETER Location
    Where to create the shortcut: Desktop (default), StartMenu, or Both.

.PARAMETER Name
    Shortcut display name. Default: "Desktop Organizer".

.PARAMETER IconPath
    Icon to use. Default: a folder icon from the system shell library.

.EXAMPLE
    .\Create-Shortcut.ps1
    Put a "Desktop Organizer" shortcut on the Desktop.

.EXAMPLE
    .\Create-Shortcut.ps1 -Location Both
    Add it to both the Desktop and the Start Menu.
#>

[CmdletBinding()]
param(
    [ValidateSet('Desktop','StartMenu','Both')]
    [string] $Location = 'Desktop',

    [string] $Name = 'Desktop Organizer',

    [string] $IconPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$guiScript = Join-Path $scriptDir 'Organize-Desktop-GUI.ps1'
if (-not (Test-Path -LiteralPath $guiScript)) {
    throw "Could not find Organize-Desktop-GUI.ps1 next to this script (looked in $scriptDir)."
}

# Launch through Windows PowerShell (preinstalled, STA - ideal for WPF), hidden.
$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $winPs)) { $winPs = 'powershell.exe' }

$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $guiScript

# Default icon: a folder glyph from the Windows shell icon library.
if (-not $IconPath) {
    $IconPath = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',4'
}

$targets = switch ($Location) {
    'Desktop'   { @([Environment]::GetFolderPath('Desktop')) }
    'StartMenu' { @([Environment]::GetFolderPath('Programs')) }
    'Both'      { @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) }
}

$shell = New-Object -ComObject WScript.Shell
foreach ($dir in $targets) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lnkPath = Join-Path $dir ("$Name.lnk")

    $shortcut = $shell.CreateShortcut($lnkPath)
    $shortcut.TargetPath       = $winPs
    $shortcut.Arguments        = $arguments
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.IconLocation     = $IconPath
    $shortcut.WindowStyle      = 7           # 7 = minimized; combined with -WindowStyle Hidden, no window shows
    $shortcut.Description      = 'Sort loose Desktop files into category folders'
    $shortcut.Save()

    Write-Host "Created shortcut: $lnkPath" -ForegroundColor Green
}

Write-Host ''
Write-Host "Double-click '$Name' to launch the organizer - no PowerShell window will appear." -ForegroundColor Cyan
