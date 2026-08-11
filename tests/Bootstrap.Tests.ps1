BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:bootstrapPath = Join-Path $script:repoRoot 'download-dependencies.ps1'
    $env:RD_BOOTSTRAP_UNITTEST = '1'
    $script:previousToolkitCache = $env:RD_TOOLKIT_CACHE
    $env:RD_TOOLKIT_CACHE = Join-Path $TestDrive 'shared-toolkit-cache'
    . $script:bootstrapPath
}

AfterAll {
    Remove-Item Env:RD_BOOTSTRAP_UNITTEST -ErrorAction SilentlyContinue
    if ($null -ne $script:previousToolkitCache) {
        $env:RD_TOOLKIT_CACHE = $script:previousToolkitCache
    } else {
        Remove-Item Env:RD_TOOLKIT_CACHE -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap menu and manifest selection' {
    It 'exposes the nine top-level wrapper menu entries in order' {
        $menu = @(Get-RdBootstrapMenuEntries)
        $menu | Should -HaveCount 9
        $menu.Name | Should -Be @(
            'rust',
            'rust-staging',
            'rust+oxide',
            'rust-staging+oxide',
            'rust+carbon',
            'rust-staging+carbon',
            'rust+oxide+carbon',
            'rust-staging+oxide+carbon',
            'all'
        )
        $menu[1].Channel | Should -Be 'Staging'
        $menu[0].Channel | Should -Be 'Production'
        $menu[8].Channel | Should -BeNullOrEmpty
    }

    It 'resolves -Script without prompting' {
        $selection = Resolve-RdBootstrapMenuSelection -Script 'rust+oxide'
        $selection.Name | Should -Be 'rust+oxide'
        $selection.Channel | Should -Be 'Production'
    }

    It 'maps a menu number through Read-Host with one retry' {
        $responses = [Collections.Queue]::new(@('nope', '2'))
        $selection = Resolve-RdBootstrapMenuSelection -ReadHostCommand {
            param($prompt)
            $responses.Dequeue()
        }
        $selection.Name | Should -Be 'rust-staging'
    }

    It 'throws after two invalid menu choices' {
        $responses = [Collections.Queue]::new(@('x', 'y'))
        {
            Resolve-RdBootstrapMenuSelection -ReadHostCommand {
                param($prompt)
                $responses.Dequeue()
            }
        } | Should -Throw '*Invalid menu choice*'
    }

    It 'resolves publicize from y/n with one retry' {
        $responses = [Collections.Queue]::new(@('maybe', 'yes'))
        $result = Resolve-RdBootstrapPublicize -PublicizeBound:$false -Publicize:$false -ReadHostCommand {
            param($prompt)
            $responses.Dequeue()
        }
        $result | Should -BeTrue
    }

    It 'skips the publicize prompt when -Publicize was bound' {
        $state = @{ Called = $false }
        $result = Resolve-RdBootstrapPublicize -PublicizeBound:$true -Publicize:$false -ReadHostCommand {
            param($prompt)
            $state.Called = $true
            'y'
        }
        $result | Should -BeFalse
        $state.Called | Should -BeFalse
    }

    It 'resolves server platform from menu numbers and names' {
        (Resolve-RdBootstrapServerPlatform -ServerPlatform 'Linux') | Should -Be 'Linux'
        (Resolve-RdBootstrapServerPlatform -ServerPlatform 'All') | Should -Be 'All'
        $responses = [Collections.Queue]::new(@('x', '3'))
        $resolved = Resolve-RdBootstrapServerPlatform -ReadHostCommand {
            param($prompt)
            $responses.Dequeue()
        }
        $resolved | Should -Be 'All'
    }

    It 'skips the server platform prompt when -ServerPlatform is set' {
        $state = @{ Called = $false }
        $resolved = Resolve-RdBootstrapServerPlatform -ServerPlatform Windows -ReadHostCommand {
            param($prompt)
            $state.Called = $true
            '2'
        }
        $resolved | Should -Be 'Windows'
        $state.Called | Should -BeFalse
    }

    It 'prefers staging project manifest for Staging channel when both exist' {
        $project = Join-Path $TestDrive 'project'
        $toolkit = Join-Path $TestDrive 'toolkit'
        New-Item -ItemType Directory $project -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'examples') -Force | Out-Null
        Set-Content (Join-Path $project 'rust-dependencies.json') '{"outputDirectory":"./dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        Set-Content (Join-Path $project 'rust-staging-dependencies.json') '{"outputDirectory":"./dependencies-staging","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $prod = Get-RdBootstrapManifestPath -ProjectRoot $project -ToolkitRoot $toolkit -Channel Production
        $staging = Get-RdBootstrapManifestPath -ProjectRoot $project -ToolkitRoot $toolkit -Channel Staging
        $prod | Should -Be (Resolve-Path (Join-Path $project 'rust-dependencies.json')).Path
        $staging | Should -Be (Resolve-Path (Join-Path $project 'rust-staging-dependencies.json')).Path
    }

    It 'falls back to production manifest for Staging when staging file is absent' {
        $project = Join-Path $TestDrive 'project-single'
        $toolkit = Join-Path $TestDrive 'toolkit-single'
        New-Item -ItemType Directory $project -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'examples') -Force | Out-Null
        Set-Content (Join-Path $project 'rust-dependencies.json') '{"outputDirectory":"./dependencies","publicReleases":[],"privateReleases":[],"githubNuget":[]}'
        $staging = Get-RdBootstrapManifestPath -ProjectRoot $project -ToolkitRoot $toolkit -Channel Staging
        $staging | Should -Be (Resolve-Path (Join-Path $project 'rust-dependencies.json')).Path
    }

    It 'auto-seeds the production project manifest from the toolkit example' {
        $project = Join-Path $TestDrive 'project-seed'
        $toolkit = Join-Path $TestDrive 'toolkit-seed'
        $examples = Join-Path $toolkit 'examples'
        New-Item -ItemType Directory $project -Force | Out-Null
        New-Item -ItemType Directory $examples -Force | Out-Null
        Copy-Item (Join-Path $script:repoRoot 'examples' 'rust-dependencies.example.json') (Join-Path $examples 'rust-dependencies.example.json')
        $prodPath = Join-Path $project 'rust-dependencies.json'
        Test-Path $prodPath | Should -BeFalse
        $resolved = Get-RdBootstrapManifestPath -ProjectRoot $project -ToolkitRoot $toolkit -Channel Production
        Test-Path $prodPath | Should -BeTrue
        $resolved | Should -Be (Resolve-Path $prodPath).Path
    }
}

