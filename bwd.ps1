[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'start', 'update', 'enable', 'disable', 'stop', 'restart', 'expose')]
    [string]$Command,

    [string]$DataVhdxPath,
    [switch]$NonInteractive,
    [switch]$DeleteDockerData,
    [switch]$RemoveConfiguration,
    [switch]$SkipBackup,
    [switch]$Force,
    [switch]$Watch,
    [switch]$Clear
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
    expose    = @('Watch', 'Clear')
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Host 'Usage: .\bwd.ps1 <install|uninstall|start|update|enable|disable|stop|restart|expose> [arguments]'
    exit 1
}

$allowed = $commandParameters[$Command]
$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -eq 'Command') { continue }
    if ($name -notin $allowed) {
        throw "The argument -$name is not valid for '$Command'."
    }
    $forward[$name] = $PSBoundParameters[$name]
}

$target = Join-Path $PSScriptRoot "src\$Command.ps1"
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "The internal script for '$Command': $target"
}

& $target @forward
