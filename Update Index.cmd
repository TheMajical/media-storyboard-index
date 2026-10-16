@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for the media storyboard index (Windows).
rem
rem  * Put this file, update-index.ps1 and template.html in the folder that
rem    contains your videos, then double-click to (re)build the index.
rem  * Or pass a folder:  "Update Index.cmd" "D:\Media\Videos"
rem  * Extra options are passed through, e.g.:  "Update Index.cmd" -SpeedMs 1000
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0update-index.ps1"
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Base "%~dp0"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Base %*
)
echo.
pause