Describe 'Bootstrap release hash and toolkit install' {
    It 'caches toolkit versions in a shared user cache root' {
        $root = Get-RdBootstrapToolkitCacheRoot
        $root | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'shared-toolkit-cache')))
        $root | Should -Not -Match '[\\/]\.rust-dependencies-toolkit([\\/]|$)'
    }

    It 'parses GitHub asset digests' {
        (ConvertFrom-RdBootstrapAssetDigest -Digest 'sha256:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' -AssetName 'rust-dependencies-1.0.0.zip') |
            Should -Be 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899'
        (ConvertFrom-RdBootstrapAssetDigest -Digest 'SHA256:AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899' -AssetName 'rust-dependencies-1.0.0.zip') |
            Should -Be 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899'
        { ConvertFrom-RdBootstrapAssetDigest -Digest '' -AssetName 'rust-dependencies-1.0.0.zip' } |
            Should -Throw '*no GitHub digest*'
        { ConvertFrom-RdBootstrapAssetDigest -Digest 'md5:00' -AssetName 'rust-dependencies-1.0.0.zip' } |
            Should -Throw '*Unsupported GitHub asset digest*'
    }

    It 'rejects a SHA-256 mismatch when installing a toolkit' {
        $project = Join-Path $TestDrive 'project-hash'
        New-Item -ItemType Directory $project -Force | Out-Null
        Mock Get-RdBootstrapRelease {
            [pscustomobject]@{
                Tag = 'v9.9.9'
                Version = '9.9.9'
                ZipName = 'rust-dependencies-9.9.9.zip'
                ZipUrl = 'https://example.invalid/rust-dependencies-9.9.9.zip'
                ExpectedSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            }
        }
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            Set-Content $OutFile 'not-the-matching-bytes'
        }
        { Install-RdBootstrapToolkit -ProjectRoot $project -Repo 'ilovepatatos-rust/rust-dependencies' } |
            Should -Throw '*SHA-256 mismatch*'
    }

    It 'uses ToolkitRoot without downloading when provided' {
        $project = Join-Path $TestDrive 'project-local'
        $toolkit = Join-Path $TestDrive 'toolkit-local'
        New-Item -ItemType Directory (Join-Path $toolkit 'scripts' 'utility') -Force | Out-Null
        Set-Content (Join-Path $toolkit 'scripts' 'utility' 'Invoke-RustDependencies.ps1') '# stub'
        $resolved = Install-RdBootstrapToolkit -ProjectRoot $project -Repo 'ilovepatatos-rust/rust-dependencies' -ToolkitRoot $toolkit
        $resolved | Should -Be (Resolve-Path $toolkit).Path
    }

    It 'uses ProjectRoot as the toolkit when it already contains the entrypoint' {
        $project = Join-Path $TestDrive 'project-checkout'
        New-Item -ItemType Directory (Join-Path $project 'scripts' 'utility') -Force | Out-Null
        Set-Content (Join-Path $project 'scripts' 'utility' 'Invoke-RustDependencies.ps1') '# stub'
        Mock Get-RdBootstrapRelease { throw 'should not download' }
        $resolved = Install-RdBootstrapToolkit -ProjectRoot $project -Repo 'ilovepatatos-rust/rust-dependencies'
        $resolved | Should -Be (Resolve-Path $project).Path
    }

    It 'runs the selected script with the project manifest when -Script is set' {
        $project = Join-Path $TestDrive 'project-run'
        $toolkit = Join-Path $TestDrive 'toolkit-run'
        New-Item -ItemType Directory $project -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'scripts' 'utility') -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'examples') -Force | Out-Null
        Copy-Item (Join-Path $script:repoRoot 'examples' 'rust-dependencies.example.json') (Join-Path $toolkit 'examples' 'rust-dependencies.example.json')
        Set-Content (Join-Path $toolkit 'scripts' 'utility' 'Invoke-RustDependencies.ps1') '# stub'
        $marker = Join-Path $project 'ran.txt'
        $allRust = Join-Path $toolkit 'scripts' 'rust.ps1'
        Set-Content $allRust @"
param([string]`$ManifestPath,[string]`$ServerPlatform,[switch]`$Publicize,[switch]`$WhatIf)
Set-Content -LiteralPath '$($marker.Replace('\','\\'))' -Value ("`$ManifestPath|`$ServerPlatform|`$Publicize")
"@
        Invoke-RdBootstrap -ProjectRoot $project -ToolkitRoot $toolkit -Script rust -ServerPlatform Windows -PublicizeBound
        Test-Path $marker | Should -BeTrue
        (Get-Content $marker -Raw).Trim() | Should -Be "$(Resolve-Path (Join-Path $project 'rust-dependencies.json'))|Windows|False"
    }

    It 'passes prompted publicize and platform into the selected script' {
        $project = Join-Path $TestDrive 'project-prompt-run'
        $toolkit = Join-Path $TestDrive 'toolkit-prompt-run'
        New-Item -ItemType Directory $project -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'scripts' 'utility') -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $toolkit 'examples') -Force | Out-Null
        Copy-Item (Join-Path $script:repoRoot 'examples' 'rust-dependencies.example.json') (Join-Path $toolkit 'examples' 'rust-dependencies.example.json')
        Set-Content (Join-Path $toolkit 'scripts' 'utility' 'Invoke-RustDependencies.ps1') '# stub'
        $marker = Join-Path $project 'ran-prompt.txt'
        $allRust = Join-Path $toolkit 'scripts' 'rust.ps1'
        Set-Content $allRust @"
param([string]`$ManifestPath,[string]`$ServerPlatform,[switch]`$Publicize,[switch]`$WhatIf)
Set-Content -LiteralPath '$($marker.Replace('\','\\'))' -Value ("`$ServerPlatform|`$Publicize")
"@
        $responses = [Collections.Queue]::new(@('y', '2'))
        Invoke-RdBootstrap -ProjectRoot $project -ToolkitRoot $toolkit -Script rust -ReadHostCommand {
            param($prompt)
            $responses.Dequeue()
        }
        (Get-Content $marker -Raw).Trim() | Should -Be 'Linux|True'
    }
}
