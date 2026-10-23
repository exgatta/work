@echo off
setlocal
cd /d "%~dp0"
echo === Diff copy : DRY RUN (nothing is copied) ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiffCopy.ps1" -DryRun
echo.
pause
exit /b %ERRORLEVEL%
