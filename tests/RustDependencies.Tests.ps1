BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'RustDependencies.psd1') -Force
}

Describe 'Manifest and path validation' {
    It 'rejects invalid JSON' {
        $path = Join-Path $TestDrive 'invalid.json'
        Set-Content $path '{'
        { Read-RdManifest $path } | Should -Throw '*not valid JSON*'
    }

    It 'requires an output directory' {
        $path = Join-Path $TestDrive 'missing-output.json'
        Set-Content $path '{"repositoryRoot":".","providers":{"steam":{}}}'
        { Read-RdManifest $path } | Should -Throw "*outputDirectory*"
    }

    It 'requires a repository root' {
        $path = Join-Path $TestDrive 'missing-root.json'
        Set-Content $path '{"outputDirectory":"./dependencies","providers":{"steam":{}}}'
        { Read-RdManifest $path } | Should -Throw "*repositoryRoot*"
    }

    It 'rejects a filesystem root as output' {
        $path = Join-Path $TestDrive 'root.json'
        $root = [IO.Path]::GetPathRoot($TestDrive).Replace('\', '\\')
        Set-Content $path "{`"repositoryRoot`":`".`",`"outputDirectory`":`"$root`",`"providers`":{`"steam`":{}}}"
        $manifest = Read-RdManifest $path
        { Resolve-RdOutputPath $manifest } | Should -Throw '*Unsafe*'
    }

    It 'rejects an output path containing the manifest' {
        $path = Join-Path $TestDrive 'self-delete.json'
        Set-Content $path '{"repositoryRoot":".","outputDirectory":".","providers":{"steam":{}}}'
        $manifest = Read-RdManifest $path
        { Resolve-RdOutputPath $manifest } | Should -Throw '*Unsafe*'
    }

    It 'supports a consumer manifest below its repository root' {
        $scripts = Join-Path $TestDrive 'scripts'
        New-Item -ItemType Directory $scripts | Out-Null
        $path = Join-Path $scripts 'dependencies.json'
        Set-Content $path '{"repositoryRoot":"..","outputDirectory":"../src/dependencies","providers":{"steam":{}}}'
        $resolved = Resolve-RdOutputPath (Read-RdManifest $path)
        $resolved | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'src/dependencies')))
    }

    It 'rejects output outside repository without explicit opt-in' {
        $path = Join-Path $TestDrive 'outside.json'
        Set-Content $path '{"repositoryRoot":"./repo","outputDirectory":"./outside/dependencies","providers":{"steam":{}}}'
        { Resolve-RdOutputPath (Read-RdManifest $path) } | Should -Throw '*outside repositoryRoot*'
    }

    It 'allows outside output only with a boolean opt-in' {
        $path = Join-Path $TestDrive 'outside-opt-in.json'
        Set-Content $path '{"repositoryRoot":"./repo","outputDirectory":"./outside/dependencies","allowOutputOutsideRepository":true,"providers":{"steam":{}}}'
        { Resolve-RdOutputPath (Read-RdManifest $path) } | Should -Not -Throw
    }
}

Describe 'Host and target platform selection' {
    It 'keeps host and target independent' {
        $result = Resolve-RdPlatform -HostPlatform Linux -ServerPlatform Windows
        $result.Host | Should -Be 'Linux'
        $result.Server | Should -Be 'Windows'
        $result.HostAsset | Should -Be 'linux-x64'
        $result.Folder | Should -Be 'windows'
    }

    It 'defaults target to the selected host' {
        (Resolve-RdPlatform -HostPlatform Windows).Server | Should -Be 'Windows'
    }

    It 'rejects traversal in target folder mappings during orchestration' {
        $path = Join-Path $TestDrive 'traversal.json'
        Set-Content $path '{"repositoryRoot":".","outputDirectory":"./safe/output","targetPlatformMapping":{"Windows":"../escape"},"providers":{"steam":{}}}'
        { Invoke-RustDependencies -ManifestPath $path -Provider Rust -ServerPlatform Windows -WhatIf } | Should -Throw '*safe path segment*'
    }
}

