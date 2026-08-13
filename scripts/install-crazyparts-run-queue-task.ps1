param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$queueScript = Join-Path $PSScriptRoot 'process-crazyparts-run-queue.ps1'
$taskName = 'TECHM8 Crazy Parts Run Queue'

$taskService = New-Object -ComObject 'Schedule.Service'
$taskService.Connect()
$taskFolder = $taskService.GetFolder('\')
$definition = $taskService.NewTask(0)
$definition.RegistrationInfo.Description = 'Checks Admin Auto Price List requests and starts one Crazy Parts brand update at a time.'
$definition.Settings.Enabled = $true
$definition.Settings.StartWhenAvailable = $true
$definition.Settings.AllowDemandStart = $true
$definition.Settings.DisallowStartIfOnBatteries = $false
$definition.Settings.StopIfGoingOnBatteries = $false
$definition.Settings.ExecutionTimeLimit = 'PT6H'
$definition.Settings.MultipleInstances = 2

$trigger = $definition.Triggers.Create(2)
$trigger.StartBoundary = (Get-Date).Date.ToString('yyyy-MM-ddTHH:mm:ss')
$trigger.DaysInterval = 1
$trigger.Repetition.Interval = 'PT1M'
$trigger.Repetition.Duration = 'P1D'
$trigger.Repetition.StopAtDurationEnd = $false
$trigger.Enabled = $true

$action = $definition.Actions.Create(0)
$action.Path = 'powershell.exe'
$action.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$queueScript`""
$action.WorkingDirectory = $projectRoot

# TASK_CREATE_OR_UPDATE = 6; TASK_LOGON_INTERACTIVE_TOKEN = 3.
$taskFolder.RegisterTaskDefinition($taskName, $definition, 6, $null, $null, 3, $null) | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host 'Auto Price List Run Now queue installed. Requests are checked every minute.'
