param(
    [Parameter(Mandatory = $true)]
    [string]$LogDir,

    [string]$Filter = "Watcher_*.log",

    [ValidateRange(1, 10000)]
    [int]$TailLines = 200,

    [ValidateRange(1, 3600)]
    [int]$CheckEverySeconds = 3
)

if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
  throw "Log directory does not exist: $LogDir"
}

$currentPath = $null

while ($true) {
  try {
    $latest = Get-ChildItem -LiteralPath $LogDir -Filter $Filter -File -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($null -eq $latest) {
      Start-Sleep -Seconds $CheckEverySeconds
      continue
    }

    if ($latest.FullName -ne $currentPath) {
      $currentPath = $latest.FullName
      Write-Host ""
      Write-Host ("=== NOW FOLLOWING: {0} (LastWrite: {1}) ===" -f $currentPath, $latest.LastWriteTime) -ForegroundColor Cyan
    }

    Get-Content -LiteralPath $currentPath -Tail $TailLines -Wait -ErrorAction Stop |
      Where-Object { $_ -notmatch 'START:' }
  }
  catch {
    Write-Host ("[tail retry] {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Start-Sleep -Seconds $CheckEverySeconds
  }
}
