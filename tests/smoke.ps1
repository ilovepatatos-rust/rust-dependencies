#!/usr/bin/env pwsh
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()

foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object Extension -in '.ps1', '.psm1', '.psd1') {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in $errors) { $failures.Add("$($file.Name): $($error.Message)") }
}

try {
    Import-Module (Join-Path $root 'RustDependencies.psd1') -Force
    $cross = Resolve-RdPlatform -HostPlatform Linux -ServerPlatform Windows
    if ($cross.HostAsset -ne 'linux-x64' -or $cross.Folder -ne 'windows') { throw 'Cross-platform mapping is incorrect.' }

    $temp = Join-Path ([IO.Path]::GetTempPath()) "rust-dependencies-smoke-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory $temp | Out-Null
    try {
        $output = Join-Path $temp 'output'
        $manifestPath = Join-Path $temp 'manifest.json'
        @{ repositoryRoot = $temp; outputDirectory = $output; providers = @{ steam = @{} } } | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
        $manifest = Read-RdManifest $manifestPath
        if ((Resolve-RdOutputPath $manifest) -ne [IO.Path]::GetFullPath($output)) { throw 'Output path resolution failed.' }
        New-Item -ItemType Directory $output | Out-Null
        Set-Content (Join-Path $output 'stale.txt') 'stale'
        Clear-RdOutput $output
        if (Test-Path (Join-Path $output 'stale.txt')) { throw 'Output cleanup failed.' }

        $unsafePath = Join-Path $temp 'unsafe.json'
        @{ repositoryRoot = '.'; outputDirectory = '.'; providers = @{ steam = @{} } } | ConvertTo-Json -Depth 5 | Set-Content $unsafePath
        $rejected = $false
        try { Resolve-RdOutputPath (Read-RdManifest $unsafePath) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Manifest-containing output path was not rejected.' }

        $mappingPath = Join-Path $temp 'mapping.json'
        @{
            repositoryRoot = '.'
            outputDirectory = './safe/output'
            targetPlatformMapping = @{ Windows = '../escape' }
            providers = @{ steam = @{} }
        } | ConvertTo-Json -Depth 5 | Set-Content $mappingPath
        $rejected = $false
        try { Invoke-RustDependencies -ManifestPath $mappingPath -Provider Rust -ServerPlatform Windows -WhatIf }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Unsafe platform mapping was not rejected.' }

        $outsidePath = Join-Path $temp 'outside.json'
        @{
            repositoryRoot = './repository'
            outputDirectory = './elsewhere/dependencies'
            providers = @{ steam = @{} }
        } | ConvertTo-Json -Depth 5 | Set-Content $outsidePath
        $rejected = $false
        try { Resolve-RdOutputPath (Read-RdManifest $outsidePath) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Output outside repositoryRoot was not rejected.' }

        $outsideOptInPath = Join-Path $temp 'outside-opt-in.json'
        @{
            repositoryRoot = './repository'
            outputDirectory = './elsewhere/dependencies'
            allowOutputOutsideRepository = $true
            providers = @{ steam = @{} }
        } | ConvertTo-Json -Depth 5 | Set-Content $outsideOptInPath
        Resolve-RdOutputPath (Read-RdManifest $outsideOptInPath) | Out-Null

        $module = Get-Module RustDependencies
        $excluded = & $module {
            param($manifest)
            Test-RdExcluded 'runtimes\win-x64\native\NativeLibrary.dll' $manifest
        } ([pscustomobject]@{ exclusions = @() })
        if (-not $excluded) { throw 'Windows separator exclusion normalization failed.' }

        $carbonDefault = & $module {
            $manifest = [pscustomobject]@{ providers = [pscustomobject]@{ carbon = [pscustomobject]@{} } }
            Resolve-RdFrameworkDescriptor carbon $manifest ([pscustomobject]@{ Server = 'Linux' }) Staging
        }
        if ($carbonDefault.repo -ne 'CarbonCommunity/Carbon' -or
            $carbonDefault.asset -ne 'Carbon.Linux.Debug.tar.gz') {
            throw 'Carbon staging defaults are incorrect.'
        }

        foreach ($serverPlatform in 'Windows', 'Linux') {
            $oxideStaging = & $module {
                param($platform)
                $manifest = [pscustomobject]@{
                    providers = [pscustomobject]@{
                        oxide = [pscustomobject]@{ assets = [pscustomobject]@{ Staging = [pscustomobject]@{} } }
                    }
                }
                Resolve-RdFrameworkDescriptor oxide $manifest ([pscustomobject]@{ Server = $platform }) Staging
            } $serverPlatform
            if ($oxideStaging.url -notlike 'https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/*') {
                throw "Oxide staging URL is incorrect for $serverPlatform."
            }
        }

        $directDll = Join-Path $temp 'Extension.Api.dll'
        Set-Content $directDll 'managed assembly placeholder'
        $releaseOutput = Join-Path $temp 'release-output'
        $releaseTemp = Join-Path $temp 'release-temp'
        New-Item -ItemType Directory $releaseTemp | Out-Null
        $releaseManifest = [pscustomobject]@{
            exclusions = @()
            providers = [pscustomobject]@{
                publicReleases = @([pscustomobject]@{
                    name = 'ExtensionApi'
                    url = 'https://example.invalid/Extension.Api.dll'
                })
            }
        }
        & $module {
            param($manifest, $platform, $output, $providerTemp, $asset)
            function Invoke-RdDownloadDescriptor { return $asset }
            Invoke-RdReleaseCollection 'publicReleases' $manifest $platform $output $providerTemp
        } $releaseManifest ([pscustomobject]@{ Folder = 'windows' }) $releaseOutput $releaseTemp $directDll
        if (-not (Test-Path (Join-Path $releaseOutput 'publicReleases/windows/ExtensionApi/Extension.Api.dll'))) {
            throw 'Direct DLL release handling failed.'
        }
    }
    finally {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force }
    }
}
catch {
    $failures.Add($_.Exception.Message)
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Smoke tests passed: parser, module, safety, providers, direct DLLs, and cleanup."
