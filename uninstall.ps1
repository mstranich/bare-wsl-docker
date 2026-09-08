param(
    [switch]$DeleteDockerData,
    [switch]$RemoveConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
if (Test-Path -LiteralPath $script:ConfigPath) {
    $config = Get-Config
}
else {
    if (-not (Test-Path -LiteralPath $script:DefaultConfigPath)) {
        throw "No existe la configuración local ni $script:DefaultConfigPath."
    }
    $config = Get-Content -LiteralPath $script:DefaultConfigPath -Raw | ConvertFrom-Json
    Write-Host 'No existe configuración local; se usarán los valores predeterminados para completar la limpieza.'
}

Unregister-ScheduledTask -TaskName $config.startupTask.name -Confirm:$false -ErrorAction SilentlyContinue

if (Test-DistroExists $config.distributionName) {
    try {
        Invoke-WslScript -Distribution $config.distributionName -Script "rc-service docker stop || true; umount '$($config.storage.mountPoint)' || true"
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
$configuredUserHost = [Environment]::GetEnvironmentVariable('DOCKER_HOST', 'User')
if ($configuredUserHost -eq $expectedHost) {
    [Environment]::SetEnvironmentVariable('DOCKER_HOST', $null, 'User')
    [Environment]::SetEnvironmentVariable('DOCKER_TLS_VERIFY', $null, 'User')
    [Environment]::SetEnvironmentVariable('DOCKER_CERT_PATH', $null, 'User')
}
$configuredComposePathConversion = [Environment]::GetEnvironmentVariable('COMPOSE_CONVERT_WINDOWS_PATHS', 'User')
if ($configuredComposePathConversion -eq '1') {
    [Environment]::SetEnvironmentVariable('COMPOSE_CONVERT_WINDOWS_PATHS', $null, 'User')
}

$clientCertDirectory = Resolve-ConfiguredPath $config.paths.clientCertificates
foreach ($certificateName in 'ca.pem', 'cert.pem', 'key.pem') {
    Remove-Item -LiteralPath (Join-Path $clientCertDirectory $certificateName) -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $clientCertDirectory) {
    $remainingCertificates = @(Get-ChildItem -LiteralPath $clientCertDirectory -Force -ErrorAction SilentlyContinue)
    if ($remainingCertificates.Count -eq 0) {
        Remove-Item -LiteralPath $clientCertDirectory -Force
    }
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
