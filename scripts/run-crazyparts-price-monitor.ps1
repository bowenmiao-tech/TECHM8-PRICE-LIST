param(
    [switch]$All,
    [switch]$SupportedBrands,
    [string[]]$Family,
    [string[]]$Model,
    [switch]$Headful,
    [switch]$SyncSupabase,
    [ValidateRange(1, 8)]
    [int]$Concurrency = 1,
    [int]$MaxModels = 0,
    [string]$CredentialPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $CredentialPath) {
    $CredentialPath = Join-Path $projectRoot '.secrets\crazyparts-credential.xml'
}

if (-not (Test-Path -LiteralPath $CredentialPath)) {
    throw "Credential file not found. Run scripts\setup-crazyparts-credential.ps1 first."
}

$credential = Import-Clixml -LiteralPath $CredentialPath
$env:CRAZYPARTS_EMAIL = $credential.UserName
$env:CRAZYPARTS_PASSWORD = $credential.GetNetworkCredential().Password
$env:CRAZYPARTS_TRACK_STATUS = if ($SyncSupabase) { '1' } else { '0' }

$nodeArgs = @((Join-Path $PSScriptRoot 'crazyparts-price-monitor.mjs'))
$historyPathFile = Join-Path $projectRoot "outputs\crazyparts-price-monitor\.run-history-$PID.txt"
$nodeArgs += @('--history-path-file', $historyPathFile)
$supportedFamilies = @(
    'A Series', 'Oppo', 'Huawei', 'Xiaomi', 'Redmi', 'Motorola',
    'Nokia', 'Oneplus', 'Realme', 'Vivo', 'Sony', 'Apple Mac'
)

if ($All) {
    $nodeArgs += '--all'
}

foreach ($modelValue in $Model) {
    if (-not [string]::IsNullOrWhiteSpace($modelValue)) {
        $nodeArgs += @('--model', $modelValue)
    }
}

$familyValues = @($Family)
if ($SupportedBrands) {
    $familyValues += $supportedFamilies
}

if (@($familyValues | Where-Object { $_ -eq 'A Series' }).Count -gt 0) {
    $familyValues += @('Tab A Series', 'Tab S Series')
}

if (@($familyValues | Where-Object { $_ -eq 'Apple Mac' }).Count -gt 0) {
    $familyValues = @($familyValues | Where-Object { $_ -ne 'Apple Mac' })
    $familyValues += @('iMac', 'Macbook Pro', 'Macbook Air', 'Macbook')
}

foreach ($familyValue in @($familyValues | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($familyValue)) {
        $nodeArgs += @('--family', $familyValue)
    }
}

if ($Headful) {
    $nodeArgs += '--headful'
}

if ($MaxModels -gt 0) {
    $nodeArgs += @('--max-models', [string]$MaxModels)
}

$nodeArgs += @('--concurrency', [string]$Concurrency)

Push-Location $projectRoot
try {
    & node @nodeArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -and $SyncSupabase) {
        if (-not (Test-Path -LiteralPath $historyPathFile)) {
            throw 'The price capture completed without returning its exact history file.'
        }
        $capturedHistoryPath = (Get-Content -LiteralPath $historyPathFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($capturedHistoryPath) -or -not (Test-Path -LiteralPath $capturedHistoryPath)) {
            throw 'The captured price history file could not be verified.'
        }
        & node (Join-Path $PSScriptRoot 'sync-crazyparts-to-supabase.mjs') --apply --history $capturedHistoryPath
        $exitCode = $LASTEXITCODE
    }
}
finally {
    Remove-Item Env:CRAZYPARTS_EMAIL -ErrorAction SilentlyContinue
    Remove-Item Env:CRAZYPARTS_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:CRAZYPARTS_TRACK_STATUS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $historyPathFile -Force -ErrorAction SilentlyContinue
    Pop-Location
}

exit $exitCode
