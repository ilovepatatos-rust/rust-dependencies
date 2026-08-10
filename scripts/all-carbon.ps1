#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([string]$ManifestPath, [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform, [switch]$Publicize)
$invoke = @{ ManifestPath = $ManifestPath; Channel = 'Production'; Framework = 'Carbon'; Provider = @('Rust', 'Carbon', 'Public', 'Private', 'NuGet'); ClearOutput = $true }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($Publicize) { $invoke.Publicize = $true }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke
