#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Unit tests for SimRacingLauncher.psm1 (Pester 5/6 syntax).

    Everything that touches the real machine (processes, windows, monitors) is mocked inside the
    module, so these tests never launch, move or close anything. Real-time waits use short
    timeouts (a second or less) rather than a mocked clock. Mocks placed inside the module
    (-ModuleName) can read this file's $script: variables, which the sequence mocks rely on.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-Test* helpers build test doubles (in memory, or a throw-away file under TestDrive).')]
param()

BeforeAll {
    $script:ModuleName = 'SimRacingLauncher'
    Import-Module (Join-Path $PSScriptRoot '..\SimRacingLauncher.psm1') -Force

    # Test-double factories -----------------------------------------------------------------

    function New-TestMonitor {
        param([int]$Number, [int]$X, [bool]$Primary = $false)
        [pscustomobject]@{
            Number      = $Number
            DeviceName  = "\\.\DISPLAY$Number"
            Primary     = $Primary
            Bounds      = [System.Drawing.Rectangle]::new($X, 0, 2560, 1440)
            WorkingArea = [System.Drawing.Rectangle]::new($X, 0, 2560, 1392)
        }
    }

    function New-TestApp {
        param(
            [string]$Name = 'App',
            [string]$Path = 'C:\Apps\App.exe',
            [string]$Arguments = '',
            [string]$ExitArguments = '',
            [string]$WindowTitle = '',
            $Monitor = 4
        )
        [pscustomobject]@{
            Name          = $Name
            Path          = $Path
            Arguments     = $Arguments
            ExitArguments = $ExitArguments
            WindowTitle   = $WindowTitle
            Monitor       = $Monitor
            ProcessName   = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        }
    }

    function New-TestProcess {
        param([string]$ProcessName, [int]$Id = 100)
        [pscustomobject]@{ ProcessName = $ProcessName; Id = $Id }
    }

    function New-TestWindow {
        param([int]$Handle = 1000, [string]$Title = 'Window')
        [pscustomobject]@{ Handle = [IntPtr]$Handle; Title = $Title }
    }

    function New-TestConfigFile {
        param([string]$Json)
        $file = Join-Path $TestDrive ('apps-{0}.json' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($file, $Json, [System.Text.UTF8Encoding]::new($false))   # BOM-less UTF-8, like most editors
        return $file
    }

    function New-Win32Error {
        # 5 = access denied (UIPI / elevation), 1400 = invalid window handle (window already closed).
        param([int]$Code)
        [System.ComponentModel.Win32Exception]::new($Code)
    }

    $script:Monitors = @(
        (New-TestMonitor -Number 1 -X 2560),
        (New-TestMonitor -Number 2 -X 0 -Primary $true),
        (New-TestMonitor -Number 3 -X -2560)
    )
}

Describe 'Get-LauncherConfig' {
    Context 'valid configuration' {
        It 'parses every field, expands environment variables and derives the process name' {
            $file = New-TestConfigFile @'
{ "applications": [
  { "name": " SimHub ", "path": "C:\\Program Files (x86)\\SimHub\\SimHubWPF.exe", "arguments": "-x", "exitArguments": "-exit", "windowTitle": "SimHub*", "monitor": 4 },
  { "name": "RaceLab", "path": "%TEMP%\\racelab\\RacelabApps.exe" }
] }
'@
            $config = Get-LauncherConfig -Path $file
            $config.Path | Should -Be $file
            $config.Applications | Should -HaveCount 2

            $simhub = $config.Applications[0]
            $simhub.Name | Should -Be 'SimHub'
            $simhub.Path | Should -Be 'C:\Program Files (x86)\SimHub\SimHubWPF.exe'
            $simhub.ProcessName | Should -Be 'SimHubWPF'
            $simhub.Arguments | Should -Be '-x'
            $simhub.ExitArguments | Should -Be '-exit'
            $simhub.WindowTitle | Should -Be 'SimHub*'
            $simhub.Monitor | Should -Be 4
            $simhub.Monitor | Should -BeOfType [int]

            $racelab = $config.Applications[1]
            $racelab.Path | Should -Be (Join-Path $env:TEMP 'racelab\RacelabApps.exe')
            $racelab.Monitor | Should -BeNullOrEmpty
            $racelab.Arguments | Should -Be ''
            $racelab.ExitArguments | Should -Be ''
            $racelab.WindowTitle | Should -Be ''
        }

        It 'accepts a single-application configuration (one-element JSON arrays are easy to lose in PowerShell)' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "Only", "path": "C:\\a\\Only.exe", "monitor": 2 } ] }'
            $config = Get-LauncherConfig -Path $file
            $config.Applications | Should -HaveCount 1
            $config.Applications[0].Monitor | Should -Be 2
        }

        It 'reads BOM-less UTF-8 correctly (non-ASCII names and paths)' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "Café", "path": "C:\\Jeux\\Éditeur\\App.exe" } ] }'
            $app = (Get-LauncherConfig -Path $file).Applications[0]
            $app.Name | Should -Be 'Café'
            $app.Path | Should -Be 'C:\Jeux\Éditeur\App.exe'
        }

        It 'loads the shipped apps.json' {
            $config = Get-LauncherConfig -Path (Join-Path $PSScriptRoot '..\apps.json')
            $config.Applications.Name | Should -Be @('MOZA Pit House', 'SimHub', 'RaceLab', 'iRacing UI')
            $config.Applications.Monitor | Should -Be @(3, 3, 3, 3)
        }
    }

    Context 'file problems' {
        It 'reports a missing file with its path' {
            { Get-LauncherConfig -Path 'C:\does\not\exist.json' } | Should -Throw -ExpectedMessage '*not found*C:\does\not\exist.json*'
        }

        It 'reports invalid JSON' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "A", '
            { Get-LauncherConfig -Path $file } | Should -Throw -ExpectedMessage '*not valid JSON*'
        }

        It 'requires a non-empty applications array' {
            foreach ($json in '{}', '{ "applications": [] }', '{ "applications": "SimHub" }') {
                $file = New-TestConfigFile $json
                { Get-LauncherConfig -Path $file } | Should -Throw -ExpectedMessage '*"applications" must be a non-empty array*'
            }
        }
    }

    Context 'entry problems' {
        It 'requires name and path' {
            $file = New-TestConfigFile '{ "applications": [ { "monitor": 4 } ] }'
            $message = ({ Get-LauncherConfig -Path $file } | Should -Throw -PassThru).Exception.Message
            $message | Should -Match 'applications\[0\]: "name" is required'
            $message | Should -Match 'applications\[0\]: "path" is required'
        }

        It 'rejects a relative path, a shortcut, and invalid characters' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "A", "path": "SimHub\\SimHubWPF.exe" }, { "name": "B", "path": "C:\\x\\B.lnk" }, { "name": "C", "path": "C:\\x\\C|.exe" } ] }'
            $message = ({ Get-LauncherConfig -Path $file } | Should -Throw -PassThru).Exception.Message
            $message | Should -Match '"A": "path" must be a full path'
            $message | Should -Match '"B": "path" must point to an \.exe file'
            $message | Should -Match '"C": "path" contains characters that are not allowed'
        }

        It 'points out an environment variable that is not defined on this PC' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "A", "path": "%SIMRIG_NO_SUCH_VAR%\\App.exe" } ] }'
            { Get-LauncherConfig -Path $file } | Should -Throw -ExpectedMessage '*an environment variable in it is not defined on this PC*'
        }

        It 'rejects a monitor that is not a whole number of 1 or more' {
            foreach ($value in '0', '-1', '"4"', '2.5', 'true') {
                $file = New-TestConfigFile ('{ "applications": [ { "name": "A", "path": "C:\\a\\A.exe", "monitor": ' + $value + ' } ] }')
                { Get-LauncherConfig -Path $file } | Should -Throw -ExpectedMessage '*"A": "monitor" must be a whole number of 1 or more*'
            }
        }

        It 'treats a null monitor like a missing one (no placement)' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "A", "path": "C:\\a\\A.exe", "monitor": null } ] }'
            (Get-LauncherConfig -Path $file).Applications[0].Monitor | Should -BeNullOrEmpty
        }

        It 'rejects non-string arguments, exitArguments and windowTitle' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "A", "path": "C:\\a\\A.exe", "arguments": 1, "exitArguments": true, "windowTitle": 5 } ] }'
            $message = ({ Get-LauncherConfig -Path $file } | Should -Throw -PassThru).Exception.Message
            $message | Should -Match '"arguments" must be a string'
            $message | Should -Match '"exitArguments" must be a string'
            $message | Should -Match '"windowTitle" must be a string'
        }

        It 'rejects duplicate names and two entries with the same executable name' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "simhub", "path": "C:\\a\\SimHubWPF.exe" }, { "name": "SimHub", "path": "C:\\b\\SimHubWPF.exe" } ] }'
            $message = ({ Get-LauncherConfig -Path $file } | Should -Throw -PassThru).Exception.Message
            $message | Should -Match 'Duplicate application name: "simhub" appears 2 times'
            $message | Should -Match 'both use the executable SimHubWPF.exe'
        }

        It 'reports every problem in one go, with the file path' {
            $file = New-TestConfigFile '{ "applications": [ { "name": "", "path": "" }, { "name": "B", "path": "C:\\b\\B.exe", "monitor": 0 } ] }'
            $message = ({ Get-LauncherConfig -Path $file } | Should -Throw -PassThru).Exception.Message
            $message | Should -Match ([regex]::Escape($file))
            ($message -split "`n" | Where-Object { $_ -like '  - *' }) | Should -HaveCount 3
        }
    }
}

