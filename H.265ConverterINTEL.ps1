<#
H.265ConverterINTEL.ps1  (Windows PowerShell 5.1 compatible)

Version 1.0 ‚Äì Original logic
Version 1.1 ‚Äì Added +genpts and warning-only decode handling
Version 1.2 ‚Äì Capture ffmpeg stderr to temp files so PowerShell does not wrap
                native stderr in NativeCommandError records during decode validation
Version 1.3 ‚Äì Added real failed-file backoff markers and excluded internal RAW folders
                from scan candidates

Fix in this version:
- Prevents false "Decode test failed" quarantine on files that only emit
  "non monotonically increasing dts" timestamp warnings during ffmpeg null decode.
- Uses temp-file stderr capture instead of 2>&1 so Windows PowerShell 5.1
  does not inject:
    - "ffmpeg.exe : ..."
    - "At line:..."
    - "CategoryInfo"
    - "FullyQualifiedErrorId"
- Adds -fflags +genpts to decode validation.
- Still quarantines for real decode errors.
- When a file is quarantined, the original source video is also moved into QuarantineRoot
- Failed encodes now create .failed markers and honor FailBackoffMinutes
- RAW\_state and RAW\_PROCESSED are ignored during scans

Other features:
- Local temp only (no temporary encoding on network storage)
- Live console dashboard (YES)
- Stable file check (default 60s)
- HEVC QSV (hevc_qsv) with auto-deinterlace when field_order != progressive (bwdif)
- Encode -> validate -> copy to the destination as .part -> rename to final
- Quarantine on suspicious outputs (duration mismatch / decode test / too-small)
#>

