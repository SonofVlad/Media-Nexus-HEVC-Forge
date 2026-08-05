@echo off
setlocal EnableExtensions

REM ============================================================
REM USER SETTINGS - EDIT THESE VALUES ONLY
REM ============================================================

set "PROCESSROOT="
set "OUTPUTROOT="
set "QUARANTINEROOT="
set "LOCALTEMPROOT=%TEMP%\HEVCForge"
set "PARALLEL=4"
set "QSVQUALITY=20"
set "OUTPUTCONTAINER=mkv"
set "POLLSECONDS=10"
set "STABLESECONDS=30"
set "MAXDURATIONDELTASECONDS=5"
set "MINSIZERATIO=0.05"
set "ONSUCCESS=leave"
set "SKIPIFOUTPUTEXISTS=true"
set "MOVEALREADYENCODEDTOPROCESSED=false"
set "FAILBACKOFFMINUTES=30"
set "SHOWCONSOLESTATUS=true"

REM ============================================================
REM DO NOT EDIT BELOW THIS LINE
REM ============================================================

pushd "%~dp0"

if not defined PROCESSROOT set /p "PROCESSROOT=Input folder: "
if not defined OUTPUTROOT set /p "OUTPUTROOT=Output folder: "
if not defined QUARANTINEROOT set /p "QUARANTINEROOT=Quarantine folder: "

set "SCRIPT=%~dp0H.265ConverterINTEL.ps1"
set "FFMPEGBIN=%~dp0FFmpeg\bin"

echo.
echo ============================================================
echo Starting HEVC Forge Intel QSV Converter...
echo WorkingDir: "%~dp0"
echo Script:     "%SCRIPT%"
echo FFmpegBin:  "%FFMPEGBIN%"
echo ============================================================
echo.

if exist "%SCRIPT%" goto ScriptFound
echo ERROR: PowerShell script was not found.
echo Expected file:
echo "%SCRIPT%"
goto Failed

:ScriptFound
if exist "%FFMPEGBIN%\ffmpeg.exe" goto FFmpegFound
echo ERROR: ffmpeg.exe was not found.
echo Expected file:
echo "%FFMPEGBIN%\ffmpeg.exe"
goto Failed

:FFmpegFound
if exist "%FFMPEGBIN%\ffprobe.exe" goto FFprobeFound
echo ERROR: ffprobe.exe was not found.
echo Expected file:
echo "%FFMPEGBIN%\ffprobe.exe"
goto Failed

:FFprobeFound
set "SKIPARG="
set "MOVEARG="
set "STATUSARG="
if /I "%SKIPIFOUTPUTEXISTS%"=="true" set "SKIPARG=-SkipIfOutputExists"
if /I "%MOVEALREADYENCODEDTOPROCESSED%"=="true" set "MOVEARG=-MoveAlreadyEncodedToProcessed"
if /I "%SHOWCONSOLESTATUS%"=="true" set "STATUSARG=-ShowConsoleStatus"

echo Launching PowerShell watcher...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" ^
  -FFmpegBin "%FFMPEGBIN%" ^
  -ProcessRoot "%PROCESSROOT%" ^
  -OutputRoot "%OUTPUTROOT%" ^
  -QuarantineRoot "%QUARANTINEROOT%" ^
  -LocalTempRoot "%LOCALTEMPROOT%" ^
  -OutputContainer "%OUTPUTCONTAINER%" ^
  -Parallel %PARALLEL% ^
  -QsvQuality %QSVQUALITY% ^
  -PollSeconds %POLLSECONDS% ^
  -StableSeconds %STABLESECONDS% ^
  -MaxDurationDeltaSeconds %MAXDURATIONDELTASECONDS% ^
  -MinSizeRatio %MINSIZERATIO% ^
  -OnSuccess "%ONSUCCESS%" ^
  -FailBackoffMinutes %FAILBACKOFFMINUTES% ^
  %SKIPARG% ^
  %MOVEARG% ^
  %STATUSARG%

set "EXITCODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo Converter exited with code %EXITCODE%.
echo Logs folder: %OUTPUTROOT%\_logs
echo ============================================================
echo.
pause
popd
exit /b %EXITCODE%

:Failed
echo.
echo The converter did not start.
echo.
pause
popd
exit /b 1
