#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$ManifestPath, [ValidateSet('Windows', 'Linux')][string]$ServerPlatform, [switch]$Publicize)
$invoke = @{ ManifestPath = $ManifestPath; Channel = 'Staging'; Framework = 'Both'; Provider = @('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet'); ClearOutput = $true }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($Publicize) { $invoke.Publicize = $true }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke
