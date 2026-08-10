#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([string]$ManifestPath, [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform)
$invoke = @{ ManifestPath = $ManifestPath; Channel = 'Staging'; Framework = 'Both'; Provider = @('Rust') }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke
