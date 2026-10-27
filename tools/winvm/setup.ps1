# BeeModel - set up the job runner in the Windows 11 VM, once, in an
# administrator PowerShell (omarchy-windows-vm launch):
#   powershell -ExecutionPolicy Bypass -File \\host.lan\Data\bee-run\setup-<n>.ps1
# (tools/winvm-run.sh publishes it under a fresh name; see runner.ps1 for
# why.) It turns off the network-file caches, so files the host writes show
# at once, copies boot.ps1 to C:\bee-run and registers a task that starts
# it, hidden, at every log-on, and starts it now. boot.ps1 runs whatever
# runner the host publishes, so later runners need no new setup.
$share = '\\host.lan\Data\bee-run'
$local = 'C:\bee-run'
Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 `
    -FileNotFoundCacheLifetime 0 -Force
New-Item -ItemType Directory -Force $local | Out-Null
Copy-Item "$share\boot.ps1" "$local\boot.ps1" -Force
Stop-ScheduledTask -TaskName 'BeeModel runner' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'bee-run\\(runner|boot)' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $local\boot.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'BeeModel runner' -Action $action -Trigger $trigger `
    -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'BeeModel runner'
Write-Host "BeeModel runner: registered and started ($((Get-ScheduledTask 'BeeModel runner').Actions.Arguments))"
