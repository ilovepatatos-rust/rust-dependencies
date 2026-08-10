#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Script,
    [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform,
    [switch]$Publicize,
    [switch]$WhatIf,
    [string]$Repo = 'ilovepatatos-rust/rust-dependencies',
    [string]$ProjectRoot,
    [string]$ToolkitRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RdBootstrapMenuEntries {
    @(
        [pscustomobject]@{ Number = 1; Name = 'all-rust'; Channel = 'Production' }
        [pscustomobject]@{ Number = 2; Name = 'all-rust-staging'; Channel = 'Staging' }
        [pscustomobject]@{ Number = 3; Name = 'all-oxide'; Channel = 'Production' }
        [pscustomobject]@{ Number = 4; Name = 'all-oxide-staging'; Channel = 'Staging' }
        [pscustomobject]@{ Number = 5; Name = 'all-carbon'; Channel = 'Production' }
        [pscustomobject]@{ Number = 6; Name = 'all-carbon-staging'; Channel = 'Staging' }
        [pscustomobject]@{ Number = 7; Name = 'all'; Channel = 'Production' }
        [pscustomobject]@{ Number = 8; Name = 'all-staging'; Channel = 'Staging' }
    )
}

function Resolve-RdBootstrapVersionLabel {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'latest') {
        return 'latest'
    }
    return $Version.TrimStart('v', 'V')
}

function Get-RdBootstrapRelease {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Version
    )
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'rust-dependencies-bootstrap'
    }
    $token = @($env:GH_TOKEN, $env:GITHUB_TOKEN) | Where-Object { $_ } | Select-Object -First 1
    if ($token) { $headers.Authorization = "Bearer $token" }

    $label = Resolve-RdBootstrapVersionLabel $Version
    $api = if ($label -eq 'latest') {
        "https://api.github.com/repos/$Repo/releases/latest"
    } else {
        "https://api.github.com/repos/$Repo/releases/tags/v$label"
    }
    $release = Invoke-RestMethod -Uri $api -Headers $headers
    $tag = [string]$release.tag_name
    if (-not $tag) { throw "GitHub release for '$Repo' did not include a tag_name." }
    $versionNumber = $tag.TrimStart('v', 'V')
    $zipName = "rust-dependencies-$versionNumber.zip"
    $shaName = "$zipName.sha256"
    $zipAsset = @($release.assets | Where-Object name -eq $zipName) | Select-Object -First 1
    $shaAsset = @($release.assets | Where-Object name -eq $shaName) | Select-Object -First 1
    if (-not $zipAsset) { throw "Release '$tag' does not contain asset '$zipName'." }
    if (-not $shaAsset) { throw "Release '$tag' does not contain asset '$shaName'." }
    [pscustomobject]@{
        Tag = $tag
        Version = $versionNumber
        ZipName = $zipName
        ShaName = $shaName
        ZipUrl = [string]$zipAsset.browser_download_url
        ShaUrl = [string]$shaAsset.browser_download_url
    }
}

function Get-RdBootstrapExpectedHash {
    param([Parameter(Mandatory)][string]$ShaFilePath, [Parameter(Mandatory)][string]$ZipName)
    $line = (Get-Content -LiteralPath $ShaFilePath -TotalCount 1).Trim()
    if ($line -match '^(?<hash>[A-Fa-f0-9]{64})(?:\s+\*?(?<name>\S+))?$') {
        $hash = $Matches['hash'].ToLowerInvariant()
        if ($Matches['name']) {
            $name = $Matches['name']
            if ($name -ne $ZipName -and [IO.Path]::GetFileName($name) -ne $ZipName) {
                throw "SHA-256 file names '$name' but expected '$ZipName'."
            }
        }
        return $hash
    }
    throw "Unable to parse SHA-256 checksum from '$ShaFilePath'."
}

