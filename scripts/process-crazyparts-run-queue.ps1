param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runScript = Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1'
$scheduledTaskPrefix = 'TECHM8 Crazy Parts '

function Invoke-LinkedQueryJson {
    param([Parameter(Mandatory = $true)][string]$Sql)

    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & supabase db query --linked $Sql --output json --agent=no 2>$null | Out-String
    $queryExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorPreference
    if ($queryExitCode -ne 0) {
        throw 'Could not contact the price update queue.'
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        return @()
    }
    $parsed = $output | ConvertFrom-Json
    return @($parsed | Where-Object { $null -ne $_ })
}

$runningPriceTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName.StartsWith($scheduledTaskPrefix) -and
    $_.TaskName -ne 'TECHM8 Crazy Parts Run Queue' -and
    $_.State -eq 'Running'
})
if ($runningPriceTasks.Count -gt 0) {
    exit 0
}

$claimSql = @"
with next_request as (
  select id
  from public.crazyparts_run_requests
  where status = 'queued'
  order by requested_at
  for update skip locked
  limit 1
)
update public.crazyparts_run_requests as request
set status = 'running',
    started_at = now(),
    message = 'This computer is starting the requested update.'
from next_request
where request.id = next_request.id
returning request.id, request.family, request.brand;
"@

Push-Location $projectRoot
try {
    $claimedRows = @(Invoke-LinkedQueryJson -Sql $claimSql)
    if ($claimedRows.Count -eq 0) {
        exit 0
    }

    $request = $claimedRows[0]
    $requestId = [long]$request.id
    $family = [string]$request.family

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runScript `
        -Family $family -Concurrency 1 -SyncSupabase
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        $finishSql = "update public.crazyparts_run_requests set status = 'completed', completed_at = now(), message = 'Latest verified prices are live.' where id = $requestId;"
    } else {
        $finishSql = "update public.crazyparts_run_requests set status = 'failed', completed_at = now(), message = 'The requested update did not finish. Check the brand status and run it again.' where id = $requestId;"
    }
    Invoke-LinkedQueryJson -Sql $finishSql | Out-Null
    exit $exitCode
}
catch {
    if ($requestId) {
        $failureSql = "update public.crazyparts_run_requests set status = 'failed', completed_at = now(), message = 'The local queue could not start or finish this update.' where id = $requestId;"
        try { Invoke-LinkedQueryJson -Sql $failureSql | Out-Null } catch {}
    }
    throw
}
finally {
    Pop-Location
}
