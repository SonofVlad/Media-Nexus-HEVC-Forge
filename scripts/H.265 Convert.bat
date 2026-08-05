@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================
REM USER SETTINGS - EDIT THESE VALUES ONLY
REM ============================================================

REM Full path to your input folder. You can also pass it as argument 1.
set "PROCESSROOT=%~1"

REM Full path to your output folder. You can also pass it as argument 2.
set "OUTPUTROOT=%~2"

REM Full path to your quarantine folder. You can also pass it as argument 3.
set "QUARANTINEROOT=%~3"

REM Local temp working folder on this PC (recommended: fast SSD)
set "LOCALTEMPROOT=%TEMP%\HEVCForge"

REM How many encodes to run at once
set "PARALLEL=4"

REM HEVC QSV quality (lower = larger/better quality, 18-22 is a common range)
set "QSVQUALITY=20"

REM Output container: mkv or mp4
set "OUTPUTCONTAINER=mkv"

REM How often to scan for new files (seconds)
set "POLLSECONDS=10"

REM File must stay the same size for this many seconds before processing
set "STABLESECONDS=30"

REM Allowed duration difference between source and output (seconds)
set "MAXDURATIONDELTASECONDS=5"

REM Minimum allowed output size ratio before quarantine
set "MINSIZERATIO=0.05"

REM What to do with successfully encoded source files: leave or move
set "ONSUCCESS=leave"

REM If output already exists, skip re-encoding: true or false
set "SKIPIFOUTPUTEXISTS=true"

REM If output already exists, move source to _PROCESSED: true or false
set "MOVEALREADYENCODEDTOPROCESSED=false"

REM If a file fails, wait this many minutes before retrying
set "FAILBACKOFFMINUTES=30"

REM Show live console dashboard: true or false
set "SHOWCONSOLESTATUS=true"

REM ============================================================
REM DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING
REM ============================================================

pushd "%~dp0"

if not defined PROCESSROOT set /p "PROCESSROOT=Input folder: "
if not defined OUTPUTROOT set /p "OUTPUTROOT=Output folder: "
if not defined QUARANTINEROOT set /p "QUARANTINEROOT=Quarantine folder: "

set "SCRIPT=%CD%\H.265Converter.ps1"
set "FFMPEGBIN=%CD%\FFmpeg\bin"

echo.
echo ============================================================
echo Starting HEVC Forge Intel QSV Converter...
echo WorkingDir: "%CD%"
echo Script:     "!SCRIPT!"
echo FFmpegBin:  "!FFMPEGBIN!"
echo ============================================================
echo.

if not exist "!SCRIPT!" (
    echo ERROR: Cannot find:
    echo !SCRIPT!
    echo.
    echo Make sure H.265Converter.ps1 is in the same folder as this BAT file.
    echo.
    pause
    popd
    exit /b 1
)

if not exist "!FFMPEGBIN!\ffmpeg.exe" (
    echo ERROR: Cannot find:
    echo !FFMPEGBIN!\ffmpeg.exe
    echo.
    echo Put ffmpeg.exe in the FFmpeg\bin folder next to this BAT file.
    echo.
    pause
    popd
    exit /b 1
)

if not exist "!FFMPEGBIN!\ffprobe.exe" (
    echo ERROR: Cannot find:
    echo !FFMPEGBIN!\ffprobe.exe
    echo.
    echo Put ffprobe.exe in the FFmpeg\bin folder next to this BAT file.
    echo.
    pause
    popd
    exit /b 1
)

set "SKIPARG="
if /I "%SKIPIFOUTPUTEXISTS%"=="true" set "SKIPARG=-SkipIfOutputExists"

set "MOVEARG="
if /I "%MOVEALREADYENCODEDTOPROCESSED%"=="true" set "MOVEARG=-MoveAlreadyEncodedToProcessed"

set "STATUSARG="
if /I "%SHOWCONSOLESTATUS%"=="true" set "STATUSARG=-ShowConsoleStatus"

echo Launching PowerShell watcher...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!SCRIPT!" ^
  -FFmpegBin "!FFMPEGBIN!" ^
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
if "%EXITCODE%"=="0" (
    echo PowerShell exited with code 0.
    echo Watcher stopped normally.
) else (
    echo PowerShell exited with code %EXITCODE%.
    echo The watcher hit an error or closed immediately.
)
echo Logs folder: %OUTPUTROOT%\_logs
echo ============================================================
echo.

popd
pause
endlocal
exit /b %EXITCODE%
