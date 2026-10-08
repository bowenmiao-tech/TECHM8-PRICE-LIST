# Starts the WeChat purchasing helper (hidden) every time this Windows user signs in.
# Run once from PowerShell:  powershell -ExecutionPolicy Bypass -File .\install-startup-task.ps1
# Remove it again:           Unregister-ScheduledTask -TaskName "TECHM8 WeChat Purchase Helper" -Confirm:$false

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonw = Join-Path $here '.venv\Scripts\pythonw.exe'
if (-not (Test-Path $pythonw)) { throw 'Run start-bot.bat once first so the helper can set itself up.' }
if (-not (Test-Path (Join-Path $here 'local\config.json'))) { throw 'local\config.json is missing. Run start-bot.bat first.' }

$action = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$(Join-Path $here 'bot.py')`"" -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'TECHM8 WeChat Purchase Helper' -Action $action -Trigger $trigger -Settings $settings `
  -Description 'Reads the WeChat supplier groups and records domestic parcels in 采购跟单.' -Force | Out-Null
Start-ScheduledTask -TaskName 'TECHM8 WeChat Purchase Helper'
Write-Host 'Installed and started. Log: local\bot.log'
