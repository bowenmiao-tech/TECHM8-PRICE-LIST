param()

$ErrorActionPreference = 'Continue'
$runScript = Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1'

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runScript `
    -Family 'Huawei' -Concurrency 1 -SyncSupabase
$huaweiExitCode = $LASTEXITCODE

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runScript `
    -Family 'Apple Mac' -Concurrency 1 -SyncSupabase
$appleMacExitCode = $LASTEXITCODE

if ($huaweiExitCode -ne 0 -or $appleMacExitCode -ne 0) {
    exit 1
}

exit 0
