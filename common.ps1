Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = $PSScriptRoot
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

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "No existe $script:ConfigPath. Ejecute install.ps1 primero."
    }

    $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    if ($config.schemaVersion -ne 1) { throw "schemaVersion no soportado: $($config.schemaVersion)" }
    if ([string]::IsNullOrWhiteSpace($config.distributionName)) { throw 'distributionName no puede estar vacío.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.distributionDirectory)) { throw 'paths.distributionDirectory no puede estar vacío.' }
    if ([string]::IsNullOrWhiteSpace($config.paths.dataVhdx)) { throw 'paths.dataVhdx no puede estar vacío.' }
    if (-not $config.paths.dataVhdx.EndsWith('.vhdx', [StringComparison]::OrdinalIgnoreCase)) { throw 'paths.dataVhdx debe terminar en .vhdx.' }
    return $config
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
    return "ssh://$($Config.windowsCli.hostAlias)"
}

function Write-ManagedSshConfig {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$PrivateKeyPath
    )

    $sshDir = Join-Path $HOME '.ssh'
    $sshConfig = Join-Path $sshDir 'config'
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $begin = '# BEGIN dockerd-wsl (managed)'
    $end = '# END dockerd-wsl (managed)'
    $existing = if (Test-Path -LiteralPath $sshConfig) { Get-Content -LiteralPath $sshConfig -Raw } else { '' }
    $pattern = "(?ms)^$([regex]::Escape($begin))\r?\n.*?^$([regex]::Escape($end))\r?\n?"
    $existing = [regex]::Replace($existing, $pattern, '').TrimEnd()
    $keyForSsh = $PrivateKeyPath.Replace('\', '/')
    $block = @"
$begin
Host $($Config.windowsCli.hostAlias)
    HostName 127.0.0.1
    Port $($Config.windowsCli.sshPort)
    User docker
    IdentityFile $keyForSsh
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking accept-new
$end
"@
    (($existing + "`r`n`r`n" + $block).TrimStart()) | Set-Content -LiteralPath $sshConfig -Encoding ascii
}

function Remove-ManagedSshConfig {
    $sshConfig = Join-Path (Join-Path $HOME '.ssh') 'config'
    if (-not (Test-Path -LiteralPath $sshConfig)) { return }
    $begin = '# BEGIN dockerd-wsl (managed)'
    $end = '# END dockerd-wsl (managed)'
    $content = Get-Content -LiteralPath $sshConfig -Raw
    $pattern = "(?ms)^$([regex]::Escape($begin))\r?\n.*?^$([regex]::Escape($end))\r?\n?"
    $updated = [regex]::Replace($content, $pattern, '').Trim()
    if ($updated) { ($updated + "`r`n") | Set-Content -LiteralPath $sshConfig -Encoding ascii }
    else { Remove-Item -LiteralPath $sshConfig -Force }
}

function Register-DockerdStartupTask {
    param([Parameter(Mandatory)]$Config)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:RepoRoot 'start.ps1')`" -NonInteractive"
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $actionArgs -WorkingDirectory $script:RepoRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $trigger.Delay = "PT$([int]$Config.startupTask.delaySeconds)S"
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Config.startupTask.name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Monta el VHDX de datos e inicia Docker Engine dentro de WSL.' -Force | Out-Null
}
