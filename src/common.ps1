Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:ConfigPath = Join-Path $script:RepoRoot 'etc\config.json'
$script:DefaultConfigPath = Join-Path $script:RepoRoot 'etc\config.default.json'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from PowerShell with administrator privileges.'
    }
}

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) {
        return [IO.Path]::GetFullPath($expanded)
    }

    return [IO.Path]::GetFullPath((Join-Path (Split-Path $script:ConfigPath -Parent) $expanded))
}

function ConvertTo-PortablePath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $etc = [IO.Path]::GetFullPath((Split-Path $script:ConfigPath -Parent))
    $etcUri = [Uri](($etc.TrimEnd('\') + '\'))
    $pathUri = [Uri]$full
    $relative = $etcUri.MakeRelativeUri($pathUri).ToString().Replace('/', '\')
    if (-not $relative.StartsWith('..') -and $pathUri.Scheme -ne $etcUri.Scheme) {
        return $full
    }
    return $relative
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
        throw "Only local paths with a drive letter are supported for WSL interoperability: $full"
    }
    $drive = $Matches.drive.ToLowerInvariant()
    $rest = $Matches.rest.Replace('\', '/')
    return "/mnt/$drive/$rest"
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Does not exist $script:ConfigPath. Run .\bwd.ps1 install first."
    }

    $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    $defaults = Get-Content -LiteralPath $script:DefaultConfigPath -Raw | ConvertFrom-Json
    Merge-ConfigDefaults -Target $config -Defaults $defaults
    if ($config.schemaVersion -ne 1) { throw "unsupported schemaVersion: $($config.schemaVersion)" }
    if ([string]::IsNullOrWhiteSpace($config.distributionName)) { throw 'distributionName must not be empty.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.distributionDirectory)) { throw 'paths.distributionDirectory must not be empty.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.dataVhdx)) { throw 'paths.dataVhdx must not be empty.' }
    if (-not $config.paths.dataVhdx.EndsWith('.vhdx', [StringComparison]::OrdinalIgnoreCase)) { throw 'paths.dataVhdx must end in .vhdx.' }
    return $config
}

function Merge-ConfigDefaults {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Defaults)
    foreach ($property in $Defaults.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$property.Name]
        if (-not $existing) {
            $Target | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
        elseif ($existing.Value -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
            Merge-ConfigDefaults -Target $existing.Value -Defaults $property.Value
        }
    }
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    New-Item -ItemType Directory -Path (Split-Path $script:ConfigPath -Parent) -Force | Out-Null
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Test-DistroExists {
    param([Parameter(Mandatory)][string]$Name)
    $names = & wsl.exe --list --quiet 2>$null
    return @($names | ForEach-Object { (($_ -replace [string][char]0, '')).Trim() }) -contains $Name
}

function Test-DockerEngineRunning {
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-DistroExists $Config.distributionName)) {
        return $false
    }

    $state = Get-WslOutput -Distribution $Config.distributionName -Command 'rc-service docker status >/dev/null 2>&1 && echo running || true' -AllowFailure
    return $state -eq 'running'
}

function Invoke-WslScript {
    param(
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$Script,
        [string]$User = 'root'
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n"))
    $base64 = [Convert]::ToBase64String($bytes)
    & wsl.exe -d $Distribution -u $User -- sh -lc "printf '%s' '$base64' | base64 -d | sh"
    if ($LASTEXITCODE -ne 0) { throw "A command failed inside $Distribution (exit code $LASTEXITCODE)." }
}

function Get-WslOutput {
    param(
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$Command,
        [string]$User = 'root',
        [switch]$AllowFailure
    )

    $output = & wsl.exe -d $Distribution -u $User -- sh -lc $Command 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Failed '$Command' inside $Distribution (exit code $exitCode)."
    }
    return ($output -join "`n").Trim()
}

