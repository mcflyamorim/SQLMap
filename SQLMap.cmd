@echo off
rem Starts the SQLMap UI. The console shows the startup steps (like Launch-SQLSecReview.cmd); keep it open while
rem SQLMap runs. -ExecutionPolicy Bypass applies to this process only (the scripts are not signed yet).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SQLMap.ps1"
