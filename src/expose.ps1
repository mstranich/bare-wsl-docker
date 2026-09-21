param(
    [switch]$Watch,
    [switch]$Clear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Assert-Administrator
$config = Get-Config
$logDirectory = Resolve-ConfiguredPath $config.paths.logs
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory 'expose.log'

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    if (-not $Watch) { Write-Host $Message }
}

function Invoke-Sync {
    try {
        foreach ($change in (Sync-LanExposure -Config $config)) { Write-Log $change }
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
}

if ($Clear) {
    $removed = @(Clear-LanExposure $config)
    if ($removed.Count -eq 0) { Write-Host 'No LAN-exposed ports to remove.' }
    else { Write-Host "Removed LAN exposure for: $(($removed | ForEach-Object { "$_/tcp" }) -join ', ')" }
    return
}

if (-not [bool]$config.lanExposure.enabled) {
    Write-Host 'LAN exposure is disabled in etc/config.json (lanExposure.enabled).'
    return
}

if (-not $Watch) {
    if (-not (Test-DockerEngineRunning $config)) { throw 'Docker Engine is not running.' }
    Invoke-Sync
    $ports = @(Get-PublishedLanPorts $config)
    if ($ports.Count -eq 0) { Write-Host 'No container publishes a TCP port on 0.0.0.0; nothing is exposed on the LAN.' }
    else { Write-Host "Exposed on $(Get-WindowsHostAddress $config): $(($ports | ForEach-Object { "$_/tcp" }) -join ', ')" }
    return
}

# Watch mode: reconcile now, then follow container start/die events until the Engine goes away.
$docker = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $docker) { Write-Log 'ERROR: docker.exe is required for watch mode.'; exit 1 }
Set-DockerClientEnvironment $config
Write-Log "Watcher started (PID $PID)."

try {
    while ($true) {
        if (-not (Test-DockerEngineRunning $config)) {
            Write-Log 'Docker Engine is not running; watcher exiting.'
            break
        }
        Invoke-Sync

        # docker events blocks until the daemon disconnects; each line is one container lifecycle event.
        # Native stderr must not become a terminating error here, or the watcher dies silently.
        try {
            $ErrorActionPreference = 'Continue'
            & docker.exe events --filter type=container --filter event=start --filter event=die --format '{{.Action}} {{.Actor.Attributes.name}}' 2>$null | ForEach-Object {
                Write-Log "event: $_"
                Invoke-Sync
            }
        }
        catch {
            Write-Log "ERROR: $($_.Exception.Message)"
        }
        finally {
            $ErrorActionPreference = 'Stop'
        }

        Write-Log 'Event stream closed; retrying in 5 seconds.'
        Start-Sleep -Seconds 5
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    Write-Log 'Watcher stopped.'
}
