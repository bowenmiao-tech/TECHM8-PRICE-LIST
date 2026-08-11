param(
    [switch]$All,
    [string[]]$Model,
    [switch]$Headful,
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
}
finally {
    Remove-Item Env:CRAZYPARTS_EMAIL -ErrorAction SilentlyContinue
    Remove-Item Env:CRAZYPARTS_PASSWORD -ErrorAction SilentlyContinue
    Pop-Location
}

exit $exitCode

