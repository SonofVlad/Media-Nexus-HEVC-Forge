param(
    [string]$LogDir,
    [string]$Filter,
    [int]$TailLines,
    [int]$CheckEverySeconds
)

$currentPath = $null

while ($true) {
  try {
    $latest = Get-ChildItem $LogDir -Filter $Filter -ErrorAction Stop |
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

    Get-Content $currentPath -Tail $TailLines -Wait -ErrorAction Stop |
      Where-Object { $_ -notmatch 'START:' }
  }
  catch {
    Write-Host ("[tail retry] {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Start-Sleep -Seconds $CheckEverySeconds
  }
}