param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config

if (-not (Test-DistroExists $config.distributionName)) {
    Write-Host "Docker Engine no está instalado: no existe la distribución $($config.distributionName)."
    return
}

if ($Force) {
    Write-Warning 'Deteniendo Docker Engine de forma inmediata; las operaciones en curso serán interrumpidas.'
    & wsl.exe --terminate $config.distributionName
    if ($LASTEXITCODE -ne 0) { throw "No se pudo terminar la distribución $($config.distributionName)." }
    Write-Host 'Docker Engine fue detenido de forma inmediata.'
    return
}

$engineState = Get-WslOutput -Distribution $config.distributionName -Command 'rc-service docker status >/dev/null 2>&1 && echo running || true' -AllowFailure
if ($engineState -ne 'running') {
    Write-Host 'Docker Engine ya está detenido.'
    return
}

Write-Host 'Deteniendo Docker Engine de forma ordenada...'
Invoke-WslScript -Distribution $config.distributionName -Script 'rc-service docker stop'
Write-Host 'Docker Engine está detenido.'
