<#
H.265ConverterINTEL.ps1  (Windows PowerShell 5.1 compatible)

Version 1.0 â€“ Original logic
Version 1.1 â€“ Added +genpts and warning-only decode handling
Version 1.2 â€“ Capture ffmpeg stderr to temp files so PowerShell does not wrap
                native stderr in NativeCommandError records during decode validation
Version 1.3 â€“ Added real failed-file backoff markers and excluded internal RAW folders
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

    # HEVC QSV quality: lower = higher quality/larger file. 18â€“22 is usually a safe range.
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

        foreaÛ^õ¶‰žËkºwµçE±A…Ñ €‘Ñ•µÁ=ÕÐ¤¤ì(€€€€€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰%0ˆ(€€€€€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€‰µÁ•œÍÕ•ÍÌ‰ÕÐÑ•µÀ½ÕÑÁÕÐµ¥ÍÍ¥¹œˆ(€€€€€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹ÉÉQ•áÐ€ô€‘ÍÑ‘•ÉÈÄ¹QÉ¥´ ¤(€€€€€€€€€€€€€€€€€€€M•ÐµMÑ…ÑÕÌ€‰%0ˆ€‘É•°€‘É•ÍÕ±Ð¹9½Ñ”(€€€€€€€€€€€€€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô(€€€€€€€ô(€€€€€€€™¥¹…±±äì(€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘ÍÑ‘•ÉÈÅ¥±”¤ìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘ÍÑ‘•ÉÈÅ¥±”€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô(€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘ÍÑ‘•ÉÈÉ¥±”¤ìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘ÍÑ‘•ÉÈÉ¥±”€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô(€€€€€€€ô((€€€€€€€5½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘Ñ•µÁ=ÕÐ€µ•ÍÑ¥¹…Ñ¥½¸€‘Ñ•µÁ¥¹…±1½…°€µ½É”(€€€€€€€M•ÐµMÑ…ÑÕÌ€‰Y1%Q%9ˆ€‘É•°€ˆˆ((€€€€€€€€ŒY…±¥‘…Ñ¥½¹Ì(€€€€€€€€‘ÍÉÕÈ€ô•ÐµÕÉ…Ñ¥½¹%¹¹•È€‘ÁÉ½‰•á”€‘MÉÕ±°(€€€€€€€€‘½ÕÑÕÈ€ô•ÐµÕÉ…Ñ¥½¹%¹¹•È€‘ÁÉ½‰•á”€‘Ñ•µÁ¥¹…±1½…°(€€€€€€€€‘É•ÍÕ±Ð¹MÉÕÈ€ô€‘ÍÉÕÈ(€€€€€€€€‘É•ÍÕ±Ð¹=ÕÑÕÈ€ô€‘½ÕÑÕÈ((€€€€€€€¥˜€ ‘ÍÉÕÈ€µ…¹€‘½ÕÑÕÈ¤ì(€€€€€€€€€€€€‘‘•±Ñ„€ôm5…Ñ¡tèé‰Ì ‘ÍÉÕÈ€´€‘½ÕÑÕÈ¤(€€€€€€€€€€€¥˜€ ‘‘•±Ñ„€µÐ€‘5…áÕÉ…Ñ¥½¹•±Ñ…M•½¹‘Ì¤ì(€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰EUI9Q%9ˆ(€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€ ‰ÕÉ…Ñ¥½¸µ¥Íµ…Ñ €¡‘•±Ñ„ìÁõÌ¤ˆ€µ˜€‘‘•±Ñ„¤(€€€€€€€€€€€€€€€M•ÐµMÑ…ÑÕÌ€‰EUI9Q%9ˆ€‘É•°€‘É•ÍÕ±Ð¹9½Ñ”(€€€€€€€€€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€€€€€€€€€ô(€€€€€€€ô((€€€€€€€€‘‘Ð€ô•½‘”µQ•ÍÑ%¹¹•È€‘µÁ•á”€‘Ñ•µÁ¥¹…±1½…°(€€€€€€€¥˜€ µ¹½Ð€‘‘Ð¹=¬¤ì(€€€€€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰EUI9Q%9ˆ(€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€‰•½‘”Ñ•ÍÐ™…¥±•ˆ(€€€€€€€€€€€€‘É•ÍÕ±Ð¹ÉÉQ•áÐ€ô€‘‘Ð¹Q•áÐ(€€€€€€€€€€€M•ÐµMÑ…ÑÕÌ€‰EUI9Q%9ˆ€‘É•°€‘É•ÍÕ±Ð¹9½Ñ”(€€€€€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€€€€€ô((€€€€€€€¥˜€ ‘‘Ð¹½¹Ñ…¥¹Í-•ä ‰]…É¹¥¹=¹±äˆ¤€µ…¹€‘‘Ð¹]…É¹¥¹=¹±ä¤ì(€€€€€€€€€€€¥˜€¡mÍÑÉ¥¹tèé%Í9Õ±±=É]¡¥Ñ•MÁ…” ‘É•ÍÕ±Ð¹9½Ñ”¤¤ì(€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€‰•½‘”Ù…±¥‘…Ñ¥½¸Á…ÍÍ•Ý¥Ñ ¥¹½É…‰±”QLÝ…É¹¥¹Ìˆ(€€€€€€€€€€€ô•±Í”ì(€€€€€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€ ‘É•ÍÕ±Ð¹9½Ñ”€¬€ˆð•½‘”Ù…±¥‘…Ñ¥½¸Á…ÍÍ•Ý¥Ñ ¥¹½É…‰±”QLÝ…É¹¥¹Ìˆ¤(€€€€€€€€€€€ô(€€€€€€€ô((€€€€€€€€‘½ÕÑM¥é”€ô€¡•Ðµ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘Ñ•µÁ¥¹…±1½…°¤¹1•¹Ñ (€€€€€€€€‘É•ÍÕ±Ð¹=ÕÑM¥é•5€ôm5…Ñ¡tèéI½Õ¹ ‘½ÕÑM¥é”€¼€Å5°€Ä¤((€€€€€€€€‘É…Ñ¥¼€ô€À¸À(€€€€€€€¥˜€ ‘ÍÉM¥é”€µÐ€À¤ì€‘É…Ñ¥¼€ôm‘½Õ‰±•t‘½ÕÑM¥é”€¼m‘½Õ‰±•t‘ÍÉM¥é”ô((€€€€€€€€ŒI•Í½±ÕÑ¥½¸µ…Ý…É”µ¥¹¥µÕ´½ÕÑÁÕÐÉ…Ñ¥¼è(€€€€€€€€Œ€€´M€ ðôÔÜØ¤è€Ô”(€€€€€€€€Œ€€´€ÜÈÁÀ€ ðôÜÈÀ¤è€Ô”(€€€€€€€€Œ€€´€ÄÀàÁÀ¬è€Ô”(€€€€€€€€‘¡QáÐ€ô€˜€‘ÁÉ½‰•á”€µØ•ÉÉ½È€µÍ•±•Ñ}ÍÑÉ•…µÌØèÀ€µÍ¡½Ý}•¹ÑÉ¥•ÌÍÑÉ•…´õ¡•¥¡Ð€µ½˜‘•™…Õ±Ðõ¹ÜôÄé¹¬ôÄ€‘MÉÕ±°€Èø‘¹Õ±°(€€€€€€€€‘¡•¥¡Ð€ô€À(€€€€€€€¥˜€ ‘¡QáÐ¤ìm¥¹ÑtèéQÉåA…ÉÍ” ‘¡QáÐ¹QÉ¥´ ¤°mÉ•™t‘¡•¥¡Ð¤ð=ÕÐµ9Õ±°ô((€€€€€€€€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”€ô€‘5¥¹M¥é•I…Ñ¥¼(€€€€€€€¥˜€ ‘¡•¥¡Ð€µÐ€À¤ì(€€€€€€€€€€€¥˜€ ‘¡•¥¡Ð€µ±”€ÔÜØ¤ì€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”€ô€À¸ÀÔô(€€€€€€€€€€€•±Í•¥˜€ ‘¡•¥¡Ð€µ±”€ÜÈÀ¤ì€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”€ô€À¸ÀÔô(€€€€€€€€€€€•±Í”ì€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”€ô€À¸ÀÔô(€€€€€€€ô((€€€€€€€¥˜€ ‘É…Ñ¥¼€µ±Ð€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”¤ì(€€€€€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰EUI9Q%9ˆ(€€€€€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€ ‰=ÕÑÁÕÐÑ½¼Íµ…±°€¡É…Ñ¥¼ìÀé@Áô°µ¥¸ìÄé@Áô°¡•¥¡ÐìÉô¤ˆ€µ˜€‘É…Ñ¥¼°€‘µ¥¹I…Ñ¥½™™•Ñ¥Ù”°€‘¡•¥¡Ð¤(€€€€€€€€€€€M•ÐµMÑ…ÑÕÌ€‰EUI9Q%9ˆ€‘É•°€‘É•ÍÕ±Ð¹9½Ñ”(€€€€€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€€€€€ô((€€€€€€€M•ÐµMÑ…ÑÕÌ€‰=Ae%9ˆ€‘É•°€ˆˆ((€€€€€€€€Œ½ÁäÑ¼Ñ¡”‘•ÍÑ¥¹…Ñ¥½¸…Ì€¹Á…ÉÐ°Ñ¡•¸É•¹…µ”Ñ¼Ñ¡”™¥¹…°™¥±”¸(€€€€€€€€‘‘•ÍÑA…ÉÐ€ô€‘‘•ÍÑ¥¹…°€¬€ˆ¹Á…ÉÐˆ(€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘‘•ÍÑA…ÉÐ¤ìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘‘•ÍÑA…ÉÐ€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô((€€€€€€€½Áäµ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘Ñ•µÁ¥¹…±1½…°€µ•ÍÑ¥¹…Ñ¥½¸€‘‘•ÍÑA…ÉÐ€µ½É”((€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘‘•ÍÑ¥¹…°¤ìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘‘•ÍÑ¥¹…°€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô(€€€€€€€5½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘‘•ÍÑA…ÉÐ€µ•ÍÑ¥¹…Ñ¥½¸€‘‘•ÍÑ¥¹…°€µ½É”((€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰=9ˆ(€€€€€€€M•ÐµMÑ…ÑÕÌ€‰=9ˆ€‘É•°€ˆˆ((€€€€€€€€Œ±•…¹ÕÀ±½…°Ñ•µÀ½ÕÑÁÕÐ(€€€€€€€ÑÉäìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘Ñ•µÁ¥¹…±1½…°€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô…Ñ íô((€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€ô(€€€…Ñ ì(€€€€€€€€‘É•ÍÕ±Ð¹MÑ…ÑÕÌ€ô€‰%0ˆ(€€€€€€€€‘É•ÍÕ±Ð¹9½Ñ”€ô€‰á•ÁÑ¥½¸ˆ(€€€€€€€€‘É•ÍÕ±Ð¹ÉÉQ•áÐ€ô€‘|¹á•ÁÑ¥½¸¹5•ÍÍ…”(€€€€€€€M•ÐµMÑ…ÑÕÌ€‰%0ˆ€¡½…±•Í•%¹¹•È€‘É•ÍÕ±Ð¹I•±A…Ñ €ˆ¡Õ¹­¹½Ý¸¤ˆ¤€‘É•ÍÕ±Ð¹9½Ñ”(€€€€€€€É•ÑÕÉ¸mÁÍÕÍÑ½µ½‰©•Ñt‘É•ÍÕ±Ð(€€€ô(€€€™¥¹…±±äì(€€€€€€€ÑÉäìI•µ½Ù”µ%Ñ•´€µ1¥Ñ•É…±A…Ñ €‘ÍÑ…ÑÕÍ¥±”€µ½É”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ô…Ñ íô(€€€ô)ô((Œ€´´´´´´´´´´´´´´´´ÉÕ¹ÍÁ…”Á½½°€´´´´´´´´´´´´´´´´(‘Á½½°€ômIÕ¹ÍÁ…•…Ñ½ÉåtèéÉ•…Ñ•IÕ¹ÍÁ…•A½½° Ä°€‘A…É…±±•°¤(‘Á½½°¹=Á•¸ ¤(‘ÉÕ¹¹¥¹œ€ô9•Üµ=‰©•ÐMåÍÑ•´¹½±±•Ñ¥½¹Ì¹ÉÉ…å1¥ÍÐ(‘¥¹±¥¡Ð€ô9•Üµ=‰©•Ð€MåÍÑ•´¹½±±•Ñ¥½¹Ì¹•¹•É¥Œ¹!…Í¡M•ÑmÍÑÉ¥¹tœ€¡mMÑÉ¥¹½µÁ…É•Étèé=É‘¥¹…±%¹½É•…Í”¤((‘±…ÍÑMÕµµ…Éä€ô€ˆˆ()™Õ¹Ñ¥½¸]É¥Ñ”µ5…¹¥™•ÍÐ ‘½‰¨¤ì(€€€€‘ÍÉÕÉMÑÈ€ô€ˆˆ(€€€€‘½ÕÑÕÉMÑÈ€ô€ˆˆ(€€€¥˜€ ‘¹Õ±°€µ¹”€‘½‰¨¹MÉÕÈ¤ì€‘ÍÉÕÉMÑÈ€ôm5…Ñ¡tèéI½Õ¹¡m‘½Õ‰±•t‘½‰¨¹MÉÕÈ°€È¤¹Q½MÑÉ¥¹œ ¤ô(€€€¥˜€ ‘¹Õ±°€µ¹”€‘½‰¨¹=ÕÑÕÈ¤ì€‘½ÕÑÕÉMÑÈ€ôm5…Ñ¡tèéI½Õ¹¡m‘½Õ‰±•t‘½‰¨¹=ÕÑÕÈ°€È¤¹Q½MÑÉ¥¹œ ¤ô((€€€€‘¹½Ñ•M…™”€ô€¡½…±•Í”€‘½‰¨¹9½Ñ”€ˆˆ¤€µÉ•Á±…”€œˆœ°œˆˆœ((€€€€‘±¥¹”€ô€ìÁô±ìÅô°‰ìÉôˆ±ìÍô±ìÑô±ìÕô±ìÙô±ìÝô±ìáô°‰ìåôˆœ€µ˜€(€€€€€€€€‘•¹Øé=5AUQI95°€(€€€€€€€€¡½…±•Í”€‘½‰¨¹MÑ…ÑÕÌ€‰%0ˆ¤°€(€€€€€€€€ ¡½…±•Í”€‘½‰¨¹I•±A…Ñ €ˆˆ¤€µÉ•Á±…”€œˆœ°œˆˆœ¤°€(€€€€€€€€¡½…±•Í”€‘½‰¨¹MÉM¥é•5€ˆˆ¤°€(€€€€€€€€¡½…±•Í”€‘½‰¨¹=ÕÑM¥é•5€ˆˆ¤°€(€€€€€€€€‘ÍÉÕÉMÑÈ°€(€€€€€€€€‘½ÕÑÕÉMÑÈ°€(€€€€€€€€¡½…±•Í”€‘½‰¨¹¥•±‘=É‘•È€ˆˆ¤°€(€€€€€€€€¡½…±•Í”€‘½‰¨¹•¥¹Ð€ˆˆ¤°€(€€€€€€€€‘¹½Ñ•M…™”((€€€€‘±¥¹”ð=ÕÐµ¥±”€µ¥±•A…Ñ €‘µ…¹¥™•ÍÑA…Ñ €µÁÁ•¹€µ¹½‘¥¹œUQà)ô()™Õ¹Ñ¥½¸I•¹‘•Èµ…Í¡‰½…Éì(€€€¥˜€ µ¹½Ð€‘M¡½Ý½¹Í½±•MÑ…ÑÕÌ¤ìÉ•ÑÕÉ¸ô(€€€ÑÉäì(€€€€€€€€‘ÅÕ•Õ•½Õ¹Ð€ô(€€€€€€€€€€€€¡•Ðµ¡¥±‘%Ñ•´€µA…Ñ €‘AÉ½•ÍÍI½½Ð€µI•ÕÉÍ”€µ¥±”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ð(€€€€€€€€€€€€]¡•É”µ=‰©•Ðì(€€€€€€€€€€€€€€€€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘ÑÉÕ”(€€€€€€€€€€€€€€€¥˜€ µ¹½Ð€ ‘Ù¥‘•½áÐ€µ½¹Ñ…¥¹Ì€‘|¹áÑ•¹Í¥½¸¹Q½1½Ý•É%¹Ù…É¥…¹Ð ¤¤¤ì€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘™…±Í”ô((€€€€€€€€€€€€€€€¥˜€ ‘¥¹±Õ‘•%¹EÕ•Õ”¤ì(€€€€€€€€€€€€€€€€€€€€‘É•±D€ô•ÐµI•°€‘AÉ½•ÍÍI½½Ð€‘|¹Õ±±9…µ”(€€€€€€€€€€€€€€€€€€€¥˜€ µ¹½Ð€‘É•±D¤ì€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘™…±Í”ô(€€€€€€€€€€€€€€€€€€€•±Í•¥˜€¡%Ìµ%¹Ñ•É¹…±AÉ½•ÍÍI•°€‘É•±D¤ì€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘™…±Í”ô(€€€€€€€€€€€€€€€€€€€•±Í•¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €¡•ÐµAÉ½•ÍÍ•‘5…É­•ÉA…Ñ €‘É•±D¤¤ì€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘™…±Í”ô(€€€€€€€€€€€€€€€€€€€•±Í•¥˜€¡%Ìµ…¥±ÕÉ•	…­½™™Ñ¥Ù”€‘É•±D¤ì€‘¥¹±Õ‘•%¹EÕ•Õ”€ô€‘™…±Í”ô(€€€€€€€€€€€€€€€ô((€€€€€€€€€€€€€€€€‘¥¹±Õ‘•%¹EÕ•Õ”(€€€€€€€€€€€€ô¤¹½Õ¹Ð((€€€€€€€±•…Èµ!½ÍÐ(€€€€€€€]É¥Ñ”µ!½ÍÐ€ ‰mìÁõtÑ¥Ù”èìÅô½ìÉôðEMXDõìÍôðEÕ•Õ”èìÑôˆ€µ˜€¡•Ðµ…Ñ”€µ½Éµ…Ð€‰! éµ´éÍÌˆ¤°€‘ÉÕ¹¹¥¹œ¹½Õ¹Ð°€‘A…É…±±•°°€‘EÍÙEÕ…±¥Ñä°€‘ÅÕ•Õ•½Õ¹Ð¤(€€€€€€€¥˜€ ‘±…ÍÑMÕµµ…Éä¤ì]É¥Ñ”µ!½ÍÐ€ ‰1…ÍÐèìÁôˆ€µ˜€‘±…ÍÑMÕµµ…Éä¤ô(€€€€€€€]É¥Ñ”µ!½ÍÐ€ˆˆ((€€€€€€€€‘¥‘à€ô€Ä(€€€€€€€™½É•… € ‘È¥¸€ ‘ÉÕ¹¹¥¹œðM½ÉÐµ=‰©•ÐMÑ…ÉÐ¤¤ì(€€€€€€€€€€€€‘Í˜€ô)½¥¸µA…Ñ €‘ÍÑ…ÑÕÍ¥È€ ‰©½‰}ìÁô¹ÑáÐˆ€µ˜€‘È¹)½‰%¤(€€€€€€€€€€€€‘ÍÑ…Ñ”€ô€‰IU99%9ˆ(€€€€€€€€€€€€‘É•°€€€ô€ˆ¡ÍÑ…ÉÑ¥¹œ¤ˆ(€€€€€€€€€€€€‘¹½Ñ”€€ô€ˆˆ(€€€€€€€€€€€€‘•±…ÁÍ•€ô½Éµ…Ðµ±…ÁÍ•€‘È¹MÑ…ÉÐ((€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘Í˜¤ì(€€€€€€€€€€€€€€€€‘±¥¹”€ô€¡•Ðµ½¹Ñ•¹Ð€µ1¥Ñ•É…±A…Ñ €‘Í˜€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ðM•±•Ðµ=‰©•Ð€µ¥ÉÍÐ€Ä¤(€€€€€€€€€€€€€€€¥˜€ ‘±¥¹”¤ì(€€€€€€€€€€€€€€€€€€€€‘Á…ÉÑÌ€ô€‘±¥¹”€µÍÁ±¥Ð€qðœ°€Ð(€€€€€€€€€€€€€€€€€€€¥˜€ ‘Á…ÉÑÌ¹½Õ¹Ð€µ”€Ì¤ì(€€€€€€€€€€€€€€€€€€€€€€€€‘ÍÑ…Ñ”€ô€‘Á…ÉÑÍlÁt(€€€€€€€€€€€€€€€€€€€€€€€€‘É•°€€€ô€‘Á…ÉÑÍlÉt(€€€€€€€€€€€€€€€€€€€€€€€¥˜€ ‘Á…ÉÑÌ¹½Õ¹Ð€µ”€Ð¤ì€‘¹½Ñ”€ô€‘Á…ÉÑÍlÍtô(€€€€€€€€€€€€€€€€€€€ô(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô((€€€€€€€€€€€¥˜€ ‘¹½Ñ”¤ì(€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍÐ€ ˆ€€ìÁôìÄ°´ÄÁôìÉô€€¡ìÍô¤€ìÑôˆ€µ˜€‘¥‘à°€‘ÍÑ…Ñ”°€‘É•°°€‘•±…ÁÍ•°€‘¹½Ñ”¤(€€€€€€€€€€€ô•±Í”ì(€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍÐ€ ˆ€€ìÁôìÄ°´ÄÁôìÉô€€¡ìÍô¤ˆ€µ˜€‘¥‘à°€‘ÍÑ…Ñ”°€‘É•°°€‘•±…ÁÍ•¤(€€€€€€€€€€€ô(€€€€€€€€€€€€‘¥‘à¬¬(€€€€€€€ô((€€€€€€€¥˜€ ‘ÉÕ¹¹¥¹œ¹½Õ¹Ð€µ•Ä€À¤ì(€€€€€€€€€€€]É¥Ñ”µ!½ÍÐ€ˆ€€¡¥‘±”¤ˆ(€€€€€€€ô(€€€ô…Ñ ìô)ô()™Õ¹Ñ¥½¸MÑ…ÉÐµ)½ˆ¡mÍÑÉ¥¹t‘ÍÉŒ¤ì(€€€€‘©½‰%€ômÕ¥‘tèé9•ÝÕ¥ ¤¹Q½MÑÉ¥¹œ ‰8ˆ¤(€€€€‘ÁÌ€ômA½Ý•ÉM¡•±±tèéÉ•…Ñ” ¤(€€€€‘ÁÌ¹IÕ¹ÍÁ…•A½½°€ô€‘Á½½°(€€€€‘¹Õ±°€ô€‘ÁÌ¹‘‘MÉ¥ÁÐ ‘Ý½É­•ÉMÉ¥ÁÐ¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘©½‰%¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘ÍÉŒ¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘AÉ½•ÍÍI½½Ð¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘=ÕÑÁÕÑI½½Ð¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘EÕ…É…¹Ñ¥¹•I½½Ð¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘=ÕÑÁÕÑ½¹Ñ…¥¹•È¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘EÍÙEÕ…±¥Ñä¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘µÁ•á”¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘ÁÉ½‰•á”¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘1½…±Q•µÁI½½Ð¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘ÍÑ…ÑÕÍ¥È¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘5…áÕÉ…Ñ¥½¹•±Ñ…M•½¹‘Ì¤¸(€€€€€€€‘‘ÉÕµ•¹Ð ‘5¥¹M¥é•I…Ñ¥¼¤¸(€€€€€€€‘‘ÉÕµ•¹Ð¡m‰½½±t‘M­¥Á%™=ÕÑÁÕÑá¥ÍÑÌ¤((€€€€‘ €ô€‘ÁÌ¹	•¥¹%¹Ù½­” ¤(€€€€‘¹Õ±°€ô€‘ÉÕ¹¹¥¹œ¹‘¡mÁÍÕÍÑ½µ½‰©•Ñuì(€€€€€€€ALô‘ÁÌì!…¹‘±”ô‘ ìMÉŒô‘ÍÉŒì)½‰%ô‘©½‰%ìMÑ…ÉÐô¡•Ðµ…Ñ”¤(€€€ô¤)ô()I•¹‘•Èµ…Í¡‰½…É()™Õ¹Ñ¥½¸%Í%¹Ñ•É¹…±I…ÝA…Ñ ì(€€€Á…É…´¡mÍÑÉ¥¹t‘A…Ñ ¤((€€€€‘¹½Éµ…±¥é•€ô€‘A…Ñ €µÉ•Á±…”€œ¼œ°€pœ(€€€€‘É½½Ð€ô€‘AÉ½•ÍÍI½½Ð¹QÉ¥µ¹ pœ¤(€€€É•ÑÕÉ¸€ (€€€€€€€€‘¹½Éµ…±¥é•€µ±¥­”€ˆ‘É½½Ñq}ÍÑ…Ñ•p¨ˆ€µ½È(€€€€€€€€‘¹½Éµ…±¥é•€µ±¥­”€ˆ‘É½½Ñq}AI=MMp¨ˆ(€€€€¤)ô()Ý¡¥±”€ ‘ÑÉÕ”¤ì((€€€€Œ¥±°Í±½ÑÌ(€€€Ý¡¥±”€ ‘ÉÕ¹¹¥¹œ¹½Õ¹Ð€µ±Ð€‘A…É…±±•°¤ì(€€€€€€€€‘…¹‘¥‘…Ñ•Ì€ô(€€€€€€€€€€€•Ðµ¡¥±‘%Ñ•´€µA…Ñ €‘AÉ½•ÍÍI½½Ð€µI•ÕÉÍ”€µ¥±”€µÉÉ½ÉÑ¥½¸M¥±•¹Ñ±å½¹Ñ¥¹Õ”ð(€€€€€€€€€€€]¡•É”µ=‰©•Ðì(€€€€€€€€€€€€€€€€ ‘Ù¥‘•½áÐ€µ½¹Ñ…¥¹Ì€‘|¹áÑ•¹Í¥½¸¹Q½1½Ý•É%¹Ù…É¥…¹Ð ¤¤€µ…¹(€€€€€€€€€€€€€€€€ ‘|¹9…µ”€µ¹½Ñµ…Ñ €p¸¡Á…ÉÑñÑµÀ¤œ¤(€€€€€€€€€€€ôð(€€€€€€€€€€€M½ÉÐµ=‰©•ÐÕ±±9…µ”((€€€€€€€€‘Á¥­•€ô€‘¹Õ±°(€€€€€€€™½É•… € ‘˜¥¸€‘…¹‘¥‘…Ñ•Ì¤ì(€€€€€€€€€€€¥˜€ ‘¥¹±¥¡Ð¹½¹Ñ…¥¹Ì ‘˜¹Õ±±9…µ”¤¤ì½¹Ñ¥¹Õ”ô((€€€€€€€€€€€€‘É•°€ô•ÐµI•°€‘AÉ½•ÍÍI½½Ð€‘˜¹Õ±±9…µ”(€€€€€€€€€€€¥˜€ µ¹½Ð€‘É•°¤ì½¹Ñ¥¹Õ”ô(€€€€€€€€€€€¥˜€¡%Ìµ%¹Ñ•É¹…±AÉ½•ÍÍI•°€‘É•°¤ì½¹Ñ¥¹Õ”ô((€€€€€€€€€€€€Œ%˜…±É•…‘äµ…É­•ÁÉ½•ÍÍ•°¥¹½É”™½É•Ù•È(€€€€€€€€€€€€‘ÁÉ½•ÍÍ•‘5…É­•È€ô•ÐµAÉ½•ÍÍ•‘5…É­•ÉA…Ñ €‘É•°(€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘ÁÉ½•ÍÍ•‘5…É­•È¤ì½¹Ñ¥¹Õ”ô((€€€€€€€€€€€€Œ%˜„ÁÉ•Ù¥½ÕÌÁ±…¥¸%0¡…ÁÁ•¹•É••¹Ñ±ä°¡½¹½ÈÑ¡”½¹™¥ÕÉ•É•ÑÉä‰…­½™˜(€€€€€€€€€€€¥˜€¡%Ìµ…¥±ÕÉ•	…­½™™Ñ¥Ù”€‘É•°¤ì½¹Ñ¥¹Õ”ô((€€€€€€€€€€€€Œ%˜½ÕÑÁÕÐ…±É•…‘ä•á¥ÍÑÌ°µ…É¬ÁÉ½•ÍÍ•€¡…¹½ÁÑ¥½¹…±±äµ½Ù”½ÕÐ½˜I\¤(€€€€€€€€€€€¥˜€ ‘M­¥Á%™=ÕÑÁÕÑá¥ÍÑÌ¤ì(€€€€€€€€€€€€€€€€‘•áÁ•Ñ•‘=ÕÐ€ô•ÐµáÁ•Ñ•‘=ÕÑÁÕÑA…Ñ €‘É•°(€€€€€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘•áÁ•Ñ•‘=ÕÐ¤ì(€€€€€€€€€€€€€€€€€€€ÑÉäì€ ‰ìÁô=ÕÑÁÕÐ•á¥ÍÑÌèìÅôˆ€µ˜€¡•Ðµ…Ñ”¤°€‘•áÁ•Ñ•‘=ÕÐ¤ð=ÕÐµ¥±”€µ¥±•A…Ñ €‘ÁÉ½•ÍÍ•‘5…É­•È€µ¹½‘¥¹œUQà€µ½É”ô…Ñ íô(€€€€€€€€€€€€€€€€€€€1½œ€ ‰5I,AI=MM€¡½ÕÑÁÕÐ•á¥ÍÑÌ¤èìÁôˆ€µ˜€‘É•°¤((€€€€€€€€€€€€€€€€€€€¥˜€ ‘5½Ù•±É•…‘å¹½‘•‘Q½AÉ½•ÍÍ•¤ì(€€€€€€€€€€€€€€€€€€€€€€€5½Ù”µQ½AÉ½•ÍÍ•€µÍÉÕ±°€‘˜¹Õ±±9…µ”€µÉ•°€‘É•°(€€€€€€€€€€€€€€€€€€€€€€€1½œ€ ‰5=YÑ¼}AI=MMèìÁôˆ€µ˜€‘É•°¤(€€€€€€€€€€€€€€€€€€€ô(€€€€€€€€€€€€€€€€€€€½¹Ñ¥¹Õ”(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô((€€€€€€€€€€€€ŒMÑ…‰±”½ÁäÕ…É(€€€€€€€€€€€¥˜€ µ¹½Ð€¡%Ìµ¥±•MÑ…‰±”€µA…Ñ €‘˜¹Õ±±9…µ”€µMÑ…‰±•M•½¹‘Ì€‘MÑ…‰±•M•½¹‘Ì¤¤ì½¹Ñ¥¹Õ”ô((€€€€€€€€€€€€‘Á¥­•€ô€‘˜¹Õ±±9…µ”(€€€€€€€€€€€‰É•…¬(€€€€€€€ô((€€€€€€€¥˜€ µ¹½Ð€‘Á¥­•¤ì‰É•…¬ô((€€€€€€€€‘¥¹±¥¡Ð¹‘ ‘Á¥­•¤ð=ÕÐµ9Õ±°(€€€€€€€1½œ€ ‰MQIPèìÁôˆ€µ˜€‘Á¥­•¤(€€€€€€€MÑ…ÉÐµ)½ˆ€‘Á¥­•(€€€€€€€I•¹‘•Èµ…Í¡‰½…É(€€€ô((€€€€Œ½±±•Ð™¥¹¥Í¡•(€€€™½È€ ‘¤€ô€‘ÉÕ¹¹¥¹œ¹½Õ¹Ð€´€Äì€‘¤€µ”€Àì€‘¤´´¤ì(€€€€€€€€‘È€ô€‘ÉÕ¹¹¥¹l‘¥t(€€€€€€€¥˜€ ‘È¹!…¹‘±”¹%Í½µÁ±•Ñ•¤ì(€€€€€€€€€€€€‘½‰¨€ô€‘¹Õ±°(€€€€€€€€€€€ÑÉäì€‘½‰¨€ô€‘È¹AL¹¹‘%¹Ù½­” ‘È¹!…¹‘±”¤ô…Ñ ì(€€€€€€€€€€€€€€€€‘½‰¨€ômÁÍÕÍÑ½µ½‰©•ÑuìMÑ…ÑÕÌô‰%0ˆìI•±A…Ñ ôˆ¡Õ¹­¹½Ý¸¤ˆì9½Ñ”ô‰¹‘%¹Ù½­”™…¥±•ˆìÉÉQ•áÐô‘|¹á•ÁÑ¥½¸¹5•ÍÍ…”ô(€€€€€€€€€€€ô((€€€€€€€€€€€€‘È¹AL¹¥ÍÁ½Í” ¤(€€€€€€€€€€€€‘ÉÕ¹¹¥¹œ¹I•µ½Ù•Ð ‘¤¤(€€€€€€€€€€€€‘¥¹±¥¡Ð¹I•µ½Ù” ‘È¹MÉŒ¤ð=ÕÐµ9Õ±°((€€€€€€€€€€€¥˜€ ‘½‰¨€µ¥ÌmMåÍÑ•´¹ÉÉ…åt¤ì€‘½‰¨€ô€‘½‰©lÁtô((€€€€€€€€€€€€‘ÍÑ…ÑÕÌ€ô½…±•Í”€‘½‰¨¹MÑ…ÑÕÌ€‰%0ˆ(€€€€€€€€€€€€‘É•°€€€€ô½…±•Í”€‘½‰¨¹I•±A…Ñ €ˆ¡Õ¹­¹½Ý¸¤ˆ(€€€€€€€€€€€€‘¹½Ñ”€€€ô½…±•Í”€‘½‰¨¹9½Ñ”€ˆˆ((€€€€€€€€€€€]É¥Ñ”µ5…¹¥™•ÍÐ€‘½‰¨((€€€€€€€€€€€¥˜€ ‘ÍÑ…ÑÕÌ€µ•Ä€‰=9ˆ¤ì(€€€€€€€€€€€€€€€€‘±…ÍÑMÕµµ…Éä€ô€ ‰=9ìÁôðìÅõ5€´øìÉõ5ìÍôˆ€µ˜€‘É•°°€¡½…±•Í”€‘½‰¨¹MÉM¥é•5€ˆˆ¤°€¡½…±•Í”€‘½‰¨¹=ÕÑM¥é•5€ˆˆ¤°€‘¹½Ñ”¤¹QÉ¥´ ¤(€€€€€€€€€€€€€€€1½œ€ ‰=9èìÁôðìÅõ5€´øìÉõ5ðìÍôˆ€µ˜€‘É•°°€¡½…±•Í”€‘½‰¨¹MÉM¥é•5€ˆˆ¤°€¡½…±•Í”€‘½‰¨¹=ÕÑM¥é•5€ˆˆ¤°€‘¹½Ñ”¤((€€€€€€€€€€€€€€€±•…Èµ…¥±•‘5…É­•È€‘É•°((€€€€€€€€€€€€€€€€Œ5…É¬ÁÉ½•ÍÍ•Í¼I\‘½•Í¸Ð•ÐÉ”µÍ…¹¹•™½É•Ù•È(€€€€€€€€€€€€€€€€‘ÁÉ½•ÍÍ•‘5…É­•È€ô•ÐµAÉ½•ÍÍ•‘5…É­•ÉA…Ñ €‘É•°(€€€€€€€€€€€€€€€ÑÉäì€ ‰ìÁô=9ˆ€µ˜€¡•Ðµ…Ñ”¤¤ð=ÕÐµ¥±”€µ¥±•A…Ñ €‘ÁÉ½•ÍÍ•‘5…É­•È€µ¹½‘¥¹œUQà€µ½É”ô…Ñ íô((€€€€€€€€€€€€€€€¥˜€ ‘=¹MÕ•ÍÌ€µ•Ä€‰µ½Ù”ˆ¤ì(€€€€€€€€€€€€€€€€€€€€‘ÍÉÕ±°€ô)½¥¸µA…Ñ €‘AÉ½•ÍÍI½½Ð€‘É•°(€€€€€€€€€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘ÍÉÕ±°¤ì(€€€€€€€€€€€€€€€€€€€€€€€5½Ù”µQ½AÉ½•ÍÍ•€µÍÉÕ±°€‘ÍÉÕ±°€µÉ•°€‘É•°(€€€€€€€€€€€€€€€€€€€€€€€1½œ€ ‰5=YÑ¼}AI=MMèìÁôˆ€µ˜€‘É•°¤(€€€€€€€€€€€€€€€€€€€ô(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô(€€€€€€€€€€€•±Í•¥˜€ ‘ÍÑ…ÑÕÌ€µ•Ä€‰M-%@ˆ¤ì(€€€€€€€€€€€€€€€€‘±…ÍÑMÕµµ…Éä€ô€ ‰M-%@ìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤¹QÉ¥´ ¤(€€€€€€€€€€€€€€€1½œ€ ‰M-%@èìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤((€€€€€€€€€€€€€€€±•…Èµ…¥±•‘5…É­•È€‘É•°((€€€€€€€€€€€€€€€€Œ5…É¬ÁÉ½•ÍÍ•½¸M-%@Ñ½¼€¡ÁÉ•Ù•¹ÑÌ•¹‘±•ÍÌM-%@±½½ÁÌ¤(€€€€€€€€€€€€€€€€‘ÁÉ½•ÍÍ•‘5…É­•È€ô•ÐµAÉ½•ÍÍ•‘5…É­•ÉA…Ñ €‘É•°(€€€€€€€€€€€€€€€ÑÉäì€ ‰ìÁôM-%@ìÅôˆ€µ˜€¡•Ðµ…Ñ”¤°€‘¹½Ñ”¤ð=ÕÐµ¥±”€µ¥±•A…Ñ €‘ÁÉ½•ÍÍ•‘5…É­•È€µ¹½‘¥¹œUQà€µ½É”ô…Ñ íô(€€€€€€€€€€€ô(€€€€€€€€€€€•±Í•¥˜€ ‘ÍÑ…ÑÕÌ€µ•Ä€‰EUI9Q%9ˆ¤ì(€€€€€€€€€€€€€€€€‘±…ÍÑMÕµµ…Éä€ô€ ‰EUI9Q%9ìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤¹QÉ¥´ ¤(€€€€€€€€€€€€€€€1½ÉÈ€ ‰EUI9Q%9èìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤((€€€€€€€€€€€€€€€±•…Èµ…¥±•‘5…É­•È€‘É•°((€€€€€€€€€€€€€€€€‘Å9½Ñ”€ô)½¥¸µA…Ñ €‘EÕ…É…¹Ñ¥¹•I½½Ð€ ¡M…™”µ5…É­•É9…µ”€‘É•°¤€¬€ˆ¹ÑáÐˆ¤(€€€€€€€€€€€€€€€  (€€€€€€€€€€€€€€€€€€€€ ‰I•±A…Ñ èìÁôˆ€µ˜€‘É•°¤°(€€€€€€€€€€€€€€€€€€€€ ‰I•…Í½¸è€ìÁôˆ€µ˜€‘¹½Ñ”¤°(€€€€€€€€€€€€€€€€€€€€ ‰¥•±‘=É‘•ÈèìÁôˆ€µ˜€¡½…±•Í”€‘½‰¨¹¥•±‘=É‘•È€ˆˆ¤¤°(€€€€€€€€€€€€€€€€€€€€ ‰•¥¹Ðè€€ìÁôˆ€µ˜€¡½…±•Í”€‘½‰¨¹•¥¹Ð€ˆˆ¤¤°(€€€€€€€€€€€€€€€€€€€€ ‰MÉM¥é•5èìÁôˆ€µ˜€¡½…±•Í”€‘½‰¨¹MÉM¥é•5€ˆˆ¤¤°(€€€€€€€€€€€€€€€€€€€€ ‰=ÕÑM¥é•5èìÁôˆ€µ˜€¡½…±•Í”€‘½‰¨¹=ÕÑM¥é•5€ˆˆ¤¤°(€€€€€€€€€€€€€€€€€€€€ˆˆ°(€€€€€€€€€€€€€€€€€€€€‰ÉÉ½ÉQ•áÐèˆ°(€€€€€€€€€€€€€€€€€€€€¡½…±•Í”€‘½‰¨¹ÉÉQ•áÐ€ˆˆ¤(€€€€€€€€€€€€€€€€¤ð=ÕÐµ¥±”€µ¥±•A…Ñ €‘Å9½Ñ”€µ¹½‘¥¹œUQà€µ½É”((€€€€€€€€€€€€€€€€‘ÍÉÕ±°€ô)½¥¸µA…Ñ €‘AÉ½•ÍÍI½½Ð€‘É•°(€€€€€€€€€€€€€€€¥˜€¡Q•ÍÐµA…Ñ €µ1¥Ñ•É…±A…Ñ €‘ÍÉÕ±°¤ì(€€€€€€€€€€€€€€€€€€€5½Ù”µQ½EÕ…É…¹Ñ¥¹”€µÍÉÕ±°€‘ÍÉÕ±°€µÉ•°€‘É•°(€€€€€€€€€€€€€€€€€€€1½ÉÈ€ ‰EUI9Q%9M=UI5=YèìÁôˆ€µ˜€‘É•°¤(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô(€€€€€€€€€€€•±Í”ì(€€€€€€€€€€€€€€€€‘±…ÍÑMÕµµ…Éä€ô€ ‰%0ìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤¹QÉ¥´ ¤(€€€€€€€€€€€€€€€1½ÉÈ€ ‰%0èìÁôðìÅôˆ€µ˜€‘É•°°€‘¹½Ñ”¤(€€€€€€€€€€€€€€€]É¥Ñ”µ…¥±•‘5…É­•È€µÉ•°€‘É•°€µ¹½Ñ”€‘¹½Ñ”€µ•ÉÉQ•áÐ€¡½…±•Í”€‘½‰¨¹ÉÉQ•áÐ€ˆˆ¤(€€€€€€€€€€€€€€€¥˜€ ‘…¥±	…­½™™5¥¹ÕÑ•Ì€µÐ€À¤ì(€€€€€€€€€€€€€€€€€€€1½ÉÈ€ ‰%0	-=èìÁôÝ¥±°‰”Í­¥ÁÁ•™½ÈìÅôµ¥¹ÕÑ”¡Ì¤ˆ€µ˜€‘É•°°€‘…¥±	…­½™™5¥¹ÕÑ•Ì¤(€€€€€€€€€€€€€€€ô(€€€€€€€€€€€ô((€€€€€€€€€€€I•¹‘•Èµ…Í¡‰½…É(€€€€€€€ô(€€€ô((€€€I•¹‘•Èµ…Í¡‰½…É(€€€MÑ…ÉÐµM±••À€µM•½¹‘Ì€‘A½±±M•½¹‘Ì)ô((Œ¹½ÐÉ•…¡•(‘Á½½°¹±½Í” ¤(‘Á½½°¹¥ÍÁ½Í” ¤(