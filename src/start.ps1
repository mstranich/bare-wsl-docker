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
    if (-not (Test-DistroExists $config.distributionName)) { throw "The distribution $($config.distributionName) does not exist." }
    Write-Log 'Mounting the data VHDX...'
    Mount-DockerDataVhd $config

    $mountPoint = [string]$config.storage.mountPoint
    $dataRoot = [string]$config.storage.dockerDataRoot
    $windowsHostAddress = Get-WindowsHostAddress $config
    Write-Log "Configuring host-gateway for Windows at $windowsHostAddress..."
    $engineWasRunning = Test-DockerEngineRunning $config
    $daemonConfigurationChanged = Set-DockerDaemonConfiguration -Config $config -WindowsHostAddress $windowsHostAddress

    Write-Log 'Starting Docker Engine...'
    Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eu
mountpoint -q '$mountPoint'
test "`$(findmnt -n -o FSTYPE '$mountPoint')" = ext4
case '$dataRoot/' in '$mountPoint/'*) ;; *) echo 'data-root is outside the VHDX' >&2; exit 1;; esac
mkdir -p /run/openrc
touch /run/openrc/softlevel
if rc-service docker status >/dev/null 2>&1; then
  if [ '$($daemonConfigurationChanged.ToString().ToLowerInvariant())' = true ]; then
    rc-service docker restart
  fi
else
  rc-service docker start
fi
"@

    if ($engineWasRunning -and $daemonConfigurationChanged) {
        Write-Log 'Docker Engine was restarted to apply the new host-gateway target.'
    }

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        $result = Get-WslOutput -Distribution $config.distributionName -Command 'docker info >/dev/null 2>&1 && echo ready || true' -AllowFailure
        if ($result -eq 'ready') { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Docker Engine did not respond within 30 seconds.' }

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
            throw 'Docker works inside Alpine, but docker.exe could not connect over TLS within 30 seconds.'
        }
    }
    Write-Log "Docker Engine is ready. host-gateway points to Windows ($windowsHostAddress)."

    if ([bool]$config.lanExposure.enabled) {
        Write-Log "Exposing published ports on $windowsHostAddress..."
        foreach ($change in (Sync-LanExposure -Config $config -WindowsHostAddress $windowsHostAddress)) { Write-Log $change }
        Start-LanExposureWatcher $config
        Write-Log 'LAN exposure watcher is running.'
    }
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if (-not $NonInteractive) { Write-Error $_ }
    exit 1
}
