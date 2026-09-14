Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$task = Get-ScheduledTask -TaskName $config.startupTask.name -ErrorAction SilentlyContinue

if (-not $task) {
    Write-Host "The scheduled task '$($config.startupTask.name)' is not registered."
}
elseif ($task.State -eq 'Disabled') {
    Write-Host "The scheduled task '$($config.startupTask.name)' is already disabled."
}
else {
    Disable-ScheduledTask -TaskName $config.startupTask.name | Out-Null
    Write-Host "Scheduled task '$($config.startupTask.name)' disabled."
}

if (Test-DockerEngineRunning $config) {
    Write-Warning 'Docker Engine is still running. The scheduled task controls only automatic startup; use .\bwd.ps1 stop to stop the Engine.'
}