Describe 'Monitors' {
    It 'Get-Monitor numbers monitors from their device name and sorts them' {
        $monitors = @(Get-Monitor)
        $monitors.Count | Should -BeGreaterThan 0
        $monitors.Number | Should -Be ($monitors.Number | Sort-Object)
        foreach ($monitor in $monitors) { $monitor.DeviceName | Should -Be "\\.\DISPLAY$($monitor.Number)" }
        @($monitors | Where-Object Primary) | Should -HaveCount 1
    }

    It 'Resolve-TargetMonitor returns the configured monitor when it is connected' {
        (Resolve-TargetMonitor -Monitors $script:Monitors -Number 3).Number | Should -Be 3
    }

    It 'Resolve-TargetMonitor falls back to the primary monitor when the configured one is not connected' {
        $target = Resolve-TargetMonitor -Monitors $script:Monitors -Number 4
        $target.Number | Should -Be 2
        $target.Primary | Should -BeTrue
    }

    It 'Resolve-TargetMonitor returns nothing when no monitor is configured' {
        Resolve-TargetMonitor -Monitors $script:Monitors -Number $null | Should -BeNullOrEmpty
    }
}

Describe 'Process and window lookup' {
    It 'Get-AppProcess asks for the exact name, with wildcard characters escaped' {
        Mock -ModuleName $script:ModuleName Get-Process { @() }
        $null = Get-AppProcess -ProcessName 'App [x]'
        Should -Invoke -ModuleName $script:ModuleName Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq 'App `[x`]' }
    }

    It 'Get-AppWindow returns nothing when the application is not running' {
        Mock -ModuleName $script:ModuleName Get-AppProcess { @() }
        Get-AppWindow -ProcessName 'App' | Should -BeNullOrEmpty
    }
}