function Get-WindowsHostAddress {
    param([Parameter(Mandatory)]$Config)

    $defaultRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Alive' } |
        Sort-Object @{ Expression = { [int]$_.RouteMetric + [int]$_.InterfaceMetric } }, RouteMetric, InterfaceMetric)

    foreach ($route in $defaultRoutes) {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AddressState -eq 'Preferred' -and
                -not $_.SkipAsSource -and
                $_.IPAddress -notmatch '^(127\.|169\.254\.)'
            })
        if ($addresses.Count -gt 0) {
            return [string]$addresses[0].IPAddress
        }
    }

    $gateway = Get-WslOutput -Distribution $Config.distributionName -Command "ip -4 route show default | awk 'NR == 1 { print `$3 }'" -AllowFailure
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($gateway) -and
        [Net.IPAddress]::TryParse($gateway, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        return $gateway
    }

    throw 'Could not determine an IPv4 address for Windows reachable from the containers.'
}

function Set-DockerDaemonConfiguration {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$WindowsHostAddress
    )

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($WindowsHostAddress, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "The Windows address is not a valid IPv4 address: $WindowsHostAddress"
    }

    $daemonConfig = [ordered]@{
        'data-root'       = [string]$Config.storage.dockerDataRoot
        hosts             = @(
            'unix:///var/run/docker.sock'
            "tcp://127.0.0.1:$([int]$Config.windowsCli.tlsPort)"
        )
        tls               = $true
        tlsverify         = $true
        tlscacert         = '/etc/docker/tls/ca.pem'
        tlscert           = '/etc/docker/tls/server-cert.pem'
        tlskey            = '/etc/docker/tls/server-key.pem'
        'host-gateway-ips' = @($WindowsHostAddress)
    }
    $daemonJson = ($daemonConfig | ConvertTo-Json -Depth 5) + "`n"
    $currentJson = Get-WslOutput -Distribution $Config.distributionName -Command 'cat /etc/docker/daemon.json 2>/dev/null || true' -AllowFailure
    if (($currentJson.TrimEnd() + "`n") -eq $daemonJson) {
        return $false
    }

    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($daemonJson))
    Invoke-WslScript -Distribution $Config.distributionName -Script @"
set -eu
mkdir -p /etc/docker /run/bare-docker
printf '%s' '$payload' | base64 -d > /run/bare-docker/daemon.json.new
dockerd --validate --config-file /run/bare-docker/daemon.json.new >/dev/null
chmod 600 /run/bare-docker/daemon.json.new
mv /run/bare-docker/daemon.json.new /run/bare-docker/daemon.json
ln -sfn /run/bare-docker/daemon.json /etc/docker/daemon.json
"@
    return $true
}

function Mount-DockerDataVhd {
    param([Parameter(Mandatory)]$Config)

    $name = [string]$Config.distributionName
    $vhdx = Resolve-ConfiguredPath $Config.paths.dataVhdx
    $label = [string]$Config.storage.label

    if (-not (Test-Path -LiteralPath $vhdx)) { throw "The Data VHDX: $vhdx" }
    & wsl.exe -d $name -u root -- true | Out-Null

    $device = Get-WslOutput -Distribution $name -Command "blkid -L '$label' 2>/dev/null || true" -AllowFailure
    if ([string]::IsNullOrWhiteSpace($device)) {
        $mountOutput = & wsl.exe --mount $vhdx --vhd --bare 2>&1
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 1
            $device = Get-WslOutput -Distribution $name -Command "blkid -L '$label' 2>/dev/null || true" -AllowFailure
            if ([string]::IsNullOrWhiteSpace($device)) {
                throw "Could not attach $vhdx. wsl.exe reported: $($mountOutput -join ' ')"
            }
        }
    }

    $mountPoint = [string]$Config.storage.mountPoint
    $dataRoot = [string]$Config.storage.dockerDataRoot
    Invoke-WslScript -Distribution $name -Script @"
set -eu
device=`$(blkid -L '$label')
test -b "`$device"
mkdir -p '$mountPoint'
if ! mountpoint -q '$mountPoint'; then
  mount "`$device" '$mountPoint'
fi
test "`$(findmnt -n -o SOURCE '$mountPoint')" = "`$device"
mkdir -p '$dataRoot'
"@
}

function Get-DockerHostValue {
    param([Parameter(Mandatory)]$Config)
    return "tcp://127.0.0.1:$([int]$Config.windowsCli.tlsPort)"
}

