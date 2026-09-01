Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Join-Path $root 'scripts'
$moduleManifest = Join-Path $root 'module' 'RustDependencies.psd1'
$exampleManifest = Join-Path $root 'examples' 'rust-dependencies.example.json'

$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'download-dependencies.ps1'),
    [ref]$null,
    [ref]$null
)

try {
    $rootScripts = @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')
    if ($rootScripts.Count -ne 1 -or $rootScripts[0].Name -ne 'download-dependencies.ps1') {
        throw 'Repository root must contain exactly download-dependencies.ps1 as its PowerShell entrypoint.'
    }
    $expectedRootWrappers = @(
        'all.ps1',
        'rust+oxide+carbon.ps1',
        'rust-staging+oxide+carbon.ps1',
        'rust+oxide.ps1',
        'rust-staging+oxide.ps1',
        'rust+carbon.ps1',
        'rust-staging+carbon.ps1',
        'rust.ps1',
        'rust-staging.ps1'
    )
    $rootWrappers = @(Get-ChildItem -LiteralPath $scriptsRoot -File -Filter '*.ps1')
    if ($rootWrappers.Count -ne $expectedRootWrappers.Count -or
        @($rootWrappers.Name | Where-Object { $_ -notin $expectedRootWrappers }).Count -ne 0) {
        throw 'Only the nine named orchestration wrappers may exist directly under scripts/.'
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
    if ($wrappers.Count -ne 18) { throw "Expected 18 wrapper entrypoints, found $($wrappers.Count)." }
    $expectedInvocations = @{
        'all.ps1' = 'ForEach-Object -ThrottleLimit 2 -Parallel'
        'rust+oxide+carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust-staging+oxide+carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust+oxide.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust-staging+oxide.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust+carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust-staging+carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
        'rust-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
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
            throw "$relativePath does not invoke the expected entrypoint."
        }
        if ($relativePath -eq 'all.ps1') {
            if ($source -notmatch [regex]::Escape("Join-Path `$PSScriptRoot 'rust+oxide+carbon.ps1'")) {
                throw 'all.ps1 must invoke rust+oxide+carbon.ps1.'
            }
            if ($source -notmatch [regex]::Escape("Join-Path `$PSScriptRoot 'rust-staging+oxide+carbon.ps1'")) {
                throw 'all.ps1 must also invoke rust-staging+oxide+carbon.ps1.'
            }
        }
    }
    $manifestInfo = Test-ModuleManifest -Path $moduleManifest
    if ($manifestInfo.RootModule -ne 'RustDependencies.psm1') { throw 'The module manifest RootModule is incorrect.' }
    Get-Content -LiteralPath $exampleManifest -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
    $stagingExample = Join-Path $root 'examples' 'rust-staging-dependencies.example.json'
    $stagingManifest = Get-Content -LiteralPath $stagingExample -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($stagingManifest.outputDirectory -ne './dependencies') {
        throw 'Staging example outputDirectory must be ./dependencies.'
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
        @{ outputDirectory = $output; publicReleases = @(); privateReleases = @(); githubNuget = @() } | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
        $manifest = Read-RdManifest $manifestPath
        if ((Resolve-RdOutputPath $manifest) -ne [IO.Path]::GetFullPath($output)) { throw 'Output path resolution failed.' }
        New-Item -ItemType Directory $output | Out-Null
        Set-Content (Join-Path $output 'stale.txt') 'stale'
        Clear-RdOutput $output
        if (Test-Path (Join-Path $output 'stale.txt')) { throw 'Output cleanup failed.' }

        $unsafePath = Join-Path $temp 'unsafe.json'
        @{ outputDirectory = '.'; publicReleases = @(); privateReleases = @(); githubNuget = @() } | ConvertTo-Json -Depth 5 | Set-Content $unsafePath
        $rejected = $false
        try { Resolve-RdOutputPath (Read-RdManifest $unsafePath) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Manifest-containing output path was not rejected.' }

        $outsidePath = Join-Path $temp 'outside.json'
        @{
            outputDirectory = '../elsewhere/dependencies'
            publicReleases = @(); privateReleases = @(); githubNuget = @()
        } | ConvertTo-Json -Depth 5 | Set-Content $outsidePath
        $outsideResolved = Resolve-RdOutputPath (Read-RdManifest $outsidePath)
        $expectedOutside = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $temp) 'elsewhere/dependencies'))
        if ($outsideResolved -ne $expectedOutside) { throw 'Output outside the manifest directory was not resolved.' }

        $excluded = & $module {
            Test-RdExcluded 'runtimes\win-x64\native\NativeLibrary.dll'
        }
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
            publicReleases = @([pscustomobject]@{
                name = 'ExtensionApi'
                url = 'https://example.invalid/Extension.Api.dll'
            })
        }
        & $module {
            param($manifest, $platform, $output, $providerTemp, $asset)
            function Invoke-RdDownloadDescriptor { return $asset }
            Invoke-RdReleaseCollection 'publicReleases' $manifest $platform Production $output $providerTemp Both
        } $releaseManifest ([pscustomobject]@{ Folder = 'windows' }) $releaseOutput $releaseTemp $directDll
        if (-not (Test-Path (Join-Path $releaseOutput 'main/windows/oxide/Extension.Api.dll')) -or
            -not (Test-Path (Join-Path $releaseOutput 'main/windows/carbon/Extension.Api.dll'))) {
            throw 'Direct DLL release handling failed.'
        }
        if (Test-Path (Join-Path $releaseOutput 'main/windows/rust/Extension.Api.dll')) {
            throw 'Shared release DLLs must not be copied into the vanilla rust/ leaf.'
        }

        $frameworkFolders = & $module {
            $carbonItem = [pscustomobject]@{ frameworks = @('Carbon') }
            [pscustomobject]@{
                Carbon = @(Get-RdItemFrameworkFolders $carbonItem Carbon 'smoke')
                Oxide = @(Get-RdItemFrameworkFolders $carbonItem Oxide 'smoke')
                Shared = @(Get-RdItemFrameworkFolders ([pscustomobject]@{}) Both 'smoke')
                BothLeaves = @(Get-RdSelectedFrameworkFolders Both)
            }
        }
        if ($frameworkFolders.Carbon -ne 'carbon' -or $frameworkFolders.Oxide.Count -ne 0 -or
            ($frameworkFolders.Shared -join ',') -ne 'oxide,carbon' -or
            ($frameworkFolders.BothLeaves -join ',') -ne 'rust,oxide,carbon') {
            throw 'Framework filtering or shared output mapping failed.'
        }
    }
    finally {
        if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force }
    }

    Write-Host 'Smoke tests passed: parser, module, safety, providers, direct DLLs, and cleanup.'
    # Explicit success: GitHub Actions pwsh fails the step if a prior native
    # command left a non-zero $LASTEXITCODE even when the script itself succeeded.
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