Describe 'Win32 error codes (real calls on a handle that does not exist)' {
    # These are deliberately NOT mocked: the error code must be read right after the P/Invoke, and
    # only a real call proves that nothing in between overwrites it.
    It 'Get-WindowRectangle reports "invalid window handle" (1400) for a dead handle' {
        InModuleScope $script:ModuleName {
            $failure = { Get-WindowRectangle -WindowHandle ([IntPtr]0x7FFF0001) } | Should -Throw -PassThru
            $failure.Exception | Should -BeOfType [System.ComponentModel.Win32Exception]
            $failure.Exception.NativeErrorCode | Should -Be 1400
        }
    }

    It 'Send-WindowClose reports "invalid window handle" (1400) for a dead handle' {
        InModuleScope $script:ModuleName {
            $failure = { Send-WindowClose -WindowHandle ([IntPtr]0x7FFF0001) } | Should -Throw -PassThru
            $failure.Exception.NativeErrorCode | Should -Be 1400
        }
    }

    It 'Move-WindowToMonitor reports "invalid window handle" (1400) for a dead handle' {
        InModuleScope $script:ModuleName -Parameters @{ Monitors = $script:Monitors } {
            $failure = { Move-WindowToMonitor -WindowHandle ([IntPtr]0x7FFF0001) -Monitor $Monitors[0] -Monitors $Monitors } | Should -Throw -PassThru
            $failure.Exception.NativeErrorCode | Should -Be 1400
        }
    }
}

