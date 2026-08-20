# Register a persistent local server as a logon scheduled task (ASCII-only).
$exe    = "powershell.exe"
$script = Join-Path $env:USERPROFILE "code\semi-dashboard\serve.ps1"
$arg    = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Port 8090 -NoBrowser"

$action  = New-ScheduledTaskAction -Execute $exe -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName "SemiDashboard-Serve" -Action $action -Trigger $trigger `
  -Settings $settings -RunLevel Limited -Force | Out-Null
Write-Host "registered SemiDashboard-Serve"

Start-ScheduledTask -TaskName "SemiDashboard-Serve"
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName "SemiDashboard-Serve").State
Write-Host ("task state: " + $state)
