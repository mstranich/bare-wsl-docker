param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config

if (-not (Test-DistroExists $config.distributionName)) {
    Write-Host "Docker Engine is not installed: distribution $($config.distributionName)."
    return
}

if ($Force) {
    Write-Warning 'Stopping Docker Engine immediately; in-progress operations will be interrupted.'
    & wsl.exe --terminate $config.distributionName
    if ($LASTEXITCODE -ne 0) { throw "Could not terminate the distribution $($config.distributionName)." }
    Write-Host 'Docker Engine was stopped immediately.'
    return
}

$engineState = Get-WslOutput -Distribution $config.distributionName -Command 'rc-service docker status >/dev/null 2>&1 && echo running || true' -AllowFailure
if ($engineState -ne 'running') {
    Write-Host 'Docker Engine is already stopped.'
    return
}

Write-Host 'Stopping Docker Engine gracefully...'
Invoke-WslScript -Distribution $config.distributionName -Script 'rc-service docker stop'
Write-Host 'Docker Engine is stopped.'