Describe 'Get-PlacementRectangle (pure geometry)' {
    It 'keeps the size and the position relative to the current monitor' {
        InModuleScope $script:ModuleName -Parameters @{ Monitors = $script:Monitors } {
            $window = [System.Drawing.Rectangle]::new(-2560 + 300, 200, 1600, 1000)     # on monitor 3, offset (300,200)
            $placement = Get-PlacementRectangle -WindowRectangle $window -TargetMonitor $Monitors[0] -Monitors $Monitors
            $placement | Should -Be ([System.Drawing.Rectangle]::new(2560 + 300, 200, 1600, 1000))
        }
    }

    It 'shrinks a window that is larger than the target work area and keeps it fully on screen' {
        InModuleScope $script:ModuleName -Parameters @{ Monitors = $script:Monitors } {
            $window = [System.Drawing.Rectangle]::new(2000, 1000, 3000, 2000)           # bottom-right of monitor 2, oversized
            $placement = Get-PlacementRectangle -WindowRectangle $window -TargetMonitor $Monitors[2] -Monitors $Monitors
            $placement | Should -Be ([System.Drawing.Rectangle]::new(-2560, 0, 2560, 1392))
        }
    }

    It 'puts a window that is off every screen at the top-left of the target' {
        InModuleScope $script:ModuleName -Parameters @{ Monitors = $script:Monitors } {
            $window = [System.Drawing.Rectangle]::new(9000, 9000, 800, 600)             # saved on a monitor that is gone
            $placement = Get-PlacementRectangle -WindowRectangle $window -TargetMonitor $Monitors[1] -Monitors $Monitors
            $placement | Should -Be ([System.Drawing.Rectangle]::new(0, 0, 800, 600))
        }
    }
}

Describe 'Start-LauncherApp' {
    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-AppProcess { @() }
        Mock -ModuleName $script:ModuleName Test-Path { $true }
        Mock -ModuleName $script:ModuleName Start-Process { }
    }

    It 'launches with the executable folder as working directory and no ArgumentList when there are no arguments' {
        $result = Start-LauncherApp -App (New-TestApp -Path 'C:\Apps\App.exe')
        $result.Outcome | Should -Be 'Launched'
        $result.Severity | Should -Be 'Success'
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Apps\App.exe' -and $WorkingDirectory -eq 'C:\Apps' -and -not $PesterBoundParameters.ContainsKey('ArgumentList')
        }
    }

    It 'tells Electron applications not to attach to this console before launching' {
        $saved = $env:ELECTRON_NO_ATTACH_CONSOLE
        try {
            Remove-Item Env:\ELECTRON_NO_ATTACH_CONSOLE -ErrorAction SilentlyContinue
            $null = Start-LauncherApp -App (New-TestApp)
            $env:ELECTRON_NO_ATTACH_CONSOLE | Should -Be '1'
        }
        finally { $env:ELECTRON_NO_ATTACH_CONSOLE = $saved }
    }

    It 'passes configured arguments' {
        $null = Start-LauncherApp -App (New-TestApp -Arguments '-minimized')
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -eq '-minimized' }
    }

    It 'does not launch an application that is already running (idempotent)' {
        Mock -ModuleName $script:ModuleName Get-AppProcess { @(New-TestProcess 'App') }
        $result = Start-LauncherApp -App (New-TestApp)
        $result.Outcome | Should -Be 'AlreadyRunning'
        $result.Message | Should -Be 'already running'
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 0
    }

    It 'reports a missing executable with the path and continues without launching' {
        Mock -ModuleName $script:ModuleName Test-Path { $false }
        $result = Start-LauncherApp -App (New-TestApp -Path 'C:\Apps\Missing.exe')
        $result.Outcome | Should -Be 'NotFound'
        $result.Severity | Should -Be 'Error'
        $result.Message | Should -Be 'executable not found: C:\Apps\Missing.exe (check "path" in apps.json)'
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 0
    }

    It 'reports a launch failure with the underlying reason' {
        Mock -ModuleName $script:ModuleName Start-Process { throw 'The operation was canceled by the user.' }
        $result = Start-LauncherApp -App (New-TestApp)
        $result.Outcome | Should -Be 'LaunchFailed'
        $result.Severity | Should -Be 'Error'
        $result.Message | Should -Be 'failed to start: The operation was canceled by the user.'
    }

    It 'skips the launch under -WhatIf' {
        $result = Start-LauncherApp -App (New-TestApp) -WhatIf
        $result.Outcome | Should -Be 'Skipped'
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 0
    }
}

