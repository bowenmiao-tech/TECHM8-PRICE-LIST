param(
    [string]$Email,
    [SecureString]$Password,
    [string]$CredentialPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $CredentialPath) {
    $CredentialPath = Join-Path $projectRoot '.secrets\crazyparts-credential.xml'
}

if (-not $Email) {
    $Email = Read-Host 'Crazy Parts email address'
}

if (-not $Password) {
    $Password = Read-Host 'Crazy Parts password' -AsSecureString
}

if ([string]::IsNullOrWhiteSpace($Email)) {
    throw 'An email address is required.'
}

$credentialDirectory = Split-Path -Parent $CredentialPath
New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null

$credential = [PSCredential]::new($Email.Trim(), $Password)
$credential | Export-Clixml -LiteralPath $CredentialPath -Force

Write-Host "Encrypted Crazy Parts credential saved to $CredentialPath"
Write-Host 'It can only be decrypted by this Windows user on this computer.'

