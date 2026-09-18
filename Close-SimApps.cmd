@echo off
rem One click: close every app in apps.json, gracefully first.
rem -ExecutionPolicy Bypass applies to this one run only, so the script works on any PC without changing its policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-SimRacingApps.ps1"
if errorlevel 1 pause
