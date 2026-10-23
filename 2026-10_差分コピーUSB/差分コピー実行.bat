@echo off
setlocal
cd /d "%~dp0"
echo === Diff copy : run ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiffCopy.ps1"
set RC=%ERRORLEVEL%
echo.
if %RC%==0 (echo [OK] finished.) else (echo [NG] finished with errors. exit code=%RC%)
pause
exit /b %RC%
