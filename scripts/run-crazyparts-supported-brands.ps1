param(
    [string[]]$Family = @(
        'A Series', 'Oppo', 'Huawei', 'Xiaomi', 'Redmi', 'Motorola',
        'Nokia', 'Oneplus', 'Realme', 'Vivo', 'Sony'
    ),
    [string]$FamilyCsv = '',
    [ValidateRange(1, 2)]
    [int]$Concurrency = 1,
    [ValidateRange(0, 3)]
    [int]$RetryCount = 1,
    [ValidateRange(10, 7200)]
    [int]$RetryDelaySeconds = 120,
    [ValidateRange(0, 21600)]
    [int]$InitialDelaySeconds = 0
)

$ErrorActionPreference = 'Stop'
$runScript = Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1'
$failedFamilies = [System.Collections.Generic.List[string]]::new()
$familyValues = if ([string]::IsNullOrWhiteSpace($FamilyCsv)) {
    @($Family)
} else {
    @($FamilyCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($InitialDelaySeconds -gt 0) {
    Write-Host "[$(Get-Date -Format s)] Cooling down for $InitialDelaySeconds seconds before contacting Crazy Parts."
    Start-Sleep -Seconds $InitialDelaySeconds
}

foreach ($familyValue in @($familyValues | Select-Object -Unique)) {
    $completed = $false
    for ($attempt = 1; $attempt -le ($RetryCount + 1); $attempt += 1) {
        Write-Host "[$(Get-Date -Format s)] Starting Crazy Parts family '$familyValue' (attempt $attempt/$($RetryCount + 1))."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runScript `
            -Family $familyValue -Concurrency $Concurrency -SyncSupabase
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "[$(Get-Date -Format s)] Completed and verified '$familyValue'."
            $completed = $true
            break
        }
        Write-Warning "Crazy Parts family '$familyValue' failed with exit code $exitCode."
        if ($attempt -le $RetryCount) {
            Write-Host "Waiting $RetryDelaySeconds seconds before retrying '$familyValue'."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    if (-not $completed) {
        $failedFamilies.Add($familyValue)
    }
}

if ($failedFamilies.Count -gt 0) {
    throw "Crazy Parts update did not complete for: $($failedFamilies -join ', ')"
}

Write-Host "[$(Get-Date -Format s)] All requested Crazy Parts families were updated and verified."
