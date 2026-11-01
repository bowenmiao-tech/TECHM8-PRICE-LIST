param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1') -Family @('iPad Pro','iPad Air','iPad Mini') -Concurrency 1 -SyncSupabase
exit $LASTEXITCODE
