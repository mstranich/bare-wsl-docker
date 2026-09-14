Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$task = Get-ScheduledTask -TaskName $config.startupTask.name -ErrorAction SilentlyContinue
Register-DockerdStartupTask $config

if (-not $task) {
    Write-Host "Scheduled task '$($config.startupTask.name)' registered and enabled."
}
elseif ($task.State -eq 'Disabled') {
    Write-Host "Scheduled task '$($config.startupTask.name)' updated and enabled."
}
else {
    Write-Host "Scheduled task '$($config.startupTask.name)' updated; it was already enabled."
}

if (Test-DockerEngineRunning $config) {
    Write-Host 'Docker Engine is already running.'
}
else {
    Write-Host 'Docker Engine remains stopped. You can start it manually through .\bwd.ps1 start.'
}
