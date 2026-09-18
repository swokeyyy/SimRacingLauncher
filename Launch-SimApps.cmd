@echo off
rem One click: launch every app in apps.json and place its window on its configured monitor.
rem -ExecutionPolicy Bypass applies to this one run only, so the script works on any PC without changing its policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SimRacingApps.ps1"
if errorlevel 1 pause