Describe 'Invoke-WindowPlacement' {
    BeforeAll {
        function Invoke-Placement {
            param($App = (New-TestApp), [bool]$WasLaunched = $true, [int]$Timeout = 1, [int]$Settle = 0)
            $item = [pscustomobject]@{ App = $App; Monitor = $script:target; WasLaunched = $WasLaunched }
            @(Invoke-WindowPlacement -Items @($item) -Monitors $script:Monitors -TimeoutSeconds $Timeout -SettleSeconds $Settle -ExitGraceSeconds 1)
        }
    }

    BeforeEach {
        Mock -ModuleName $script:ModuleName Start-Sleep { }
        Mock -ModuleName $script:ModuleName Get-AppProcess { @(New-TestProcess 'App') }
        Mock -ModuleName $script:ModuleName Get-AppWindow { New-TestWindow }
        Mock -ModuleName $script:ModuleName Test-WindowMinimized { $false }
        # Windows start on monitor 3; a window that has been moved reports the target monitor afterwards.
        Mock -ModuleName $script:ModuleName Get-WindowMonitor { if ($script:moved -contains $WindowHandle) { $script:target } else { $script:Monitors[2] } }
        Mock -ModuleName $script:ModuleName Move-WindowToMonitor { $script:moved.Add($WindowHandle); $true }
        $script:target = $script:Monitors[0]                                          # monitor 1
        $script:moved = [System.Collections.Generic.List[IntPtr]]::new()
        $script:calls = 0
    }

    It 'moves a launched window to the target monitor once it appears' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $script:calls++; if ($script:calls -lt 3) { $null } else { New-TestWindow } }
        $results = Invoke-Placement
        $results | Should -HaveCount 1
        $results[0].Outcome | Should -Be 'Placed'
        $results[0].Message | Should -Be 'window placed on monitor 1'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 1 -Exactly -ParameterFilter { $Monitor.Number -eq 1 -and $WindowHandle -eq [IntPtr]1000 }
    }

    It 'passes the configured window title to the window lookup' {
        $null = Invoke-Placement -App (New-TestApp -WindowTitle 'Racelab*')
        Should -Invoke -ModuleName $script:ModuleName Get-AppWindow -ParameterFilter { $WindowTitle -eq 'Racelab*' }
    }

    It 'does not move a window that is already on the target monitor' {
        Mock -ModuleName $script:ModuleName Get-WindowMonitor { $script:target }
        $results = Invoke-Placement -WasLaunched $false
        $results[0].Outcome | Should -Be 'AlreadyOnMonitor'
        $results[0].Message | Should -Be 'window already on monitor 1'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 0
    }

    It 'moves an already-running window that is on the wrong monitor (design decision: idempotent placement)' {
        $results = Invoke-Placement -WasLaunched $false
        $results[0].Outcome | Should -Be 'Placed'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 1 -Exactly
    }

    It 'leaves a minimized window alone' {
        Mock -ModuleName $script:ModuleName Test-WindowMinimized { $true }
        $results = Invoke-Placement -WasLaunched $false
        $results[0].Outcome | Should -Be 'Minimized'
        $results[0].Message | Should -Be 'window is minimized; left where it is'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 0
    }

    It 'gives up with a warning when no window appears within the timeout (application hangs)' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $null }
        $results = Invoke-Placement -Timeout 1
        $results | Should -HaveCount 1
        $results[0].Outcome | Should -Be 'NoWindow'
        $results[0].Severity | Should -Be 'Warning'
        $results[0].Message | Should -Be 'no window appeared within 1 seconds; not positioned (still loading, started minimized to the tray, or failed silently?)'
    }

    It 'reports immediately when an already-running application has no visible window (tray)' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $null }
        $results = Invoke-Placement -WasLaunched $false -Timeout 30
        $results[0].Outcome | Should -Be 'NoWindow'
        $results[0].Message | Should -Be 'is running but has no visible window; not positioned (minimized to the tray?)'
    }

    It 'reports a launched process that exits before showing a window' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $null }
        Mock -ModuleName $script:ModuleName Get-AppProcess { @() }
        $results = Invoke-Placement -Timeout 30
        $results[0].Outcome | Should -Be 'Exited'
        $results[0].Severity | Should -Be 'Error'
        $results[0].Message | Should -Be 'process exited before showing a window (did it crash?)'
    }

    It 'reports a launched process that exits after its window was positioned' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $script:calls++; if ($script:calls -eq 1) { New-TestWindow } else { $null } }
        Mock -ModuleName $script:ModuleName Get-AppProcess { if ($script:calls -eq 1) { @(New-TestProcess 'App') } else { @() } }
        $results = Invoke-Placement -Timeout 30 -Settle 5
        $results[0].Outcome | Should -Be 'Placed'
        $results[1].Outcome | Should -Be 'Exited'
        $results[1].Message | Should -Be 'process exited after its window was positioned (did it crash?)'
    }

    It 'keeps polling when the window closes between finding it and using it (splash screen race)' {
        Mock -ModuleName $script:ModuleName Get-WindowMonitor { $script:calls++; if ($script:calls -eq 1) { throw (New-Win32Error 1400) } else { $script:Monitors[2] } }
        $results = Invoke-Placement
        $results | Should -HaveCount 1
        $results[0].Outcome | Should -Be 'Placed'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 1 -Exactly
    }

    It 'treats a move that fails because the window just closed as the same race, not as a failure' {
        Mock -ModuleName $script:ModuleName Move-WindowToMonitor { $script:calls++; if ($script:calls -eq 1) { throw (New-Win32Error 1400) } else { $true } }
        $results = Invoke-Placement
        $results | Should -HaveCount 1
        $results[0].Outcome | Should -Be 'Placed'
    }

    It 'warns when the positioned window closes and nothing replaces it within the settle period' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $script:calls++; if ($script:calls -eq 1) { New-TestWindow } else { $null } }
        $results = Invoke-Placement -Timeout 30 -Settle 1
        $results[0].Outcome | Should -Be 'Placed'
        $results[1].Outcome | Should -Be 'WindowGone'
        $results[1].Severity | Should -Be 'Warning'
        $results[1].Message | Should -Be 'the window that was positioned has closed and no new window appeared within 1 seconds; if the application opens elsewhere, run with a longer -SettleSeconds'
    }

    It 'restarts the settle period when the placed window disappears, so a late replacement is still placed' {
        # Real 100 ms polls. Placement at ~0 s; window present until ~0.5 s; gone from ~0.5 s to ~1.1 s; replacement after.
        # With a 1 s settle: counting from the placement would give up at ~1.0 s (a false "window gone");
        # counting from the disappearance keeps waiting and places the replacement.
        Mock -ModuleName $script:ModuleName Start-Sleep { [System.Threading.Thread]::Sleep(100) }
        Mock -ModuleName $script:ModuleName Get-AppWindow { $script:calls++; if ($script:calls -le 5) { New-TestWindow -Handle 1000 } elseif ($script:calls -le 11) { $null } else { New-TestWindow -Handle 2000 } }
        $results = Invoke-Placement -Timeout 30 -Settle 1
        $results.Outcome | Should -Not -Contain 'WindowGone'
        $results | Should -HaveCount 2
        $results[1].Message | Should -Be 'window moved to monitor 1 again (a new window appeared, or the application had repositioned it)'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 1 -Exactly -ParameterFilter { $WindowHandle -eq [IntPtr]2000 }
    }

    It 'places the window that replaces a splash screen' {
        # 1: splash (handle 1000, wrong monitor) -> placed; 2: nothing; 3+: real window (handle 2000, wrong monitor) -> placed.
        Mock -ModuleName $script:ModuleName Get-AppWindow { $script:calls++; if ($script:calls -eq 1) { New-TestWindow -Handle 1000 } elseif ($script:calls -eq 2) { $null } else { New-TestWindow -Handle 2000 } }
        $results = Invoke-Placement -Timeout 30 -Settle 1
        $results[0].Message | Should -Be 'window placed on monitor 1'
        $results[1].Message | Should -Be 'window moved to monitor 1 again (a new window appeared, or the application had repositioned it)'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 1 -Exactly -ParameterFilter { $WindowHandle -eq [IntPtr]2000 }
    }

    It 'reports an access-denied move with the launcher-specific hint and moves on' {
        Mock -ModuleName $script:ModuleName Move-WindowToMonitor { throw (New-Win32Error 5) }
        $results = Invoke-Placement
        $results[0].Outcome | Should -Be 'MoveFailed'
        $results[0].Severity | Should -Be 'Error'
        $results[0].Message | Should -BeLike 'could not move window to monitor 1: Access is denied*let this launcher start it normally, or move the window by hand.'
        $results[0].Message | Should -Not -BeLike '*run this*as Administrator*'
    }

    It 'reports any other move failure without the elevation hint' {
        Mock -ModuleName $script:ModuleName Move-WindowToMonitor { throw (New-Win32Error 1401) }
        $results = Invoke-Placement
        $results[0].Outcome | Should -Be 'MoveFailed'
        $results[0].Message | Should -Not -BeLike '*Administrator*'
    }

    It 'warns when the application rejects the move' {
        Mock -ModuleName $script:ModuleName Move-WindowToMonitor { $false }
        $results = Invoke-Placement
        $results[0].Outcome | Should -Be 'MoveNotApplied'
        $results[0].Severity | Should -Be 'Warning'
    }

    It 'moves the window back if the application repositions it during the settle period' {
        # 1st look: wrong monitor -> move; 2nd look: wrong again (app moved itself back) -> move again; then right.
        Mock -ModuleName $script:ModuleName Get-WindowMonitor { $script:calls++; if ($script:calls -le 2) { $script:Monitors[2] } else { $script:target } }
        $results = Invoke-Placement -Settle 1
        $results[0].Outcome | Should -Be 'Placed'
        $results[1].Message | Should -Be 'window moved to monitor 1 again (a new window appeared, or the application had repositioned it)'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 2 -Exactly
    }

    It 'gives up with a warning on an application that keeps moving its window back' {
        Mock -ModuleName $script:ModuleName Get-WindowMonitor { $script:Monitors[2] }   # always "wrong": the app fights back forever
        $results = Invoke-Placement -Timeout 30 -Settle 10
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 3 -Exactly
        $results[-1].Outcome | Should -Be 'MoveNotApplied'
        $results[-1].Message | Should -Be 'window keeps leaving monitor 1 after being moved there 3 times (the application enforces its own position); left where it is'
    }

    It 'skips the move under -WhatIf' {
        $item = [pscustomobject]@{ App = (New-TestApp); Monitor = $script:target; WasLaunched = $false }
        $results = @(Invoke-WindowPlacement -Items @($item) -Monitors $script:Monitors -WhatIf)
        $results[0].Outcome | Should -Be 'Skipped'
        Should -Invoke -ModuleName $script:ModuleName Move-WindowToMonitor -Times 0
    }
}