function Test-RdBootstrapToolkitRoot {
    param([Parameter(Mandatory)][string]$Path)
    $entrypoint = Join-Path $Path 'scripts' 'utility' 'Invoke-RustDependencies.ps1'
    return (Test-Path -LiteralPath $entrypoint -PathType Leaf)
}

function Install-RdBootstrapToolkit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Version,
        [string]$ToolkitRoot
    )
    if ($ToolkitRoot) {
        if (-not (Test-RdBootstrapToolkitRoot $ToolkitRoot)) {
            throw "ToolkitRoot '$ToolkitRoot' is missing scripts/utility/Invoke-RustDependencies.ps1."
        }
        return (Resolve-Path -LiteralPath $ToolkitRoot).Path
    }

    if (Test-RdBootstrapToolkitRoot $ProjectRoot) {
        Write-Host "Using local toolkit at '$ProjectRoot' (skipping download)."
        return (Resolve-Path -LiteralPath $ProjectRoot).Path
    }

    $release = Get-RdBootstrapRelease -Repo $Repo -Version $Version
    $cacheRoot = Join-Path $ProjectRoot '.rust-dependencies-toolkit'
    $versionRoot = Join-Path $cacheRoot $release.Version
    $marker = Join-Path $versionRoot 'scripts' 'utility' 'Invoke-RustDependencies.ps1'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        Write-Host "Using cached toolkit $($release.Tag) at '$versionRoot'."
        return (Resolve-Path -LiteralPath $versionRoot).Path
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $temp = Join-Path ([IO.Path]::GetTempPath()) "rd-bootstrap-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $zipPath = Join-Path $temp $release.ZipName
        $shaPath = Join-Path $temp $release.ShaName
        Write-Host "Downloading $($release.ZipName) from $Repo $($release.Tag)..."
        Invoke-WebRequest -Uri $release.ZipUrl -OutFile $zipPath -UseBasicParsing
        Invoke-WebRequest -Uri $release.ShaUrl -OutFile $shaPath -UseBasicParsing
        $expected = Get-RdBootstrapExpectedHash -ShaFilePath $shaPath -ZipName $release.ZipName
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 mismatch for '$($release.ZipName)'. Expected $expected but got $actual."
        }
        $extract = Join-Path $temp 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        $prefixed = Join-Path $extract "rust-dependencies-$($release.Version)"
        $sourceRoot = if (Test-RdBootstrapToolkitRoot $prefixed) {
            $prefixed
        } elseif (Test-RdBootstrapToolkitRoot $extract) {
            $extract
        } else {
            $found = Get-ChildItem -LiteralPath $extract -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { Test-RdBootstrapToolkitRoot $_.FullName } |
                Select-Object -First 1
            if (-not $found) {
                throw "Downloaded archive did not contain a toolkit root with scripts/utility/Invoke-RustDependencies.ps1."
            }
            $found.FullName
        }
        if (Test-Path -LiteralPath $versionRoot) {
            Remove-Item -LiteralPath $versionRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $versionRoot) -Force | Out-Null
        Copy-Item -LiteralPath $sourceRoot -Destination $versionRoot -Recurse -Force
        if (-not (Test-RdBootstrapToolkitRoot $versionRoot)) {
            throw "Failed to install toolkit into '$versionRoot'."
        }
        Write-Host "Installed toolkit $($release.Tag) at '$versionRoot'."
        return (Resolve-Path -LiteralPath $versionRoot).Path
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RdBootstrapManifestPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel
    )
    $productionPath = Join-Path $ProjectRoot 'rust-dependencies.json'
    $stagingPath = Join-Path $ProjectRoot 'rust-staging-dependencies.json'
    $selected = if ($Channel -eq 'Staging' -and (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
        $stagingPath
    } else {
        $productionPath
    }
    if ($selected -eq $productionPath -and -not (Test-Path -LiteralPath $productionPath -PathType Leaf)) {
        $example = Join-Path $ToolkitRoot 'examples' 'rust-dependencies.example.json'
        if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
            throw "Project manifest '$productionPath' is missing and toolkit example '$example' was not found."
        }
        Copy-Item -LiteralPath $example -Destination $productionPath
        Write-Host "Created project manifest at '$productionPath' from the toolkit example."
    }
    if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) {
        throw "Resolved project manifest '$selected' was not found."
    }
    return (Resolve-Path -LiteralPath $selected).Path
}

function Resolve-RdBootstrapMenuSelection {
    param(
        [string]$Script,
        [scriptblock]$ReadHostCommand
    )
    $menu = @(Get-RdBootstrapMenuEntries)
    if (-not [string]::IsNullOrWhiteSpace($Script)) {
        $normalized = $Script.Trim() -replace '\.ps1$', ''
        $match = @($menu | Where-Object { $_.Name -eq $normalized })
        if ($match.Count -ne 1) {
            throw "Unknown -Script '$Script'. Expected one of: $($menu.Name -join ', ')."
        }
        return $match[0]
    }

    Write-Host ''
    Write-Host 'Select a dependencies download script:'
    foreach ($entry in $menu) {
        Write-Host ("{0}. {1}" -f $entry.Number, $entry.Name)
    }
    if (-not $ReadHostCommand) {
        $ReadHostCommand = { param($prompt) Read-Host $prompt }
    }
    $choice = & $ReadHostCommand 'Enter choice (1-8)'
    $selected = @($menu | Where-Object { $_.Number.ToString() -eq "$choice" })
    if ($selected.Count -ne 1) {
        $choice = & $ReadHostCommand 'Invalid choice. Enter choice (1-8)'
        $selected = @($menu | Where-Object { $_.Number.ToString() -eq "$choice" })
    }
    if ($selected.Count -ne 1) {
        throw "Invalid menu choice '$choice'. Expected a number from 1 to 8."
    }
    return $selected[0]
}

function ConvertFrom-RdBootstrapYesNo {
    param([string]$Value)
    switch -Regex ($Value.Trim()) {
        '^(?i:y|yes)$' { return $true }
        '^(?i:n|no)$' { return $false }
        default { return $null }
    }
}

function Resolve-RdBootstrapPublicize {
    param(
        [bool]$PublicizeBound,
        [bool]$Publicize,
        [scriptblock]$ReadHostCommand
    )
    if ($PublicizeBound) { return $Publicize }

    Write-Host ''
    Write-Host 'Publicize dependencies after download?'
    if (-not $ReadHostCommand) {
        $ReadHostCommand = { param($prompt) Read-Host $prompt }
    }
    $answer = ConvertFrom-RdBootstrapYesNo (& $ReadHostCommand 'Enter y/n')
    if ($null -eq $answer) {
        $answer = ConvertFrom-RdBootstrapYesNo (& $ReadHostCommand 'Invalid choice. Enter y/n')
    }
    if ($null -eq $answer) {
        throw "Invalid publicize choice. Expected y/yes or n/no."
    }
    return $answer
}

function ConvertFrom-RdBootstrapServerPlatform {
    param([string]$Value)
    $trimmed = "$Value".Trim()
    switch -Regex ($trimmed) {
        '^(?i:windows|1)$' { return 'Windows' }
        '^(?i:linux|2)$' { return 'Linux' }
        '^(?i:all|both|3)$' { return 'All' }
        default { return $null }
    }
}

function Resolve-RdBootstrapServerPlatform {
    param(
        [string]$ServerPlatform,
        [scriptblock]$ReadHostCommand
    )
    if (-not [string]::IsNullOrWhiteSpace($ServerPlatform)) {
        $resolved = ConvertFrom-RdBootstrapServerPlatform $ServerPlatform
        if (-not $resolved) {
            throw "Invalid -ServerPlatform '$ServerPlatform'. Expected Windows, Linux, or All."
        }
        return $resolved
    }

    Write-Host ''
    Write-Host 'Select server platform:'
    Write-Host '1. Windows'
    Write-Host '2. Linux'
    Write-Host '3. All (Windows and Linux)'
    if (-not $ReadHostCommand) {
        $ReadHostCommand = { param($prompt) Read-Host $prompt }
    }
    $choice = ConvertFrom-RdBootstrapServerPlatform (& $ReadHostCommand 'Enter choice (1-3 or Windows/Linux/All)')
    if (-not $choice) {
        $choice = ConvertFrom-RdBootstrapServerPlatform (& $ReadHostCommand 'Invalid choice. Enter choice (1-3 or Windows/Linux/All)')
    }
    if (-not $choice) {
        throw "Invalid server platform choice. Expected Windows/Linux/All or 1/2/3."
    }
    return $choice
}

function Invoke-RdBootstrap {
    [CmdletBinding()]
    param(
        [string]$Version,
        [string]$Script,
        [string]$ServerPlatform,
        [switch]$Publicize,
        [switch]$PublicizeBound,
        [switch]$WhatIf,
        [string]$Repo = 'ilovepatatos-rust/rust-dependencies',
        [string]$ProjectRoot,
        [string]$ToolkitRoot,
        [scriptblock]$ReadHostCommand
    )
    if (-not $ProjectRoot) {
        if ($PSScriptRoot) { $ProjectRoot = $PSScriptRoot }
        else { $ProjectRoot = (Get-Location).Path }
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $installedRoot = Install-RdBootstrapToolkit -ProjectRoot $ProjectRoot -Repo $Repo -Version $Version -ToolkitRoot $ToolkitRoot
    $selection = Resolve-RdBootstrapMenuSelection -Script $Script -ReadHostCommand $ReadHostCommand
    $usePublicize = Resolve-RdBootstrapPublicize -PublicizeBound:$PublicizeBound -Publicize:([bool]$Publicize) -ReadHostCommand $ReadHostCommand
    $resolvedPlatform = Resolve-RdBootstrapServerPlatform -ServerPlatform $ServerPlatform -ReadHostCommand $ReadHostCommand
    $manifestPath = Get-RdBootstrapManifestPath -ProjectRoot $ProjectRoot -ToolkitRoot $installedRoot -Channel $selection.Channel
    $scriptPath = Join-Path $installedRoot 'scripts' "$($selection.Name).ps1"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Toolkit script '$scriptPath' was not found."
    }
    $invoke = @{
        ManifestPath = $manifestPath
        ServerPlatform = $resolvedPlatform
    }
    if ($usePublicize) { $invoke.Publicize = $true }
    if ($WhatIf) { $invoke.WhatIf = $true }
    Write-Host "Running $($selection.Name) with manifest '$manifestPath'..."
    & $scriptPath @invoke
}

function Wait-RdBootstrapKeyPress {
    if ($env:RD_BOOTSTRAP_UNITTEST -eq '1') { return }
    if ($env:CI -or $env:GITHUB_ACTIONS) { return }
    if (-not [Environment]::UserInteractive) { return }
    Write-Host ''
    Write-Host 'Press Enter to exit...'
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host 'Press Enter to exit'
    }
}

if ($env:RD_BOOTSTRAP_UNITTEST -ne '1') {
    $script:RdBootstrapFailed = $false
    try {
        Invoke-RdBootstrap `
            -Version $Version `
            -Script $Script `
            -ServerPlatform $ServerPlatform `
            -Publicize:$Publicize `
            -PublicizeBound:($PSBoundParameters.ContainsKey('Publicize')) `
            -WhatIf:$WhatIf `
            -Repo $Repo `
            -ProjectRoot $ProjectRoot `
            -ToolkitRoot $ToolkitRoot
    } catch {
        $script:RdBootstrapFailed = $true
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        }
    } finally {
        Wait-RdBootstrapKeyPress
    }
    if ($script:RdBootstrapFailed) { exit 1 }
}
