# SimRacingLauncher

One click to start your sim-racing apps and put each window on the monitor you want; one click
to close them all again — gracefully first, forcefully only if an app refuses.

Works on any Windows 10/11 PC with nothing to install: it is plain Windows PowerShell 5.1.

## Files

| File | What it is |
|---|---|
| `Launch-SimApps.cmd` | **Double-click to launch everything.** |
| `Close-SimApps.cmd` | **Double-click to close everything.** |
| `apps.json` | The list of applications — the only file you edit. |
| `Start-SimRacingApps.ps1` / `Stop-SimRacingApps.ps1` | The launcher and the closer (what the `.cmd` files run). |
| `SimRacingLauncher.psm1` | The shared engine. |
| `Tests\` | Automated tests (see *Running the tests*). |
| `DESIGN.md` | Why it is built this way, the research behind it, and the review record. |
| `PSScriptAnalyzerSettings.psd1` | Lint settings used when changing the code (see *Modifying the tool*). |

You can move or copy the whole folder anywhere; everything is found relative to the scripts.
To put the launcher on your taskbar or Start menu, right-click a `.cmd` file → *Create shortcut*
and pin the shortcut.

## Running the launcher and the closer

Double-click `Launch-SimApps.cmd`. It prints the monitors it sees, launches each app in the order
listed in `apps.json` (skipping ones that are already running), waits for each window to appear,
moves it to its monitor, and closes the console when everything went as configured. If anything
did not (a warning or an error), the console stays open so you can read it — press any key to
close it.

Double-click `Close-SimApps.cmd`. Apps are closed in reverse order. Each one is first asked to
close politely (its own exit command if it has one, otherwise the same request the X button
sends) and given 15 seconds; only if it is still running is it terminated. The console stays
open if anything needed force or could not be closed.

From a PowerShell prompt you can also run the scripts directly, with options:

```powershell
.\Start-SimRacingApps.ps1                          # same as the .cmd
.\Start-SimRacingApps.ps1 -ListMonitors            # just show the monitor numbers and exit
.\Start-SimRacingApps.ps1 -WhatIf                  # show what would be launched/moved, do nothing
.\Start-SimRacingApps.ps1 -WindowTimeoutSeconds 60 # wait longer for slow apps (default 30)
.\Stop-SimRacingApps.ps1 -CloseTimeoutSeconds 30   # give apps longer to close (default 15)
.\Stop-SimRacingApps.ps1 -WhatIf                   # show what would be closed, do nothing
.\Stop-SimRacingApps.ps1 -Confirm                  # ask before each app
Get-Help .\Start-SimRacingApps.ps1 -Full           # all parameters
```

(If PowerShell refuses to run the `.ps1` directly because of its execution policy, use the
`.cmd` files — they run the scripts with a one-off `-ExecutionPolicy Bypass`.)

## Adding a new application

Open `apps.json` and append an entry to the `applications` list. Only `name` and `path` are
required; add `monitor` if you want its window moved:

```json
{
  "applications": [
    { "name": "MOZA Pit House", "path": "C:\\Program Files (x86)\\MOZA Pit House\\MOZA Pit House.exe", "monitor": 4 },
    { "name": "Crew Chief",     "path": "C:\\Program Files (x86)\\Britton IT Ltd\\CrewChiefV4\\CrewChiefV4.exe", "monitor": 4 }
  ]
}
```

Rules that keep it working:

- **Backslashes are doubled** in JSON (`C:\\Program Files\\...`).
- `path` must be the full path to the **`.exe`** itself, not a shortcut. To find it: right-click
  the app's Start-menu entry → *Open file location* → right-click the shortcut → *Properties* →
  copy *Target*. Environment variables are allowed (`%LOCALAPPDATA%\\...`) — use them for apps
  that install per user, like RaceLab, so the same file works for other people.
- The order of the list is the launch order; the closer runs it in reverse.
- No comments are allowed in the file (Windows PowerShell's JSON parser rejects them).

All fields:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Shown in every message. |
| `path` | yes | Full path to the `.exe`. |
| `monitor` | no | Monitor number to move the window to (see below). Leave it out for "just launch it". |
| `arguments` | no | Command-line arguments to launch with, e.g. `"-minimized"`. |
| `exitArguments` | no | If the app has its own exit command, put it here and the closer uses it instead of the window close request. SimHub: `"-exit"`. |
| `windowTitle` | no | Which window is the app's main window, as a wildcard pattern on the title, e.g. `"SimHub*"`. Only needed for apps that have several visible windows (overlay layers, dashboards) — without it the first visible window is used. |

If something in the file is wrong, both scripts tell you exactly what and where, and launch or
close nothing until it is fixed.

## Choosing which monitor each app opens on

Run `Launch-SimApps.cmd` (or `.\Start-SimRacingApps.ps1 -ListMonitors`) and look at the list at
the top:

```
Monitors detected on this PC (use these numbers for "monitor" in apps.json):
  1: 2560x1440 at (2560,0)
  2: 2560x1440 at (0,0)  (primary)
  3: 2560x1440 at (-2560,0)
