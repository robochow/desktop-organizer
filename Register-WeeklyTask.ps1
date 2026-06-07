<#
.SYNOPSIS
    Registers a Windows Scheduled Task that runs the Desktop Organizer once a week.

.DESCRIPTION
    Creates a per-user scheduled task ("DesktopOrganizer-Weekly") that runs
    Organize-Desktop.ps1 with -Unattended, so it organizes without prompting but
    still writes a log you can undo. The task runs only when you are logged on
    (your Desktop is a per-user folder) and needs NO administrator rights, because
    it only moves your own files.

    Re-running this script updates the existing task in place.

.PARAMETER DayOfWeek
    Which day to run. Default: Sunday.

.PARAMETER Time
    Time of day to run, 24h "HH:mm". Default: 09:00.

.PARAMETER TaskName
    Scheduled task name. Default: DesktopOrganizer-Weekly.

.EXAMPLE
    .\Register-WeeklyTask.ps1
    Run every Sunday at 09:00.

.EXAMPLE
    .\Register-WeeklyTask.ps1 -DayOfWeek Monday -Time 18:30
    Run every Monday at 6:30 PM.
#>

[CmdletBinding()]
param(
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string] $DayOfWeek = 'Sunday',

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string] $Time = '09:00',

    [string] $TaskName = 'DesktopOrganizer-Weekly'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the full path to the organizer script that sits next to this one.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$organizer = Join-Path $scriptDir 'Organize-Desktop.ps1'
if (-not (Test-Path -LiteralPath $organizer)) {
    throw "Could not find Organize-Desktop.ps1 next to this script (looked in $scriptDir)."
}

# Use the same PowerShell host that is running this script (Windows PowerShell or pwsh).
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = Join-Path $PSHOME 'powershell.exe' }

$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Unattended' -f $organizer

$action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments -WorkingDirectory $scriptDir

# Weekly trigger at the requested day/time.
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $Time

# Run as the current interactive user; no elevation needed for moving own files.
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

# Be polite: don't run on battery, allow a missed run to start late.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$description = "Sorts loose files on the Desktop into category folders. Runs unattended; writes an undo log to %LOCALAPPDATA%\DesktopOrganizer\logs."

# Register (replacing any existing task with the same name).
Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description $description -Force | Out-Null

Write-Host ''
Write-Host "Scheduled task registered." -ForegroundColor Green
Write-Host "  Name    : $TaskName"
Write-Host "  Runs    : Every $DayOfWeek at $Time"
Write-Host "  Command : $psExe $arguments"
Write-Host ''
Write-Host "Useful commands:" -ForegroundColor Cyan
Write-Host "  Run it now to test :  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  See its status     :  Get-ScheduledTaskInfo -TaskName '$TaskName'"
Write-Host "  Remove it          :  .\Unregister-WeeklyTask.ps1"
