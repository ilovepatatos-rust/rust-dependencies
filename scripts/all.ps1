#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param([string]$ManifestPath, [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform, [switch]$Publicize)
$invoke = @{}
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) { $invoke.ManifestPath = $ManifestPath }
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($Publicize) { $invoke.Publicize = $true }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
& (Join-Path $PSScriptRoot 'rust+oxide+carbon.ps1') @invoke
& (Join-Path $PSScriptRoot 'rust-staging+oxide+carbon.ps1') @invoke
