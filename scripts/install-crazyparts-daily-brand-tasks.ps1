param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$StartTime = '05:00'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runScript = Join-Path $PSScriptRoot 'run-crazyparts-price-monitor.ps1'
$credentialPath = Join-Path $projectRoot '.secrets\crazyparts-credential.xml'
$legacyTaskName = 'TECHM8 Crazy Parts Monthly Price Update'
$schedule = @(
    @{ Day = 1; Family = 'A Series'; Label = 'Samsung A Series' },
    @{ Day = 2; Family = 'Oppo'; Label = 'OPPO' },
    @{ Day = 3; Family = 'Huawei'; Label = 'HUAWEI' },
    @{ Day = 4; Family = 'Xiaomi'; Label = 'XIAOMI' },
    @{ Day = 5; Family = 'Redmi'; Label = 'REDMI' },
    @{ Day = 6; Family = 'Motorola'; Label = 'MOTOROLA' },
    @{ Day = 7; Family = 'Nokia'; Label = 'NOKIA' },
    @{ Day = 8; Family = 'Oneplus'; Label = 'ONEPLUS' },
    @{ Day = 9; Family = 'Realme'; Label = 'REALME' },
    @{ Day = 10; Family = 'Vivo'; Label = 'VIVO' },
    @{ Day = 11; Family = 'Sony'; Label = 'SONY' }
)

if (-not (Test-Path -LiteralPath $credentialPath)) {
    throw 'Encrypted Crazy Parts credential is missing. Run setup-crazyparts-credential.ps1 first.'
}

$legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
}

$timeParts = $StartTime.Split(':')
$now = Get-Date
$taskService = New-Object -ComObject 'Schedule.Service'
$taskService.Connect()
$taskFolder = $taskService.GetFolder('\')

foreach ($item in $schedule) {
    $taskName = 'TECHM8 Crazy Parts {0:D2} {1}' -f $item.Day, $item.Label
    $startBoundary = Get-Date -Year $now.Year -Month $now.Month -Day $item.Day `
        -Hour ([int]$timeParts[0]) -Minute ([int]$timeParts[1]) -Second 0
    if ($startBoundary -le $now) {
        $startBoundary = $startBoundary.AddMonths(1)
    }

    $definition = $taskService.NewTask(0)
    $definition.RegistrationInfo.Description = "Updates and verifies TECHM8 $($item.Label) repair prices from Crazy Parts."
    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT6H'

    $trigger = $definition.Triggers.Create(4)
    $trigger.StartBoundary = $startBoundary.ToString('yyyy-MM-ddTHH:mm:ss')
    $trigger.DaysOfMonth = [int][math]::Pow(2, $item.Day - 1)
    $trigger.MonthsOfYear = 4095
    $trigger.Enabled = $true

    $action = $definition.Actions.Create(0)
    $action.Path = 'powershell.exe'
    $action.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`" -Family `"$($item.Family)`" -Concurrency 1 -SyncSupabase"
    $action.WorkingDirectory = $projectRoot

    # TASK_CREATE_OR_UPDATE = 6; TASK_LOGON_INTERACTIVE_TOKEN = 3.
    $taskFolder.RegisterTaskDefinition($taskName, $definition, 6, $null, $null, 3, $null) | Out-Null
    Write-Host "Scheduled day $($item.Day): $($item.Label) at $StartTime."
}

Write-Host 'Crazy Parts daily brand schedule installed. The former single monthly task was removed.'
