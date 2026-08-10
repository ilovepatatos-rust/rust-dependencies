BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptsRoot = Join-Path $script:repoRoot 'scripts'
    $script:examplesRoot = Join-Path $script:repoRoot 'examples'
    Import-Module (Join-Path $script:repoRoot 'module' 'RustDependencies.psd1') -Force
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

    It 'rejects non-boolean allowOutputOutsideRepository values' {
        $path = Join-Path $TestDrive 'outside-bad-type.json'
        Set-Content $path '{"repositoryRoot":"./repo","outputDirectory":"./outside/dependencies","allowOutputOutsideRepository":"true","providers":{"steam":{}}}'
        { Read-RdManifest $path } | Should -Throw '*JSON boolean*'
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
        $manifest = Get-Content (Join-Path $script:examplesRoot 'rust-dependencies.example.json') -Raw | ConvertFrom-Json
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
            $windows.assetName | Should -Be 'Oxide.Rust.zip'
            $linux.url | Should -Be 'https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip'
            $linux.assetName | Should -Be 'Oxide.Rust-linux.zip'
        }
    }
}

Describe 'Selective Rust depot downloads' {
    It 'ignores DepotDownloader metadata and selects the real Managed directory' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $install = Join-Path $Root 'metadata-and-real'
            $metadata = Join-Path $install '.DepotDownloader/staging/RustDedicated_Data/Managed'
            $real = Join-Path $install 'RustDedicated_Data/Managed'
            New-Item -ItemType Directory $metadata -Force | Out-Null
            New-Item -ItemType Directory $real -Force | Out-Null
            Set-Content (Join-Path $metadata 'metadata.dll') 'metadata'
            Set-Content (Join-Path $real 'Assembly-CSharp.dll') 'managed assembly placeholder'

            $selected = Resolve-RdRustManagedDirectory $install

            $selected.FullName | Should -Be (Resolve-Path $real).Path
        }
    }

    It 'fails clearly when no real Managed directory contains DLLs' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $install = Join-Path $Root 'metadata-only'
            $metadata = Join-Path $install '.DepotDownloader/staging/RustDedicated_Data/Managed'
            New-Item -ItemType Directory $metadata -Force | Out-Null
            Set-Content (Join-Path $metadata 'metadata.dll') 'metadata'
            { Resolve-RdRustManagedDirectory $install } |
                Should -Throw '*No real RustDedicated_Data/Managed directory containing DLL files*.DepotDownloader metadata paths*'
        }
    }

    It 'fails deterministically when multiple real Managed directories exist' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $install = Join-Path $Root 'ambiguous'
            $first = Join-Path $install 'a/RustDedicated_Data/Managed'
            $second = Join-Path $install 'b/RustDedicated_Data/Managed'
            New-Item -ItemType Directory $second -Force | Out-Null
            New-Item -ItemType Directory $first -Force | Out-Null
            Set-Content (Join-Path $second 'Second.dll') 'managed assembly placeholder'
            Set-Content (Join-Path $first 'First.dll') 'managed assembly placeholder'
            { Resolve-RdRustManagedDirectory $install } |
                Should -Throw '*Multiple real Rust Managed directories*a/RustDedicated_Data/Managed, b/RustDedicated_Data/Managed*Refusing ambiguous selection*'
        }
    }

    It 'selects dotnet for DLL distributions and direct host executables otherwise' {
        InModuleScope RustDependencies {
            Mock Get-Command { [pscustomobject]@{ Source = 'dotnet-host' } } -ParameterFilter { $Name -eq 'dotnet' }
            $dll = Resolve-RdDepotDownloaderInvocation ([pscustomobject]@{ Path = 'DepotDownloader.dll'; Mode = 'Dotnet' })
            $windows = Resolve-RdDepotDownloaderInvocation ([pscustomobject]@{ Path = 'DepotDownloader.exe'; Mode = 'Executable' })
            $linux = Resolve-RdDepotDownloaderInvocation ([pscustomobject]@{ Path = '/tmp/DepotDownloader'; Mode = 'Executable' })

            $dll.CommandPath | Should -Be 'dotnet-host'
            $dll.PrefixArguments | Should -Be @('DepotDownloader.dll')
            $windows.CommandPath | Should -Be 'DepotDownloader.exe'
            $windows.PrefixArguments | Should -HaveCount 0
            $linux.CommandPath | Should -Be '/tmp/DepotDownloader'
            $linux.PrefixArguments | Should -HaveCount 0
            Should -Invoke Get-Command -ParameterFilter { $Name -eq 'dotnet' } -Times 1
        }
    }

    It 'classifies configured DLL, Windows executable, and Linux executable paths' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $dllPath = Join-Path $Root 'DepotDownloader.dll'
            $windowsPath = Join-Path $Root 'DepotDownloader.exe'
            $linuxPath = Join-Path $Root 'DepotDownloader'
            Set-Content $dllPath 'placeholder'
            Set-Content $windowsPath 'placeholder'
            Set-Content $linuxPath 'placeholder'
            Mock Set-RdLinuxExecutablePermission

            (New-RdDepotDownloaderCommand $dllPath Windows).Mode | Should -Be 'Dotnet'
            (New-RdDepotDownloaderCommand $windowsPath Windows).Mode | Should -Be 'Executable'
            (New-RdDepotDownloaderCommand $linuxPath Linux).Mode | Should -Be 'Executable'
            Should -Invoke Set-RdLinuxExecutablePermission -ParameterFilter { $Path -eq $linuxPath } -Times 1
        }
    }

    It 'discovers self-contained executables in host-specific archives' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $manifest = [pscustomobject]@{ providers = [pscustomobject]@{ steam = [pscustomobject]@{} } }
            Mock Invoke-RdDownloadDescriptor {
                param($Descriptor, $Destination, $Token, $Channel)
                if ($Descriptor.assetPattern -match 'windows-x64') { return (Join-Path $Root 'windows.zip') }
                return (Join-Path $Root 'linux.zip')
            }
            Mock Expand-RdArchive {
                param($Archive, $Destination)
                New-Item -ItemType Directory $Destination -Force | Out-Null
                $name = if ($Archive -match 'windows') { 'DepotDownloader.exe' } else { 'DepotDownloader' }
                Set-Content (Join-Path $Destination $name) 'placeholder'
            }
            Mock Set-RdLinuxExecutablePermission

            $windows = Get-RdDepotDownloader $manifest ([pscustomobject]@{ Host = 'Windows'; HostAsset = 'windows-x64' }) (Join-Path $Root 'windows-temp')
            $linux = Get-RdDepotDownloader $manifest ([pscustomobject]@{ Host = 'Linux'; HostAsset = 'linux-x64' }) (Join-Path $Root 'linux-temp')

            $windows.Mode | Should -Be 'Executable'
            [IO.Path]::GetFileName($windows.Path) | Should -Be 'DepotDownloader.exe'
            $linux.Mode | Should -Be 'Executable'
            [IO.Path]::GetFileName($linux.Path) | Should -Be 'DepotDownloader'
            Should -Invoke Set-RdLinuxExecutablePermission -Times 1
        }
    }

    It 'returns actionable errors for unsupported archives and missing dotnet' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $archive = Join-Path $Root 'DepotDownloader-linux-x64.zip'
            Set-Content $archive 'placeholder'
            $manifest = [pscustomobject]@{ providers = [pscustomobject]@{ steam = [pscustomobject]@{} } }
            $platform = [pscustomobject]@{ Host = 'Linux'; HostAsset = 'linux-x64' }
            Mock Invoke-RdDownloadDescriptor { $archive }
            Mock Expand-RdArchive {
                param($Archive, $Destination)
                New-Item -ItemType Directory $Destination -Force | Out-Null
            }
            { Get-RdDepotDownloader $manifest $platform (Join-Path $Root 'temp') } |
                Should -Throw '*contained none of the supported host files*DepotDownloader*'

            Mock Get-Command -ParameterFilter { $Name -eq 'dotnet' }
            { Resolve-RdDepotDownloaderInvocation ([pscustomobject]@{ Path = 'DepotDownloader.dll'; Mode = 'Dotnet' }) } |
                Should -Throw "*dotnet is required*DepotDownloader.dll*"
        }
    }

    It 'uses only the managed DLL regex by default' {
        InModuleScope RustDependencies {
            $entries = @(Get-RdSteamFileList ([pscustomobject]@{}))
            $entries | Should -HaveCount 1
            $entries[0] | Should -Be 'regex:RustDedicated_Data/Managed/.*\.dll'
        }
    }

    It 'accepts manifest file list overrides and rejects invalid entries' {
        InModuleScope RustDependencies {
            $entries = @(Get-RdSteamFileList ([pscustomobject]@{ fileList = @('file:A.dll', 'regex:Managed/.*\.dll') }))
            $entries | Should -Be @('file:A.dll', 'regex:Managed/.*\.dll')
            { Get-RdSteamFileList ([pscustomobject]@{ fileList = 'file:A.dll' }) } | Should -Throw '*JSON array*'
            { Get-RdSteamFileList ([pscustomobject]@{ fileList = @() }) } | Should -Throw '*at least one*'
            { Get-RdSteamFileList ([pscustomobject]@{ fileList = @('') }) } | Should -Throw '*non-empty string*'
            { Get-RdSteamFileList ([pscustomobject]@{ fileList = @(42) }) } | Should -Throw '*non-empty string*'
        }
    }

    It 'passes a UTF-8 no-BOM file list for Windows and Linux targets' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-RdDepotDownloader { [pscustomobject]@{ Path = 'DepotDownloader.dll'; Mode = 'Dotnet' } }
            Mock Get-Command { [pscustomobject]@{ Source = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
            Mock Invoke-RdDepotDownloaderProcess {
                param($CommandPath, $Arguments, $FailureContext)
                $index = [Array]::IndexOf($Arguments, '-filelist')
                if ($index -lt 0 -or -not (Test-Path -LiteralPath $Arguments[$index + 1])) {
                    throw 'DepotDownloader file list argument is missing.'
                }
                if ($CommandPath -ne 'dotnet' -or $Arguments[0] -ne 'DepotDownloader.dll') {
                    throw 'DLL DepotDownloader command selection is incorrect.'
                }
            }

            foreach ($target in 'Windows', 'Linux') {
                $temp = Join-Path $Root "rust-$target"
                $output = Join-Path $Root "output-$target"
                $managed = if ($target -eq 'Windows') {
                    Join-Path $temp 'rust-server/RustDedicated_Data/Managed'
                } else {
                    Join-Path $temp 'rust-server/linux-layout/RustDedicated_Data/Managed'
                }
                New-Item -ItemType Directory $managed -Force | Out-Null
                Set-Content (Join-Path $managed 'Assembly-CSharp.dll') 'managed assembly placeholder'
                $manifest = [pscustomobject]@{
                    exclusions = @()
                    providers = [pscustomobject]@{
                        steam = [pscustomobject]@{
                            appId = 258550
                            depots = [pscustomobject]@{ Windows = 258551; Linux = 258552 }
                            fileList = @('regex:RustDedicated_Data/Managed/.*\.dll')
                        }
                    }
                }
                $platform = [pscustomobject]@{
                    Server = $target
                    Folder = $target.ToLowerInvariant()
                    Host = 'Windows'
                    HostAsset = 'windows-x64'
                }

                Invoke-RdRust $manifest $platform Production $output $temp

                $fileList = Join-Path $temp 'rust-managed-dlls.filelist.txt'
                (Get-Content -LiteralPath $fileList -Raw).TrimEnd("`r", "`n") |
                    Should -Be 'regex:RustDedicated_Data/Managed/.*\.dll'
                $bytes = [IO.File]::ReadAllBytes($fileList)
                ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
                    Should -BeFalse
                Test-Path (Join-Path $output "rust/$($target.ToLowerInvariant())/managed/Assembly-CSharp.dll") |
                    Should -BeTrue
            }
            Should -Invoke Invoke-RdDepotDownloaderProcess -Times 2 -Exactly
        }
    }
}

Describe 'Framework managed directory selection' {
    It 'selects a unique Oxide Managed directory' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $extract = Join-Path $Root 'oxide-extract'
            $managed = Join-Path $extract 'RustDedicated_Data/Managed'
            New-Item -ItemType Directory $managed -Force | Out-Null
            Set-Content (Join-Path $managed 'Oxide.Core.dll') 'x'
            $selected = Resolve-RdFrameworkManagedDirectory -Name oxide -ExtractPath $extract
            $selected.FullName | Should -Be (Resolve-Path $managed).Path
        }
    }

    It 'rejects ambiguous Oxide Managed directories' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $extract = Join-Path $Root 'oxide-ambiguous'
            $first = Join-Path $extract 'a/Managed'
            $second = Join-Path $extract 'b/Managed'
            New-Item -ItemType Directory $first -Force | Out-Null
            New-Item -ItemType Directory $second -Force | Out-Null
            { Resolve-RdFrameworkManagedDirectory -Name oxide -ExtractPath $extract } |
                Should -Throw '*Multiple Managed directories*a/Managed, b/Managed*Refusing ambiguous selection*'
        }
    }

    It 'rejects ambiguous Carbon carbon/managed directories' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $extract = Join-Path $Root 'carbon-ambiguous'
            $first = Join-Path $extract 'a/carbon/managed'
            $second = Join-Path $extract 'b/carbon/managed'
            New-Item -ItemType Directory $first -Force | Out-Null
            New-Item -ItemType Directory $second -Force | Out-Null
            { Resolve-RdFrameworkManagedDirectory -Name carbon -ExtractPath $extract } |
                Should -Throw '*Multiple carbon/managed directories*a/carbon/managed, b/carbon/managed*Refusing ambiguous selection*'
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

    It 'clears only the provider subtree in focused Rust downloads' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Get-RdDepotDownloader { [pscustomobject]@{ Path = 'DepotDownloader.dll'; Mode = 'Dotnet' } }
            Mock Get-Command { [pscustomobject]@{ Source = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
            Mock Invoke-RdDepotDownloaderProcess {
                param($CommandPath, $Arguments, $FailureContext)
                $dirIndex = [Array]::IndexOf($Arguments, '-dir')
                $install = $Arguments[$dirIndex + 1]
                $managed = Join-Path $install 'RustDedicated_Data/Managed'
                New-Item -ItemType Directory $managed -Force | Out-Null
                Set-Content (Join-Path $managed 'Assembly-CSharp.dll') 'fresh'
            }

            $output = Join-Path $Root 'dependencies'
            $rustManaged = Join-Path $output 'rust/windows/managed'
            New-Item -ItemType Directory $rustManaged -Force | Out-Null
            Set-Content (Join-Path $rustManaged 'stale.dll') 'stale'
            Set-Content (Join-Path $output 'keep-root.dll') 'keep'
            New-Item -ItemType Directory (Join-Path $output 'oxide/windows/managed') -Force | Out-Null
            Set-Content (Join-Path $output 'oxide/windows/managed/Oxide.Core.dll') 'keep'

            $manifest = [pscustomobject]@{
                exclusions = @()
                providers = [pscustomobject]@{ steam = [pscustomobject]@{} }
            }
            $platform = [pscustomobject]@{ Server = 'Windows'; Folder = 'windows'; Host = 'Windows'; HostAsset = 'windows-x64' }
            $temp = Join-Path $Root 'temp'
            New-Item -ItemType Directory $temp -Force | Out-Null
            Invoke-RdRust $manifest $platform Production $output $temp

            Test-Path (Join-Path $rustManaged 'stale.dll') | Should -BeFalse
            Test-Path (Join-Path $rustManaged 'Assembly-CSharp.dll') | Should -BeTrue
            Test-Path (Join-Path $output 'keep-root.dll') | Should -BeTrue
            Test-Path (Join-Path $output 'oxide/windows/managed/Oxide.Core.dll') | Should -BeTrue
        }
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

    It 'keeps unrelated output files in focused mode' {
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows
        Test-Path (Join-Path $script:output 'stale.dll') | Should -BeTrue
    }

    It 'reports the planned work for WhatIf without invoking providers' {
        $messages = @(Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows -Publicize -WhatIf *>&1 |
            ForEach-Object { "$_" })
        $text = $messages -join [Environment]::NewLine
        $text | Should -Match 'WhatIf: would run Invoke-RustDependencies'
        $text | Should -Match 'Publicize=True'
        $text | Should -Match 'would publicize'
        Should -Invoke Invoke-RdRust -ModuleName RustDependencies -Times 0
    }

    It 'publicizes after providers when -Publicize is set' {
        Mock Invoke-RdPublicizeOutput -ModuleName RustDependencies
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows -Publicize
        Should -Invoke Invoke-RdPublicizeOutput -ModuleName RustDependencies -Times 1
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

    It 'selects extension framework independently from server platform' {
        Mock Invoke-RdFramework -ModuleName RustDependencies
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Oxide,Carbon -Framework Carbon -ServerPlatform Windows
        Should -Invoke Invoke-RdFramework -ModuleName RustDependencies -ParameterFilter { $Name -eq 'carbon' } -Times 1
        Should -Invoke Invoke-RdFramework -ModuleName RustDependencies -ParameterFilter { $Name -eq 'oxide' } -Times 0
    }
}

Describe 'GitHub authentication' {
    It 'prefers GH_TOKEN over GITHUB_TOKEN' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                $env:GH_TOKEN = 'from-gh'
                $env:GITHUB_TOKEN = 'from-github'
                Get-RdGitHubToken | Should -Be 'from-gh'
            }
            finally {
                $env:GH_TOKEN = $previousGh
                $env:GITHUB_TOKEN = $previousGithub
            }
        }
    }

    It 'falls back to GITHUB_TOKEN when GH_TOKEN is unset' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                $env:GITHUB_TOKEN = 'from-github'
                Get-RdGitHubToken | Should -Be 'from-github'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'requires authentication only when Required is set' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                Mock Get-Command
                Get-RdGitHubToken | Should -BeNullOrEmpty
                { Get-RdGitHubToken -Required } | Should -Throw '*GitHub authentication required*'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe 'NuGet version selection' {
    BeforeEach {
        $script:nugetCalls = [Collections.Generic.List[string]]::new()
    }

    It 'selects <Version> as <Expected>' -ForEach @(
        @{ Version = 'latest'; Expected = '1.2.0'; IncludePrerelease = $true }
        @{ Version = 'stable'; Expected = '1.2.0'; IncludePrerelease = $false }
        @{ Version = 'prerelease'; Expected = '1.1.0-beta'; IncludePrerelease = $false }
        @{ Version = '1.0.0'; Expected = '1.0.0'; IncludePrerelease = $false }
    ) {
        InModuleScope RustDependencies -Parameters @{
            Root = $TestDrive
            Version = $Version
            Expected = $Expected
            IncludePrerelease = $IncludePrerelease
            Calls = $script:nugetCalls
        } {
            param($Root, $Version, $Expected, $IncludePrerelease, $Calls)
            $output = Join-Path $Root "nuget-out-$Version"
            $temp = Join-Path $Root "nuget-temp-$Version"
            New-Item -ItemType Directory $temp -Force | Out-Null
            Mock Get-RdGitHubToken { 'token' }
            Mock Invoke-RestMethod {
                param($Uri, $Headers)
                if ($Uri -eq 'https://nuget.example.invalid/index.json') {
                    return [pscustomobject]@{
                        resources = @([pscustomobject]@{ '@type' = 'PackageBaseAddress/3.0.0'; '@id' = 'https://nuget.example.invalid/v3/package/' })
                    }
                }
                return [pscustomobject]@{ versions = @('1.0.0', '1.1.0-beta', '1.2.0') }
            }
            Mock Invoke-WebRequest {
                param($Uri, $Headers, $OutFile)
                $Calls.Add([string]$Uri)
                Set-Content $OutFile 'nupkg'
            }
            Mock Expand-RdArchive {
                param($Archive, $Destination)
                $lib = Join-Path $Destination 'lib/netstandard2.0'
                New-Item -ItemType Directory $lib -Force | Out-Null
                Set-Content (Join-Path $lib 'Example.Package.dll') 'dll'
            }

            $manifest = [pscustomobject]@{
                exclusions = @()
                providers = [pscustomobject]@{
                    githubNuget = @(
                        [pscustomobject]@{
                            name = 'Example.Package'
                            source = 'https://nuget.example.invalid/index.json'
                            version = $Version
                            includePrerelease = $IncludePrerelease
                        }
                    )
                }
            }
            Invoke-RdNuGetCollection $manifest ([pscustomobject]@{ Folder = 'windows' }) $output $temp Both
            Test-Path (Join-Path $output 'nuget/shared/windows/Example.Package/lib/netstandard2.0/Example.Package.dll') | Should -BeTrue
            $Calls | Should -Contain "https://nuget.example.invalid/v3/package/example.package/$Expected/example.package.$Expected.nupkg"
        }
    }
}