function Set-DockerClientEnvironment {
    param([Parameter(Mandatory)]$Config, [switch]$Persist)
    $hostValue = Get-DockerHostValue $Config
    $certPath = Resolve-ConfiguredPath $Config.paths.clientCertificates
    $env:DOCKER_HOST = $hostValue
    $env:DOCKER_TLS_VERIFY = '1'
    $env:DOCKER_CERT_PATH = $certPath
    if ($Persist) {
        [Environment]::SetEnvironmentVariable('DOCKER_HOST', $hostValue, 'User')
        [Environment]::SetEnvironmentVariable('DOCKER_TLS_VERIFY', '1', 'User')
        [Environment]::SetEnvironmentVariable('DOCKER_CERT_PATH', $certPath, 'User')
    }
}

function Register-DockerdStartupTask {
    param([Parameter(Mandatory)]$Config)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $managerPath = Join-Path $script:RepoRoot 'bwd.ps1'
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$managerPath`" start -NonInteractive"
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $actionArgs -WorkingDirectory $script:RepoRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $trigger.Delay = "PT$([int]$Config.startupTask.delaySeconds)S"
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Config.startupTask.name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Mounts the data VHDX and starts Docker Engine inside WSL.' -Force | Out-Null
}

function Invoke-DockerCli {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Arguments)

    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($docker) {
        Set-DockerClientEnvironment $Config
        $output = & docker.exe @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { throw "docker.exe $($Arguments -join ' ') failed (exit code $LASTEXITCODE)." }
        return @($output)
    }

    $quoted = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    $text = Get-WslOutput -Distribution $Config.distributionName -Command "docker $quoted"
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text -split "`n")
}

function Get-PublishedLanPorts {
    # TCP ports that containers publish on every address (0.0.0.0). Ports bound to 127.0.0.1
    # stay private on purpose; UDP cannot be forwarded by portproxy and is ignored.
    param([Parameter(Mandatory)]$Config)

    $ports = [Collections.Generic.HashSet[int]]::new()
    foreach ($line in (Invoke-DockerCli -Config $Config -Arguments @('ps', '--format', '{{.Ports}}'))) {
        foreach ($match in [regex]::Matches([string]$line, '0\.0\.0\.0:(?<port>\d+)->\d+/tcp')) {
            $ports.Add([int]$match.Groups['port'].Value) | Out-Null
        }
    }
    return @($ports | Sort-Object)
}

function Get-LanExposureRuleName {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$Port)
    return "$($Config.lanExposure.ruleNamePrefix): $Port/tcp"
}

function Get-ManagedLanPorts {
    # The firewall rules created by this project are the ledger of what it manages.
    param([Parameter(Mandatory)]$Config)

    $pattern = '^' + [regex]::Escape("$($Config.lanExposure.ruleNamePrefix): ") + '(?<port>\d+)/tcp$'
    $ports = @()
    foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        if ($rule.DisplayName -match $pattern) { $ports += [int]$Matches.port }
    }
    return @($ports | Sort-Object -Unique)
}

function Get-PortProxyEntries {
    # netsh output is localized; only the four-column address/port rows are parsed.
    $entries = @()
    foreach ($line in @(& netsh.exe interface portproxy show v4tov4)) {
        if ($line -match '^\s*(?<listenAddress>[\d.]+)\s+(?<listenPort>\d+)\s+(?<connectAddress>[\d.]+)\s+(?<connectPort>\d+)\s*$') {
            $entries += [pscustomobject]@{
                ListenAddress  = $Matches.listenAddress
                ListenPort     = [int]$Matches.listenPort
                ConnectAddress = $Matches.connectAddress
                ConnectPort    = [int]$Matches.connectPort
            }
        }
    }
    return $entries
}

function Remove-LanPortForward {
    # Only entries that relay into WSL (127.0.0.1, same port) are removed; other portproxies are left alone.
    param([Parameter(Mandatory)][int]$Port)

    foreach ($entry in @(Get-PortProxyEntries | Where-Object { $_.ListenPort -eq $Port -and $_.ConnectAddress -eq '127.0.0.1' -and $_.ConnectPort -eq $Port })) {
        & netsh.exe interface portproxy delete v4tov4 listenaddress=$($entry.ListenAddress) listenport=$Port | Out-Null
    }
}

