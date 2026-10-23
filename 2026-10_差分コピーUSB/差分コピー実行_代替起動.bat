@echo off
setlocal
cd /d "%~dp0"
echo === Diff copy : run (alternative launcher) ===
echo Use this one only if the normal .bat stops with an "execution policy" error.
powershell.exe -NoProfile -Command "$d = '%~dp0'.TrimEnd('\'); $s = Get-Content -LiteralPath (Join-Path $d 'DiffCopy.ps1') -Raw -Encoding UTF8; & ([scriptblock]::Create($s)) -BaseDir $d; exit $LASTEXITCODE"
set RC=%ERRORLEVEL%
echo.
if %RC%==0 (echo [OK] finished.) else (echo [NG] finished with errors. exit code=%RC%)
pause
exit /b %RC%
