Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:ConfigPath = Join-Path $script:RepoRoot 'etc\config.json'
$script:DefaultConfigPath = Join-Path $script:RepoRoot 'etc\config.default.json'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Este script debe ejecutarse desde PowerShell con privilegios de administrador.'
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
        throw "Solo se admiten rutas locales con letra de unidad para interoperabilidad WSL: $full"
    }
    $drive = $Matches.drive.ToLowerInvariant()
    $rest = $Matches.rest.Replace('\', '/')
    return "/mnt/$drive/$rest"
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "No existe $script:ConfigPath. Ejecute .\bwd.ps1 install primero."
    }

    $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    $defaults = Get-Content -LiteralPath $script:DefaultConfigPath -Raw | ConvertFrom-Json
    Merge-ConfigDefaults -Target $config -Defaults $defaults
    if ($config.schemaVersion -ne 1) { throw "schemaVersion no soportado: $($config.schemaVersion)" }
    if ([string]::IsNullOrWhiteSpace($config.distributionName)) { throw 'distributionName no puede estar vacío.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.distributionDirectory)) { throw 'paths.distributionDirectory no puede estar vacío.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.dataVhdx)) { throw 'paths.dataVhdx no puede estar vacío.' }
    if (-not $config.paths.dataVhdx.EndsWith('.vhdx', [StringComparison]::OrdinalIgnoreCase)) { throw 'paths.dataVhdx debe terminar en .vhdx.' }
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
    if ($LASTEXITCODE -ne 0) { throw "Falló un comando dentro de $Distribution (código $LASTEXITCODE)." }
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
        throw "Falló '$Command' dentro de $Distribution (código $exitCode)."
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

    throw 'No se pudo determinar una dirección IPv4 de Windows alcanzable desde los contenedores.'
}

function Set-DockerDaemonConfiguration {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$WindowsHostAddress
    )

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($WindowsHostAddress, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "La dirección de Windows no es una IPv4 válida: $WindowsHostAddress"
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

    if (-not (Test-Path -LiteralPath $vhdx)) { throw "No existe el VHDX de datos: $vhdx" }
    & wsl.exe -d $name -u root -- true | Out-Null

    $device = Get-WslOutput -Distribution $name -Command "blkid -L '$label' 2>/dev/null || true" -AllowFailure
    if ([string]::IsNullOrWhiteSpace($device)) {
        $mountOutput = & wsl.exe --mount $vhdx --vhd --bare 2>&1
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 1
            $device = Get-WslOutput -Distribution $name -Command "blkid -L '$label' 2>/dev/null || true" -AllowFailure
            if ([string]::IsNullOrWhiteSpace($device)) {
                throw "No se pudo adjuntar $vhdx. wsl.exe informó: $($mountOutput -join ' ')"
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
    Register-ScheduledTask -TaskName $Config.startupTask.name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Monta el VHDX de datos e inicia Docker Engine dentro de WSL.' -Force | Out-Null
}