```

The position `(x,y)` tells you where each one sits: `(0,0)` is the primary monitor, negative x is
to its left, positive x to its right. Put the number you want in that app's `monitor` field —
each app can have a different one. The numbers usually match the ones Windows *Display Settings*
shows under *Identify*, but not always (Windows has no reliable mapping), so trust this list.

- A window is moved keeping its size and its relative position; a maximized window is re-maximized
  on the new monitor; a minimized window is left alone.
- An app that is **already running** also has its window moved to its configured monitor, so
  running the launcher always ends in the configured layout.
- If the configured monitor **is not connected** (switched off, unplugged, a different PC) the
  window goes to the primary monitor instead and you get a warning — never an error.

## Using this on another PC

1. Copy the folder.
2. Fix the `path` of any app installed somewhere else (the launcher reports each missing one by
   name and keeps going, so just run it and read the list).
3. Run `Launch-SimApps.cmd` once, read the monitor list at the top, and change each `monitor`
   number to the monitor you want on *that* PC. If you have fewer monitors than the number in
   the file, everything simply lands on the primary monitor until you edit it.

That is all — nothing to install, no admin rights needed.

## When something does not go as planned

Every problem is reported by app name; these are the ones you are most likely to see.

| Message | Meaning / what to do |
|---|---|
| `executable not found: …` | Fix `path` in `apps.json`. The other apps still launch. |
| `failed to start: …` | Windows refused to start it (e.g. you cancelled a UAC prompt). The other apps still launch. |
| `no window appeared within 30 seconds` | It is still loading, crashed silently, or starts minimized to the tray. If it is a tray app, remove its `monitor` field so the launcher does not wait for a window. |
| `the window that was positioned has closed and no new window appeared…` | The launcher positioned a splash screen and the real window took longer than the settle time to appear. Run with `-SettleSeconds 20` (or more); if the app has several windows, set `windowTitle`. |
| `monitor 4 is not connected …; using primary monitor 2 instead` | Turn the monitor on / plug it in, or change the number. |
| `could not move window …: Access is denied … running as Administrator` | Windows does not let a normal script touch the window of an app running as Administrator. Close that app and let the launcher start it normally (do **not** run the launcher as Administrator — every app it starts would be elevated too). MOZA Pit House ends up elevated after its own updater relaunches it. |
| `did not close within 15 seconds; terminated forcefully` | The app ignored the close request (it minimizes to the tray on close, or showed a dialog). Harmless for these apps when idle — see below. |
| `could not be closed, even forcefully` | Almost always an app running as Administrator; close it by hand (or run the closer as Administrator for that one time). |

Notes on the four apps:

- **SimHub** is closed through its own documented `-exit` command, so it exits cleanly even if
  its *Minimize to system tray* option is on.
- **MOZA Pit House** shows a "Close Tip" dialog on the X button unless you have set it to
  *Exit Pit House* and *No more reminders*; until you do, the closer will have to terminate it
  after the timeout. Never run the closer while Pit House is updating firmware.
- **RaceLab** has an always-on-top overlay layer as well as its control window; `windowTitle`
  `"Racelab*"` makes sure the control window is the one that is moved and closed. Its `path`
  must stay the `%LOCALAPPDATA%\racelabapps\RacelabApps.exe` stub (the versioned `app-x.y.z`
  folder changes with every update).
- **iRacing UI**: closing it does not close a running sim session; the closer only touches the
  apps listed in `apps.json`.

## Modifying the tool

Everything you are likely to want to change is a config field or a script parameter, so start
there. If you do want to change the code, this is how it is laid out:

| Where | What lives there |
|---|---|
| `apps.json` | The applications: names, paths, arguments, exit commands, window titles, monitors. |
| `Start-SimRacingApps.ps1` / `Stop-SimRacingApps.ps1` | Thin "controllers": parameters and defaults (timeouts, settle time), console output, exit codes. They contain no launch/close logic. |
| `SimRacingLauncher.psm1` | The engine, in regions: Win32 interop (the only place that calls Windows directly), configuration loading and validation, monitor enumeration and fallback, process/window lookup, placement (`Get-PlacementRectangle` is the pure geometry), the launch loop (`Invoke-WindowPlacement`), the close sequence (`Stop-LauncherApp`). Every function returns result objects; none prints. |
| `Tests\SimRacingLauncher.Tests.ps1` | One test per behaviour and per error message. Add one when you change either. |
| `DESIGN.md` | The reasoning: research, the failure-mode table with the exact messages, and the decisions that were deliberately made (and why). Read section 6 before changing an error path. |

Common changes and where to make them:

- **Defaults for the timeouts** (30 s window wait, 10 s settle, 15 s graceful close): the `param()`
  blocks at the top of the two scripts — or leave the defaults and add the parameter to the
  `powershell.exe` line in the `.cmd` file, e.g. `-WindowTimeoutSeconds 60`.
- **Where on the monitor a window lands** (currently: same size and same relative position,
  clamped to the monitor; top-left if it was off-screen): `Get-PlacementRectangle`.
- **Leave already-running windows alone instead of moving them**: in `Start-SimRacingApps.ps1`,
  only add applications with `$result.Outcome -eq 'Launched'` to `$placements`.
- **How an app is asked to close**: the `exitArguments` field covers apps with an exit command;
  anything else is in `Stop-LauncherApp` (graceful request → wait → terminate).
- **A new message or outcome**: add a `New-Result` in the engine, print it through `Show-Status`
  in the script, add the row to `DESIGN.md` section 6 and a test.

Keep it running on stock Windows: the code targets Windows PowerShell 5.1 (no `&&`, ternary,
`??`, or other PowerShell 7-only syntax) and the `.ps1`/`.psm1` files stay ASCII (or get a UTF-8
BOM), otherwise 5.1 misreads them. After a change, run the tests and the linter:

```powershell
Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck   # once
Invoke-Pester .\Tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1        # expect no output
```

## Running the tests

The tests never launch, move or close anything — everything that touches the machine is mocked,
except three tests that call the real Windows API on a window handle that does not exist. They
need Pester 5 or newer (Windows ships the ancient 3.4; install the current one once):

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester .\Tests
```

## License

MIT — see `LICENSE`. Use it, change it, share it; no warranty.
