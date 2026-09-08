param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stopArguments = @{}
if ($Force) { $stopArguments.Force = $true }

& (Join-Path $PSScriptRoot 'stop.ps1') @stopArguments
if (-not $?) { throw 'No se pudo detener Docker Engine; no se intentará iniciarlo.' }

& (Join-Path $PSScriptRoot 'start.ps1')
