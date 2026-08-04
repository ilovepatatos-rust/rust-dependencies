#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [ValidateSet('Windows', 'Linux')][string]$ServerPlatform,
    [ValidateSet('Production', 'Staging')][string]$Channel = 'Production',
    [ValidateSet('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet')][string[]]$Provider = @('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet'),
    [switch]$ClearOutput
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RustDependencies.psd1') -Force
Invoke-RustDependencies @PSBoundParameters
