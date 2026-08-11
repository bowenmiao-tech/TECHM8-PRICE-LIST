param(
    [switch]$All,
    [string[]]$Family,
    [string[]]$Model,
    [switch]$Headful,
    [switch]$SyncSupabase,
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

$nodeArgs = @((Join-Path $PSScriptRoot 'crazyparts-price-monitor.mjs'))

if ($All) {
    $nodeArgs += '--all'
}

foreach ($modelValue in $Model) {
    if (-not [string]::IsNullOrWhiteSpace($modelValue)) {
        $nodeArgs += @('--model', $modelValue)
    }
}

foreach ($familyValue in $Family) {
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

Push-Location $projectRoot
try {
    & node @nodeArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -and $SyncSupabase) {
        & node (Join-Path $PSScriptRoot 'sync-crazyparts-to-supabase.mjs') --apply
        $exitCode = $LASTEXITCODE
    }
}
finally {
    Remove-Item Env:CRAZYPARTS_EMAIL -ErrorAction SilentlyContinue
    Remove-Item Env:CRAZYPARTS_PASSWORD -ErrorAction SilentlyContinue
    Pop-Location
}

exit $exitCode
