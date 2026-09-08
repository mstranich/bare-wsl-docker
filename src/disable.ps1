Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$task = Get-ScheduledTask -TaskName $config.startupTask.name -ErrorAction SilentlyContinue

if (-not $task) {
    Write-Host "La tarea programada '$($config.startupTask.name)' no está registrada."
}
elseif ($task.State -eq 'Disabled') {
    Write-Host "La tarea programada '$($config.startupTask.name)' ya está deshabilitada."
}
else {
    Disable-ScheduledTask -TaskName $config.startupTask.name | Out-Null
    Write-Host "Tarea programada '$($config.startupTask.name)' deshabilitada."
}

if (Test-DockerEngineRunning $config) {
    Write-Warning 'Docker Engine continúa en funcionamiento. La tarea programada solo controla el inicio automático; use .\bwd.ps1 stop para detener el Engine.'
}
