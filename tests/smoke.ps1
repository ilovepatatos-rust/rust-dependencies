#!/usr/bin/env pwsh
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Join-Path $root 'scripts'
$moduleManifest = Join-Path $root 'module' 'RustDependencies.psd1'
$exampleManifest = Join-Path $root 'examples' 'rust-dependencies.example.json'
$failures = [Collections.Generic.List[string]]::new()

foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object Extension -in '.ps1', '.psm1', '.psd1') {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in $errors) { $failures.Add("$($file.Name): $($error.Message)") }
}

try {
    $rootScripts = @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')
    if ($rootScripts.Count -ne 1 -or $rootScripts[0].Name -ne 'download-dependencies.ps1') {
        throw 'Repository root must contain exactly download-dependencies.ps1 as its PowerShell entrypoint.'
    }
    $expectedRootWrappers = @(
        'all.ps1',
        'all-staging.ps1',
        'all-oxide.ps1',
        'all-oxide-staging.ps1',
        'all-carbon.ps1',
        'all-carbon-staging.ps1',
        'all-rust.ps1',
        'all-rust-staging.ps1'
    )
    $rootWrappers = @(Get-ChildItem -LiteralPath $scriptsRoot -File -Filter '*.ps1')
    if ($rootWrappers.Count -ne $expectedRootWrappers.Count -or
        @($rootWrappers.Name | Where-Object { $_ -notin $expectedRootWrappers }).Count -ne 0) {
        throw 'Only the eight all-* wrappers may exist directly under scripts/.'
    }
    $looseRoot = @(Get-ChildItem -LiteralPath $scriptsRoot -File |
        Where-Object { $_.Extension -ne '.ps1' })
    if ($looseRoot.Count -ne 0) {
        throw "Unexpected non-wrapper files under scripts/: $($looseRoot.Name -join ', ')"
    }
    $entrypoints = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter 'Invoke-RustDependencies.ps1')
    if ($entrypoints.Count -ne 1 -or
        $entrypoints[0].FullName -ne (Join-Path $scriptsRoot 'utility' 'Invoke-RustDependencies.ps1')) {
        throw 'Expected exactly one central entrypoint at scripts/utility/Invoke-RustDependencies.ps1.'
    }
    $helperNames = @('Invoke-RustDependencies.ps1', 'Resolve-DefaultManifestPath.ps1')
    $wrappers = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter '*.ps1' |
        Where-Object Name -notin $helperNames)
    if ($wrappers.Count -ne 17) { throw "Expected 17 wrapper entrypoints, found $($wrappers.Count)." }
    $expectedInvocations = @{
        'all.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-oxide.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-oxide-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-carbon-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-rust.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'all-rust-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust/download.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust/staging.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'oxide/download.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'oxide/staging.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'carbon/download.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'carbon/staging.ps1' = "& (Join-Path `$PSScriptRoot '..' 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'utility/public-dlls.ps1' = "& (Join-Path `$PSScriptRoot 'Invoke-RustDependencies.ps1') @invoke"
        'utility/private-dlls.ps1' = "& (Join-Path `$PSScriptRoot 'Invoke-RustDependencies.ps1') @invoke"
        'utility/publicize.ps1' = "& (Join-Path `$PSScriptRoot 'Invoke-RustDependencies.ps1') @invoke"
    }
    foreach ($wrapper in $wrappers) {
        $relativePath = [IO.Path]::GetRelativePath($scriptsRoot, $wrapper.FullName).Replace('\', '/')
        if (-not $expectedInvocations.ContainsKey($relativePath)) {
            throw "Unexpected wrapper entrypoint: $relativePath"
        }
        $source = Get-Content -LiteralPath $wrapper.FullName -Raw
        if ($source -notmatch [regex]::Escape($expectedInvocations[$relativePath])) {
            throw "$relativePath does not invoke the central entrypoint using the expected relative path."
        }
    }
    $manifestInfo = Test-ModuleManifest -Path $moduleManifest
    if ($manifestInfo.RootModule -ne 'RustDependencies.psm1') { throw 'The module manifest RootModule is incorrect.' }
    Get-Content -LiteralPath $exampleManifest -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
    $stagingExample = Join-Path $root 'examples' 'rust-staging-dependencies.example.json'
    $stagingManifest = Get-Content -LiteralPath $stagingExample -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($stagingManifest.outputDirectory -ne './dependencies-staging') {
        throw 'Staging example outputDirectory must be ./dependencies-staging.'
    }

    Import-Module $moduleManifest -Force
    $cross = Resolve-RdPlatform -HostPlatform Linux -ServerPlatform Windows
    if ($cross.HostAsset -ne 'linux-x64' -or $cross.Folder -ne 'windows') { throw 'Cross-platform mapping is incorrect.' }
    $module = Get-Module RustDependencies
    $defaultFileList = @(& $module { Get-RdSteamFileList })
    if ($defaultFileList.Count -ne 1 -or $defaultFileList[0] -ne 'regex:RustDedicated_Data/Managed/.*\.dll') {
        throw 'Default Rust DepotDownloader file list is incorrect.'
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) "rust-dependencies-smoke-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory $temp | Out-Null
    try {
        $output = Join-Path $temp 'output'
        $manifestPath = Join-Path $temp 'manifest.json'
        @{ repositoryRoot = $temp; outputDirectory = $output; publicReleases = @(); privateReleases = @(); githubNuget = @() } | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
        $manifest = Read-RdManifest $manifestPath
        if ((Resolve-RdOutputPath $manifest) -ne [IO.Path]::GetFullPath($output)) { throw 'Output path resolution failed.' }
        New-Item -ItemType Directory $output | Out-Null
        Set-Content (Join-Path $output 'stale.txt') 'stale'
        Clear-RdOutput $output
        if (Test-Path (Join-Path $output 'stale.txt')) { throw 'Output cleanup failed.' }

        $unsafePath = Join-Path $temp 'unsafe.json'
        @{ repositoryRoot = '.'; outputDirectory = '.'; publicReleases = @(); privateReleases = @(); githubNuget = @() } | ConvertTo-Json -Depth 5 | Set-Content $unsafePath
        $rejected = $false
        try { Resolve-RdOutputPath (Read-RdManifest $unsafePath) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Manifest-containing output path was not rejected.' }

        $mappingPath = Join-Path $temp 'mapping.json'
        @{
            repositoryRoot = '.'
            outputDirectory = './safe/output'
            targetPlatformMapping = @{ Windows = '../escape' }
            publicReleases = @(); privateReleases = @(); githubNuget = @()
        } | ConvertTo-Json -Depth 5 | Set-Content $mappingPath
        $rejected = $false
        try { Invoke-RustDependencies -ManifestPath $mappingPath -Provider Rust -ServerPlatform Windows -WhatIf }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Unsafe platform mapping was not rejected.' }

        $outsidePath = Join-Path $temp 'outside.json'
        @{
            repositoryRoot = './repository'
            outputDirectory = './elsewhere/dependencies'
            publicReleases = @(); privateReleases = @(); githubNuget = @()
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
            publicReleases = @(); privateReleases = @(); githubNuget = @()
        } | ConvertTo-Json -Depth 5 | Set-Content $outsideOptInPath
        Resolve-RdOutputPath (Read-RdManifest $outsideOptInPath) | Out-Null

        $excluded = & $module {
            param($manifest)
            Test-RdExcluded 'runtimes\win-x64\native\NativeLibrary.dll' $manifest
        } ([pscustomobject]@{ exclusions = @() })
        if (-not $excluded) { throw 'Windows separator exclusion normalization failed.' }

        $carbonDefault = & $module {
            Resolve-RdFrameworkDescriptor carbon ([pscustomobject]@{}) ([pscustomobject]@{ Server = 'Linux' }) Staging
        }
        if ($carbonDefault.repo -ne 'CarbonCommunity/Carbon' -or
            $carbonDefault.asset -ne 'Carbon.Linux.Debug.tar.gz') {
            throw 'Carbon staging defaults are incorrect.'
        }

        foreach ($serverPlatform in 'Windows', 'Linux') {
            $oxideStaging = & $module {
                param($platform)
                Resolve-RdFrameworkDescriptor oxide ([pscustomobject]@{}) ([pscustomobject]@{ Server = $platform }) Staging
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
            publicReleases = @([pscustomobject]@{
                name = 'ExtensionApi'
                url = 'https://example.invalid/Extension.Api.dll'
            })
        }
        & $module {
            param($manifest, $platform, $output, $providerTemp, $asset)
            function Invoke-RdDownloadDescriptor { return $asset }
            Invoke-RdReleaseCollection 'publicReleases' $manifest $platform $output $providerTemp Both
        } $releaseManifest ([pscustomobject]@{ Folder = 'windows' }) $releaseOutput $releaseTemp $directDll
        if (-not (Test-Path (Join-Path $releaseOutput 'windows/oxide/Extension.Api.dll')) -or
            -not (Test-Path (Join-Path $releaseOutput 'windows/carbon/Extension.Api.dll'))) {
            throw 'Direct DLL release handling failed.'
        }

        $frameworkFolders = & $module {
            $carbonItem = [pscustomobject]@{ frameworks = @('Carbon') }
            [pscustomobject]@{
                Carbon = @(Get-RdItemFrameworkFolders $carbonItem Carbon 'smoke')
                Oxide = @(Get-RdItemFrameworkFolders $carbonItem Oxide 'smoke')
                Shared = @(Get-RdItemFrameworkFolders ([pscustomobject]@{}) Both 'smoke')
            }
        }
        if ($frameworkFolders.Carbon -ne 'carbon' -or $frameworkFolders.Oxide.Count -ne 0 -or
            ($frameworkFolders.Shared -join ',') -ne 'oxide,carbon') {
            throw 'Framework filtering or shared output mapping failed.'
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