Describe 'Provider descriptors and exclusions' {
    It 'uses exact Carbon release assets and repository' {
        $manifest = Get-Content (Join-Path $PSScriptRoot '..' 'rust-dependencies.example.json') -Raw | ConvertFrom-Json
        $manifest.providers.carbon.assets.Production.Windows.asset | Should -Be 'Carbon.Windows.Release.zip'
        $manifest.providers.carbon.assets.Production.Linux.asset | Should -Be 'Carbon.Linux.Release.tar.gz'
        $manifest.providers.carbon.assets.Staging.Windows.asset | Should -Be 'Carbon.Windows.Debug.zip'
        $manifest.providers.carbon.assets.Staging.Linux.asset | Should -Be 'Carbon.Linux.Debug.tar.gz'
        foreach ($channel in 'Production', 'Staging') {
            $manifest.providers.carbon.assets.$channel.Windows.repo | Should -Be 'CarbonCommunity/Carbon'
            $manifest.providers.carbon.assets.$channel.Linux.repo | Should -Be 'CarbonCommunity/Carbon'
            $manifest.providers.carbon.assets.$channel.Windows.PSObject.Properties.Name | Should -Not -Contain 'assetPattern'
            $manifest.providers.carbon.assets.$channel.Linux.PSObject.Properties.Name | Should -Not -Contain 'assetPattern'
        }
    }

    It 'uses exact Carbon defaults when assets are omitted' {
        InModuleScope RustDependencies {
            $manifest = [pscustomobject]@{ providers = [pscustomobject]@{ carbon = [pscustomobject]@{} } }
            $windows = [pscustomobject]@{ Server = 'Windows' }
            $linux = [pscustomobject]@{ Server = 'Linux' }
            $production = Resolve-RdFrameworkDescriptor carbon $manifest $windows Production
            $staging = Resolve-RdFrameworkDescriptor carbon $manifest $linux Staging
            $production.repo | Should -Be 'CarbonCommunity/Carbon'
            $production.tag | Should -Be 'production_build'
            $production.asset | Should -Be 'Carbon.Windows.Release.zip'
            $staging.repo | Should -Be 'CarbonCommunity/Carbon'
            $staging.tag | Should -Be 'rustbeta_staging_build'
            $staging.asset | Should -Be 'Carbon.Linux.Debug.tar.gz'
        }
    }

    It 'normalizes Windows separators before matching native exclusions' {
        InModuleScope RustDependencies {
            $manifest = [pscustomobject]@{ exclusions = @() }
            Test-RdExcluded 'runtimes\win-x64\native\NativeLibrary.dll' $manifest | Should -BeTrue
        }
    }

    It 'uses verified staging Oxide endpoints for both targets' {
        $path = Join-Path $TestDrive 'oxide-staging.json'
        Set-Content $path '{"repositoryRoot":".","outputDirectory":"./safe/dependencies","providers":{"oxide":{"assets":{"Staging":{}}}}}'
        $manifest = Read-RdManifest $path
        InModuleScope RustDependencies -Parameters @{ Manifest = $manifest } {
            param($Manifest)
            $windows = Resolve-RdFrameworkDescriptor oxide $Manifest ([pscustomobject]@{ Server = 'Windows' }) Staging
            $linux = Resolve-RdFrameworkDescriptor oxide $Manifest ([pscustomobject]@{ Server = 'Linux' }) Staging
            $windows.url | Should -Be 'https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust.zip'
            $windows.name | Should -Be 'Oxide.Rust.zip'
            $linux.url | Should -Be 'https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip'
            $linux.name | Should -Be 'Oxide.Rust-linux.zip'
        }
    }
}

