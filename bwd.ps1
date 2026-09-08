[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'start', 'update', 'enable', 'disable', 'stop', 'restart')]
    [string]$Command,

    [string]$DataVhdxPath,
    [switch]$NonInteractive,
    [switch]$DeleteDockerData,
    [switch]$RemoveConfiguration,
    [switch]$SkipBackup,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commandParameters = @{
    install   = @('DataVhdxPath', 'NonInteractive')
    uninstall = @('DeleteDockerData', 'RemoveConfiguration')
    start     = @('NonInteractive')
    update    = @('SkipBackup')
    enable    = @()
    disable   = @()
    stop      = @('Force')
    restart   = @('Force')
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Host 'Uso: .\bwd.ps1 <install|uninstall|start|update|enable|disable|stop|restart> [argumentos]'
    exit 1
}

$allowed = $commandParameters[$Command]
$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -eq 'Command') { continue }
    if ($name -notin $allowed) {
        throw "El argumento -$name no es válido para '$Command'."
    }
    $forward[$name] = $PSBoundParameters[$name]
}

$target = Join-Path $PSScriptRoot "src\$Command.ps1"
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "No existe el script interno para '$Command': $target"
}

& $target @forward
