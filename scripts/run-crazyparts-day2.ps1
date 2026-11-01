param()
$ErrorActionPreference = 'Continue'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1') -Family 'Oppo' -Concurrency 1 -SyncSupabase
$oppoExit = $LASTEXITCODE
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-crazyparts-ipad.ps1')
$ipadExit = $LASTEXITCODE
if($oppoExit -ne 0 -or $ipadExit -ne 0){ exit 1 }
exit 0
