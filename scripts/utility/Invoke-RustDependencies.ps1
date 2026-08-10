#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [ValidateSet('Windows', 'Linux')][string]$ServerPlatform = $(if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } else { throw 'Unsupported host OS.' }),
    [ValidateSet('Production', 'Staging')][string]$Channel = 'Production',
    [ValidateSet('Oxide', 'Carbon', 'Both')][string]$Framework = 'Both',
    [ValidateSet('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet')][string[]]$Provider = @('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet'),
    [switch]$ClearOutput,
    [switch]$Publicize
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'module' 'RustDependencies.psd1') -Force
$invoke = @{
    ManifestPath = $ManifestPath
    Channel = $Channel
    Framework = $Framework
    Provider = $Provider
    ClearOutput = $ClearOutput
    Publicize = $Publicize
}
if ($ServerPlatform) { $invoke.ServerPlatform = $ServerPlatform }
if ($WhatIfPreference) { $invoke.WhatIf = $true }
Invoke-RustDependencies @invoke
