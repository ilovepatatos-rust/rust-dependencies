#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath,
    [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform,
    [ValidateSet('Oxide', 'Carbon', 'Both')][string]$Framework = 'Both'
)
$invoke = @{ ManifestPath = $ManifestPath; Framework = $Framework; Provider = @('Public', 'NuGet') }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot 'Invoke-RustDependencies.ps1') @invoke