Describe 'RdPublicizer' {
    It 'passes the Mono.Cecil self-test for Oxide and Carbon rules' {
        $project = Join-Path $script:repoRoot 'tools' 'RdPublicizer' 'RdPublicizer.csproj'
        Test-Path $project | Should -BeTrue
        & dotnet run --project $project -c Release -- --self-test
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Release collection asset handling' {
    It 'uses URL basename instead of the top-level logical collection name' {
        InModuleScope RustDependencies {
            $resolved = Resolve-RdReleaseAsset ([pscustomobject]@{
                name = 'Oxide.Ext.ConsoleExt'
                url = 'https://example.invalid/releases/Oxide.Ext.ConsoleExt.dll'
            })
            $resolved.Name | Should -Be 'Oxide.Ext.ConsoleExt.dll'
        }
    }

    It 'supports assetName overrides and nested legacy URL names only when enabled' {
        InModuleScope RustDependencies {
            $override = Resolve-RdReleaseAsset ([pscustomobject]@{
                name = 'LogicalName'
                url = 'https://example.invalid/download'
                assetName = 'Useful.Asset.dll'
            })
            $override.Name | Should -Be 'Useful.Asset.dll'

            $legacyDescriptor = [pscustomobject]@{
                name = 'Legacy.Asset.dll'
                url = 'https://example.invalid/download'
            }
            (Resolve-RdReleaseAsset $legacyDescriptor).Name | Should -Be 'download'
            (Resolve-RdReleaseAsset $legacyDescriptor -AllowLegacyUrlName).Name | Should -Be 'Legacy.Asset.dll'
            { Resolve-RdReleaseAsset ([pscustomobject]@{ url = 'https://example.invalid/' }) } |
                Should -Throw '*require assetName*'
        }
    }

    It 'copies a direct DLL without archive expansion' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'direct-dll.json'
        Set-Content $manifestPath '{"repositoryRoot":"./repository","outputDirectory":"./repository/dependencies","providers":{"publicReleases":[{"name":"Oxide.Ext.ConsoleExt","url":"https://example.invalid/Oxide.Ext.ConsoleExt.dll"}]}}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Save-RdUri -ModuleName RustDependencies {
            param($Uri, $Destination, $Token, $Api)
            Set-Content $Destination 'managed assembly placeholder'
        }
        Mock Expand-RdArchive -ModuleName RustDependencies

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -ServerPlatform Windows

        Test-Path (Join-Path $output 'publicReleases/shared/windows/Oxide.Ext.ConsoleExt/Oxide.Ext.ConsoleExt.dll') | Should -BeTrue
        Should -Invoke Expand-RdArchive -ModuleName RustDependencies -Times 0
    }

    It 'preserves legacy URL name inside a nested release descriptor' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'nested-legacy.json'
        Set-Content $manifestPath '{"repositoryRoot":"./repository","outputDirectory":"./repository/dependencies","providers":{"publicReleases":[{"name":"LogicalFolder","release":{"url":"https://example.invalid/download","name":"Legacy.Asset.dll"}}]}}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Save-RdUri -ModuleName RustDependencies {
            param($Uri, $Destination, $Token, $Api)
            Set-Content $Destination 'managed assembly placeholder'
        }

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -ServerPlatform Windows

        Test-Path (Join-Path $output 'publicReleases/shared/windows/LogicalFolder/Legacy.Asset.dll') | Should -BeTrue
    }

    It 'filters release assets before download and isolates framework output' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'framework-releases.json'
        Set-Content $manifestPath @'
{
  "repositoryRoot": "./repository",
  "outputDirectory": "./repository/dependencies",
  "providers": {
    "publicReleases": [
      { "name": "OxideOnly", "url": "https://example.invalid/OxideOnly.dll", "frameworks": ["Oxide"] },
      { "name": "CarbonOnly", "url": "https://example.invalid/CarbonOnly.dll", "frameworks": ["Carbon"] },
      { "name": "Common", "url": "https://example.invalid/Common.dll" }
    ]
  }
}
'@
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Invoke-RdDownloadDescriptor -ModuleName RustDependencies {
            param($Descriptor, $Destination, $Token, $Channel)
            $path = Join-Path $Destination ([IO.Path]::GetFileName(([uri]$Descriptor.url).AbsolutePath))
            Set-Content $path 'managed assembly placeholder'
            return $path
        }

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -Framework Carbon -ServerPlatform Windows

        Should -Invoke Invoke-RdDownloadDescriptor -ModuleName RustDependencies -Times 2
        Test-Path (Join-Path $output 'publicReleases/carbon/windows/CarbonOnly/CarbonOnly.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'publicReleases/shared/windows/Common/Common.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'publicReleases/oxide/windows/OxideOnly/OxideOnly.dll') | Should -BeFalse
    }

    It 'downloads a dual-framework item once and installs it for both' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'both-frameworks.json'
        Set-Content $manifestPath '{"repositoryRoot":"./repository","outputDirectory":"./repository/dependencies","providers":{"publicReleases":[{"name":"Dual","url":"https://example.invalid/Dual.dll","frameworks":["Oxide","Carbon"]}]}}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Invoke-RdDownloadDescriptor -ModuleName RustDependencies {
            param($Descriptor, $Destination, $Token, $Channel)
            $path = Join-Path $Destination 'Dual.dll'
            Set-Content $path 'managed assembly placeholder'
            return $path
        }

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -Framework Both -ServerPlatform Linux

        Should -Invoke Invoke-RdDownloadDescriptor -ModuleName RustDependencies -Times 1
        Test-Path (Join-Path $output 'publicReleases/oxide/linux/Dual/Dual.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'publicReleases/carbon/linux/Dual/Dual.dll') | Should -BeTrue
    }

    It 'filters private and NuGet items before authentication or download' {
        $manifestPath = Join-Path $TestDrive 'filtered-auth.json'
        Set-Content $manifestPath @'
{
  "repositoryRoot": "./repository",
  "outputDirectory": "./repository/dependencies",
  "providers": {
    "privateReleases": [
      { "name": "OxidePrivate", "repo": "owner/private", "asset": "Private.dll", "frameworks": ["Oxide"] }
    ],
    "githubNuget": [
      { "name": "Oxide.Package", "source": "https://nuget.pkg.github.com/owner/index.json", "frameworks": ["Oxide"] }
    ]
  }
}
'@
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Invoke-RdDownloadDescriptor -ModuleName RustDependencies
        Mock Invoke-RestMethod -ModuleName RustDependencies

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Private,NuGet -Framework Carbon -ServerPlatform Windows

        Should -Invoke Get-RdGitHubToken -ModuleName RustDependencies -Times 0
        Should -Invoke Invoke-RdDownloadDescriptor -ModuleName RustDependencies -Times 0
        Should -Invoke Invoke-RestMethod -ModuleName RustDependencies -Times 0
    }
}

Describe 'Repository layout and wrapper forwarding' {
    It 'keeps entrypoints, module files, and examples in their dedicated folders' {
        @(Get-ChildItem -LiteralPath $script:repoRoot -File -Filter '*.ps1').Count | Should -Be 0
        $rootWrappers = @(Get-ChildItem -LiteralPath $script:scriptsRoot -File -Filter '*.ps1')
        $rootWrappers | Should -HaveCount 6
        $rootWrappers.Name | Should -Be @(
            'all-carbon-staging.ps1',
            'all-carbon.ps1',
            'all-oxide-staging.ps1',
            'all-oxide.ps1',
            'all-staging.ps1',
            'all.ps1'
        )
        $entrypoints = @(Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter 'Invoke-RustDependencies.ps1')
        $entrypoints | Should -HaveCount 1
        $entrypoints[0].FullName | Should -Be (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1')
        Test-Path (Join-Path $script:repoRoot 'module' 'RustDependencies.psm1') | Should -BeTrue
        Test-Path (Join-Path $script:examplesRoot 'rust-dependencies.example.json') | Should -BeTrue
        (Test-ModuleManifest (Join-Path $script:repoRoot 'module' 'RustDependencies.psd1')).RootModule |
            Should -Be 'RustDependencies.psm1'
    }

    It 'has every wrapper call the central utility entrypoint' {
        $expectedInvocations = @{
            'all.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
            'all-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
            'all-oxide.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
            'all-oxide-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
            'all-carbon.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
            'all-carbon-staging.ps1' = "& (Join-Path `$PSScriptRoot 'utility' 'Invoke-RustDependencies.ps1') @invoke"
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
        $wrappers = @(Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter '*.ps1' |
            Where-Object Name -ne 'Invoke-RustDependencies.ps1')
        $wrappers | Should -HaveCount 15
        foreach ($wrapper in $wrappers) {
            $relativePath = [IO.Path]::GetRelativePath($script:scriptsRoot, $wrapper.FullName).Replace('\', '/')
            $expectedInvocations.Keys | Should -Contain $relativePath
            $source = Get-Content -LiteralPath $wrapper.FullName -Raw
            $source | Should -Match ([regex]::Escape($expectedInvocations[$relativePath]))
            $source | Should -Match 'ManifestPath\s*=\s*\$ManifestPath'
            $source | Should -Match 'if \(\$ServerPlatform\) \{ \$invoke\.ServerPlatform = \$ServerPlatform \}'
            $source | Should -Match 'if \(\$WhatIfPreference\) \{ \$invoke\.WhatIf = \$true \}'
        }
    }

    It 'exposes an opt-in Publicize switch on all wrappers and the central entrypoint' {
        foreach ($name in 'all.ps1', 'all-staging.ps1', 'all-oxide.ps1', 'all-oxide-staging.ps1', 'all-carbon.ps1', 'all-carbon-staging.ps1') {
            (Get-Content (Join-Path $script:scriptsRoot $name) -Raw) | Should -Match '\[switch\]\$Publicize'
            (Get-Content (Join-Path $script:scriptsRoot $name) -Raw) | Should -Match 'if \(\$Publicize\) \{ \$invoke\.Publicize = \$true \}'
        }
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1') -Raw) | Should -Match '\[switch\]\$Publicize'
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'publicize.ps1') -Raw) | Should -Match "Publicize = \`$true"
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'publicize.ps1') -Raw) | Should -Match "Provider = @\(\)"
    }

    It 'propagates central entrypoint failures through every wrapper' {
        $invalidManifest = Join-Path $TestDrive 'invalid-wrapper-manifest.json'
        Set-Content -LiteralPath $invalidManifest '{'
        foreach ($wrapper in Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter '*.ps1' |
            Where-Object Name -ne 'Invoke-RustDependencies.ps1') {
            { & $wrapper.FullName -ManifestPath $invalidManifest -ServerPlatform Windows -WhatIf } |
                Should -Throw '*not valid JSON*'
        }
    }

    It 'binds optional framework on focused public and private wrappers' {
        $manifestPath = Join-Path $TestDrive 'wrapper.json'
        Set-Content $manifestPath '{"repositoryRoot":".","outputDirectory":"./safe/dependencies","providers":{}}'
        { & (Join-Path $script:scriptsRoot 'utility' 'public-dlls.ps1') -ManifestPath $manifestPath -Framework Oxide -WhatIf } | Should -Not -Throw
        { & (Join-Path $script:scriptsRoot 'utility' 'private-dlls.ps1') -ManifestPath $manifestPath -Framework Carbon -WhatIf } | Should -Not -Throw
        { & (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1') -ManifestPath $manifestPath -Framework Both -WhatIf } | Should -Not -Throw
    }

    It 'pins all wrappers to their named framework' {
        (Get-Content (Join-Path $script:scriptsRoot 'all-oxide.ps1') -Raw) | Should -Match "Framework = 'Oxide'"
        (Get-Content (Join-Path $script:scriptsRoot 'all-oxide-staging.ps1') -Raw) | Should -Match "Framework = 'Oxide'"
        (Get-Content (Join-Path $script:scriptsRoot 'all-carbon.ps1') -Raw) | Should -Match "Framework = 'Carbon'"
        (Get-Content (Join-Path $script:scriptsRoot 'all-carbon-staging.ps1') -Raw) | Should -Match "Framework = 'Carbon'"
        (Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw) | Should -Match "Framework = 'Both'"
        (Get-Content (Join-Path $script:scriptsRoot 'all-staging.ps1') -Raw) | Should -Match "Framework = 'Both'"
    }
}
