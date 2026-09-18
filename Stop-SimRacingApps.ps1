<#
.SYNOPSIS
    Closes every application listed in apps.json, gracefully first and forcefully only if needed.

.DESCRIPTION
    Applications are closed in reverse order of apps.json. Each one first receives a graceful
    close request (its own exit command if apps.json gives one, otherwise the same close message
    the X button sends). Only if it is still running after CloseTimeoutSeconds, or if no close
    request could be delivered at all, is it terminated forcefully.

    Exit codes: 0 = every application closed gracefully or was not running, 1 = at least one
    application had to be terminated forcefully or could not be closed (see the output),
    2 = the configuration could not be loaded and nothing was closed.

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to apps.json next to this script.

.PARAMETER CloseTimeoutSeconds
    How long to give each application to close gracefully before terminating it.

.EXAMPLE
    .\Stop-SimRacingApps.ps1

.EXAMPLE
    .\Stop-SimRacingApps.ps1 -WhatIf
    Shows which applications would be closed without closing them.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [ValidateRange(1, 600)][int]$CloseTimeoutSeconds = 15
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

try {
    $config = Get-LauncherConfig -Path $ConfigPath
}
catch {
    Show-Status 'Error' '' $_.Exception.Message
    exit 2
}

$apps = @($config.Applications)
[array]::Reverse($apps)

$script:hadProblem = $false
$script:skipped = 0
Show-Status 'Plain' '' "Closing $($apps.Count) application(s) from $($config.Path) (reverse launch order, up to $CloseTimeoutSeconds seconds each)"
foreach ($app in $apps) {
    $result = Stop-LauncherApp -App $app -TimeoutSeconds $CloseTimeoutSeconds @shouldProcess
    # Under -WhatIf a skipped step is already announced by PowerShell's own "What if:" line.
    if ($result.Outcome -ne 'Skipped' -or -not $WhatIfPreference) { Show-Status $result.Severity $result.Name $result.Message }
    if ($result.Severity -in 'Warning', 'Error') { $script:hadProblem = $true }
    if ($result.Outcome -eq 'Skipped') { $script:skipped++ }
}

Show-Status 'Plain' '' ''
if ($WhatIfPreference) { Show-Status 'Info' '' 'Nothing was changed (-WhatIf).' }
if ($script:hadProblem) {
    Show-Status 'Warning' '' 'Finished, but not every application closed cleanly - see above.'
    exit 1
}
if ($WhatIfPreference) { exit 0 }
if ($script:skipped -gt 0) {
    Show-Status 'Info' '' "Finished; $($script:skipped) application(s) skipped at your request."
    exit 0
}
Show-Status 'Success' '' 'All applications are closed.'
exit 0