[CmdletBinding()]
param(
    [string]$FFmpegBin,

    # Hot-folder paths
    [string]$ProcessRoot,
    [string]$OutputRoot,
    [string]$QuarantineRoot,

    [ValidateSet("mkv","mp4")]
    [string]$OutputContainer,

    # HEVC QSV quality: lower = higher quality/larger file. 18‚Äì22 is usually a safe range.
    [ValidateRange(10,35)]
    [int]$QsvQuality,

    # Parallel workers
    [ValidateRange(1,8)]
    [int]$Parallel,

    # Watch loop cadence
    [ValidateRange(2,600)]
    [int]$PollSeconds,

    # Stable file check: wait N seconds, re-check size (prevents processing while you're copying)
    [ValidateRange(10,600)]
    [int]$StableSeconds,

    # Validation
    [ValidateRange(1,30)]
    [int]$MaxDurationDeltaSeconds,

    # Output must be at least this fraction of input size (catches "something went wrong" tiny outputs)
    [ValidateRange(0.05,0.95)]
    [double]$MinSizeRatio,

    # Local temp encode root (keep on fast SSD)
    [string]$LocalTempRoot,

    # Success behavior for files we actually encoded:
    # leave = keep originals in RAW
    # move  = move originals into RAW\_PROCESSED (flattened filenames)
    [ValidateSet("leave","move")]
    [string]$OnSuccess,

    # If output already exists, skip re-encoding (prevents loops)
    [switch]$SkipIfOutputExists,

    # If output already exists, automatically move the source into RAW\_PROCESSED
    [switch]$MoveAlreadyEncodedToProcessed,

    # If a file fails, create a .failed marker and skip retry for this many minutes
    [ValidateRange(0,1440)]
    [int]$FailBackoffMinutes,

    # Console dashboard (Clear-Host each poll)
    [switch]$ShowConsoleStatus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Normalize incoming FFmpeg path in case the launcher passes a trailing slash or quotes
$FFmpegBin = [string]$FFmpegBin
$FFmpegBin = $FFmpegBin.Trim()
$FFmpegBin = $FFmpegBin.Trim('"')
$FFmpegBin = $FFmpegBin.TrimEnd([char[]]'\/')


# ---------------- helpers ----------------
function Coalesce([object]$Value, [string]$Fallback = "") {
    if ($null -ne $Value) { return [string]$Value }
    return $Fallback
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required file not found: $Path" }
}

function Ensure-Dir([string]$Path) {
    $null = New-Item -ItemType Directory -Force -Path $Path
}

function Get-Rel([string]$Root, [string]$FullPath) {
    $rootNorm = [IO.Path]::GetFullPath(($Root.TrimEnd('\') + '\'))
    $fullNorm = [IO.Path]::GetFullPath($FullPath)
    if ($fullNorm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullNorm.Substring($rootNorm.Length)
    }
    return $null
}

function Safe-MarkerName([string]$rel) {
    return ($rel -replace '[\\/:*?"<>|]', '_')
}

function Is-InternalProcessRel([string]$rel) {
    if ([string]::IsNullOrWhiteSpace($rel)) { return $true }
    $norm = $rel -replace '/', '\'
    return (
        $norm.StartsWith('_state\', [StringComparison]::OrdinalIgnoreCase) -or
        $norm.Equals('_state', [StringComparison]::OrdinalIgnoreCase) -or
        $norm.StartsWith('_PROCESSED\', [StringComparison]::OrdinalIgnoreCase) -or
        $norm.Equals('_PROCESSED', [StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-ProcessedMarkerPath([string]$rel) {
    return (Join-Path $stateDir ((Safe-MarkerName $rel) + ".processed.txt"))
}

function Get-FailedMarkerPath([string]$rel) {
    return (Join-Path $stateDir ((Safe-MarkerName $rel) + ".failed.txt"))
}

function Is-FailureBackoffActive([string]$rel) {
    if ($FailBackoffMinutes -le 0) { return $false }

    $failedMarker = Get-FailedMarkerPath $rel
    if (-not (Test-Path -LiteralPath $failedMarker)) { return $false }

    try {
        $item = Get-Item -LiteralPath $failedMarker -ErrorAction Stop
        $ageMinutes = ((Get-Date) - $item.LastWriteTime).TotalMinutes
        if ($ageMinutes -lt $FailBackoffMinutes) {
            return $true
        }

        Remove-Item -LiteralPath $failedMarker -Force -ErrorAction SilentlyContinue
        Log ("FAIL BACKOFF EXPIRED: {0}" -f $rel)
        return $false
    }
    catch {
        return $false
    }
}

function Write-FailedMarker([string]$rel, [string]$note, [string]$errText) {
    if ($FailBackoffMinutes -le 0) { return }

    $failedMarker = Get-FailedMarkerPath $rel
    try {
        @(
            ("FailedAt: {0}" -f (Get-Date).ToString("o")),
            ("BackoffMinutes: {0}" -f $FailBackoffMinutes),
            ("RelPath: {0}" -f $rel),
            ("Note: {0}" -f $note),
            "",
            "ErrorText:",
            (Coalesce $errText "")
        ) | Out-File -FilePath $failedMarker -Encoding UTF8 -Force
    }
    catch {}
}

function Clear-FailedMarker([string]$rel) {
    $failedMarker = Get-FailedMarkerPath $rel
    if (Test-Path -LiteralPath $failedMarker) {
        Remove-Item -LiteralPath $failedMarker -Force -ErrorAction SilentlyContinue
    }
}

function Is-FileStable([string]$Path, [int]$StableSeconds) {
    try {
        $a = Get-Item -LiteralPath $Path -ErrorAction Stop
        $s1 = $a.Length
        Start-Sleep -Seconds $StableSeconds
        $b = Get-Item -LiteralPath $Path -ErrorAction Stop
        $s2 = $b.Length
        return ($s1 -eq $s2)
    } catch {
        return $false
    }
}

function Format-Elapsed([DateTime]$start) {
    $ts = (Get-Date) - $start
    "{0:00}:{1:00}:{2:00}" -f [int]$ts.Hours, [int]$ts.Minutes, [int]$ts.Seconds
}

function Get-ExpectedOutputPath([string]$rel) {
    $relDir   = Split-Path $rel -Parent
    $baseName = [IO.Path]::GetFileNameWithoutExtension($rel)
    $dstDir = $OutputRoot
    if ($relDir) { $dstDir = Join-Path $OutputRoot $relDir }
    return (Join-Path $dstDir ($baseName + "." + $OutputContainer))
}

function Move-ToProcessed([string]$srcFull, [string]$rel) {
    $processedDir = Join-Path $ProcessRoot "_PROCESSED"
    Ensure-Dir $processedDir
    $dst = Join-Path $processedDir (Safe-MarkerName $rel)
    try { Move-Item -LiteralPath $srcFull -Destination $dst -Force -ErrorAction Stop } catch {}
}

function Move-ToQuarantine([string]$srcFull, [string]$rel) {
    Ensure-Dir $QuarantineRoot
    $dst = Join-Path $QuarantineRoot (Safe-MarkerName $rel)
    try { Move-Item -LiteralPath $srcFull -Destination $dst -Force -ErrorAction Stop } catch {}
}

function Test-IsIgnorableDecodeWarning([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $lines = @(
        $Text -split "(`r`n|`n|`r)" |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($lines.Count -eq 0) { return $false }

    foreach ($line in $lines) {
        if (
            ($line -match 'non monotonically increasing dts') -or
            ($line -match '^Last message repeated \d+ times$')
        ) {
            continue
        }
        return $false
    }

    return $true
}

function Decode-Test([string]$p) {
    $stderrFile = Join-Path $env:TEMP ("ffmpeg_decode_test_{0}.log" -f ([guid]::NewGuid().ToString("N")))
    try {
        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }

        & $FFmpegExe -nostdin -v error -fflags +genpts -i $p -map 0:v:0 -an -sn -dn -f null NUL 2>$stderrFile

        $text = ""
        if (Test-Path -LiteralPath $stderrFile) {
            $text = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        }
        $text = ($text | Out-String).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            return @{ Ok = $true; Text = "" }
        }

        if (Test-IsIgnorableDecodeWarning $text) {
            return @{ Ok = $true; Text = $text; WarningOnly = $true }
        }

        return @{ Ok = $false; Text = $text }
    }
    finally {
        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------- ffmpeg paths ----------------
$FFmpegExe  = Join-Path $FFmpegBin "ffmpeg.exe"
$FFprobeExe = Join-Path $FFmpegBin "ffprobe.exe"
Require-File $FFmpegExe
Require-File $FFprobeExe

# Verify QSV encoder exists
$encodersText = & $FFmpegExe -hide_banner -encoders 2>$null | Out-String
if ($encodersText -notmatch "hevc_qsv") {
    throw "FFmpeg does not report hevc_qsv. Ensure Intel iGPU drivers are installed and you have a full FFmpeg build."
}

# ---------------- folders/logging ----------------
Ensure-Dir $ProcessRoot
Ensure-Dir $OutputRoot
Ensure-Dir $QuarantineRoot
Ensure-Dir $LocalTempRoot

$stateDir = Join-Path $ProcessRoot "_state"
Ensure-Dir $stateDir

$logDir = Join-Path $OutputRoot "_logs"
Ensure-Dir $logDir

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$mainLog = Join-Path $logDir ("Watcher_{0}_{1}.log" -f $env:COMPUTERNAME, $timestamp)
$errLog  = Join-Path $logDir ("Watcher_{0}_{1}.errors.log" -f $env:COMPUTERNAME, $timestamp)
$manifestPath = Join-Path $logDir ("Watcher_Manifest_{0}_{1}.csv" -f $env:COMPUTERNAME, $timestamp)

function Log([string]$msg)    { ("[{0}] {1}" -f (Get-Date), $msg) | Out-File -FilePath $mainLog -Append -Encoding UTF8 }
function LogErr([string]$msg) { ("[{0}] {1}" -f (Get-Date), $msg) | Out-File -FilePath $errLog  -Append -Encoding UTF8; Log $msg }

# Status dir for console dashboard
$statusDir = Join-Path $LocalTempRoot ("_status_" + $env:COMPUTERNAME)
Ensure-Dir $statusDir

Log "Starting watcher on $env:COMPUTERNAME"
Log ("ProcessRoot:    {0}" -f $ProcessRoot)
Log ("OutputRoot:     {0}" -f $OutputRoot)
Log ("QuarantineRoot: {0}" -f $QuarantineRoot)
Log ("Parallel:       {0}" -f $Parallel)
Log ("QsvQuality:     {0}" -f $QsvQuality)
Log ("StableSeconds:  {0}" -f $StableSeconds)
Log ("PollSeconds:    {0}" -f $PollSeconds)
Log ("OnSuccess:      {0}" -f $OnSuccess)
Log ("SkipIfOutputExists: {0}" -f $SkipIfOutputExists)
Log ("MoveAlreadyEncodedToProcessed: {0}" -f $MoveAlreadyEncodedToProcessed)
Log ("FailBackoffMinutes: {0}" -f $FailBackoffMinutes)
Log ("LocalTempRoot:  {0}" -f $LocalTempRoot)
Log ("StatusDir:      {0}" -f $statusDir)

"Computer,Status,RelPath,SrcSizeMB,OutSizeMB,SrcDuration,OutDuration,FieldOrder,Deint,Note" |
    Out-File -FilePath $manifestPath -Encoding UTF8

# Video extensions
$videoExt = @(".mkv",".mp4",".avi",".mov",".mpg",".mpeg",".ts",".m2ts",".mts",".wmv")

Log ("VideoExt:       {0}" -f ($videoExt -join ', '))

if ($ShowConsoleStatus) {
    Write-Host ""
    Write-Host "Watcher initialized successfully."
    Write-Host ("Logs: {0}" -f $logDir)
    Write-Host ("Supported input extensions: {0}" -f ($videoExt -join ", "))
    Write-Host "Scanning RAW folder now..."
    Write-Host ""
}


function Get-Duration([string]$p) {
    $dur = & $FFprobeExe -v error -show_entries format=duration -of default=nw=1:nk=1 $p 2>$null
    if (-not $dur) { return $null }
    $dur = $dur.Trim()
    [double]$secs = 0
    if ([double]::TryParse($dur, [ref]$secs)) { return $secs }
    return $null
}

# ---------------- worker script ----------------
$workerScript = {
    param(
        [string]$JobId,
        [string]$SrcFull,
        [string]$ProcessRoot,
        [string]$OutputRoot,
        [string]$QuarantineRoot,
        [string]$OutputContainer,
        [int]$QsvQuality,
        [string]$FFmpegExe,
        [string]$FFprobeExe,
        [string]$LocalTempRoot,
        [string]$StatusDir,
        [int]$MaxDurationDeltaSeconds,
        [double]$MinSizeRatio,
        [bool]$SkipIfOutputExists
    )

    $result = [ordered]@{
        Status      = "UNKNOWN"   # DONE, QUARANTINE, FAIL, SKIP
        RelPath     = $null
        Note        = $null
        FieldOrder  = $null
        Deint       = $false
        SrcSizeMB   = $null
        OutSizeMB   = $null
        SrcDur      = $null
        OutDur      = $null
        ErrText     = $null
        OutputFinal = $null
    }

    $statusFile = Join-Path $StatusDir ("job_{0}.txt" -f $JobId)

    function CoalesceInner([object]$Value, [string]$Fallback = "") {
        if ($null -ne $Value) { return [string]$Value }
        return $Fallback
    }

    function Set-Status([string]$state, [string]$rel, [string]$note = "") {
        try {
            $line = "{0}|{1}|{2}|{3}" -f $state, (Get-Date).ToString("o"), $rel, $note
            $line | Out-File -FilePath $statusFile -Encoding UTF8 -Force
        } catch {}
    }

    function Get-RelInner([string]$root, [string]$full) {
        $rootNorm = [IO.Path]::GetFullPath(($root.TrimEnd('\') + '\'))
        $fullNorm = [IO.Path]::GetFullPath($full)
        if ($fullNorm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
            return $fullNorm.Substring($rootNorm.Length)
        }
        return $null
    }

    function Get-DurationInner([string]$probeExe, [string]$p) {
        $dur = & $probeExe -v error -show_entries format=duration -of default=nw=1:nk=1 $p 2>$null
        if (-not $dur) { return $null }
        $dur = $dur.Trim()
        [double]$secs = 0
        if ([double]::TryParse($dur, [ref]$secs)) { return $secs }
        return $null
    }

    function Test-IsIgnorableDecodeWarningInner([string]$Text) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

        $lines = @(
            $Text -split "(`r`n|`n|`r)" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($lines.Count -eq 0) { return $false }

        forea◊´hëÈÏ∂ªßq´^t       $result.Status = "FAIL"
                    $result.Note = "FFmpeg success but temp output missing"
                    $result.ErrText = $stderr1.Trim()
                    Set-Status "FAIL" $rel $result.Note
                    return [pscustomobject]$result
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $stderr1File) { Remove-Item -LiteralPath $stderr1File -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stderr2File) { Remove-Item -LiteralPath $stderr2File -Force -ErrorAction SilentlyContinue }
        }

        Move-Item -LiteralPath $tempOut -Destination $tempFinalLocal -Force
        Set-Status "VALIDATING" $rel ""

        # Validations
        $srcDur = Get-DurationInner $FFprobeExe $SrcFull
        $outDur = Get-DurationInner $FFprobeExe $tempFinalLocal
        $result.SrcDur = $srcDur
        $result.OutDur = $outDur

        if ($srcDur -and $outDur) {
            $delta = [Math]::Abs($srcDur - $outDur)
            if ($delta -gt $MaxDurationDeltaSeconds) {
                $result.Status = "QUARANTINE"
                $result.Note = ("Duration mismatch (delta {0}s)" -f $delta)
                Set-Status "QUARANTINE" $rel $result.Note
                return [pscustomobject]$result
            }
        }

        $dt = Decode-TestInner $FFmpegExe $tempFinalLocal
        if (-not $dt.Ok) {
            $result.Status = "QUARANTINE"
            $result.Note = "Decode test failed"
            $result.ErrText = $dt.Text
            Set-Status "QUARANTINE" $rel $result.Note
            return [pscustomobject]$result
        }

        if ($dt.ContainsKey("WarningOnly") -and $dt.WarningOnly) {
            if ([string]::IsNullOrWhiteSpace($result.Note)) {
                $result.Note = "Decode validation passed with ignorable DTS warnings"
            } else {
                $result.Note = ($result.Note + " | Decode validation passed with ignorable DTS warnings")
            }
        }

        $outSize = (Get-Item -LiteralPath $tempFinalLocal).Length
        $result.OutSizeMB = [Math]::Round($outSize / 1MB, 1)

        $ratio = 0.0
        if ($srcSize -gt 0) { $ratio = [double]$outSize / [double]$srcSize }

        # Resolution-aware minimum output ratio:
        #  - SD (<=576): 5%
        #  - 720p (<=720): 5%
        #  - 1080p+: 5%
        $hTxt = & $FFprobeExe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 $SrcFull 2>$null
        $height = 0
        if ($hTxt) { [int]::TryParse($hTxt.Trim(), [ref]$height) | Out-Null }

        $minRatioEffective = $MinSizeRatio
        if ($height -gt 0) {
            if ($height -le 576) { $minRatioEffective = 0.05 }
            elseif ($height -le 720) { $minRatioEffective = 0.05 }
            else { $minRatioEffective = 0.05 }
        }

        if ($ratio -lt $minRatioEffective) {
            $result.Status = "QUARANTINE"
            $result.Note = ("Output too small (ratio {0:P0}, min {1:P0}, height {2})" -f $ratio, $minRatioEffective, $height)
            Set-Status "QUARANTINE" $rel $result.Note
            return [pscustomobject]$result
        }

        Set-Status "COPYING" $rel ""

        # Copy to the destination as .part, then rename to the final file.
        $destPart = $destFinal + ".part"
        if (Test-Path -LiteralPath $destPart) { Remove-Item -LiteralPath $destPart -Force -ErrorAction SilentlyContinue }

        Copy-Item -LiteralPath $tempFinalLocal -Destination $destPart -Force

        if (Test-Path -LiteralPath $destFinal) { Remove-Item -LiteralPath $destFinal -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $destPart -Destination $destFinal -Force

        $result.Status = "DONE"
        Set-Status "DONE" $rel ""

        # Cleanup local temp output
        try { Remove-Item -LiteralPath $tempFinalLocal -Force -ErrorAction SilentlyContinue } catch {}

        return [pscustomobject]$result
    }
    catch {
        $result.Status = "FAIL"
        $result.Note = "Exception"
        $result.ErrText = $_.Exception.Message
        Set-Status "FAIL" (CoalesceInner $result.RelPath "(unknown)") $result.Note
        return [pscustomobject]$result
    }
    finally {
        try { Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ---------------- runspace pool ----------------
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Parallel)
$pool.Open()
$running = New-Object System.Collections.ArrayList
$inFlight = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

$lastSummary = ""

function Write-Manifest($obj) {
    $srcDurStr = ""
    $outDurStr = ""
    if ($null -ne $obj.SrcDur) { $srcDurStr = [Math]::Round([double]$obj.SrcDur, 2).ToString() }
    if ($null -ne $obj.OutDur) { $outDurStr = [Math]::Round([double]$obj.OutDur, 2).ToString() }

    $noteSafe = (Coalesce $obj.Note "") -replace '"','""'

    $line = '{0},{1},"{2}",{3},{4},{5},{6},{7},{8},"{9}"' -f `
        $env:COMPUTERNAME, `
        (Coalesce $obj.Status "FAIL"), `
        ((Coalesce $obj.RelPath "") -replace '"','""'), `
        (Coalesce $obj.SrcSizeMB ""), `
        (Coalesce $obj.OutSizeMB ""), `
        $srcDurStr, `
        $outDurStr, `
        (Coalesce $obj.FieldOrder ""), `
        (Coalesce $obj.Deint ""), `
        $noteSafe

    $line | Out-File -FilePath $manifestPath -Append -Encoding UTF8
}

function Render-Dashboard {
    if (-not $ShowConsoleStatus) { return }
    try {
        $queueCount =
            (Get-ChildItem -Path $ProcessRoot -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object {
                $includeInQueue = $true
                if (-not ($videoExt -contains $_.Extension.ToLowerInvariant())) { $includeInQueue = $false }

                if ($includeInQueue) {
                    $relQ = Get-Rel $ProcessRoot $_.FullName
                    if (-not $relQ) { $includeInQueue = $false }
                    elseif (Is-InternalProcessRel $relQ) { $includeInQueue = $false }
                    elseif (Test-Path -LiteralPath (Get-ProcessedMarkerPath $relQ)) { $includeInQueue = $false }
                    elseif (Is-FailureBackoffActive $relQ) { $includeInQueue = $false }
                }

                $includeInQueue
             }).Count

        Clear-Host
        Write-Host ("[{0}] Active: {1}/{2} | QSV Q={3} | Queue: {4}" -f (Get-Date -Format "HH:mm:ss"), $running.Count, $Parallel, $QsvQuality, $queueCount)
        if ($lastSummary) { Write-Host ("Last: {0}" -f $lastSummary) }
        Write-Host ""

        $idx = 1
        foreach ($r in ($running | Sort-Object Start)) {
            $sf = Join-Path $statusDir ("job_{0}.txt" -f $r.JobId)
            $state = "RUNNING"
            $rel   = "(starting)"
            $note  = ""
            $elapsed = Format-Elapsed $r.Start

            if (Test-Path -LiteralPath $sf) {
                $line = (Get-Content -LiteralPath $sf -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($line) {
                    $parts = $line -split '\|', 4
                    if ($parts.Count -ge 3) {
                        $state = $parts[0]
                        $rel   = $parts[2]
                        if ($parts.Count -ge 4) { $note = $parts[3] }
                    }
                }
            }

            if ($note) {
                Write-Host ("  #{0} {1,-10} {2}  ({3})  {4}" -f $idx, $state, $rel, $elapsed, $note)
            } else {
                Write-Host ("  #{0} {1,-10} {2}  ({3})" -f $idx, $state, $rel, $elapsed)
            }
            $idx++
        }

        if ($running.Count -eq 0) {
            Write-Host "  (idle)"
        }
    } catch { }
}

function Start-Job([string]$src) {
    $jobId = [Guid]::NewGuid().ToString("N")
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($workerScript).
        AddArgument($jobId).
        AddArgument($src).
        AddArgument($ProcessRoot).
        AddArgument($OutputRoot).
        AddArgument($QuarantineRoot).
        AddArgument($OutputContainer).
        AddArgument($QsvQuality).
        AddArgument($FFmpegExe).
        AddArgument($FFprobeExe).
        AddArgument($LocalTempRoot).
        AddArgument($statusDir).
        AddArgument($MaxDurationDeltaSeconds).
        AddArgument($MinSizeRatio).
        AddArgument([bool]$SkipIfOutputExists)

    $h = $ps.BeginInvoke()
    $null = $running.Add([pscustomobject]@{
        PS=$ps; Handle=$h; Src=$src; JobId=$jobId; Start=(Get-Date)
    })
}

Render-Dashboard

function IsInternalRawPath {
    param([string]$Path)

    $normalized = $Path -replace '/', '\'
    $root = $ProcessRoot.TrimEnd('\')
    return (
        $normalized -like "$root\_state\*" -or
        $normalized -like "$root\_PROCESSED\*"
    )
}

while ($true) {

    # Fill slots
    while ($running.Count -lt $Parallel) {
        $candidates =
            Get-ChildItem -Path $ProcessRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($videoExt -contains $_.Extension.ToLowerInvariant()) -and
                ($_.Name -notmatch '\.(part|tmp)$')
            } |
            Sort-Object FullName

        $picked = $null
        foreach ($f in $candidates) {
            if ($inFlight.Contains($f.FullName)) { continue }

            $rel = Get-Rel $ProcessRoot $f.FullName
            if (-not $rel) { continue }
            if (Is-InternalProcessRel $rel) { continue }

            # If already marked processed, ignore forever
            $processedMarker = Get-ProcessedMarkerPath $rel
            if (Test-Path -LiteralPath $processedMarker) { continue }

            # If a previous plain FAIL happened recently, honor the configured retry backoff
            if (Is-FailureBackoffActive $rel) { continue }

            # If output already exists, mark processed (and optionally move out of RAW)
            if ($SkipIfOutputExists) {
                $expectedOut = Get-ExpectedOutputPath $rel
                if (Test-Path -LiteralPath $expectedOut) {
                    try { ("{0} Output exists: {1}" -f (Get-Date), $expectedOut) | Out-File -FilePath $processedMarker -Encoding UTF8 -Force } catch {}
                    Log ("MARK PROCESSED (output exists): {0}" -f $rel)

                    if ($MoveAlreadyEncodedToProcessed) {
                        Move-ToProcessed -srcFull $f.FullName -rel $rel
                        Log ("MOVED to _PROCESSED: {0}" -f $rel)
                    }
                    continue
                }
            }

            # Stable copy guard
            if (-not (Is-FileStable -Path $f.FullName -StableSeconds $StableSeconds)) { continue }

            $picked = $f.FullName
            break
        }

        if (-not $picked) { break }

        $inFlight.Add($picked) | Out-Null
        Log ("START: {0}" -f $picked)
        Start-Job $picked
        Render-Dashboard
    }

    # Collect finished
    for ($i = $running.Count - 1; $i -ge 0; $i--) {
        $r = $running[$i]
        if ($r.Handle.IsCompleted) {
            $obj = $null
            try { $obj = $r.PS.EndInvoke($r.Handle) } catch {
                $obj = [pscustomobject]@{ Status="FAIL"; RelPath="(unknown)"; Note="EndInvoke failed"; ErrText=$_.Exception.Message }
            }

            $r.PS.Dispose()
            $running.RemoveAt($i)
            $inFlight.Remove($r.Src) | Out-Null

            if ($obj -is [System.Array]) { $obj = $obj[0] }

            $status = Coalesce $obj.Status "FAIL"
            $rel    = Coalesce $obj.RelPath "(unknown)"
            $note   = Coalesce $obj.Note ""

            Write-Manifest $obj

            if ($status -eq "DONE") {
                $lastSummary = ("DONE {0} | {1}MB -> {2}MB {3}" -f $rel, (Coalesce $obj.SrcSizeMB ""), (Coalesce $obj.OutSizeMB ""), $note).Trim()
                Log ("DONE: {0} | {1}MB -> {2}MB | {3}" -f $rel, (Coalesce $obj.SrcSizeMB ""), (Coalesce $obj.OutSizeMB ""), $note)

                Clear-FailedMarker $rel

                # Mark processed so RAW doesn't get re-scanned forever
                $processedMarker = Get-ProcessedMarkerPath $rel
                try { ("{0} DONE" -f (Get-Date)) | Out-File -FilePath $processedMarker -Encoding UTF8 -Force } catch {}

                if ($OnSuccess -eq "move") {
                    $srcFull = Join-Path $ProcessRoot $rel
                    if (Test-Path -LiteralPath $srcFull) {
                        Move-ToProcessed -srcFull $srcFull -rel $rel
                        Log ("MOVED to _PROCESSED: {0}" -f $rel)
                    }
                }
            }
            elseif ($status -eq "SKIP") {
                $lastSummary = ("SKIP {0} | {1}" -f $rel, $note).Trim()
                Log ("SKIP: {0} | {1}" -f $rel, $note)

                Clear-FailedMarker $rel

                # Mark processed on SKIP too (prevents endless SKIP loops)
                $processedMarker = Get-ProcessedMarkerPath $rel
                try { ("{0} SKIP {1}" -f (Get-Date), $note) | Out-File -FilePath $processedMarker -Encoding UTF8 -Force } catch {}
            }
            elseif ($status -eq "QUARANTINE") {
                $lastSummary = ("QUARANTINE {0} | {1}" -f $rel, $note).Trim()
                LogErr ("QUARANTINE: {0} | {1}" -f $rel, $note)

                Clear-FailedMarker $rel

                $qNote = Join-Path $QuarantineRoot ((Safe-MarkerName $rel) + ".txt")
                @(
                    ("RelPath: {0}" -f $rel),
                    ("Reason:  {0}" -f $note),
                    ("FieldOrder: {0}" -f (Coalesce $obj.FieldOrder "")),
                    ("Deint:   {0}" -f (Coalesce $obj.Deint "")),
                    ("SrcSizeMB: {0}" -f (Coalesce $obj.SrcSizeMB "")),
                    ("OutSizeMB: {0}" -f (Coalesce $obj.OutSizeMB "")),
                    "",
                    "ErrorText:",
                    (Coalesce $obj.ErrText "")
                ) | Out-File -FilePath $qNote -Encoding UTF8 -Force

                $srcFull = Join-Path $ProcessRoot $rel
                if (Test-Path -LiteralPath $srcFull) {
                    Move-ToQuarantine -srcFull $srcFull -rel $rel
                    LogErr ("QUARANTINED SOURCE MOVED: {0}" -f $rel)
                }
            }
            else {
                $lastSummary = ("FAIL {0} | {1}" -f $rel, $note).Trim()
                LogErr ("FAIL: {0} | {1}" -f $rel, $note)
                Write-FailedMarker -rel $rel -note $note -errText (Coalesce $obj.ErrText "")
                if ($FailBackoffMinutes -gt 0) {
                    LogErr ("FAIL BACKOFF: {0} will be skipped for {1} minute(s)" -f $rel, $FailBackoffMinutes)
                }
            }

            Render-Dashboard
        }
    }

    Render-Dashboard
    Start-Sleep -Seconds $PollSeconds
}

# not reached
$pool.Close()
$pool.Dispose()
Bà»[ù[]ZX⁄»ﬁ[ò»€€ùô\ù\ÉB