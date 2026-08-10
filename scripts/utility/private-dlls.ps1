#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [ValidateSet('Windows', 'Linux')][string]$ServerPlatform,
    [ValidateSet('Oxide', 'Carbon', 'Both')][string]$Framework = 'Both'
)
$invoke = @{ ManifestPath = $ManifestPath; Framework = $Framework; Provider = @('Private') }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot 'Invoke-RustDependencies.ps1') @invoke