Describe 'Output cleanup' {
    It 'clears only the configured output directory' {
        $output = Join-Path $TestDrive 'dependencies'
        $other = Join-Path $TestDrive 'unrelated.txt'
        New-Item -ItemType Directory $output | Out-Null
        Set-Content (Join-Path $output 'old.dll') 'old'
        Set-Content $other 'keep'
        Clear-RdOutput $output
        Test-Path (Join-Path $output 'old.dll') | Should -BeFalse
        Test-Path $other | Should -BeTrue
        Test-Path $output | Should -BeTrue
    }
}

Describe 'Archive mapping' {
    It 'maps zip archives to Expand-Archive' {
        $archive = Join-Path $TestDrive 'asset.zip'
        Set-Content $archive 'not read because mocked'
        Mock Expand-Archive -ModuleName RustDependencies
        Expand-RdArchive $archive (Join-Path $TestDrive 'expanded')
        Should -Invoke Expand-Archive -ModuleName RustDependencies -Times 1
    }

    It 'maps tar.gz archives to the tar adapter' {
        $archive = Join-Path $TestDrive 'asset.tar.gz'
        Set-Content $archive 'not read because mocked'
        Mock Invoke-RdTar -ModuleName RustDependencies
        Expand-RdArchive $archive (Join-Path $TestDrive 'expanded-tar')
        Should -Invoke Invoke-RdTar -ModuleName RustDependencies -Times 1
    }

    It 'rejects unknown archive formats' {
        $archive = Join-Path $TestDrive 'asset.bin'
        Set-Content $archive 'x'
        { Expand-RdArchive $archive (Join-Path $TestDrive 'expanded') } | Should -Throw '*Unsupported archive*'
    }
}

Describe 'Orchestration' {
    BeforeEach {
        $script:output = Join-Path $TestDrive 'dependencies'
        $script:manifestPath = Join-Path $TestDrive 'manifest.json'
        Set-Content $script:manifestPath "{`"repositoryRoot`":`"$($TestDrive.Replace('\','\\'))`",`"outputDirectory`":`"$($script:output.Replace('\','\\'))`",`"providers`":{`"steam`":{}}}"
        New-Item -ItemType Directory $script:output -Force | Out-Null
        Set-Content (Join-Path $script:output 'stale.dll') 'stale'
        Mock Invoke-RdRust -ModuleName RustDependencies
    }

    It 'clears output before invoking a provider in all mode' {
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ClearOutput -ServerPlatform Windows
        Test-Path (Join-Path $script:output 'stale.dll') | Should -BeFalse
        Should -Invoke Invoke-RdRust -ModuleName RustDependencies -Times 1
    }

    It 'does not clear output for focused mode' {
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows
        Test-Path (Join-Path $script:output 'stale.dll') | Should -BeTrue
    }

    It 'removes temporary directories when a provider fails' {
        $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'rust-dependencies-*' |
            ForEach-Object FullName)
        Mock Invoke-RdRust -ModuleName RustDependencies { throw 'simulated provider failure' }
        { Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows } | Should -Throw '*simulated*'
        $after = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'rust-dependencies-*' |
            ForEach-Object FullName)
        @($after | Where-Object { $_ -notin $before }).Count | Should -Be 0
    }
}

Describe 'Release collection asset handling' {
    It 'copies a direct DLL without archive expansion' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'direct-dll.json'
        Set-Content $manifestPath '{"repositoryRoot":"./repository","outputDirectory":"./repository/dependencies","providers":{"publicReleases":[{"name":"ExtensionApi","url":"https://example.invalid/Extension.Api.dll"}]}}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Invoke-RdDownloadDescriptor -ModuleName RustDependencies {
            param($Descriptor, $Destination, $Token, $Channel)
            $path = Join-Path $Destination 'Extension.Api.dll'
            Set-Content $path 'managed assembly placeholder'
            return $path
        }
        Mock Expand-RdArchive -ModuleName RustDependencies

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -ServerPlatform Windows

        Test-Path (Join-Path $output 'publicReleases/windows/ExtensionApi/Extension.Api.dll') | Should -BeTrue
        Should -Invoke Expand-RdArchive -ModuleName RustDependencies -Times 0
    }
}
