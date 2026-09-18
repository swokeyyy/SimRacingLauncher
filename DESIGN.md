# SimRacingLauncher — research record and design decisions

This file records *why* the tool is built the way it is. `README.md` explains how to use it.
Everything below was established on 2026-09-18 on the owner's own PC (Windows 11 Pro 26200,
Windows PowerShell 5.1, RTX 5070 Ti driving four LG monitors) plus web research; each claim
says which.

## 1. Prior art and the professional standard

**PowerShell, not `.bat`.** Microsoft's own command-line team wrote that Cmd "can no longer
easily [be] improve[d]" and that PowerShell "was built for today and the future"
(Rich Turner, Windows Command Line blog, 2017,
<https://devblogs.microsoft.com/commandline/rumors-of-cmds-death-have-been-greatly-exaggerated/>).
ITPro Today: "no longer any need to write old-style batch files … Microsoft has positioned
[PowerShell] as the primary means of automating the Windows operating system"
(<https://www.itprotoday.com/powershell/break-your-batch-habit-and-move-to-powershell>).
Batch has no structured error handling, no JSON parsing, no process objects, and no way to call
the Windows API — every one of which this tool needs. The only batch in the project is the two
four-line `.cmd` wrappers that exist so the scripts can be double-clicked.

**Sim-racing prior art.** Three real tools orchestrate launching/closing companion apps:
[SimLauncher](https://github.com/Stashpeak/SimLauncher) (GPL-3, Electron; launch order, delays,
kill/relaunch, auto-close), RaceLab's built-in
[Tools Manager](https://garage.racelab.app/docs/advanced-features/tools-manager/) (2026; launch
order, delays; termination modes *Graceful* = `WM_CLOSE`, *Force*, *Force by name*,
*Double-close* for tray apps) and [MotorHome](https://github.com/rickymw/MotorHome). **None of
them positions windows on a monitor.** The only real tool that does is Microsoft's
[PowerToys Workspaces](https://learn.microsoft.com/en-us/windows/powertoys/workspaces), which
documents the two constraints every such tool shares — "PowerToys cannot tell an app to launch
to a specific position … launch an app first, and then … move and resize it" and "apps that
launch as admin are unable to be repositioned" — and which has no close-all and no portable
config. No single existing tool covers launch + close + placement + a shareable config file, so
a small PowerShell tool is justified; its close sequence mirrors RaceLab's (graceful, then force)
and its launch-then-move loop is the only approach Windows allows.

## 2. The four applications (verified on this PC via registry Uninstall keys and Start Menu shortcuts)

| App | Executable | Notes |
|---|---|---|
| MOZA Pit House 1.4.1.13 | `C:\Program Files (x86)\MOZA Pit House\MOZA Pit House.exe` | Qt app. Its own [localisation strings](https://github.com/MOZA-Racing/pit_house_l10n/blob/main/mozapithouse_en_US.ts) show a *Close Tip* dialog on the X button ("When clicking the close button: Minimize to System Tray / Exit Pit House / No more reminders") and **no display/monitor setting**. Found running **elevated** on this PC (manifest is `asInvoker`; it was relaunched by its updater). |
| SimHub 9.11.20 | `C:\Program Files (x86)\SimHub\SimHubWPF.exe` | Documented CLI: [`-exit` "Closes the running SimHub instance"](https://github.com/SHWotever/SimHub/wiki/Command-line-interface); `-minimize`/`-restore` exist, nothing for position. Settings → "Minimize to system tray" can turn the X button into hide-to-tray. Dashboard windows are separate top-level windows. |
| RaceLab 8.4.0 | `%LOCALAPPDATA%\racelabapps\RacelabApps.exe` | Per-user Squirrel install: the stub starts `app-8.4.0\RacelabApps.exe` and exits, and the folder name changes on every update — so the config must use the stub and an environment variable. Electron: several `RacelabApps` processes; "runs quietly in the system tray". Its overlay layer is a full-screen always-on-top window titled `layouts` (observed), so the control panel must be selected by title (`Racelab*`). |
| iRacing UI 2025.04.14.02 | `C:\Program Files (x86)\iRacing\ui\iRacingUI.exe` | Electron: 8 processes, one owns the window titled `iRacing`. Nothing documented about close behaviour or position memory (assumption: plain close, no local unsaved state). Observed on the first real run: it prints its internal log (`Trace: Using dataDirectory…`, JSON `iracing-electron` lines) into the launcher's console — Electron's `RouteStdioToConsole`, disabled by the documented `ELECTRON_NO_ATTACH_CONSOLE` variable, which the launcher now sets for the applications it starts. |

**Startup order.** No documented dependency between the four. Community advice (SimLauncher docs)
to start companions with delays concerns connecting to the *sim's* telemetry, which SimHub and
RaceLab do on their own whenever the sim runs. Therefore there is **no `order` field**: the
order of the `applications` array is the launch order; the closer uses the reverse.

**Close behaviour and unsaved state (assumptions stated).** SimHub persists settings as they
change and offers `-exit`; Pit House writes profiles to the wheelbase/its files as they change;
RaceLab syncs to its cloud account; the iRacing UI holds no local state. Forceful termination is
therefore a safe *last resort* for all four when idle — but never run the closer while Pit House
is flashing firmware. Pit House's *Close Tip* dialog means a plain close request may show a
dialog instead of exiting; set it to "Exit Pit House" + "No more reminders" for a clean close.

**Window position memory.** None of the four has a native "always open on monitor N" setting
(confirmed for Pit House by its strings; SimHub's *save/restore layout* covers dashboards, RaceLab's
layout offsets cover overlays — both out of scope). External repositioning is therefore genuinely
required, and because the move is idempotent it is harmless for an app that does remember.

## 3. Technology

Windows PowerShell 5.1 is the target: it is the only PowerShell on this PC and ships with every
Windows 10/11, so the tool is shareable without installing anything. Nothing 7-only is used, and
two real 5.1 differences shaped the code: `Split-Path -LiteralPath -Parent` is ambiguous on 5.1
(so `[IO.Path]::GetDirectoryName` is used) and `Start-Process` has no `-Confirm`/`-WhatIf` on 5.1.

Window positioning has no cmdlet — [PowerShell issue #21499](https://github.com/PowerShell/PowerShell/issues/21499)
asked for it and is closed unimplemented; the workaround shown there, and in every community
script found (SysToolsLib `Window.ps1`, Richard Siddaway's blog, the GenXdev.Windows module), is
`Add-Type` P/Invoke of `user32.dll`. Monitor enumeration needs **no** P/Invoke:
`System.Windows.Forms.Screen.AllScreens` is the managed wrapper over `EnumDisplayMonitors` and
gives device name, bounds, working area and primary flag. Existing modules (GenXdev.Windows) are
large dependency trees — wrong for a tool that must be copyable.

The P/Invoke surface is the minimum for the job: `SetWindowPos` (move), `GetWindowRect`
(current size/position and post-move verification), `IsIconic`/`IsZoomed`/`ShowWindow`
(minimized/maximized handling), `EnumWindows`+`GetWindowText`+`IsWindowVisible`+`GetWindow`
(select the right window of a multi-window app), `PostMessage(WM_CLOSE)` (graceful close to
that same window — exactly what `Process.CloseMainWindow()` does internally) and the DPI call
below. Everything is in one `Add-Type` block guarded against double loading.

**Monitor numbering.** `monitor: N` means Windows device `\\.\DISPLAYN`. Microsoft confirms there
is "no built-in function … that directly maps the display numbers from the Display Settings to
the identifiers obtained from EnumDisplayMonitors"
(<https://learn.microsoft.com/en-us/answers/questions/1572062/>), so the launcher prints the
monitors it sees (number, size, position, primary) on every run and with `-ListMonitors`, and the
user picks the number from that list. On this PC `EnumDisplayDevices` showed `\\.\DISPLAY1-3`
attached to the desktop and **`\\.\DISPLAY4` present but not attached** (the fourth LG is
switched off / disconnected) — i.e. "monitor 4" is real and the fallback path is live today.

**DPI.** `powershell.exe` reports DPI awareness 0 (measured). A DPI-unaware process is handed
scaled coordinates on displays scaled above 100%, so the sizes printed for the user would not
match Display Settings. The module opts in to per-monitor-V2 awareness
(`SetProcessDpiAwarenessContext`, Windows 10 1703+; falls back to `SetProcessDPIAware`) once at
load, before `Screen` is read, so every coordinate is a physical pixel on every monitor.

## 4. Configuration (`apps.json`)

```json
{ "applications": [
    { "name": "SimHub", "path": "C:\\Program Files (x86)\\SimHub\\SimHubWPF.exe",
      "exitArguments": "-exit", "windowTitle": "SimHub*", "monitor": 4 }
] }
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Display name used in every message. Unique. |
| `path` | yes | Full path to the `.exe`; `%VAR%` environment variables are expanded. Not a shortcut. Unique executable name (the process name is derived from it). |
| `arguments` | no | Command-line arguments for launching (the original brief asks for "any required launch arguments"; none of the four needs one today). |
| `exitArguments` | no | If the app has its own exit command (SimHub `-exit`), the graceful close runs `path exitArguments` instead of sending a close message. |
| `windowTitle` | no | Wildcard pattern selecting *which* top-level window is the app's main window when it has several (overlay layers, dashboards). Without it the first visible unowned window is used — the same choice .NET's `MainWindowHandle` makes. |
| `monitor` | no | Monitor number from the launcher's list. Absent or `null` = launch only, do not move (a tray-only or background tool should not cost a 30-second wait on every run). Every shipped entry says `3` — the left monitor of the owner's triple, chosen from the launcher's list on the first real run (the fourth display, `\\.\DISPLAY4`, is usually detached, so the original "monitor 4" would have fallen back to the primary every time). |

Validation is fail-fast and all-or-nothing: every problem in the file is reported at once
(with the file path) and nothing is launched (exit code 2). A path that does not *exist* is
deliberately **not** a validation error — it is a per-application runtime failure, so the other
applications still launch. The file is read as UTF-8 explicitly (Windows PowerShell would read a
BOM-less file as ANSI). JSON comments are not supported by Windows PowerShell's parser, so the
field reference lives in the README.

## 5. Engines

**Launch** (`Start-SimRacingApps.ps1` → `Start-LauncherApp`, `Invoke-WindowPlacement`):
1. Print the monitors. Load and validate the config. Resolve each app's target monitor
   (configured → primary if not connected, with a warning).
2. For each app in array order: already running (any process with that name) → skip launch;
   executable missing → error, continue; `Start-Process` with the exe's folder as working
   directory (what a shortcut's *Start in* does); failure → error with the reason, continue.
3. One polling loop (500 ms) over every app that was launched or already running and has a
   monitor: find the app's main window (by process name and optional title — process IDs are not
   used because Electron apps and RaceLab's launcher stub make the launched PID meaningless),
   move it if it is not on the target monitor and verify where it ended up. An already-running
   app is handled once. A freshly launched app is watched until nothing has changed for the
   *settle* period (10 s): a placement or the disappearance of the placed window restarts the
   period, so a splash screen that closes and is replaced, or an app that restores its own saved
   position a moment later (the failure PowerToys Workspaces documents), is still caught; the
   watch is capped at timeout + settle. A window that vanishes between being found and being
   used (Win32 error 1400) is simply looked up again on the next poll. An application that keeps
   moving its window back is moved at most three times, then reported and left alone.
4. Exit 0 if everything matched the config, 1 if anything was warned or failed, 2 if the config
   could not be loaded. The `.cmd` wrapper pauses on non-zero so the message can be read.

**Move** (`Move-WindowToMonitor`, geometry in `Get-PlacementRectangle`): keep the window's size
(clamped to the target work area so it can never hang off the monitor) and its position relative
to its current monitor (a window that is off every screen — saved on a now-unplugged monitor —
goes to the top-left corner); a maximized window is restored, moved and re-maximized on the new
monitor (the two `ShowWindow` calls briefly activate it; the `SetWindowPos` itself uses
`SWP_NOZORDER|SWP_NOACTIVATE` and does not); then `GetWindowRect` confirms the result.

**Close** (`Stop-SimRacingApps.ps1` → `Stop-LauncherApp`), reverse array order, per app:
not running → skip; graceful request = the app's `exitArguments` command if configured, otherwise
`WM_CLOSE` to its main window (the same title-selected window, so RaceLab's control panel is asked,
not its overlay layer); wait up to 15 s for *every* process of that name to exit; only then
`Stop-Process -Force` on each, wait 5 s; still alive → final failure message, continue with the
rest. Exit 0 only if everything closed gracefully or was not running.

**`-WhatIf` / `-Confirm`.** Both scripts support them and forward them explicitly into the module
(preference variables do not cross a script-module boundary). The module's three orchestration
functions gate with `ShouldProcess`; `Stop-Process` inside is called with `-Confirm:$false` so a
confirmed close does not prompt again per process.

**Design decision — already running on the wrong monitor: it is moved.** Running the launcher
means "put my rig in the configured state"; the common case is an app auto-started or left over
from the last session on the wrong screen. A deliberately repositioned window is preserved by not
re-running the launcher (or by changing the config). PowerToys Workspaces offers the same as its
"Move existing windows" option. Exception: a **minimized** window is left alone (moving it would
have to un-minimize it, undoing a deliberate user action); it is reported.

**Design decision — elevated applications are reported, never chased.** UIPI blocks window moves,
close messages and termination across the integrity boundary (rows 7 and 14 below; reproduced on
this PC, where Pit House was left elevated by its own updater). Neither script self-elevates: an
elevated launcher would make every app it launches elevated, and a UAC prompt on every close
breaks "one click" for a situation that disappears as soon as the app is next started normally
by this launcher. The messages say exactly what to do instead.

## 6. Failure modes — exact message and behaviour

`[Name]` prefixes every line; warnings are printed by `Write-Warning` (`WARNING: [Name] …`).
Continue = the remaining applications are still processed.

| # | Failure | Message | Behaviour / exit |
|---|---|---|---|
| 1 | Config file missing, invalid JSON, or schema problems | `ERROR: Configuration file not found: <path>` / `…is not valid JSON: <path>` + parser message on the next line / `…has problems: <path>` + one bullet per problem | Halt before launching anything; exit 2 |
| 2 | Configured executable does not exist | `ERROR: executable not found: <path> (check "path" in apps.json)` | Skip this app; continue; exit 1 |
| 3 | Launch fails (permissions, corrupt install, UAC cancelled) | `ERROR: failed to start: <exception message>` | Skip; continue; exit 1 |
| 4 | App hangs — no window within the timeout | `WARNING: no window[ titled '…'] appeared within 30 seconds; not positioned (still loading, started minimized to the tray, or failed silently?)` | App left running; continue; exit 1 |
| 5 | App exits before showing a window (crash), or after its window was positioned | `ERROR: process exited before showing a window (did it crash?)` / `ERROR: process exited after its window was positioned (did it crash?)` (after a 3 s grace for launcher stubs) | Continue; exit 1 |
| 6 | Configured monitor not connected | `WARNING: monitor 4 is not connected (detected: 1, 2, 3); using primary monitor 2 instead` | Placed on the primary; continue; exit 1 |
| 7 | Move refused by Windows | `ERROR: could not move window to monitor N: <Win32 message>` + for access denied: `It appears to be running as Administrator while this script is not, so Windows blocks the request. Close it, let this launcher start it normally, or move the window by hand.` | Continue; exit 1 |
| 8 | Move accepted but the app puts the window back | `WARNING: window did not stay on monitor N after being moved (the application enforces its own position); left where it is` — or, if it moves back later, `WARNING: window keeps leaving monitor N after being moved there 3 times (…); left where it is` | Continue; exit 1 |
| 9 | Already running on the wrong monitor | `window placed on monitor N` (moved — see decision above) | exit 0 |
| 10 | Already running, minimized | `window is minimized; left where it is` | exit 0 |
| 11 | Already running, no visible window (tray) | `WARNING: is running but has no visible window[ titled '…']; not positioned (minimized to the tray?)` | Continue; exit 1 |
| 12 | The positioned window closed (splash screen) and nothing replaced it | `WARNING: the window that was positioned has closed and no new window[ titled '…'] appeared within N seconds; if the application opens elsewhere, run with a longer -SettleSeconds` (N = seconds actually waited) | Continue; exit 1 |
| 13 | Graceful close ignored (tray-on-close, a *Close Tip* dialog, no window) | `WARNING: did not close within 15 seconds; terminated forcefully` / `WARNING: has no visible window … to send a close request to (minimized to the tray?); terminated forcefully` | Forceful fallback; continue; exit 1 |
| 14 | Close fails even after the forceful fallback | `ERROR: could not be closed, even forcefully (<why>). <Stop-Process message>.` + for access denied: `It appears to be running as Administrator while this script is not, so Windows blocks the request. Close it manually, or run this closer as Administrator.`, otherwise `Close it manually.` | Reported, continue with the rest; exit 1 |

Rows 7 and 14 were reproduced live on this PC (Pit House running elevated; `odbcad32.exe`, which
auto-elevates, used as a stand-in) — `SetWindowPos`, `PostMessage(WM_CLOSE)` and `Process.Kill`
all fail with Win32 error 5 across the integrity boundary.

Considered and rejected: killing child processes by tree (a graceful close already cleans them
up and the four apps' helper processes exit with their parent); per-app timeouts (one global,
adjustable script parameter is enough); relative config paths; a top-level default monitor
(the per-app field is the single mechanism the requirement asked for); auto-elevation; a module
manifest (the scripts import the `.psm1` by path).

## 7. Tests and verification

`Tests\SimRacingLauncher.Tests.ps1` (Pester 6.2, 5.x syntax): 66 tests. All but three are mocked
at the process/window/monitor seams inside the module (nothing is really launched, moved or
closed); the three exceptions call the real Win32 functions on a handle that does not exist and
pin the error code (see §8). Coverage:
configuration parsing and every validation message (including one-element arrays, BOM-less UTF-8,
undefined environment variables); monitor resolution and fallback; exact process-name matching;
the pure placement geometry (relative position, clamping, off-screen); launch outcomes (arguments,
working directory, already running, not found, failure, WhatIf); every placement outcome including
timeout, crash before/after placement, minimized, the invalid-window-handle race, the
splash-screen replacement, the settle restart on disappearance (a timing test that fails under
the old rule), the re-move budget, access denied with/without the hint, rejected move; every
close outcome including the exit command and its fallback, tray,
timeout→force, force refused with the hint, WhatIf; and the scripts end-to-end in their read-only
modes (exit code 2 on a broken config, `-ListMonitors`, reverse close order, `-WhatIf` summary).

PSScriptAnalyzer 1.25 with `PSScriptAnalyzerSettings.psd1` reports nothing at any severity.

Live verification on this PC (2026-09-18) used a stand-in config of stock Windows apps plus a
renamed `powershell.exe` showing a form that cancels its own close: all windows landed on the
configured monitors (verified through `GetWindowRect`), the monitor-4 fallback fired, a missing
executable was reported and skipped, a second run changed nothing, the closer closed the
cooperative apps gracefully, force-terminated the stubborn one, and — with the auto-elevating
`odbcad32.exe` in the first run — reported the elevated one with the exact message in row 14.
The real four applications were exercised only in `-WhatIf` mode (they were in use), which
walked every path up to the point of change: fallback warnings, correct window selection for
all four (including RaceLab's `Racelab` panel rather than its `layouts` overlay), "already on",
"would move", and a minimized iRacing UI left alone.

## 8. Independent reviews (2026-09-18)

Three separate reviewers read the code cold, each with a different brief, and each returned
NEEDS REVISION once; every finding was either fixed or is recorded here as a deliberate choice.

*Correctness and error handling* verified all failure-mode rows against the code and found: an
uncaught `Invalid window handle` exception when a splash screen closed between lookup and use
(fixed: rows 5/12 and the "look again next poll" rule); the same race misreported as a move
failure (fixed); a silent miss when the real window appeared after the settle period (fixed:
the quiet-period rule and row 12); and nits — BOM-less UTF-8 config decoding, a shared
elevation hint that told launcher users to run as Administrator (now two hints), misleading
`-WhatIf` summaries, and a stale test comment (all fixed). On its second pass it caught a
regression introduced by a style refactor: moving the three `Marshal.GetLastWin32Error()` reads
into a helper function let PowerShell's own command invocation overwrite the thread's last
error (measured: error 203 instead of 5/1400, 20 times out of 20), which the fully mocked tests
could not see. The reads are back in the statement right after each P/Invoke, three unmocked
tests now pin the real error code, and row 7 was reproduced live again with the fixed code
(`Access is denied` from `SetWindowPos` on the elevated Pit House window).

*Idiomatic PowerShell* (against PoshCode's Practice & Style guide, Microsoft's cmdlet guidelines,
PSScriptAnalyzer rule docs and pester.dev) found: `-Confirm` advertised but not forwarded into the
module (fixed, with nested prompts suppressed), a vacuous `$PSBoundParameters` assertion in a mock
filter (fixed: `$PesterBoundParameters`), unnecessary `$global:` test state (fixed: `$script:`),
console output not routed through `Show-`-verb functions / `Write-Warning` (fixed), missing
parameter help and `OutputType` on exports (fixed), an implicit `System.Drawing` load (fixed).
Kept deliberately: positional arguments to the two fixed-order private helpers (allow-listed in
`PSScriptAnalyzerSettings.psd1`), Stroustrup brace style, plural nouns in the user-facing script
names, and message literals longer than the 115-column guideline (the tests pin the exact text).

*Anti-overengineering* cut: the dead no-primary branch, unused `PollMilliseconds` parameters and
`WindowInfo.ProcessId`, a duplicated `Test-Path`, two tests that tested nothing real, an
over-wide export list, unreachable inner `ShouldProcess` gates, and a double process enumeration
per poll; on its second pass it caught that the "settle period restarts when the placed window
disappears" rule was documented but not implemented (fixed with `GoneSince` and a timing test).
Kept with the justification above: `arguments` (explicit requirement), optional `monitor` (tray
tools), the settle watch (documented PowerToys failure), the timeout parameters (documented for
slow PCs) and the 7-line console helper duplicated in both scripts (keeps the engine free of
console output).
