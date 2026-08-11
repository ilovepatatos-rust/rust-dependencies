#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([string]$ManifestPath, [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform)
$invoke = @{ ManifestPath = $ManifestPath; Channel = 'Production'; Framework = 'Rust'; Provider = @('Rust') }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke
