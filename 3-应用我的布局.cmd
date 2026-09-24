@echo off
rem ============================================================
rem  3 - put the desktop back to MY saved layout
rem  ASCII-only content on purpose.
rem ============================================================
setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not exist "%~dp0Native.cs" goto missing
if not exist "%~dp0Restore-DesktopIcons.ps1" goto missing

set "MY=%~dp0snapshots\my-%COMPUTERNAME%.json"
if not exist "%MY%" goto nolayout

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-DesktopIcons.ps1" -LayoutFile "%MY%"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo [exit code %RC%] - see the message above.
echo Press any key to close...
pause >nul
exit /b %RC%

:nolayout
echo.
echo No personal layout saved yet for this computer:
echo   %MY%
echo Double-click "2-save-my-layout.cmd" once you are happy with the desktop.
echo.
echo Press any key to close...
pause >nul
exit /b 1

:missing
echo.
echo ERROR: files are missing next to this .cmd.
echo Copy the WHOLE folder, not a single file.
echo.
echo Press any key to close...
pause >nul
exit /b 1
