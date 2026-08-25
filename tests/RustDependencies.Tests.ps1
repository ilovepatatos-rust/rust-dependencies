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
        Set-Content $path '{"publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        { Read-RdManifest $path } | Should -Throw "*outputDirectory*"
    }

    It 'rejects a filesystem root as output' {
        $path = Join-Path $TestDrive 'root.json'
        $root = [IO.Path]::GetPathRoot($TestDrive).Replace('\', '\\')
        Set-Content $path "{`"outputDirectory`":`"$root`",`"publicReleases`":[],`"privateReleases`":[],`"githubNuget`":[]}"
        $manifest = Read-RdManifest $path
        { Resolve-RdOutputPath $manifest } | Should -Throw '*Unsafe*'
    }

    It 'rejects an output path containing the manifest' {
        $path = Join-Path $TestDrive 'self-delete.json'
        Set-Content $path '{"outputDirectory":".","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $manifest = Read-RdManifest $path
        { Resolve-RdOutputPath $manifest } | Should -Throw '*Unsafe*'
    }

    It 'resolves outputDirectory relative to the manifest directory' {
        $scripts = Join-Path $TestDrive 'scripts'
        New-Item -ItemType Directory $scripts | Out-Null
        $path = Join-Path $scripts 'dependencies.json'
        Set-Content $path '{"outputDirectory":"../src/dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $resolved = Resolve-RdOutputPath (Read-RdManifest $path)
        $resolved | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'src/dependencies')))
    }

    It 'allows output outside the manifest directory without an opt-in flag' {
        $path = Join-Path $TestDrive 'outside.json'
        Set-Content $path '{"outputDirectory":"../elsewhere/dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $resolved = Resolve-RdOutputPath (Read-RdManifest $path)
        $resolved | Should -Be ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $TestDrive) 'elsewhere/dependencies')))
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
}

Describe 'Provider descriptors and exclusions' {
    It 'uses hardcoded Carbon release assets and repository' {
        InModuleScope RustDependencies {
            $manifest = [pscustomobject]@{}
            $windows = [pscustomobject]@{ Server = 'Windows' }
            $linux = [pscustomobject]@{ Server = 'Linux' }
            $productionWindows = Resolve-RdFrameworkDescriptor carbon $manifest $windows Production
            $productionLinux = Resolve-RdFrameworkDescriptor carbon $manifest $linux Production
            $stagingWindows = Resolve-RdFrameworkDescriptor carbon $manifest $windows Staging
            $stagingLinux = Resolve-RdFrameworkDescriptor carbon $manifest $linux Staging
            $productionWindows.repo | Should -Be 'CarbonCommunity/Carbon'
            $productionWindows.tag | Should -Be 'production_build'
            $productionWindows.asset | Should -Be 'Carbon.Windows.Release.zip'
            $productionLinux.asset | Should -Be 'Carbon.Linux.Release.tar.gz'
            $stagingWindows.tag | Should -Be 'rustbeta_staging_build'
            $stagingWindows.asset | Should -Be 'Carbon.Windows.Debug.zip'
            $stagingLinux.asset | Should -Be 'Carbon.Linux.Debug.tar.gz'
        }
    }

    It 'normalizes Windows separators before matching native exclusions' {
        InModuleScope RustDependencies {
            Test-RdExcluded 'runtimes\win-x64\native\NativeLibrary.dll' | Should -BeTrue
        }
    }

    It 'uses hardcoded staging Oxide endpoints for both targets' {
        InModuleScope RustDependencies {
            $manifest = [pscustomobject]@{}
            $windows = Resolve-RdFrameworkDescriptor oxide $manifest ([pscustomobject]@{ Server = 'Windows' }) Staging
            $linux = Resolve-RdFrameworkDescriptor oxide $manifest ([pscustomobject]@{ Server = 'Linux' }) Staging
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
            $manifest = [pscustomobject]@{}
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
            $manifest = [pscustomobject]@{}
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
            $entries = @(Get-RdSteamFileList)
            $entries | Should -HaveCount 1
            $entries[0] | Should -Be 'regex:RustDedicated_Data/Managed/.*\.dll'
            (Get-RdBuiltinSteamConfig).appId | Should -Be '258550'
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
                $manifest = [pscustomobject]@{}
                $platform = [pscustomobject]@{
                    Server = $target
                    Folder = $target.ToLowerInvariant()
                    Host = 'Windows'
                    HostAsset = 'windows-x64'
                }

                Invoke-RdRust $manifest $platform Production $output $temp Both

                $fileList = Join-Path $temp 'rust-managed-dlls.filelist.txt'
                (Get-Content -LiteralPath $fileList -Raw).TrimEnd("`r", "`n") |
                    Should -Be 'regex:RustDedicated_Data/Managed/.*\.dll'
                $bytes = [IO.File]::ReadAllBytes($fileList)
                ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
                    Should -BeFalse
                $platformFolder = $target.ToLowerInvariant()
                Test-Path (Join-Path $output "main/$platformFolder/oxide/Assembly-CSharp.dll") | Should -BeTrue
                Test-Path (Join-Path $output "main/$platformFolder/carbon/Assembly-CSharp.dll") | Should -BeTrue
                Test-Path (Join-Path $output "main/$platformFolder/rust/Assembly-CSharp.dll") | Should -BeTrue
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
    It 'clears contents of the configured output directory without removing the root' {
        $output = Join-Path $TestDrive 'dependencies'
        $other = Join-Path $TestDrive 'unrelated.txt'
        $created = New-Item -ItemType Directory $output
        Set-Content (Join-Path $output 'old.dll') 'old'
        New-Item -ItemType Directory (Join-Path $output 'windows') | Out-Null
        Set-Content $other 'keep'
        Clear-RdOutput $output
        Test-Path (Join-Path $output 'old.dll') | Should -BeFalse
        Test-Path (Join-Path $output 'windows') | Should -BeFalse
        Test-Path $other | Should -BeTrue
        Test-Path $output -PathType Container | Should -BeTrue
        (Get-Item -LiteralPath $output).FullName | Should -Be $created.FullName
    }

    It 'classifies Unix framework roots as clearable without trimming the path root to empty' {
        InModuleScope RustDependencies {
            $safety = Test-RdUnsafeClearPath '/home/runner/work/repo/dependencies/main/windows/oxide'
            $safety.IsUnsafeRootOrHome | Should -BeFalse
            $safety.SegmentCount | Should -BeGreaterOrEqual 2
        }
    }

    It 'clears only selected framework roots in focused Rust downloads' {
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
            $oxideRoot = Join-Path $output 'main/windows/oxide'
            $carbonRoot = Join-Path $output 'main/windows/carbon'
            New-Item -ItemType Directory $oxideRoot -Force | Out-Null
            New-Item -ItemType Directory $carbonRoot -Force | Out-Null
            Set-Content (Join-Path $oxideRoot 'stale.dll') 'stale'
            Set-Content (Join-Path $carbonRoot 'Carbon.Core.dll') 'keep'
            Set-Content (Join-Path $output 'keep-root.dll') 'keep'

            $manifestPath = Join-Path $Root 'manifest.json'
            @{
                outputDirectory = $output
                publicReleases = @()
                privateReleases = @()
                githubNuget = @()
            } | ConvertTo-Json -Depth 5 | Set-Content $manifestPath

            Invoke-RustDependencies -ManifestPath $manifestPath -Provider Rust -Framework Oxide -ServerPlatform Windows

            Test-Path (Join-Path $oxideRoot 'stale.dll') | Should -BeFalse
            Test-Path (Join-Path $oxideRoot 'Assembly-CSharp.dll') | Should -BeTrue
            Test-Path (Join-Path $carbonRoot 'Carbon.Core.dll') | Should -BeTrue
            Test-Path (Join-Path $output 'keep-root.dll') | Should -BeTrue
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
        Set-Content $script:manifestPath "{`"outputDirectory`":`"$($script:output.Replace('\','\\'))`",`"publicReleases`":[],`"privateReleases`":[],`"githubNuget`":[]}"
        New-Item -ItemType Directory (Join-Path $script:output 'main') -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $script:output 'staging') -Force | Out-Null
        Set-Content (Join-Path $script:output 'main/stale.dll') 'stale'
        Set-Content (Join-Path $script:output 'staging/keep.dll') 'keep'
        Set-Content (Join-Path $script:output 'root-keep.dll') 'keep'
        Mock Invoke-RdRust -ModuleName RustDependencies
    }

    It 'clears only the active channel folder when -ClearOutput is set' {
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ClearOutput -ServerPlatform Windows
        Test-Path (Join-Path $script:output 'main/stale.dll') | Should -BeFalse
        Test-Path (Join-Path $script:output 'staging/keep.dll') | Should -BeTrue
        Test-Path (Join-Path $script:output 'root-keep.dll') | Should -BeTrue
        Should -Invoke Invoke-RdRust -ModuleName RustDependencies -Times 1
    }

    It 'keeps unrelated output files in focused mode' {
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows
        Test-Path (Join-Path $script:output 'main/stale.dll') | Should -BeTrue
        Test-Path (Join-Path $script:output 'root-keep.dll') | Should -BeTrue
    }

    It 'reports the planned work for WhatIf without invoking providers' {
        $messages = @(Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows -Publicize -WhatIf *>&1 |
            ForEach-Object { "$_" })
        $text = $messages -join [Environment]::NewLine
        $text | Should -Match 'WhatIf: would run Invoke-RustDependencies'
        $text | Should -Match 'Publicize=True'
        $text | Should -Match 'would publicize'
        $text | Should -Match 'overlay publicized DLLs in place'
        Should -Invoke Invoke-RdRust -ModuleName RustDependencies -Times 0
    }

    It 'publicizes after providers when -Publicize is set' {
        Mock Invoke-RdPublicizeOutput -ModuleName RustDependencies
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -ServerPlatform Windows -Publicize
        Should -Invoke Invoke-RdPublicizeOutput -ModuleName RustDependencies -Times 1
    }

    It 'overlays publicized DLLs onto the framework root in place' {
        InModuleScope RustDependencies -Parameters @{ Root = $TestDrive } {
            param($Root)
            $output = Join-Path $Root 'dependencies'
            $oxide = Join-Path $output 'main/windows/oxide'
            New-Item -ItemType Directory $oxide -Force | Out-Null
            Set-Content (Join-Path $oxide 'Assembly-CSharp.dll') 'original'
            Set-Content (Join-Path $oxide 'Oxide.Core.dll') 'keep'
            Mock Invoke-RdPublicizer {
                param($ManagedDirectory, $OutputDirectory, $Mode)
                New-Item -ItemType Directory $OutputDirectory -Force | Out-Null
                Set-Content (Join-Path $OutputDirectory 'Assembly-CSharp.dll') 'publicized'
            }

            Invoke-RdPublicizeOutput -Output $output -Platform ([pscustomobject]@{ Folder = 'windows' }) -Channel Production -Framework Oxide

            (Get-Content (Join-Path $oxide 'Assembly-CSharp.dll') -Raw).Trim() | Should -Be 'publicized'
            (Get-Content (Join-Path $oxide 'Oxide.Core.dll') -Raw).Trim() | Should -Be 'keep'
            Test-Path (Join-Path $oxide 'publicized') | Should -BeFalse
        }
    }

    It 'deletes configured DLL names from framework roots after providers' {
        $output = Join-Path $TestDrive 'repository/delete-dlls-out'
        $manifestPath = Join-Path $TestDrive 'delete-dlls.json'
        Set-Content $manifestPath @'
{
  "outputDirectory": "./repository/delete-dlls-out",
  "deleteDlls": ["Newtonsoft.Json.dll", "UnityEngine.ARModule.dll"]
}
'@
        $oxide = Join-Path $output 'main/windows/oxide'
        Mock Invoke-RdRust -ModuleName RustDependencies {
            New-Item -ItemType Directory $oxide -Force | Out-Null
            Set-Content (Join-Path $oxide 'Newtonsoft.Json.dll') 'remove'
            Set-Content (Join-Path $oxide 'UnityEngine.ARModule.dll') 'remove'
            Set-Content (Join-Path $oxide 'Assembly-CSharp.dll') 'keep'
        }
        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Rust -Framework Oxide -ServerPlatform Windows
        Test-Path (Join-Path $oxide 'Newtonsoft.Json.dll') | Should -BeFalse
        Test-Path (Join-Path $oxide 'UnityEngine.ARModule.dll') | Should -BeFalse
        Test-Path (Join-Path $oxide 'Assembly-CSharp.dll') | Should -BeTrue
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

    It 'expands ServerPlatform All into Windows then Linux' {
        $calls = [Collections.Generic.List[string]]::new()
        Mock Invoke-RdRust -ModuleName RustDependencies {
            param($Manifest, $Platform, $Channel, $Output, $Temp, $Framework)
            $calls.Add([string]$Platform.Server)
        }
        Invoke-RustDependencies -ManifestPath $script:manifestPath -Provider Rust -Framework Oxide -ServerPlatform All
        $calls | Should -Be @('Windows', 'Linux')
    }
}

Describe 'GitHub authentication' {
    BeforeEach {
        InModuleScope RustDependencies {
            $script:RdGitHubTokenCache = $null
            $script:RdGitHubTokenCacheResolved = $false
            $script:RdGitHubAuthStatusWritten = $false
        }
        Remove-Item Env:RD_GITHUB_AUTH_STATUS_WRITTEN -ErrorAction SilentlyContinue
        Remove-Item Env:RD_GITHUB_TOKEN_RESOLVED -ErrorAction SilentlyContinue
        Remove-Item Env:RD_GITHUB_TOKEN -ErrorAction SilentlyContinue
        $env:RD_GITHUB_AUTH_PROMPT = '0'
    }

    AfterEach {
        Remove-Item Env:RD_GITHUB_AUTH_PROMPT -ErrorAction SilentlyContinue
    }

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

    It 'falls back to gh auth token when env tokens are unset' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                Mock Get-RdGitHubTokenFromGh { 'from-gh-cli' }
                Mock Get-RdGitHubTokenFromGitCredential { throw 'should not use git when gh succeeds' }
                Get-RdGitHubToken | Should -Be 'from-gh-cli'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'falls back to git credential fill when gh is unavailable' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                Mock Get-RdGitHubTokenFromGh { $null }
                Mock Get-RdGitHubTokenFromGitCredential { 'from-git-credential' }
                Get-RdGitHubToken | Should -Be 'from-git-credential'
                $env:RD_GITHUB_TOKEN_RESOLVED | Should -Be '1'
                $env:RD_GITHUB_TOKEN | Should -Be 'from-git-credential'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'reuses RD_GITHUB_TOKEN for parallel children without calling credential helpers again' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                $env:RD_GITHUB_TOKEN_RESOLVED = '1'
                $env:RD_GITHUB_TOKEN = 'already-resolved'
                Mock Get-RdGitHubTokenFromGh { throw 'should not call gh' }
                Mock Get-RdGitHubTokenFromGitCredential { throw 'should not call git credential' }
                Get-RdGitHubToken | Should -Be 'already-resolved'
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
                Mock Get-RdGitHubTokenFromGh { $null }
                Mock Get-RdGitHubTokenFromGitCredential { $null }
                Get-RdGitHubToken | Should -BeNullOrEmpty
                { Get-RdGitHubToken -Required } | Should -Throw '*GitHub authentication required*'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'logs authenticated status when a token is available' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'status-token'
                $messages = @(Write-RdGitHubAuthStatus *>&1 | ForEach-Object { "$_" })
                ($messages -join [Environment]::NewLine) | Should -Match 'GitHub auth: using token'
                # Second call is a no-op (once per process / parallel tree).
                $again = @(Write-RdGitHubAuthStatus *>&1 | ForEach-Object { "$_" })
                $again.Count | Should -Be 0
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'logs anonymous remaining quota when no token is available' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                Mock Get-RdGitHubTokenFromGh { $null }
                Mock Get-RdGitHubTokenFromGitCredential { $null }
                Mock Invoke-RdJsonRequest {
                    [pscustomobject]@{ resources = [pscustomobject]@{ core = [pscustomobject]@{ remaining = 42; limit = 60 } } }
                }
                $messages = @(Write-RdGitHubAuthStatus *>&1 | ForEach-Object { "$_" })
                ($messages -join [Environment]::NewLine) | Should -Match 'no token available; anonymous API calls remaining 42/60'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'warns with login instructions when anonymous quota is exhausted' {
        InModuleScope RustDependencies {
            $previousGh = $env:GH_TOKEN
            $previousGithub = $env:GITHUB_TOKEN
            try {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                Mock Get-RdGitHubTokenFromGh { $null }
                Mock Get-RdGitHubTokenFromGitCredential { $null }
                Mock Invoke-RdJsonRequest {
                    [pscustomobject]@{ resources = [pscustomobject]@{ core = [pscustomobject]@{ remaining = 0; limit = 60 } } }
                }
                Mock Request-RdGitHubAuthentication { $false }
                $messages = @(Write-RdGitHubAuthStatus *>&1 | ForEach-Object { "$_" })
                $text = $messages -join [Environment]::NewLine
                $text | Should -Match 'anonymous API calls remaining 0/60'
                $text | Should -Match 'gh auth login'
                $text | Should -Match 'GH_TOKEN'
            }
            finally {
                if ($null -ne $previousGh) { $env:GH_TOKEN = $previousGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
                if ($null -ne $previousGithub) { $env:GITHUB_TOKEN = $previousGithub } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'annotates anonymous rate-limit failures with login instructions' {
        InModuleScope RustDependencies {
            Mock Invoke-RestMethod { throw 'API rate limit exceeded' }
            { Invoke-RdJsonRequest -Uri 'https://api.github.com/repos/example/repo/releases/latest' -Token $null } |
                Should -Throw '*gh auth login*'
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
                githubNuget = @(
                    [pscustomobject]@{
                        name = 'Example.Package'
                        source = 'https://nuget.example.invalid/index.json'
                        version = $Version
                        includePrerelease = $IncludePrerelease
                    }
                )
            }
            Invoke-RdNuGetCollection $manifest ([pscustomobject]@{ Folder = 'windows' }) Production $output $temp Both
            Test-Path (Join-Path $output 'main/windows/oxide/Example.Package.dll') | Should -BeTrue
            Test-Path (Join-Path $output 'main/windows/carbon/Example.Package.dll') | Should -BeTrue
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

    It 'does not abort when Oxide mode skips a native DLL such as msvcp140.dll' {
        $project = Join-Path $script:repoRoot 'tools' 'RdPublicizer' 'RdPublicizer.csproj'
        $built = Join-Path $script:repoRoot 'tools' 'RdPublicizer' 'bin' 'Release' 'net10.0' 'RdPublicizer.dll'
        if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
            & dotnet build $project -c Release --nologo
            $LASTEXITCODE | Should -Be 0
        }
        $managed = Join-Path $TestDrive 'publicize-native-in'
        $publicized = Join-Path $TestDrive 'publicize-native-out'
        New-Item -ItemType Directory $managed | Out-Null
        Copy-Item -LiteralPath $built -Destination (Join-Path $managed 'Assembly-CSharp.dll')
        [IO.File]::WriteAllBytes((Join-Path $managed 'msvcp140.dll'), [Text.Encoding]::UTF8.GetBytes('not a managed assembly'))

        $output = @(Invoke-RdPublicizer -ManagedDirectory $managed -OutputDirectory $publicized -Mode Oxide 2>&1)
        @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $publicized 'Assembly-CSharp.dll') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $publicized 'msvcp140.dll') | Should -BeFalse
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
        Set-Content $manifestPath '{"outputDirectory":"./repository/dependencies","publicReleases":[{"name":"Oxide.Ext.ConsoleExt","url":"https://example.invalid/Oxide.Ext.ConsoleExt.dll"}]}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Save-RdUri -ModuleName RustDependencies {
            param($Uri, $Destination, $Token, $Api)
            Set-Content $Destination 'managed assembly placeholder'
        }
        Mock Expand-RdArchive -ModuleName RustDependencies

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -ServerPlatform Windows

        Test-Path (Join-Path $output 'main/windows/oxide/Oxide.Ext.ConsoleExt.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/windows/carbon/Oxide.Ext.ConsoleExt.dll') | Should -BeTrue
        Should -Invoke Expand-RdArchive -ModuleName RustDependencies -Times 0
    }

    It 'preserves legacy URL name inside a nested release descriptor' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'nested-legacy.json'
        Set-Content $manifestPath '{"outputDirectory":"./repository/dependencies","publicReleases":[{"name":"LogicalFolder","release":{"url":"https://example.invalid/download","name":"Legacy.Asset.dll"}}]}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Save-RdUri -ModuleName RustDependencies {
            param($Uri, $Destination, $Token, $Api)
            Set-Content $Destination 'managed assembly placeholder'
        }

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -ServerPlatform Windows

        Test-Path (Join-Path $output 'main/windows/oxide/Legacy.Asset.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/windows/carbon/Legacy.Asset.dll') | Should -BeTrue
    }

    It 'filters release assets before download and isolates framework output' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'framework-releases.json'
        Set-Content $manifestPath @'
{
  "outputDirectory": "./repository/dependencies",
  "publicReleases": [
    { "name": "OxideOnly", "url": "https://example.invalid/OxideOnly.dll", "frameworks": ["Oxide"] },
    { "name": "CarbonOnly", "url": "https://example.invalid/CarbonOnly.dll", "frameworks": ["Carbon"] },
    { "name": "Common", "url": "https://example.invalid/Common.dll" }
  ]
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
        Test-Path (Join-Path $output 'main/windows/carbon/CarbonOnly.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/windows/carbon/Common.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/windows/oxide/OxideOnly.dll') | Should -BeFalse
        Test-Path (Join-Path $output 'main/windows/carbon/OxideOnly.dll') | Should -BeFalse
    }

    It 'downloads a dual-framework item once and installs it for both' {
        $output = Join-Path $TestDrive 'repository/dependencies'
        $manifestPath = Join-Path $TestDrive 'both-frameworks.json'
        Set-Content $manifestPath '{"outputDirectory":"./repository/dependencies","publicReleases":[{"name":"Dual","url":"https://example.invalid/Dual.dll","frameworks":["Oxide","Carbon"]}]}'
        Mock Get-RdGitHubToken -ModuleName RustDependencies
        Mock Invoke-RdDownloadDescriptor -ModuleName RustDependencies {
            param($Descriptor, $Destination, $Token, $Channel)
            $path = Join-Path $Destination 'Dual.dll'
            Set-Content $path 'managed assembly placeholder'
            return $path
        }

        Invoke-RustDependencies -ManifestPath $manifestPath -Provider Public -Framework Both -ServerPlatform Linux

        Should -Invoke Invoke-RdDownloadDescriptor -ModuleName RustDependencies -Times 1
        Test-Path (Join-Path $output 'main/linux/oxide/Dual.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/linux/carbon/Dual.dll') | Should -BeTrue
        Test-Path (Join-Path $output 'main/linux/rust/Dual.dll') | Should -BeFalse
    }

    It 'maps Both to oxide/carbon/rust leaves while shared items skip rust' {
        InModuleScope RustDependencies {
            @(Get-RdSelectedFrameworkFolders Both) | Should -Be @('oxide', 'carbon', 'rust')
            @(Get-RdModdingFrameworkFolders Both) | Should -Be @('oxide', 'carbon')
            @(Get-RdItemFrameworkFolders ([pscustomobject]@{}) Both 'shared') | Should -Be @('oxide', 'carbon')
            @(Get-RdPublicizerModes Both) | Should -Be @('Oxide', 'Carbon')
        }
    }

    It 'filters private and NuGet items before authentication or download' {
        $manifestPath = Join-Path $TestDrive 'filtered-auth.json'
        Set-Content $manifestPath @'
{
  "outputDirectory": "./repository/dependencies",
  "privateReleases": [
    { "name": "OxidePrivate", "repo": "owner/private", "asset": "Private.dll", "frameworks": ["Oxide"] }
  ],
  "githubNuget": [
    { "name": "Oxide.Package", "source": "https://nuget.pkg.github.com/owner/index.json", "frameworks": ["Oxide"] }
  ]
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

Describe 'Default manifest resolution' {
    BeforeEach {
        $script:toolkit = Join-Path $TestDrive "toolkit-$(New-Guid)"
        $utility = Join-Path $script:toolkit 'scripts' 'utility'
        New-Item -ItemType Directory $utility -Force | Out-Null
        Copy-Item (Join-Path $script:scriptsRoot 'utility' 'Resolve-DefaultManifestPath.ps1') (Join-Path $utility 'Resolve-DefaultManifestPath.ps1')
        $script:resolver = Join-Path $utility 'Resolve-DefaultManifestPath.ps1'
        $script:utilityRoot = $utility
    }

    It 'resolves an explicit ManifestPath' {
        $override = Join-Path $TestDrive 'custom.json'
        Set-Content $override '{"outputDirectory":"./dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $resolved = & $script:resolver -ManifestPath $override -ScriptRoot $script:utilityRoot -Channel Staging
        $resolved | Should -Be (Resolve-Path $override).Path
    }

    It 'throws when ManifestPath is omitted instead of using the toolkit cache manifest' {
        { & $script:resolver -ScriptRoot $script:utilityRoot -Channel Production } |
            Should -Throw '*ManifestPath is required*'
        { & $script:resolver -ManifestPath '' -ScriptRoot $script:utilityRoot -Channel Production } |
            Should -Throw '*ManifestPath is required*'
    }
}

Describe 'Repository layout and wrapper forwarding' {
    It 'keeps entrypoints, module files, and examples in their dedicated folders' {
        $rootPs1 = @(Get-ChildItem -LiteralPath $script:repoRoot -File -Filter '*.ps1')
        $rootPs1 | Should -HaveCount 1
        $rootPs1[0].Name | Should -Be 'download-dependencies.ps1'
        $rootWrappers = @(Get-ChildItem -LiteralPath $script:scriptsRoot -File -Filter '*.ps1')
        $rootWrappers | Should -HaveCount 9
        @($rootWrappers.Name | Sort-Object) | Should -Be @(
            'all.ps1'
            'rust-staging.ps1'
            'rust-staging+carbon.ps1'
            'rust-staging+oxide.ps1'
            'rust-staging+oxide+carbon.ps1'
            'rust.ps1'
            'rust+carbon.ps1'
            'rust+oxide.ps1'
            'rust+oxide+carbon.ps1'
        )
        @(Get-ChildItem -LiteralPath $script:scriptsRoot -File -Filter '*.cmd') | Should -HaveCount 0
        $entrypoints = @(Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter 'Invoke-RustDependencies.ps1')
        $entrypoints | Should -HaveCount 1
        $entrypoints[0].FullName | Should -Be (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1')
        Test-Path (Join-Path $script:repoRoot 'module' 'RustDependencies.psm1') | Should -BeTrue
        Test-Path (Join-Path $script:examplesRoot 'rust-dependencies.example.json') | Should -BeTrue
        Test-Path (Join-Path $script:examplesRoot 'rust-staging-dependencies.example.json') | Should -BeTrue
        (Get-Content (Join-Path $script:examplesRoot 'rust-staging-dependencies.example.json') -Raw | ConvertFrom-Json).outputDirectory |
            Should -Be './dependencies'
        (Test-ModuleManifest (Join-Path $script:repoRoot 'module' 'RustDependencies.psd1')).RootModule |
            Should -Be 'RustDependencies.psm1'
    }

    It 'has every wrapper call the central utility entrypoint' {
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
        $wrappers = @(Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter '*.ps1' |
            Where-Object Name -notin @('Invoke-RustDependencies.ps1', 'Resolve-DefaultManifestPath.ps1'))
        $wrappers | Should -HaveCount 18
        foreach ($wrapper in $wrappers) {
            $relativePath = [IO.Path]::GetRelativePath($script:scriptsRoot, $wrapper.FullName).Replace('\', '/')
            $expectedInvocations.Keys | Should -Contain $relativePath
            $source = Get-Content -LiteralPath $wrapper.FullName -Raw
            $source | Should -Match ([regex]::Escape($expectedInvocations[$relativePath]))
            if ($relativePath -eq 'all.ps1') {
                $source | Should -Match ([regex]::Escape("Join-Path `$PSScriptRoot 'rust+oxide+carbon.ps1'"))
                $source | Should -Match ([regex]::Escape("Join-Path `$PSScriptRoot 'rust-staging+oxide+carbon.ps1'"))
                $source | Should -Match '\[string\]\$ManifestPath'
                $source | Should -Match '\[string\]\$StagingManifestPath'
                $source | Should -Match 'ManifestPath\s*=\s*\$ManifestPath'
                $source | Should -Match 'if \(\$using:serverPlatform\)'
                $source | Should -Match 'if \(\$using:useWhatIf\)'
                continue
            }
            $source | Should -Match 'ManifestPath\s*=\s*\$ManifestPath'
            $source | Should -Match '\[string\]\$ManifestPath'
            $source | Should -Not -Match '\[Parameter\(Mandatory\)\]\[string\]\$ManifestPath'
            $source | Should -Match 'if \(\$ServerPlatform\) \{ \$invoke\.ServerPlatform = \$ServerPlatform \}'
            $source | Should -Match 'if \(\$WhatIfPreference\) \{ \$invoke\.WhatIf = \$true \}'
        }
    }

    It 'exposes an opt-in Publicize switch on all wrappers and the central entrypoint' {
        foreach ($name in 'rust+oxide+carbon.ps1', 'rust-staging+oxide+carbon.ps1', 'rust+oxide.ps1', 'rust-staging+oxide.ps1', 'rust+carbon.ps1', 'rust-staging+carbon.ps1', 'rust.ps1', 'rust-staging.ps1') {
            (Get-Content (Join-Path $script:scriptsRoot $name) -Raw) | Should -Match '\[switch\]\$Publicize'
            (Get-Content (Join-Path $script:scriptsRoot $name) -Raw) | Should -Match 'if \(\$Publicize\) \{ \$invoke\.Publicize = \$true \}'
        }
        (Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw) | Should -Match '\[switch\]\$Publicize'
        (Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw) | Should -Match 'if \(\$using:usePublicize\) \{ \$invoke\.Publicize = \$true \}'
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1') -Raw) | Should -Match '\[switch\]\$Publicize'
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'publicize.ps1') -Raw) | Should -Match "Publicize = \`$true"
        (Get-Content (Join-Path $script:scriptsRoot 'utility' 'publicize.ps1') -Raw) | Should -Match "Provider = @\(\)"
    }

    It 'runs production and staging channel scripts in parallel from all.ps1' {
        $source = Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw
        $source | Should -Match 'ForEach-Object -ThrottleLimit 2 -Parallel'
        $source | Should -Match 'Running production and staging in parallel'
        $source | Should -Match '\$null = & \$_\.ScriptPath @invoke'
        $source | Should -Match 'RdChannelResult'
        $source | Should -Match 'Write-RdGitHubAuthStatus'
    }

    It 'propagates central entrypoint failures through every wrapper' {
        $invalidManifest = Join-Path $TestDrive 'invalid-wrapper-manifest.json'
        Set-Content -LiteralPath $invalidManifest '{'
        foreach ($wrapper in Get-ChildItem -LiteralPath $script:scriptsRoot -Recurse -File -Filter '*.ps1' |
            Where-Object Name -notin @('Invoke-RustDependencies.ps1', 'Resolve-DefaultManifestPath.ps1')) {
            { & $wrapper.FullName -ManifestPath $invalidManifest -ServerPlatform Windows -WhatIf } |
                Should -Throw '*not valid JSON*'
        }
    }

    It 'throws when WhatIf is used without an explicit ManifestPath' {
        { & (Join-Path $script:scriptsRoot 'rust.ps1') -ServerPlatform Windows -WhatIf } |
            Should -Throw '*ManifestPath is required*'
    }

    It 'binds optional framework on focused public and private wrappers' {
        $manifestPath = Join-Path $TestDrive 'wrapper.json'
        Set-Content $manifestPath '{"outputDirectory":"./safe/dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        { & (Join-Path $script:scriptsRoot 'utility' 'public-dlls.ps1') -ManifestPath $manifestPath -Framework Oxide -WhatIf } | Should -Not -Throw
        { & (Join-Path $script:scriptsRoot 'utility' 'private-dlls.ps1') -ManifestPath $manifestPath -Framework Carbon -WhatIf } | Should -Not -Throw
        { & (Join-Path $script:scriptsRoot 'utility' 'Invoke-RustDependencies.ps1') -ManifestPath $manifestPath -Framework Both -WhatIf } | Should -Not -Throw
    }

    It 'pins all wrappers to their named framework' {
        (Get-Content (Join-Path $script:scriptsRoot 'rust+oxide.ps1') -Raw) | Should -Match "Framework = 'Oxide'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging+oxide.ps1') -Raw) | Should -Match "Framework = 'Oxide'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust+carbon.ps1') -Raw) | Should -Match "Framework = 'Carbon'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging+carbon.ps1') -Raw) | Should -Match "Framework = 'Carbon'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust+oxide+carbon.ps1') -Raw) | Should -Match "Framework = 'Both'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging+oxide+carbon.ps1') -Raw) | Should -Match "Framework = 'Both'"
        (Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw) | Should -Match "rust\+oxide\+carbon\.ps1"
        (Get-Content (Join-Path $script:scriptsRoot 'all.ps1') -Raw) | Should -Match "rust-staging\+oxide\+carbon\.ps1"
        (Get-Content (Join-Path $script:scriptsRoot 'rust.ps1') -Raw) | Should -Match "Framework = 'Rust'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging.ps1') -Raw) | Should -Match "Framework = 'Rust'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust.ps1') -Raw) | Should -Match "Provider = @\('Rust'\)"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging.ps1') -Raw) | Should -Match "Provider = @\('Rust'\)"
        (Get-Content (Join-Path $script:scriptsRoot 'rust.ps1') -Raw) | Should -Match "Channel = 'Production'"
        (Get-Content (Join-Path $script:scriptsRoot 'rust-staging.ps1') -Raw) | Should -Match "Channel = 'Staging'"
    }
}
