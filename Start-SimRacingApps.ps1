<#
.SYNOPSIS
    Launches every application listed in apps.json and places each window on its configured monitor.

.DESCRIPTION
    Applications are launched in the order they appear in apps.json. An application that is
    already running is not launched again, but its window is still moved to the configured
    monitor. If a configured monitor is not connected, the primary monitor is used instead and
    a warning is shown.

    Exit codes: 0 = everything went as configured, 1 = at least one warning or error (see the
    output), 2 = the configuration could not be loaded and nothing was launched.

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to apps.json next to this script.

.PARAMETER WindowTimeoutSeconds
    How long to wait for an application's window to appear before giving up on positioning it.

.PARAMETER SettleSeconds
    How long a newly launched window must stay unchanged before it is considered final, to catch
    applications that show a splash screen first or restore their own saved position a moment later.

.PARAMETER ListMonitors
    Only show the monitors detected on this PC, with the numbers to use in apps.json, then exit.

.EXAMPLE
    .\Start-SimRacingApps.ps1

.EXAMPLE
    .\Start-SimRacingApps.ps1 -ListMonitors

.EXAMPLE
    .\Start-SimRacingApps.ps1 -WhatIf
    Shows what would be launched and moved without doing it.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [ValidateRange(1, 600)][int]$WindowTimeoutSeconds = 30,
    [ValidateRange(0, 120)][int]$SettleSeconds = 10,
    [switch]$ListMonitors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 does not populate $PSScriptRoot while param() defaults are evaluated.
if (-not $ConfigPath) { $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'apps.json' }
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'SimRacingLauncher.psm1') -Force

# -WhatIf and -Confirm do not reach a script module's functions on their own; pass them explicitly.
$shouldProcess = @{}
foreach ($name in 'WhatIf', 'Confirm') {
    if ($PSBoundParameters.ContainsKey($name)) { $shouldProcess[$name] = $PSBoundParameters[$name] }
}

function Show-Status {
    # Console line for one engine result. Positional by design (severity, name, message); see PSScriptAnalyzerSettings.psd1.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidateSet('Plain', 'Info', 'Success', 'Warning', 'Error')][string]$Severity,
        [Parameter(Position = 1)][string]$Name,
        [Parameter(Position = 2)][string]$Message
    )
    $prefix = if ($Name) { "[$Name] " } else { '' }
    switch ($Severity) {
        'Warning' { Write-Warning "$prefix$Message" }
        'Error' { Write-Host "${prefix}ERROR: $Message" -ForegroundColor Red }
        'Success' { Write-Host "$prefix$Message" -ForegroundColor Green }
        'Info' { Write-Host "$prefix$Message" -ForegroundColor Gray }
        default { Write-Host "$prefix$Message" }
    }
}

function Show-MonitorList {
    [CmdletBinding()]
    param([object[]]$Monitors)
    Write-Host 'Monitors detected on this PC (use these numbers for "monitor" in apps.json):'
    foreach ($monitor in $Monitors) {
        $flag = if ($monitor.Primary) { '  (primary)' } else { '' }
        Write-Host ('  {0}: {1}x{2} at ({3},{4}){5}' -f $monitor.Number, $monitor.Bounds.Width, $monitor.Bounds.Height, $monitor.Bounds.X, $monitor.Bounds.Y, $flag)
    }
}

$monitors = @(Get-Monitor)
Show-MonitorList -Monitors $monitors
if ($ListMonitors) { exit 0 }

try {
    $config = Get-LauncherConfig -Path $ConfigPath
}
catch {
    Show-Status 'Error' '' $_.Exception.Message
    exit 2
}

# $script: because the placement results are consumed inside a ForEach-Object script block below.
$script:hadProblem = $false
$script:skipped = 0
$placements = [System.Collections.Generic.List[object]]::new()

Show-Status 'Plain' '' ''
Show-Status 'Plain' '' "Launching $($config.Applications.Count) application(s) from $($config.Path)"
foreach ($app in $config.Applications) {
    $target = Resolve-TargetMonitor -Monitors $monitors -Number $app.Monitor
    if ($null -ne $target -and $target.Number -ne $app.Monitor) {
        Show-Status 'Warning' $app.Name "monitor $($app.Monitor) is not connected (detected: $($monitors.Number -join ', ')); using primary monitor $($target.Number) instead"
        $script:hadProblem = $true
    }

    $result = Start-LauncherApp -App $app @shouldProcess
    # Under -WhatIf a skipped step is already announced by PowerShell's own "What if:" line.
    if ($result.Outcome -ne 'Skipped' -or -not $WhatIfPreference) { Show-Status $result.Severity $result.Name $result.Message }
    if ($result.Severity -in 'Warning', 'Error') { $script:hadProblem = $true }
    if ($result.Outcome -eq 'Skipped') { $script:skipped++ }

    if ($result.Outcome -in 'Launched', 'AlreadyRunning') {
        if ($null -ne $target) {
            $placements.Add([pscustomobject]@{ App = $app; Monitor = $target; WasLaunched = ($result.Outcome -eq 'Launched') })
        }
        else {
            Show-Status 'Info' $app.Name 'no monitor configured; window left where it opens'
        }
    }
}

if ($placements.Count -gt 0) {
    Show-Status 'Plain' '' ''
    Show-Status 'Plain' '' "Positioning windows (waiting up to $WindowTimeoutSeconds seconds for each window to appear)..."
    Invoke-WindowPlacement -Items $placements.ToArray() -Monitors $monitors -TimeoutSeconds $WindowTimeoutSeconds -SettleSeconds $SettleSeconds @shouldProcess |
        ForEach-Object {
            if ($_.Outcome -ne 'Skipped' -or -not $WhatIfPreference) { Show-Status $_.Severity $_.Name $_.Message }
            if ($_.Severity -in 'Warning', 'Error') { $script:hadProblem = $true }
            if ($_.Outcome -eq 'Skipped') { $script:skipped++ }
        }
}

Show-Status 'Plain' '' ''
if ($WhatIfPreference) { Show-Status 'Info' '' 'Nothing was changed (-WhatIf).' }
if ($script:hadProblem) {
    Show-Status 'Warning' '' 'Finished, but with warnings or errors - see above.'
    exit 1
}
if ($WhatIfPreference) { exit 0 }
if ($script:skipped -gt 0) {
    Show-Status 'Info' '' "Finished; $($script:skipped) application(s) skipped at your request."
    exit 0
}
Show-Status 'Success' '' 'All applications are running and positioned.'
exit 0
