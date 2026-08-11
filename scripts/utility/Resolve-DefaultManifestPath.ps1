#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [Parameter(Mandatory)][string]$ScriptRoot,
    [ValidateSet('Production', 'Staging')][string]$Channel = 'Production'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ScriptRoot/Channel are accepted for call-site compatibility; defaults must never
# resolve to the cached toolkit manifest (that would write into the toolkit cache).
$null = $ScriptRoot
$null = $Channel

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    throw "ManifestPath is required. Pass -ManifestPath to the script (bootstrap always supplies the project manifest)."
}

return (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
