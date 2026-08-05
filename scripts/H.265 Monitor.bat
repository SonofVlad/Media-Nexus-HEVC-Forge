@echo off
setlocal EnableExtensions

rem =====================================================
rem USER SETTINGS - EDIT ONLY THIS SECTION
rem =====================================================
set "LOGDIR=%~1"
set "FILTER=Watcher_*.log"
set "TAILLINES=200"
set "CHECKEVERYSECONDS=3"
rem =====================================================

if not defined LOGDIR set /p "LOGDIR=Converter logs folder: "

set "SCRIPT_DIR=%~dp0"
set "SCRIPT=%SCRIPT_DIR%H.265Monitor.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" (
  echo ERROR: Cannot find:
  echo %SCRIPT%
  echo.
  echo Make sure the .ps1 file is in the same folder as this .bat file.
  echo.
  pause
  exit /b 2
)

echo Running:
echo "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -LogDir "%LOGDIR%" -Filter "%FILTER%" -TailLines %TAILLINES% -CheckEverySeconds %CHECKEVERYSECONDS%
echo.

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" ^
  -LogDir "%LOGDIR%" ^
  -Filter "%FILTER%" ^
  -TailLines %TAILLINES% ^
  -CheckEverySeconds %CHECKEVERYSECONDS%

set "EC=%ERRORLEVEL%"

echo.
echo PowerShell exited with code: %EC%
pause

endlocal