Describe 'Stop-LauncherApp' {
    BeforeEach {
        Mock -ModuleName $script:ModuleName Start-Sleep { }
        Mock -ModuleName $script:ModuleName Start-Process { }
        Mock -ModuleName $script:ModuleName Stop-Process { }
        Mock -ModuleName $script:ModuleName Send-WindowClose { }
        Mock -ModuleName $script:ModuleName Get-AppWindow { New-TestWindow }
        $script:running = $true
        Mock -ModuleName $script:ModuleName Get-AppProcess { if ($script:running) { @((New-TestProcess 'App' 11), (New-TestProcess 'App' 12)) } else { @() } }
    }

    It 'reports an application that is not running and touches nothing' {
        $script:running = $false
        $result = Stop-LauncherApp -App (New-TestApp)
        $result.Outcome | Should -Be 'NotRunning'
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 0
        Should -Invoke -ModuleName $script:ModuleName Stop-Process -Times 0
    }

    It 'closes gracefully through the main window and never terminates when that works' {
        Mock -ModuleName $script:ModuleName Send-WindowClose { $script:running = $false }
        $result = Stop-LauncherApp -App (New-TestApp -WindowTitle 'App*') -TimeoutSeconds 1
        $result.Outcome | Should -Be 'ClosedGracefully'
        $result.Message | Should -Be 'closed'
        Should -Invoke -ModuleName $script:ModuleName Get-AppWindow -ParameterFilter { $WindowTitle -eq 'App*' }
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 1 -Exactly -ParameterFilter { $WindowHandle -eq [IntPtr]1000 }
        Should -Invoke -ModuleName $script:ModuleName Stop-Process -Times 0
    }

    It "uses the application's own exit command when one is configured" {
        Mock -ModuleName $script:ModuleName Start-Process { $script:running = $false }
        $result = Stop-LauncherApp -App (New-TestApp -Path 'C:\Apps\SimHubWPF.exe' -ExitArguments '-exit') -TimeoutSeconds 1
        $result.Outcome | Should -Be 'ClosedGracefully'
        Should -Invoke -ModuleName $script:ModuleName Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\Apps\SimHubWPF.exe' -and $ArgumentList -eq '-exit' -and $WorkingDirectory -eq 'C:\Apps' }
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 0
        Should -Invoke -ModuleName $script:ModuleName Stop-Process -Times 0
    }

    It 'falls back to a close message when the exit command cannot run' {
        Mock -ModuleName $script:ModuleName Start-Process { throw 'The system cannot find the file specified.' }
        Mock -ModuleName $script:ModuleName Send-WindowClose { $script:running = $false }
        $result = Stop-LauncherApp -App (New-TestApp -ExitArguments '-exit') -TimeoutSeconds 1
        $result.Outcome | Should -Be 'ClosedGracefully'
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 1 -Exactly
    }

    It 'terminates every process of the application only after the graceful timeout' {
        Mock -ModuleName $script:ModuleName Stop-Process { $script:running = $false }
        $result = Stop-LauncherApp -App (New-TestApp) -TimeoutSeconds 1
        $result.Outcome | Should -Be 'ForceClosed'
        $result.Severity | Should -Be 'Warning'
        $result.Message | Should -Be 'did not close within 1 seconds; terminated forcefully'
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName Stop-Process -Times 2 -Exactly -ParameterFilter { $Force -eq $true -and $Confirm -eq $false }
    }

    It 'goes straight to termination when there is no window to ask (tray application)' {
        Mock -ModuleName $script:ModuleName Get-AppWindow { $null }
        Mock -ModuleName $script:ModuleName Stop-Process { $script:running = $false }
        $result = Stop-LauncherApp -App (New-TestApp) -TimeoutSeconds 30
        $result.Outcome | Should -Be 'ForceClosed'
        $result.Message | Should -Be 'has no visible window to send a close request to (minimized to the tray?); terminated forcefully'
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 0
    }

    It 'reports a final failure with the closer-specific hint when even termination is refused, and continues' {
        Mock -ModuleName $script:ModuleName Send-WindowClose { throw (New-Win32Error 5) }
        Mock -ModuleName $script:ModuleName Stop-Process { throw (New-Win32Error 5) }
        $result = Stop-LauncherApp -App (New-TestApp) -TimeoutSeconds 1 -KillTimeoutSeconds 1
        $result.Outcome | Should -Be 'CloseFailed'
        $result.Severity | Should -Be 'Error'
        $result.Message | Should -BeLike 'could not be closed, even forcefully (the close request was refused - Access is denied). Access is denied. It appears to be running as Administrator*run this closer as Administrator.'
    }

    It 'reports a final failure without the hint when the cause is something else' {
        Mock -ModuleName $script:ModuleName Stop-Process { throw 'Boom' }
        $result = Stop-LauncherApp -App (New-TestApp) -TimeoutSeconds 1 -KillTimeoutSeconds 1
        $result.Outcome | Should -Be 'CloseFailed'
        $result.Message | Should -Be 'could not be closed, even forcefully (did not close within 1 seconds). Boom. Close it manually.'
    }

    It 'skips the close under -WhatIf' {
        $result = Stop-LauncherApp -App (New-TestApp) -WhatIf
        $result.Outcome | Should -Be 'Skipped'
        Should -Invoke -ModuleName $script:ModuleName Send-WindowClose -Times 0
        Should -Invoke -ModuleName $script:ModuleName Stop-Process -Times 0
    }
}

