@echo off
rem ============================================================
rem  2 - remember the desktop exactly as it is now (my layout)
rem  ASCII-only content on purpose.
rem ============================================================
setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not exist "%~dp0Native.cs" goto missing
if not exist "%~dp0Save-MyLayout.ps1" goto missing

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Save-MyLayout.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo [exit code %RC%] - see the message above.
echo Press any key to close...
pause >nul
exit /b %RC%

:missing
echo.
echo ERROR: files are missing next to this .cmd.
echo Copy the WHOLE folder, not a single file.
echo.
echo Press any key to close...
pause >nul
exit /b 1