function Sync-LanExposure {
    # Reconciles portproxy entries and firewall rules with the ports currently published on 0.0.0.0.
    # Returns one description per change so callers can log them.
    param([Parameter(Mandatory)]$Config, [string]$WindowsHostAddress)

    if (-not [bool]$Config.lanExposure.enabled) { return @() }
    if ([string]::IsNullOrWhiteSpace($WindowsHostAddress)) { $WindowsHostAddress = Get-WindowsHostAddress $Config }

    $changes = @()
    $desired = @(Get-PublishedLanPorts $Config)
    $managed = @(Get-ManagedLanPorts $Config)
    $profile = [string]$Config.lanExposure.firewallProfile

    foreach ($port in $desired) {
        $ruleName = Get-LanExposureRuleName -Config $Config -Port $port
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Description 'Managed by bwd.ps1; removed automatically when the container stops.' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile $profile | Out-Null
            $changes += "firewall: allowed $port/tcp ($profile)"
        }

        # The listener must be the LAN address: 127.0.0.1:<port> is already taken by the WSL relay.
        $entries = @(Get-PortProxyEntries | Where-Object { $_.ListenPort -eq $port -and $_.ConnectAddress -eq '127.0.0.1' -and $_.ConnectPort -eq $port })
        foreach ($stale in @($entries | Where-Object { $_.ListenAddress -ne $WindowsHostAddress })) {
            & netsh.exe interface portproxy delete v4tov4 listenaddress=$($stale.ListenAddress) listenport=$port | Out-Null
            $changes += "portproxy: removed $($stale.ListenAddress):$port (address changed)"
        }
        if (-not ($entries | Where-Object { $_.ListenAddress -eq $WindowsHostAddress })) {
            & netsh.exe interface portproxy add v4tov4 listenaddress=$WindowsHostAddress listenport=$port connectaddress=127.0.0.1 connectport=$port | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "netsh could not add the portproxy for ${WindowsHostAddress}:$port." }
            $changes += "portproxy: ${WindowsHostAddress}:$port -> 127.0.0.1:$port"
        }
    }

    foreach ($port in @($managed | Where-Object { $_ -notin $desired })) {
        Remove-LanPortForward -Port $port
        Remove-NetFirewallRule -DisplayName (Get-LanExposureRuleName -Config $Config -Port $port) -ErrorAction SilentlyContinue
        $changes += "removed $port/tcp (no longer published)"
    }

    return $changes
}

function Clear-LanExposure {
    param([Parameter(Mandatory)]$Config)

    $removed = @()
    foreach ($port in (Get-ManagedLanPorts $Config)) {
        Remove-LanPortForward -Port $port
        Remove-NetFirewallRule -DisplayName (Get-LanExposureRuleName -Config $Config -Port $port) -ErrorAction SilentlyContinue
        $removed += $port
    }
    return $removed
}

function Register-LanExposureTask {
    # On-demand task without a time limit; start.ps1 launches it and stop.ps1 stops it.
    param([Parameter(Mandatory)]$Config)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $exposePath = Join-Path $script:RepoRoot 'src\expose.ps1'
    $actionArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$exposePath`" -Watch"
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $actionArgs -WorkingDirectory $script:RepoRoot
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    Register-ScheduledTask -TaskName $Config.lanExposure.taskName -Action $action -Principal $principal -Settings $settings -Description 'Follows Docker events and publishes container ports on the Windows LAN address.' -Force | Out-Null
}

function Start-LanExposureWatcher {
    param([Parameter(Mandatory)]$Config)

    if (-not [bool]$Config.lanExposure.enabled) { return }
    $name = [string]$Config.lanExposure.taskName
    if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
        Register-LanExposureTask $Config
    }
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $name
}

function Stop-LanExposureWatcher {
    param([Parameter(Mandatory)]$Config)
    Stop-ScheduledTask -TaskName $Config.lanExposure.taskName -ErrorAction SilentlyContinue
}
