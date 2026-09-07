param(
    [string]$DataVhdxPath,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Enable-WslPrerequisites {
    Write-Host 'Verificando requisitos de WSL...'
    $restartNeeded = $false
    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $wslOperational = $false
    if ($wslCommand) {
        & wsl.exe --version *> $null
        $wslVersionExitCode = $LASTEXITCODE
        & wsl.exe --status *> $null
        $wslStatusExitCode = $LASTEXITCODE
        $wslOperational = $wslVersionExitCode -eq 0 -and $wslStatusExitCode -eq 0
    }

    if ($wslOperational) {
        Write-Host 'WSL ya está instalado y operativo; no se modificarán características opcionales de Windows.'
    }
    else {
        foreach ($featureName in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
            Write-Host "Verificando $featureName..."
            $queryOutput = & dism.exe /Online /Get-FeatureInfo "/FeatureName:$featureName" /English 2>&1
            $queryExitCode = $LASTEXITCODE
            if ($queryExitCode -ne 0) {
                throw "DISM no pudo consultar $featureName (código $queryExitCode): $($queryOutput -join ' ')"
            }
            $featureEnabled = ($queryOutput -join "`n") -match '(?m)^\s*State\s*:\s*Enabled\s*$'
            if (-not $featureEnabled) {
                Write-Host "Habilitando $featureName..."
                $enableOutput = & dism.exe /Online /Enable-Feature "/FeatureName:$featureName" /All /NoRestart /English 2>&1
                $enableExitCode = $LASTEXITCODE
                if ($enableExitCode -notin 0, 3010) {
                    throw "DISM no pudo habilitar $featureName (código $enableExitCode): $($enableOutput -join ' ')"
                }
                if ($enableExitCode -eq 3010 -or ($enableOutput -join "`n") -match '(?im)^\s*Restart Required\s*:\s*Yes\s*$') {
                    $restartNeeded = $true
                }
            }
        }
    }

    Write-Host 'Verificando cliente OpenSSH de Windows...'
    $capabilityName = 'OpenSSH.Client~~~~0.0.1.0'
    $sshQueryOutput = & dism.exe /Online /Get-CapabilityInfo "/CapabilityName:$capabilityName" /English 2>&1
    $sshQueryExitCode = $LASTEXITCODE
    if ($sshQueryExitCode -ne 0) {
        throw "DISM no pudo consultar OpenSSH Client (código $sshQueryExitCode): $($sshQueryOutput -join ' ')"
    }
    $sshInstalled = ($sshQueryOutput -join "`n") -match '(?m)^\s*State\s*:\s*Installed\s*$'
    if (-not $sshInstalled) {
        Write-Host 'Instalando el cliente OpenSSH de Windows...'
        $sshInstallOutput = & dism.exe /Online /Add-Capability "/CapabilityName:$capabilityName" /NoRestart /English 2>&1
        $sshInstallExitCode = $LASTEXITCODE
        if ($sshInstallExitCode -notin 0, 3010) {
            throw "DISM no pudo instalar OpenSSH Client (código $sshInstallExitCode): $($sshInstallOutput -join ' ')"
        }
        if ($sshInstallExitCode -eq 3010 -or ($sshInstallOutput -join "`n") -match '(?im)^\s*Restart Required\s*:\s*Yes\s*$') {
            $restartNeeded = $true
        }
    }
    return $restartNeeded
}

function Ensure-WindowsDockerCli {
    param([Parameter(Mandatory)]$Config)

    $required = @(
        @{ Command = 'docker.exe'; Id = 'Docker.DockerCLI'; Name = 'Docker CLI' },
        @{ Command = 'docker-compose.exe'; Id = 'Docker.DockerCompose'; Name = 'Docker Compose' },
        @{ Command = 'docker-credential-wincred.exe'; Id = 'Docker.docker-credential-wincred'; Name = 'Docker Credential Helper para Windows' }
    )
    foreach ($item in $required) {
        if (Get-Command $item.Command -ErrorAction SilentlyContinue) { continue }
        if (-not $Config.windowsCli.installWithWinget) {
            throw "$($item.Name) no está instalado y windowsCli.installWithWinget es false."
        }
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw "$($item.Name) no está instalado y winget.exe no está disponible."
        }
        Write-Host "Instalando $($item.Name) mediante Winget..."
        & winget.exe install --id $item.Id --exact --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Winget no pudo instalar $($item.Id)." }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
    }
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { throw 'docker.exe no quedó disponible en PATH.' }
    if (-not (Get-Command docker-compose.exe -ErrorAction SilentlyContinue)) { throw 'docker-compose.exe no quedó disponible en PATH.' }
    if (-not (Get-Command docker-credential-wincred.exe -ErrorAction SilentlyContinue)) { throw 'docker-credential-wincred.exe no quedó disponible en PATH.' }
}

function Request-RestartDecision {
    if ($NonInteractive) {
        Write-Warning 'Windows necesita reiniciarse. Vuelva a ejecutar install.ps1 después del reinicio.'
        exit 3010
    }
    while ($true) {
        $answer = (Read-Host 'Windows necesita reiniciarse. [R] Reiniciar ahora, [S] Salir y continuar después').Trim().ToUpperInvariant()
        switch ($answer) {
            'R' { Restart-Computer; exit 3010 }
            'S' { exit 3010 }
        }
    }
}

function Resolve-AlpineRelease {
    param([Parameter(Mandatory)]$Config)
    if ($Config.alpine.rootfsUrl -and $Config.alpine.rootfsSha256 -and $Config.alpine.version) { return }

    function Get-WebResponseText {
        param([Parameter(Mandatory)]$Response)
        if ($Response.Content -is [byte[]]) {
            return [Text.Encoding]::UTF8.GetString($Response.Content)
        }
        return [string]$Response.Content
    }

    $base = "$($Config.alpine.mirror.TrimEnd('/'))/$($Config.alpine.releaseChannel)/releases/$($Config.alpine.architecture)"
    Write-Host "Consultando versiones de Alpine en $base..."
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$base/"
    $responseText = Get-WebResponseText $response
    $pattern = "alpine-minirootfs-(?<version>\d+\.\d+\.\d+)-$([regex]::Escape([string]$Config.alpine.architecture))\.tar\.gz"
    $matches = [regex]::Matches($responseText, $pattern)
    if ($matches.Count -eq 0) { throw 'No se pudo localizar Alpine Mini Root Filesystem.' }
    $versions = $matches | ForEach-Object { [version]$_.Groups['version'].Value } | Sort-Object -Descending -Unique
    $version = $versions[0].ToString()
    $fileName = "alpine-minirootfs-$version-$($Config.alpine.architecture).tar.gz"
    $shaResponse = Invoke-WebRequest -UseBasicParsing -Uri "$base/$fileName.sha256"
    $shaText = (Get-WebResponseText $shaResponse).Trim()
    $sha256 = ($shaText -split '\s+')[0].ToUpperInvariant()
    if ($sha256 -notmatch '^[A-F0-9]{64}$') { throw 'El SHA-256 publicado por Alpine no es válido.' }

    $Config.alpine.version = $version
    $Config.alpine.branch = "v$(([version]$version).Major).$(([version]$version).Minor)"
    $Config.alpine.rootfsUrl = "$base/$fileName"
    $Config.alpine.rootfsSha256 = $sha256
}

function New-ExpandableVhdx {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$MaximumSizeGB)
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $diskpartFile = Join-Path $env:TEMP "dockerd-wsl-$([guid]::NewGuid().ToString('N')).txt"
    try {
        @"
create vdisk file="$Path" maximum=$($MaximumSizeGB * 1024) type=expandable
select vdisk file="$Path"
attach vdisk
detach vdisk
exit
"@ | Set-Content -LiteralPath $diskpartFile -Encoding ascii
        $output = & diskpart.exe /s $diskpartFile 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path)) {
            throw "DiskPart no pudo crear el VHDX: $($output -join ' ')"
        }
    }
    finally { Remove-Item -LiteralPath $diskpartFile -Force -ErrorAction SilentlyContinue }
}

Assert-Administrator

$newConfig = -not (Test-Path -LiteralPath $script:ConfigPath)
if ($newConfig) {
    New-Item -ItemType Directory -Path (Split-Path $script:ConfigPath -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $script:DefaultConfigPath -Destination $script:ConfigPath
}
$config = Get-Config

if ($newConfig -and (Test-DistroExists $config.distributionName)) {
    Remove-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue
    throw "Ya existe una distribución llamada $($config.distributionName), pero no había configuración local. No se la adoptó automáticamente."
}

$defaultDataVhdx = if ($DataVhdxPath) { $DataVhdxPath } else { Resolve-ConfiguredPath $config.paths.dataVhdx }
if ($newConfig -and -not $DataVhdxPath -and -not $NonInteractive) {
    $answer = Read-Host "Ruta del VHDX de datos [$defaultDataVhdx]"
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $defaultDataVhdx = $answer.Trim().Trim('"') }
}
$defaultDataVhdx = [IO.Path]::GetFullPath($defaultDataVhdx)
if (-not $defaultDataVhdx.EndsWith('.vhdx', [StringComparison]::OrdinalIgnoreCase)) { throw 'La ruta del VHDX de datos debe terminar en .vhdx.' }
$config.paths.dataVhdx = ConvertTo-PortablePath $defaultDataVhdx
Write-Host "VHDX de datos: $defaultDataVhdx"

$restartNeeded = Enable-WslPrerequisites
if ($restartNeeded) {
    Save-Config $config
    Request-RestartDecision
}

Write-Host 'Actualizando WSL...'
& wsl.exe --update
if ($LASTEXITCODE -ne 0) { throw "wsl --update falló con código $LASTEXITCODE." }
& wsl.exe --set-default-version 2
if ($LASTEXITCODE -ne 0) { throw 'No se pudo establecer WSL 2 como versión predeterminada.' }

Ensure-WindowsDockerCli $config

Resolve-AlpineRelease $config
Save-Config $config

foreach ($pathProperty in 'distributionDirectory', 'downloads', 'logs', 'backups') {
    New-Item -ItemType Directory -Path (Resolve-ConfiguredPath $config.paths.$pathProperty) -Force | Out-Null
}

$downloadPath = Join-Path (Resolve-ConfiguredPath $config.paths.downloads) ([IO.Path]::GetFileName([string]$config.alpine.rootfsUrl))
if (-not (Test-Path -LiteralPath $downloadPath) -or (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ne $config.alpine.rootfsSha256) {
    Write-Host "Descargando Alpine $($config.alpine.version)..."
    Invoke-WebRequest -UseBasicParsing -Uri $config.alpine.rootfsUrl -OutFile $downloadPath
}
if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ne $config.alpine.rootfsSha256) {
    Remove-Item -LiteralPath $downloadPath -Force
    throw 'La descarga de Alpine no coincide con el SHA-256 oficial.'
}

if (-not (Test-DistroExists $config.distributionName)) {
    $distroDir = Resolve-ConfiguredPath $config.paths.distributionDirectory
    Write-Host "Importando Alpine en $distroDir..."
    & wsl.exe --import $config.distributionName $distroDir $downloadPath --version 2
    if ($LASTEXITCODE -ne 0) { throw "No se pudo importar $($config.distributionName)." }
}

$mirror = $config.alpine.mirror.TrimEnd('/')
$branch = $config.alpine.branch
Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eux
printf '%s\n' '$mirror/$branch/main' '$mirror/$branch/community' > /etc/apk/repositories
apk update
apk add --no-cache openrc docker docker-cli docker-cli-compose openssh e2fsprogs util-linux ca-certificates
rc-update add docker default || true
rc-update add sshd default || true
if ! id docker >/dev/null 2>&1; then
  adduser -D -s /bin/ash -G docker docker
fi
# OpenSSH rechaza por completo las cuentas bloqueadas, incluso con clave pública.
# Se deja el campo de contraseña vacío, pero sshd exige exclusivamente publickey.
passwd -d docker >/dev/null
mkdir -p /run/openrc /home/docker/.ssh
touch /run/openrc/softlevel
chown -R docker:docker /home/docker
chmod 700 /home/docker/.ssh
mkdir -p /etc/network
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF
cat > /etc/wsl.conf <<'EOF'
[user]
default=docker
EOF
"@

$keyPath = Join-Path (Join-Path $HOME '.ssh') 'dockerd-wsl-ed25519'
$generateKey = -not (Test-Path -LiteralPath $keyPath)
if (-not $generateKey) {
    & ssh-keygen.exe -y -P '' -f $keyPath *> $null
    if ($LASTEXITCODE -ne 0) {
        $backupSuffix = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Write-Warning "La clave administrada existente no funciona sin passphrase. Se conservará con sufijo .$backupSuffix.bak y se generará una nueva."
        Move-Item -LiteralPath $keyPath -Destination "$keyPath.$backupSuffix.bak"
        if (Test-Path -LiteralPath "$keyPath.pub") {
            Move-Item -LiteralPath "$keyPath.pub" -Destination "$keyPath.pub.$backupSuffix.bak"
        }
        $generateKey = $true
    }
}
if ($generateKey) {
    New-Item -ItemType Directory -Path (Split-Path $keyPath -Parent) -Force | Out-Null
    & ssh-keygen.exe -q -t ed25519 -N '' -C 'dockerd-wsl' -f $keyPath
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo generar la clave SSH.' }
}
$publicKey = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()
$publicKeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey + "`n"))
$sshPort = [int]$config.windowsCli.sshPort
$listenAddress = [string]$config.windowsCli.sshListenAddress
Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eu
printf '%s' '$publicKeyB64' | base64 -d > /home/docker/.ssh/authorized_keys
chown docker:docker /home/docker/.ssh/authorized_keys
chmod 600 /home/docker/.ssh/authorized_keys
mkdir -p /etc/ssh/sshd_config.d
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/99-dockerd-wsl.conf <<'EOF'
Port $sshPort
ListenAddress $listenAddress
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers docker
EOF
ssh-keygen -A
sshd -t
"@
Write-ManagedSshConfig -Config $config -PrivateKeyPath $keyPath
$knownHost = "[127.0.0.1]:$([int]$config.windowsCli.sshPort)"
& ssh-keygen.exe -R $knownHost *> $null

$dataVhdx = Resolve-ConfiguredPath $config.paths.dataVhdx
$dataVhdExisted = Test-Path -LiteralPath $dataVhdx
if (-not $dataVhdExisted) {
    $before = @((Get-WslOutput -Distribution $config.distributionName -Command "lsblk -dn -o NAME") -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    Write-Host "Creando $dataVhdx..."
    New-ExpandableVhdx -Path $dataVhdx -MaximumSizeGB ([int]$config.storage.maximumSizeGB)
    & wsl.exe --mount $dataVhdx --vhd --bare
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo adjuntar el VHDX nuevo.' }
    Start-Sleep -Seconds 1
    $after = @((Get-WslOutput -Distribution $config.distributionName -Command "lsblk -dn -o NAME") -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    $newDevices = @($after | Where-Object { $before -notcontains $_ })
    if ($newDevices.Count -ne 1) { throw "No se pudo identificar inequívocamente el nuevo disco WSL: $($newDevices -join ', ')" }
    $device = "/dev/$($newDevices[0])"
    $label = [string]$config.storage.label
    Invoke-WslScript -Distribution $config.distributionName -Script "set -eux; mkfs.ext4 -F -L '$label' '$device'"
}

Mount-DockerDataVhd $config
$dataRoot = [string]$config.storage.dockerDataRoot
Invoke-WslScript -Distribution $config.distributionName -Script @"
set -eu
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "$dataRoot"
}
EOF
rc-service docker stop >/dev/null 2>&1 || true
rc-service sshd stop >/dev/null 2>&1 || true
"@

if ($config.windowsCli.setDockerHost) {
    [Environment]::SetEnvironmentVariable('DOCKER_HOST', (Get-DockerHostValue $config), 'User')
    $env:DOCKER_HOST = Get-DockerHostValue $config
}

Register-DockerdStartupTask $config
& (Join-Path $PSScriptRoot 'start.ps1')
if ($LASTEXITCODE -ne 0) { throw 'La instalación terminó, pero la validación de inicio falló.' }

Write-Host 'Validando descarga y ejecución de contenedores...'
& docker.exe run --rm hello-world
if ($LASTEXITCODE -ne 0) { throw 'Docker Engine está activo, pero la prueba con hello-world falló.' }

Write-Host ''
Write-Host 'Instalación completada.' -ForegroundColor Green
Write-Host "Distribución: $($config.distributionName)"
Write-Host "Datos Docker: $dataVhdx"
Write-Host "DOCKER_HOST: $(Get-DockerHostValue $config)"
