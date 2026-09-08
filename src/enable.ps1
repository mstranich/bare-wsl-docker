Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$task = Get-ScheduledTask -TaskName $config.startupTask.name -ErrorAction SilentlyContinue
Register-DockerdStartupTask $config

if (-not $task) {
    Write-Host "Tarea programada '$($config.startupTask.name)' registrada y habilitada."
}
elseif ($task.State -eq 'Disabled') {
    Write-Host "Tarea programada '$($config.startupTask.name)' actualizada y habilitada."
}
else {
    Write-Host "Tarea programada '$($config.startupTask.name)' actualizada; ya estaba habilitada."
}

if (Test-DockerEngineRunning $config) {
    Write-Host 'Docker Engine ya está en funcionamiento.'
}
else {
    Write-Host 'Docker Engine permanece detenido. Puede iniciarlo manualmente mediante .\bwd.ps1 start.'
}
