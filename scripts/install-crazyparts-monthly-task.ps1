param(
    [ValidateRange(1, 28)]
    [int]$DayOfMonth = 1,
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$StartTime = '05:00',
    [string]$TaskName = 'TECHM8 Crazy Parts Monthly Price Update',
    [string]$Family = 'A Series',
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$runScript = Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1'
$credentialPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets\crazyparts-credential.xml'

if (-not (Test-Path -LiteralPath $credentialPath)) {
    throw 'Encrypted Crazy Parts credential is missing. Run setup-crazyparts-credential.ps1 first.'
}

$timeParts = $StartTime.Split(':')
$now = Get-Date
$startBoundary = Get-Date -Year $now.Year -Month $now.Month -Day $DayOfMonth -Hour ([int]$timeParts[0]) -Minute ([int]$timeParts[1]) -Second 0
if ($startBoundary -le $now) {
    $startBoundary = $startBoundary.AddMonths(1)
}

$taskService = New-Object -ComObject 'Schedule.Service'
$taskService.Connect()
$taskFolder = $taskService.GetFolder('\')
$taskDefinition = $taskService.NewTask(0)
$taskDefinition.RegistrationInfo.Description = 'Updates TECHM8 repair prices from Crazy Parts member pricing and syncs matched A Series prices to Supabase.'
$taskDefinition.Settings.Enabled = $true
$taskDefinition.Settings.StartWhenAvailable = $true
$taskDefinition.Settings.AllowDemandStart = $true
$taskDefinition.Settings.DisallowStartIfOnBatteries = $false
$taskDefinition.Settings.StopIfGoingOnBatteries = $false
$taskDefinition.Settings.ExecutionTimeLimit = 'PT3H'

$monthlyTrigger = $taskDefinition.Triggers.Create(4)
$monthlyTrigger.StartBoundary = $startBoundary.ToString('yyyy-MM-ddTHH:mm:ss')
$monthlyTrigger.DaysOfMonth = [int][math]::Pow(2, $DayOfMonth - 1)
$monthlyTrigger.MonthsOfYear = 4095
$monthlyTrigger.Enabled = $true

$taskAction = $taskDefinition.Actions.Create(0)
$taskAction.Path = 'powershell.exe'
$scopeArguments = if ($All) { '-All' } else { "-Family `"$Family`"" }
$taskAction.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`" $scopeArguments -SyncSupabase"
$taskAction.WorkingDirectory = Split-Path -Parent $PSScriptRoot

# TASK_CREATE_OR_UPDATE = 6; TASK_LOGON_INTERACTIVE_TOKEN = 3.
$taskFolder.RegisterTaskDefinition($TaskName, $taskDefinition, 6, $null, $null, 3, $null) | Out-Null

$scopeDescription = if ($All) { 'all discovered models' } else { "family '$Family'" }
Write-Host "Scheduled '$TaskName' for $scopeDescription on day $DayOfMonth of every month at $StartTime."
