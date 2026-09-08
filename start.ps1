param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$logDirectory = Resolve-ConfiguredPath $config.paths.logs
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory 'start.log'

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    if (-not $NonInteractive) { Write-Host $Message }
}

try {
    if (-not (Test-DistroExists $config.distributionName)) { throw "No existe la distribución $($config.distributionName)." }
    Write-Log 'Montando el VHDX de datos...'
    Mount-DockerDataVhd $config

    $mountPoint = [string]$config.storage.mountPoint
    $dataRoot = [string]$config.storage.dockerDataRoot
    Write-Log 'Iniciando Docker Engine...'
    Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eu
mountpoint -q '$mountPoint'
test "`$(findmnt -n -o FSTYPE '$mountPoint')" = ext4
case '$dataRoot/' in '$mountPoint/'*) ;; *) echo 'data-root está fuera del VHDX' >&2; exit 1;; esac
mkdir -p /run/openrc
touch /run/openrc/softlevel
if ! rc-service docker status >/dev/null 2>&1; then
  rc-service docker start
fi
"@

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        $result = Get-WslOutput -Distribution $config.distributionName -Command 'docker info >/dev/null 2>&1 && echo ready || true' -AllowFailure
        if ($result -eq 'ready') { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Docker Engine no respondió dentro de 30 segundos.' }

    Set-DockerClientEnvironment $config
    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($docker) {
        $windowsClientReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            & docker.exe version *> $null
            if ($LASTEXITCODE -eq 0) {
                $windowsClientReady = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $windowsClientReady) {
            throw 'Docker funciona dentro de Alpine, pero docker.exe no pudo conectarse mediante TLS dentro de 30 segundos.'
        }
    }
    Write-Log 'Docker Engine está listo.'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if (-not $NonInteractive) { Write-Error $_ }
    exit 1
}
