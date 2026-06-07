<#
.SYNOPSIS
    Removes the weekly Desktop Organizer scheduled task.

.PARAMETER TaskName
    Scheduled task name. Default: DesktopOrganizer-Weekly.

.EXAMPLE
    .\Unregister-WeeklyTask.ps1
#>

[CmdletBinding()]
param(
    [string] $TaskName = 'DesktopOrganizer-Weekly'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "No scheduled task named '$TaskName' found - nothing to remove." -ForegroundColor Yellow
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "Your scripts and existing logs are untouched." -ForegroundColor Green
