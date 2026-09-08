param([switch]$SkipBackup)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
if (-not (Test-DistroExists $config.distributionName)) { throw "No existe la distribución $($config.distributionName)." }

& (Join-Path $PSScriptRoot 'start.ps1') -NonInteractive
if ($LASTEXITCODE -ne 0) { throw 'No se pudo preparar Docker antes de actualizar.' }

$before = Get-WslOutput -Distribution $config.distributionName -Command "printf 'Alpine '; cat /etc/alpine-release; docker version --format 'Docker {{.Server.Version}}'; docker compose version"
Write-Host "Versiones actuales:`n$before"

if (-not $SkipBackup) {
    $backupDirectory = Resolve-ConfiguredPath $config.paths.backups
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupPath = Join-Path $backupDirectory "dockerd-$((Get-Date).ToString('yyyyMMdd-HHmmss')).tar"
    Write-Host "Exportando respaldo de la distribución a $backupPath..."
    Invoke-WslScript -Distribution $config.distributionName -Script 'rc-service docker stop || true'
    & wsl.exe --terminate $config.distributionName | Out-Null
    & wsl.exe --export $config.distributionName $backupPath
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo exportar el respaldo; la actualización fue cancelada.' }
}

Mount-DockerDataVhd $config
$expectedBranch = [string]$config.alpine.branch
Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eux
grep -q '/$expectedBranch/' /etc/apk/repositories
rc-service docker stop || true
apk update
apk upgrade --available
apk add --upgrade docker docker-cli docker-cli-compose
"@

& (Join-Path $PSScriptRoot 'start.ps1') -NonInteractive
if ($LASTEXITCODE -ne 0) { throw 'La actualización finalizó, pero Docker no volvió a iniciar correctamente.' }

$after = Get-WslOutput -Distribution $config.distributionName -Command "printf 'Alpine '; cat /etc/alpine-release; docker version --format 'Docker {{.Server.Version}}'; docker compose version"
Write-Host "Actualización completada:`n$after" -ForegroundColor Green
