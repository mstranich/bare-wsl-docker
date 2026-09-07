param(
    [switch]$DeleteDockerData,
    [switch]$RemoveConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config

Unregister-ScheduledTask -TaskName $config.startupTask.name -Confirm:$false -ErrorAction SilentlyContinue

if (Test-DistroExists $config.distributionName) {
    try {
        Invoke-WslScript -Distribution $config.distributionName -Script "rc-service docker stop || true; rc-service sshd stop || true; umount '$($config.storage.mountPoint)' || true"
    }
    catch { Write-Warning $_.Exception.Message }
    & wsl.exe --terminate $config.distributionName 2>$null | Out-Null
}

$dataVhdx = Resolve-ConfiguredPath $config.paths.dataVhdx
if (Test-Path -LiteralPath $dataVhdx) {
    & wsl.exe --unmount $dataVhdx 2>$null | Out-Null
}

if (Test-DistroExists $config.distributionName) {
    Write-Host "Desregistrando $($config.distributionName)..."
    & wsl.exe --unregister $config.distributionName
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo desregistrar la distribución.' }
}

$distroDirectory = Resolve-ConfiguredPath $config.paths.distributionDirectory
if (Test-Path -LiteralPath $distroDirectory) {
    $resolvedRuntime = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runtime'))
    $resolvedDistro = [IO.Path]::GetFullPath($distroDirectory)
    if ($resolvedDistro.StartsWith($resolvedRuntime.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedDistro -Recurse -Force
    }
    else { Write-Warning "No se eliminó el directorio externo: $resolvedDistro" }
}

$expectedHost = Get-DockerHostValue $config
if ([Environment]::GetEnvironmentVariable('DOCKER_HOST', 'User') -eq $expectedHost) {
    [Environment]::SetEnvironmentVariable('DOCKER_HOST', $null, 'User')
}
Remove-ManagedSshConfig

$sshDirectory = [IO.Path]::GetFullPath((Join-Path $HOME '.ssh'))
$keyPath = Join-Path $sshDirectory 'dockerd-wsl-ed25519'
Remove-Item -LiteralPath $keyPath, "$keyPath.pub" -Force -ErrorAction SilentlyContinue

# El instalador conserva con este patrón las claves administradas incompatibles
# que fueron reemplazadas. También son artefactos propios de esta instalación.
Get-ChildItem -LiteralPath $sshDirectory -File -Filter 'dockerd-wsl-ed25519.*.bak' -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ([IO.Path]::GetFullPath($_.DirectoryName) -eq $sshDirectory) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

if (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue) {
    $knownHost = "[127.0.0.1]:$([int]$config.windowsCli.sshPort)"
    & ssh-keygen.exe -R $knownHost *> $null
}

if (Test-Path -LiteralPath $dataVhdx) {
    $deleteData = [bool]$DeleteDockerData
    if (-not $DeleteDockerData) {
        while ($true) {
            $answer = (Read-Host "¿Eliminar permanentemente el VHDX de datos $dataVhdx? [S/N]").Trim().ToUpperInvariant()
            if ($answer -eq 'S') { $deleteData = $true; break }
            if ($answer -eq 'N' -or $answer -eq '') { $deleteData = $false; break }
        }
    }

    if ($deleteData) {
        Remove-Item -LiteralPath $dataVhdx -Force
        Write-Host 'El VHDX de datos fue eliminado.' -ForegroundColor Yellow
    }
    else {
        Write-Host "Datos Docker conservados en: $dataVhdx"
    }
}

if ($RemoveConfiguration) { Remove-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue }
Write-Host 'Desinstalación completada.' -ForegroundColor Green
