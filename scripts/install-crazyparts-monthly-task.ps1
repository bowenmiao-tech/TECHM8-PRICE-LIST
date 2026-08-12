param(
    [ValidateRange(1, 28)]
    [int]$DayOfMonth = 1,
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$StartTime = '05:00',
    [string]$TaskName = 'TECHM8 Crazy Parts Monthly Price Update',
    [string]$Family = '',
    [switch]$SupportedBrands,
    [switch]$All
)

$ErrorActionPreference = 'Stop'

if ($All -or -not [string]::IsNullOrWhiteSpace($Family)) {
    throw 'The combined monthly task has been retired to prevent Crazy Parts rate limiting. Run a single family manually, or install the day 1-11 brand sequence.'
}

$dailyInstaller = Join-Path $PSScriptRoot 'install-crazyparts-daily-brand-tasks.ps1'
Write-Warning 'The old single monthly task has been replaced by one brand per day from the 1st to the 11th.'
& $dailyInstaller -StartTime $StartTime
exit $LASTEXITCODE