Describe 'Scripts (real processes, read-only modes only)' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:Launcher = Join-Path $script:Root 'Start-SimRacingApps.ps1'
        $script:Closer = Join-Path $script:Root 'Stop-SimRacingApps.ps1'
    }

    It 'both scripts exit with code 2 and launch nothing when the configuration is broken' {
        $broken = New-TestConfigFile '{ "applications": [] }'
        foreach ($scriptPath in $script:Launcher, $script:Closer) {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $broken 2>&1
            $LASTEXITCODE | Should -Be 2
            ($output -join "`n") | Should -Match '"applications" must be a non-empty array'
        }
    }

    It 'the launcher lists monitors and exits 0 with -ListMonitors' {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Launcher -ListMonitors 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match '\(primary\)'
    }

    It 'the closer processes applications in reverse configuration order' {
        # Neither executable exists as a running process, so the closer only reports "not running" - safe.
        $config = New-TestConfigFile '{ "applications": [ { "name": "ZzzFirst", "path": "C:\\x\\ZzzFirst.exe" }, { "name": "ZzzSecond", "path": "C:\\x\\ZzzSecond.exe" } ] }'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Closer -ConfigPath $config -WhatIf 2>&1)
        $LASTEXITCODE | Should -Be 0
        $lines = @($output | Where-Object { $_ -like '`[Zzz*' })
        $lines | Should -HaveCount 2
        $lines[0] | Should -BeLike '`[ZzzSecond`] not running'
        $lines[1] | Should -BeLike '`[ZzzFirst`] not running'
    }

    It 'both scripts say that nothing was changed under -WhatIf' {
        # A real executable that exists but is not running: -WhatIf must describe the launch without doing it.
        $config = New-TestConfigFile '{ "applications": [ { "name": "Character Map", "path": "%SystemRoot%\\System32\\charmap.exe" } ] }'
        foreach ($scriptPath in $script:Launcher, $script:Closer) {
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $config -WhatIf 2>&1)
            ($output -join "`n") | Should -Match 'Nothing was changed'
            ($output -join "`n") | Should -Not -Match 'All applications are'
        }
    }
}
