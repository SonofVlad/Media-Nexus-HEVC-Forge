
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
set "NVENCQUALITY=25"
set "OUTPUTCONTAINER=mkv"
set "POLLSECONDS=10"
set "STABLESECONDS=20"
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

set "SCRIPT=%~dp0H.265ConverterNVIDIA.ps1"
set "FFMPEGBIN=%~dp0FFmpeg\bin"

echo.
echo ============================================================
echo Starting HEVC Forge NVIDIA NVENC Converter...
echo WorkingDir: "%~dp0"
echo Script:     "%SCRIPT%"
echo FFmpegBin:  "%FFMPEGBIN%"
echo ============================================================
echo.

if exist "%SCRIPT%" goto ScriptFound

echo ERROR: PowerShell script was not found.
echo Expected file:
echo "%SCRIPT%"
echo.
echo Make sure the PS1 file is in the same folder as this BAT file.
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
set "SW_SKIPIFEXISTS="
set "SW_MOVEEXISTING="
set "SW_SHOWSTATUS="

if /I "%SKIPIFOUTPUTEXISTS%"=="true" set "SW_SKIPIFEXISTS=-SkipIfOutputExists"
if /I "%MOVEALREADYENCODEDTOPROCESSED%"=="true" set "SW_MOVEEXISTING=-MoveAlreadyEncodedToProcessed"
if /I "%SHOWCONSOLESTATUS%"=="true" set "SW_SHOWSTATUS=-ShowConsoleStatus"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" ^
  -ProcessRoot "%PROCESSROOT%" ^
  -OutputRoot "%OUTPUTROOT%" ^
  -QuarantineRoot "%QUARANTINEROOT%" ^
  -LocalTempRoot "%LOCALTEMPROOT%" ^
  -Parallel %PARALLEL% ^
  -NvencQuality %NVENCQUALITY% ^
  -OutputContainer "%OUTPUTCONTAINER%" ^
  -PollSeconds %POLLSECONDS% ^
  -StableSeconds %STABLESECONDS% ^
  -MaxDurationDeltaSeconds %MAXDURATIONDELTASECONDS% ^
  -MinSizeRatio %MINSIZERATIO% ^
  -OnSuccess "%ONSUCCESS%" ^
  %SW_SKIPIFEXISTS% ^
  %SW_MOVEEXISTING% ^
  -FailBackoffMinutes %FAILBACKOFFMINUTES% ^
  %SW_SHOWSTATUS% ^
  -FFmpegBin "%FFMPEGBIN%"

set "EXITCODE=%ERRORLEVEL%"
echo.
echo ============================================================
echo Converter exited with code %EXITCODE%.
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

