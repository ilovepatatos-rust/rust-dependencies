#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [Parameter(Mandatory)][string]$ScriptRoot,
    [ValidateSet('Production', 'Staging')][string]$Channel = 'Production'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    return (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
}

$scriptRootFull = (Resolve-Path -LiteralPath $ScriptRoot -ErrorAction Stop).Path
$leaf = Split-Path -Leaf $scriptRootFull
$parent = Split-Path -Parent $scriptRootFull
$parentLeaf = if ($parent) { Split-Path -Leaf $parent } else { '' }

$toolkitRoot = if ($leaf -eq 'scripts') {
    $parent
} elseif ($parentLeaf -eq 'scripts') {
    Split-Path -Parent $parent
} else {
    throw "Unable to locate toolkit root from ScriptRoot '$scriptRootFull'. Expected scripts/, scripts/<provider>/, or scripts/utility/."
}

$productionPath = Join-Path $toolkitRoot 'rust-dependencies.json'
$stagingPath = Join-Path $toolkitRoot 'rust-staging-dependencies.json'
$examplePath = Join-Path $toolkitRoot 'examples' 'rust-dependencies.example.json'

$selected = if ($Channel -eq 'Staging' -and (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
    $stagingPath
} else {
    $productionPath
}

if ($selected -eq $productionPath -and -not (Test-Path -LiteralPath $productionPath -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw "Default manifest '$productionPath' was not found and example '$examplePath' is missing."
    }
    Copy-Item -LiteralPath $examplePath -Destination $productionPath
    Write-Host "Created default manifest at '$productionPath' from examples/rust-dependencies.example.json."
}

if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) {
    throw "Resolved manifest '$selected' was not found."
}

return (Resolve-Path -LiteralPath $selected).Path
