param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stopArguments = @{}
if ($Force) { $stopArguments.Force = $true }

& (Join-Path $PSScriptRoot 'stop.ps1') @stopArguments
if (-not $?) { throw 'Could not stop Docker Engine; it will not be started.' }

& (Join-Path $PSScriptRoot 'start.ps1')
