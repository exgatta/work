@echo off
setlocal
cd /d "%~dp0"
echo === Diff copy : REGISTER ONLY ===
echo All files currently in the source folder will be marked as "already copied".
echo Nothing is copied. From the next run, only new files are copied.
echo.
set /p ANSWER=Continue? (y/N): 
if /i not "%ANSWER%"=="y" (
  echo Cancelled.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiffCopy.ps1" -RegisterOnly
echo.
pause
exit /b %ERRORLEVEL%
