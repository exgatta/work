@echo off
setlocal
cd /d "%~dp0"
echo === Diff copy : SELECT TARGET FOLDER ===
echo Pick target folder(s) from the list. The choice is saved to config.json.
echo Then a DRY RUN shows what would be copied (nothing is copied here).
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiffCopy.ps1" -SelectFolder -DryRun
echo.
pause
exit /b %ERRORLEVEL%
