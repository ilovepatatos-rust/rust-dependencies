#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$ManifestPath, [ValidateSet('Windows', 'Linux')][string]$ServerPlatform)
$invoke = @{ ManifestPath = $ManifestPath; Channel = 'Production'; Provider = @('Oxide') }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke
