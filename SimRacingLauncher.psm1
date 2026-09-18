#Requires -Version 5.1
<#
    Engine shared by Start-SimRacingApps.ps1 and Stop-SimRacingApps.ps1.

    Loads and validates apps.json, enumerates monitors, launches applications, waits for their
    windows and moves them to the configured monitor, and closes applications gracefully before
    falling back to forceful termination.

    Every engine function returns plain result objects (Name, Outcome, Severity, Message). The two
    scripts do all console output, which keeps this module quiet and unit-testable. Private helpers
    of a few lines deliberately skip comment-based help; every exported function has it.
#>

Set-StrictMode -Version Latest

#region Win32 interop

# Only what .NET does not already expose is declared here. Monitor enumeration
# uses System.Windows.Forms.Screen, a managed wrapper over EnumDisplayMonitors.
if (-not ('SimRacingLauncher.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace SimRacingLauncher
{
    public sealed class WindowInfo
    {
        public IntPtr Handle;
        public string Title;
    }

    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        public const uint SWP_NOZORDER   = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const int  SW_MAXIMIZE    = 3;
        public const int  SW_RESTORE     = 9;
        public const uint WM_CLOSE       = 0x0010;
        public const int  ERROR_ACCESS_DENIED = 5;
        public const int  ERROR_INVALID_WINDOW_HANDLE = 1400;
        private const uint GW_OWNER      = 4;
        private static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        // The visible, unowned top-level windows belonging to any of the processes, front to back.
        // Without a title filter the first one is exactly what .NET's Process.MainWindowHandle returns;
        // the list is needed because overlay layers (RaceLab, SimHub dashboards) can come first.
        public static List<WindowInfo> GetTopLevelWindows(int[] processIds)
        {
            var ids = new HashSet<int>(processIds);
            var windows = new List<WindowInfo>();
            EnumWindows((hWnd, lParam) =>
            {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (!ids.Contains((int)pid) || !IsWindowVisible(hWnd) || GetWindow(hWnd, GW_OWNER) != IntPtr.Zero)
                {
                    return true;
                }
                var title = new StringBuilder(512);
                GetWindowText(hWnd, title, title.Capacity);
                windows.Add(new WindowInfo { Handle = hWnd, Title = title.ToString() });
                return true;
            }, IntPtr.Zero);
            return windows;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsZoomed(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        // Per-monitor awareness makes every coordinate a physical pixel on every monitor, whatever
        // its scaling; the older system-DPI call is the fallback for Windows before 10 (1703).
        public static void MakeProcessDpiAware()
        {
            try { if (SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) { return; } }
            catch (EntryPointNotFoundException) { }
            SetProcessDPIAware();
        }
    }
}
'@
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# powershell.exe is not DPI-aware. On displays scaled above 100% Windows hands a DPI-unaware
# process scaled-down monitor and window coordinates, so the sizes shown to the user would not
# match Display Settings. This must run before Screen is first read.
[SimRacingLauncher.NativeMethods]::MakeProcessDpiAware()

#endregion

#region Results and shared helpers

# Windows (UIPI) refuses window messages and process termination across an integrity boundary.
# The remedies differ: running the launcher elevated would make every app it launches elevated.
$script:MoveElevationHint = 'It appears to be running as Administrator while this script is not, so Windows blocks the request. Close it, let this launcher start it normally, or move the window by hand.'
$script:CloseElevationHint = 'It appears to be running as Administrator while this script is not, so Windows blocks the request. Close it manually, or run this closer as Administrator.'

function New-Result {
    # Positional by design: every call site is (name, outcome, severity, message), see PSScriptAnalyzerSettings.psd1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory result object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$Outcome,
        [Parameter(Position = 2)][ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Severity,
        [Parameter(Position = 3)][string]$Message
    )
    [pscustomobject]@{ Name = $Name; Outcome = $Outcome; Severity = $Severity; Message = $Message }
}

# Every failing P/Invoke below is followed IMMEDIATELY by Marshal.GetLastWin32Error() in the same
# function: invoking any command in between (even a one-line helper) lets PowerShell's own
# P/Invokes overwrite the thread's last error, turning "access denied" into a meaningless code.

function Test-Win32Error {
    # True when the exception (or one it wraps) is the given Win32 error, e.g. 5 = access denied.
    [CmdletBinding()]
    [OutputType([bool])]
    param([System.Exception]$Exception, [int]$Code)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq $Code) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-TitleHint {
    # " titled 'SimHub*'" when the application is configured with a windowTitle, otherwise ''.
    [CmdletBinding()]
    [OutputType([string])]
    param($App)
    if ($App.WindowTitle) { return " titled '$($App.WindowTitle)'" }
    return ''
}

function Get-PropertyValue {
    # Safe property read for objects produced by ConvertFrom-Json under strict mode. The unary
    # comma keeps an array (even a one-element one) intact through PowerShell's output enumeration.
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param($Object, [string]$Name)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    $value = $Object.$Name
    if ($value -is [array]) { return , $value }
    return $value
}

#endregion

#region Configuration

function Get-LauncherConfig {
    <#
    .SYNOPSIS
        Reads and validates apps.json.
    .DESCRIPTION
        Returns an object with Path and Applications (Name, Path, Arguments, ExitArguments,
        WindowTitle, Monitor, ProcessName). Throws one error listing every problem found, so the
        scripts refuse to run on a broken file rather than on half of it.
    .PARAMETER Path
        Path of the configuration file.
    .EXAMPLE
        (Get-LauncherConfig -Path .\apps.json).Applications | Format-Table Name, Monitor
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }
    try {
        # UTF-8 explicitly: Windows PowerShell would otherwise read a BOM-less file as ANSI.
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file is not valid JSON: $Path`n$($_.Exception.Message)"
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    $rawEntries = Get-PropertyValue $json 'applications'
    $entries = @()
    if ($rawEntries -is [array] -and $rawEntries.Count -gt 0) {
        $entries = $rawEntries
    }
    else {
        $problems.Add('"applications" must be a non-empty array.')
    }

    $apps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]

        $name = Get-PropertyValue $entry 'name'
        if ($name -is [string] -and $name.Trim()) {
            $name = $name.Trim()
            $label = "`"$name`""
        }
        else {
            $name = ''
            $label = "applications[$i]"
            $problems.Add("$label`: `"name`" is required and must be a non-empty string.")
        }

        $rawPath = Get-PropertyValue $entry 'path'
        $exePath = ''
        if (-not ($rawPath -is [string]) -or -not $rawPath.Trim()) {
            $problems.Add("$label`: `"path`" is required and must be a non-empty string.")
        }
        else {
            $exePath = [System.Environment]::ExpandEnvironmentVariables($rawPath.Trim())
            if ($exePath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
                $problems.Add("$label`: `"path`" contains characters that are not allowed in a path (got: $rawPath).")
                $exePath = ''
            }
            elseif (-not [System.IO.Path]::IsPathRooted($exePath)) {
                $hint = if ($exePath -match '%[^%]+%') { ' - an environment variable in it is not defined on this PC' } else { '' }
                $problems.Add("$label`: `"path`" must be a full path such as C:\Program Files\App\App.exe (got: $rawPath)$hint.")
            }
            elseif (-not $exePath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                $problems.Add("$label`: `"path`" must point to an .exe file, not a shortcut or folder (got: $rawPath).")
            }
        }

        $arguments = Get-PropertyValue $entry 'arguments'
        if ($null -ne $arguments -and -not ($arguments -is [string])) {
            $problems.Add("$label`: `"arguments`" must be a string.")
            $arguments = $null
        }

        $exitArguments = Get-PropertyValue $entry 'exitArguments'
        if ($null -ne $exitArguments -and -not ($exitArguments -is [string])) {
            $problems.Add("$label`: `"exitArguments`" must be a string.")
            $exitArguments = $null
        }

        $windowTitle = Get-PropertyValue $entry 'windowTitle'
        if ($null -ne $windowTitle -and -not ($windowTitle -is [string])) {
            $problems.Add("$label`: `"windowTitle`" must be a string (wildcards allowed, for example `"SimHub*`").")
            $windowTitle = $null
        }

        $monitor = Get-PropertyValue $entry 'monitor'
        if ($null -ne $monitor) {
            if (($monitor -is [int] -or $monitor -is [long]) -and $monitor -ge 1 -and $monitor -le [int]::MaxValue) {
                $monitor = [int]$monitor
            }
            else {
                $problems.Add("$label`: `"monitor`" must be a whole number of 1 or more (for example 4), or be left out to skip window placement (got: $monitor).")
                $monitor = $null
            }
        }

        $apps.Add([pscustomobject]@{
            Name          = $name
            Path          = $exePath
            Arguments     = [string]$arguments
            ExitArguments = [string]$exitArguments
            WindowTitle   = [string]$windowTitle
            Monitor       = $monitor
            ProcessName   = if ($exePath) { [System.IO.Path]::GetFileNameWithoutExtension($exePath) } else { '' }
        })
    }

    # Group-Object compares case-insensitively, which is what file names and labels need.
    foreach ($group in ($apps | Where-Object Name | Group-Object Name | Where-Object Count -gt 1)) {
        $problems.Add("Duplicate application name: `"$($group.Group[0].Name)`" appears $($group.Count) times.")
    }
    foreach ($group in ($apps | Where-Object ProcessName | Group-Object ProcessName | Where-Object Count -gt 1)) {
        $names = ($group.Group | ForEach-Object { "`"$($_.Name)`"" }) -join ' and '
        $problems.Add("$names both use the executable $($group.Group[0].ProcessName).exe, so the launcher could not tell their processes apart.")
    }

    if ($problems.Count -gt 0) {
        throw ("Configuration file has problems: $Path`n  - " + ($problems -join "`n  - "))
    }

    [pscustomobject]@{ Path = $Path; Applications = $apps.ToArray() }
}

#endregion

#region Monitors

function Get-Monitor {
    <#
    .SYNOPSIS
        Lists the connected monitors, numbered as Windows numbers them (\\.\DISPLAY4 -> 4).
    .EXAMPLE
        Get-Monitor | Format-Table Number, Primary, Bounds
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [System.Windows.Forms.Screen]::AllScreens |
        ForEach-Object {
            [pscustomobject]@{
                Number      = [int]($_.DeviceName -replace '\D', '')
                DeviceName  = $_.DeviceName
                Primary     = $_.Primary
                Bounds      = $_.Bounds
                WorkingArea = $_.WorkingArea
            }
        } |
        Sort-Object -Property Number
}

function Resolve-TargetMonitor {
    <#
    .SYNOPSIS
        Picks the monitor an application should go to.
    .DESCRIPTION
        Returns the monitor with the configured number, the primary monitor when that number is not
        connected (the caller detects the fallback by comparing Number), or $null when no monitor is
        configured.
    .PARAMETER Monitors
        The monitors from Get-Monitor.
    .PARAMETER Number
        The configured monitor number, or $null.
    .EXAMPLE
        Resolve-TargetMonitor -Monitors (Get-Monitor) -Number 4
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object[]]$Monitors,
        [AllowNull()][Nullable[int]]$Number
    )
    if ($null -eq $Number) { return $null }
    $wanted = @($Monitors | Where-Object Number -eq $Number)
    if ($wanted.Count -gt 0) { return $wanted[0] }
    return @($Monitors | Where-Object Primary)[0]   # Windows always has exactly one primary
}

#endregion

#region Processes and windows

function Get-AppProcess {
    <#
    .SYNOPSIS
        Every running process with exactly this name (the executable's file name without .exe).
    .PARAMETER ProcessName
        The process name; wildcard characters in it are taken literally.
    .EXAMPLE
        Get-AppProcess -ProcessName 'SimHubWPF'
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Mandatory)][string]$ProcessName)
    Get-Process -Name ([WildcardPattern]::Escape($ProcessName)) -ErrorAction Ignore
}

function Get-AppWindow {
    <#
    .SYNOPSIS
        Finds the application's main window.
    .DESCRIPTION
        Returns the first visible, unowned top-level window of any process with this name (the
        same choice .NET's Process.MainWindowHandle makes), or the first one whose title matches
        WindowTitle when the application has several windows (an overlay layer, a dashboard).
        Returns a WindowInfo (Handle, Title), or $null when there is no such window.
    .PARAMETER ProcessName
        The process name.
    .PARAMETER WindowTitle
        Optional wildcard pattern for the window title, for example 'SimHub*'.
    .EXAMPLE
        Get-AppWindow -ProcessName 'RacelabApps' -WindowTitle 'Racelab*'
    #>
    [CmdletBinding()]
    [OutputType('SimRacingLauncher.WindowInfo')]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [string]$WindowTitle
    )
    # Multi-process applications (Electron) have several processes; any of them may own the window.
    $processIds = [int[]]@(Get-AppProcess -ProcessName $ProcessName | ForEach-Object { $_.Id })
    if ($processIds.Count -eq 0) { return $null }
    foreach ($window in [SimRacingLauncher.NativeMethods]::GetTopLevelWindows($processIds)) {
        if (-not $WindowTitle -or $window.Title -like $WindowTitle) { return $window }
    }
    return $null
}

function Send-WindowClose {
    # Asks a window to close (WM_CLOSE), exactly what clicking its X button does. Throws a
    # Win32Exception when Windows refuses to deliver the message (e.g. to an elevated process).
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    $native = [SimRacingLauncher.NativeMethods]
    $delivered = $native::PostMessage($WindowHandle, $native::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (-not $delivered) { throw [System.ComponentModel.Win32Exception]::new($code) }
}

function Get-WindowRectangle {
    [CmdletBinding()]
    [OutputType([System.Drawing.Rectangle])]
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    $rect = [SimRacingLauncher.NativeMethods+RECT]::new()
    $found = [SimRacingLauncher.NativeMethods]::GetWindowRect($WindowHandle, [ref]$rect)
    $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (-not $found) { throw [System.ComponentModel.Win32Exception]::new($code) }
    [System.Drawing.Rectangle]::FromLTRB($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
}

function Find-ContainingMonitor {
    # The monitor that contains the centre of the rectangle, or $null if it is off every screen.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([object[]]$Monitors, [System.Drawing.Rectangle]$Rectangle)
    $centre = [System.Drawing.Point]::new($Rectangle.X + [int]($Rectangle.Width / 2), $Rectangle.Y + [int]($Rectangle.Height / 2))
    foreach ($monitor in $Monitors) {
        if ($monitor.Bounds.Contains($centre)) { return $monitor }
    }
    return $null
}

function Get-WindowMonitor {
    # The monitor a window is currently on (by the centre of the window), or $null if it is off-screen.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object[]]$Monitors,
        [Parameter(Mandatory)][IntPtr]$WindowHandle
    )
    Find-ContainingMonitor -Monitors $Monitors -Rectangle (Get-WindowRectangle -WindowHandle $WindowHandle)
}

function Test-WindowMinimized {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    [SimRacingLauncher.NativeMethods]::IsIconic($WindowHandle)
}

function Get-PlacementRectangle {
    # Where a window should go on the target monitor: same size (clamped to the work area so it
    # can never hang off the monitor) and the same position relative to its current monitor. A
    # window that is off every screen (saved on a monitor that is now unplugged) goes top-left.
    [CmdletBinding()]
    [OutputType([System.Drawing.Rectangle])]
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$WindowRectangle,
        [Parameter(Mandatory)][object]$TargetMonitor,
        [Parameter(Mandatory)][object[]]$Monitors
    )
    $target = $TargetMonitor.WorkingArea
    $width = [Math]::Min($WindowRectangle.Width, $target.Width)
    $height = [Math]::Min($WindowRectangle.Height, $target.Height)

    $offsetX = 0
    $offsetY = 0
    $source = Find-ContainingMonitor -Monitors $Monitors -Rectangle $WindowRectangle
    if ($null -ne $source) {
        $offsetX = $WindowRectangle.X - $source.WorkingArea.X
        $offsetY = $WindowRectangle.Y - $source.WorkingArea.Y
    }
    $x = [Math]::Max($target.X, [Math]::Min($target.X + $offsetX, $target.Right - $width))
    $y = [Math]::Max($target.Y, [Math]::Min($target.Y + $offsetY, $target.Bottom - $height))
    [System.Drawing.Rectangle]::new($x, $y, $width, $height)
}

function Move-WindowToMonitor {
    # Moves a window onto a monitor. Returns $true when the window is on the monitor afterwards,
    # $false when the application did not accept the move. Throws a Win32Exception when Windows
    # refuses the request (access denied for an elevated process, or the window no longer exists).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][object]$Monitor,
        [Parameter(Mandatory)][object[]]$Monitors
    )
    $native = [SimRacingLauncher.NativeMethods]

    # A maximized window cannot simply be moved: restore it, move it, then maximize it on the new
    # monitor (these two ShowWindow calls briefly activate the window; SetWindowPos itself does not).
    $wasMaximized = $native::IsZoomed($WindowHandle)
    if ($wasMaximized) { $null = $native::ShowWindow($WindowHandle, $native::SW_RESTORE) }

    $current = Get-WindowRectangle -WindowHandle $WindowHandle
    $placement = Get-PlacementRectangle -WindowRectangle $current -TargetMonitor $Monitor -Monitors $Monitors
    $flags = $native::SWP_NOZORDER -bor $native::SWP_NOACTIVATE
    $moved = $native::SetWindowPos($WindowHandle, [IntPtr]::Zero, $placement.X, $placement.Y, $placement.Width, $placement.Height, $flags)
    $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (-not $moved) { throw [System.ComponentModel.Win32Exception]::new($code) }
    if ($wasMaximized) { $null = $native::ShowWindow($WindowHandle, $native::SW_MAXIMIZE) }

    $after = Get-WindowMonitor -Monitors $Monitors -WindowHandle $WindowHandle
    return ($null -ne $after -and $after.Number -eq $Monitor.Number)
}

#endregion

#region Launch

function Start-LauncherApp {
    <#
    .SYNOPSIS
        Launches one configured application unless it is already running.
    .DESCRIPTION
        Returns a result whose Outcome is Launched, AlreadyRunning, NotFound (the executable does
        not exist), LaunchFailed (Windows refused to start it) or Skipped (-WhatIf / not confirmed).
    .PARAMETER App
        One entry of the Applications array from Get-LauncherConfig.
    .EXAMPLE
        $config.Applications | ForEach-Object { Start-LauncherApp -App $_ }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$App)

    if (@(Get-AppProcess -ProcessName $App.ProcessName).Count -gt 0) {
        return New-Result $App.Name 'AlreadyRunning' 'Info' 'already running'
    }
    if (-not (Test-Path -LiteralPath $App.Path -PathType Leaf)) {
        return New-Result $App.Name 'NotFound' 'Error' "executable not found: $($App.Path) (check `"path`" in apps.json)"
    }
    if (-not $PSCmdlet.ShouldProcess($App.Name, "Launch $($App.Path)")) {
        return New-Result $App.Name 'Skipped' 'Info' 'skipped'
    }

    # (Start-Process never prompts on Windows PowerShell 5.1 - it has no -Confirm there.)
    $startArgs = @{
        FilePath         = $App.Path
        WorkingDirectory = [System.IO.Path]::GetDirectoryName($App.Path)   # same as a shortcut's "Start in"
        ErrorAction      = 'Stop'
    }
    if ($App.Arguments) { $startArgs.ArgumentList = $App.Arguments }   # Start-Process rejects an empty ArgumentList
    try {
        Start-Process @startArgs
    }
    catch {
        return New-Result $App.Name 'LaunchFailed' 'Error' "failed to start: $($_.Exception.Message)"
    }
    New-Result $App.Name 'Launched' 'Success' 'launched'
}

function Invoke-WindowPlacement {
    <#
    .SYNOPSIS
        Waits for each application's main window and moves it onto its target monitor.
    .DESCRIPTION
        Results stream out as events happen. An already-running application is handled once. A
        freshly launched one is watched until nothing has changed for SettleSeconds, because splash
        screens close and are replaced, and some applications restore their own saved position a
        moment after showing their window; the watch is capped at TimeoutSeconds + SettleSeconds.
    .PARAMETER Items
        Objects with App (a configured application), Monitor (from Resolve-TargetMonitor) and
        WasLaunched (whether this run launched it).
    .PARAMETER Monitors
        The monitors from Get-Monitor.
    .PARAMETER TimeoutSeconds
        How long to wait for a window to appear.
    .PARAMETER SettleSeconds
        How long a launched window must stay unchanged before it is considered final.
    .PARAMETER ExitGraceSeconds
        How long a launched process may be missing before it counts as exited (launcher stubs
        exit briefly before the real process appears).
    .PARAMETER MaxMoves
        How many times a window is moved before an application that keeps moving it back is given up on.
    .EXAMPLE
        Invoke-WindowPlacement -Items $items -Monitors (Get-Monitor) | ForEach-Object { $_.Message }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][object[]]$Monitors,
        [int]$TimeoutSeconds = 30,
        [int]$SettleSeconds = 10,
        [int]$ExitGraceSeconds = 3,
        [int]$MaxMoves = 3
    )

    $start = Get-Date
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $pending.Add([pscustomobject]@{
            App          = $item.App
            Monitor      = $item.Monitor
            WasLaunched  = [bool]$item.WasLaunched
            Placed       = $false     # a window has been seen on the target monitor at least once
            Moves        = 0          # moves made; an application that keeps moving back gets a bounded number
            LastChange   = $null      # last placement; the settle period counts from here
            GoneSince    = $null      # when the placed window was first seen missing; the settle period restarts here
            MissingSince = $null      # when the process was last seen missing (launcher stubs exit briefly)
        })
    }

    while ($pending.Count -gt 0) {
        $now = Get-Date
        # Iterate over a snapshot: items are removed while iterating.
        foreach ($item in $pending.ToArray()) {
            $app = $item.App
            $target = $item.Monitor
            $elapsed = ($now - $start).TotalSeconds
            $window = Get-AppWindow -ProcessName $app.ProcessName -WindowTitle $app.WindowTitle

            if ($null -eq $window) {
                if (@(Get-AppProcess -ProcessName $app.ProcessName).Count -eq 0) {
                    if (-not $item.WasLaunched) {
                        New-Result $app.Name 'Exited' 'Warning' 'is no longer running; not positioned'
                        $null = $pending.Remove($item)
                    }
                    elseif ($null -eq $item.MissingSince) {
                        $item.MissingSince = $now
                    }
                    elseif (($now - $item.MissingSince).TotalSeconds -ge $ExitGraceSeconds) {
                        $when = if ($item.Placed) { 'after its window was positioned' } else { 'before showing a window' }
                        New-Result $app.Name 'Exited' 'Error' "process exited $when (did it crash?)"
                        $null = $pending.Remove($item)
                    }
                    continue
                }
                $item.MissingSince = $null

                if (-not $item.WasLaunched) {
                    New-Result $app.Name 'NoWindow' 'Warning' "is running but has no visible window$(Get-TitleHint $app); not positioned (minimized to the tray?)"
                    $null = $pending.Remove($item)
                }
                elseif ($item.Placed) {
                    # The window we positioned has gone (a splash screen closed). Wait for the next one.
                    if ($null -eq $item.GoneSince) { $item.GoneSince = $now }
                    if (($now - $item.GoneSince).TotalSeconds -ge $SettleSeconds -or $elapsed -ge $TimeoutSeconds + $SettleSeconds) {
                        $waited = [int][Math]::Round(($now - $item.GoneSince).TotalSeconds)
                        New-Result $app.Name 'WindowGone' 'Warning' "the window that was positioned has closed and no new window$(Get-TitleHint $app) appeared within $waited seconds; if the application opens elsewhere, run with a longer -SettleSeconds"
                        $null = $pending.Remove($item)
                    }
                }
                elseif ($elapsed -ge $TimeoutSeconds) {
                    New-Result $app.Name 'NoWindow' 'Warning' "no window$(Get-TitleHint $app) appeared within $TimeoutSeconds seconds; not positioned (still loading, started minimized to the tray, or failed silently?)"
                    $null = $pending.Remove($item)
                }
                continue
            }
            $item.MissingSince = $null
            $item.GoneSince = $null
            $handle = $window.Handle

            try {
                if (Test-WindowMinimized -WindowHandle $handle) {
                    New-Result $app.Name 'Minimized' 'Info' 'window is minimized; left where it is'
                    $null = $pending.Remove($item)
                    continue
                }

                $current = Get-WindowMonitor -Monitors $Monitors -WindowHandle $handle
                if ($null -ne $current -and $current.Number -eq $target.Number) {
                    if (-not $item.Placed) {
                        $verb = if ($item.WasLaunched) { 'opened on' } else { 'already on' }
                        New-Result $app.Name 'AlreadyOnMonitor' 'Success' "window $verb monitor $($target.Number)"
                        $item.Placed = $true
                        $item.LastChange = $now
                    }
                }
                else {
                    if (-not $PSCmdlet.ShouldProcess($app.Name, "Move window to monitor $($target.Number)")) {
                        New-Result $app.Name 'Skipped' 'Info' 'window not moved (skipped)'
                        $null = $pending.Remove($item)
                        continue
                    }
                    if ($item.Moves -ge $MaxMoves) {
                        New-Result $app.Name 'MoveNotApplied' 'Warning' "window keeps leaving monitor $($target.Number) after being moved there $MaxMoves times (the application enforces its own position); left where it is"
                        $null = $pending.Remove($item)
                        continue
                    }
                    $item.Moves++
                    if (-not (Move-WindowToMonitor -WindowHandle $handle -Monitor $target -Monitors $Monitors)) {
                        New-Result $app.Name 'MoveNotApplied' 'Warning' "window did not stay on monitor $($target.Number) after being moved (the application enforces its own position); left where it is"
                        $null = $pending.Remove($item)
                        continue
                    }
                    if ($item.Placed) {
                        New-Result $app.Name 'Placed' 'Info' "window moved to monitor $($target.Number) again (a new window appeared, or the application had repositioned it)"
                    }
                    else {
                        New-Result $app.Name 'Placed' 'Success' "window placed on monitor $($target.Number)"
                    }
                    $item.Placed = $true
                    $item.LastChange = $now
                }
            }
            catch {
                $failure = $_.Exception
                if (Test-Win32Error $failure ([SimRacingLauncher.NativeMethods]::ERROR_INVALID_WINDOW_HANDLE)) {
                    # The window closed between finding it and using it (a splash screen): look again next poll.
                    if ($elapsed -lt $TimeoutSeconds + $SettleSeconds) { continue }
                    New-Result $app.Name 'NoWindow' 'Warning' "window kept closing before it could be positioned; gave up after $([Math]::Floor($elapsed)) seconds"
                    $null = $pending.Remove($item)
                    continue
                }
                $message = "could not move window to monitor $($target.Number): $($failure.Message)"
                if (Test-Win32Error $failure ([SimRacingLauncher.NativeMethods]::ERROR_ACCESS_DENIED)) { $message += " $script:MoveElevationHint" }
                New-Result $app.Name 'MoveFailed' 'Error' $message
                $null = $pending.Remove($item)
                continue
            }

            # An already-running application is handled once; a launched one is watched until it has
            # been quiet for the settle period, or for the overall cap.
            if (-not $item.WasLaunched -or ($now - $item.LastChange).TotalSeconds -ge $SettleSeconds -or $elapsed -ge $TimeoutSeconds + $SettleSeconds) {
                $null = $pending.Remove($item)
            }
        }
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    }
}

#endregion

#region Close

function Wait-AppExit {
    # Waits until no process with this name is left. True if that happened within the timeout.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [int]$TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (@(Get-AppProcess -ProcessName $ProcessName).Count -eq 0) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 250
    }
}

function Stop-LauncherApp {
    <#
    .SYNOPSIS
        Closes one configured application: graceful request first, forceful termination only if that fails.
    .DESCRIPTION
        The graceful request is the application's own exit command when apps.json gives one
        (exitArguments), otherwise a close message to its main window - exactly what clicking
        the X button does. If the application is still running after TimeoutSeconds, or no close
        request could be delivered at all, every process with its name is terminated. Outcomes:
        NotRunning, ClosedGracefully, ForceClosed, CloseFailed, Skipped (-WhatIf / not confirmed).
    .PARAMETER App
        One entry of the Applications array from Get-LauncherConfig.
    .PARAMETER TimeoutSeconds
        How long the application gets to close gracefully.
    .PARAMETER KillTimeoutSeconds
        How long to wait for processes to disappear after forceful termination.
    .EXAMPLE
        Stop-LauncherApp -App $config.Applications[0] -TimeoutSeconds 30
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$App,
        [int]$TimeoutSeconds = 15,
        [int]$KillTimeoutSeconds = 5
    )

    if (@(Get-AppProcess -ProcessName $App.ProcessName).Count -eq 0) {
        return New-Result $App.Name 'NotRunning' 'Info' 'not running'
    }
    if (-not $PSCmdlet.ShouldProcess($App.Name, 'Close')) {
        return New-Result $App.Name 'Skipped' 'Info' 'skipped'
    }

    # 1. Graceful request.
    $requested = $false
    $denied = $false
    $why = ''
    if ($App.ExitArguments) {
        $exitArgs = @{
            FilePath         = $App.Path
            ArgumentList     = $App.ExitArguments
            WorkingDirectory = [System.IO.Path]::GetDirectoryName($App.Path)
            ErrorAction      = 'Stop'
        }
        try {
            Start-Process @exitArgs
            $requested = $true
        }
        catch {
            $why = "its exit command failed - $($_.Exception.Message)"
        }
    }
    if (-not $requested) {
        $window = Get-AppWindow -ProcessName $App.ProcessName -WindowTitle $App.WindowTitle
        if ($null -eq $window) {
            if (-not $why) { $why = "has no visible window$(Get-TitleHint $App) to send a close request to (minimized to the tray?)" }
        }
        else {
            try {
                Send-WindowClose -WindowHandle $window.Handle
                $requested = $true
            }
            catch {
                $why = "the close request was refused - $($_.Exception.Message)"
                if (Test-Win32Error $_.Exception ([SimRacingLauncher.NativeMethods]::ERROR_ACCESS_DENIED)) { $denied = $true }
            }
        }
    }
    if ($requested) {
        if (Wait-AppExit -ProcessName $App.ProcessName -TimeoutSeconds $TimeoutSeconds) {
            return New-Result $App.Name 'ClosedGracefully' 'Success' 'closed'
        }
        $why = "did not close within $TimeoutSeconds seconds"
    }

    # 2. Forceful termination of every process with this name.
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($process in @(Get-AppProcess -ProcessName $App.ProcessName)) {
        try {
            Stop-Process -Id $process.Id -Force -Confirm:$false -ErrorAction Stop   # confirmation was handled above
        }
        catch {
            $failures.Add($_.Exception.Message)
            if (Test-Win32Error $_.Exception ([SimRacingLauncher.NativeMethods]::ERROR_ACCESS_DENIED)) { $denied = $true }
        }
    }
    if (Wait-AppExit -ProcessName $App.ProcessName -TimeoutSeconds $KillTimeoutSeconds) {
        return New-Result $App.Name 'ForceClosed' 'Warning' "$why; terminated forcefully"
    }

    $message = "could not be closed, even forcefully ($why)."
    foreach ($failure in ($failures | Select-Object -Unique)) { $message += ' ' + $failure.TrimEnd('.') + '.' }
    $message += if ($denied) { " $script:CloseElevationHint" } else { ' Close it manually.' }
    New-Result $App.Name 'CloseFailed' 'Error' $message
}

#endregion

Export-ModuleMember -Function Get-LauncherConfig, Get-Monitor, Resolve-TargetMonitor, Get-AppProcess, Get-AppWindow,
    Start-LauncherApp, Invoke-WindowPlacement, Stop-LauncherApp
