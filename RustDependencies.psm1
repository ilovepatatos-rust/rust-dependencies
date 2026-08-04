Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RdProperty {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Assert-RdSafeSegment {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9._-]+$' -or $Value -in '.', '..') {
        throw "$Label '$Value' must be one safe path segment containing only letters, numbers, dot, underscore, or hyphen."
    }
}

function Resolve-RdPlatform {
    [CmdletBinding()]
    param(
        [ValidateSet('Windows', 'Linux')][string]$ServerPlatform,
        [ValidateSet('Windows', 'Linux')][string]$HostPlatform
    )
    if (-not $HostPlatform) {
        if ($IsWindows) { $HostPlatform = 'Windows' }
        elseif ($IsLinux) { $HostPlatform = 'Linux' }
        else { throw "Unsupported host OS. PowerShell 7 on Windows or Linux is required." }
    }
    if (-not $ServerPlatform) { $ServerPlatform = $HostPlatform }
    [pscustomobject]@{
        Host = $HostPlatform
        Server = $ServerPlatform
        HostAsset = if ($HostPlatform -eq 'Windows') { 'windows-x64' } else { 'linux-x64' }
        Folder = $ServerPlatform.ToLowerInvariant()
    }
}

function Read-RdManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    try { $manifest = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 100 }
    catch { throw "Manifest '$Path' is not valid JSON: $($_.Exception.Message)" }
    if (-not (Get-RdProperty $manifest 'outputDirectory')) { throw "Manifest must define a non-empty 'outputDirectory'." }
    if (-not (Get-RdProperty $manifest 'repositoryRoot')) { throw "Manifest must define a non-empty 'repositoryRoot' relative to the manifest." }
    if (-not (Get-RdProperty $manifest 'providers')) { throw "Manifest must define 'providers'." }
    $allowOutside = Get-RdProperty $manifest 'allowOutputOutsideRepository'
    if ($null -ne $allowOutside -and $allowOutside -isnot [bool]) {
        throw "Manifest 'allowOutputOutsideRepository' must be a JSON boolean."
    }
    $manifest | Add-Member -NotePropertyName __Path -NotePropertyValue $resolved.Path -Force
    return $manifest
}

function Resolve-RdOutputPath {
    param([Parameter(Mandatory)]$Manifest)
    $raw = [string]$Manifest.outputDirectory
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'outputDirectory cannot be empty.' }
    $base = Split-Path -Parent $Manifest.__Path
    $full = if ([IO.Path]::IsPathRooted($raw)) { [IO.Path]::GetFullPath($raw) } else { [IO.Path]::GetFullPath((Join-Path $base $raw)) }
    $repositoryRootRaw = [string]$Manifest.repositoryRoot
    $repositoryRoot = if ([IO.Path]::IsPathRooted($repositoryRootRaw)) {
        [IO.Path]::GetFullPath($repositoryRootRaw)
    } else {
        [IO.Path]::GetFullPath((Join-Path $base $repositoryRootRaw))
    }
    $root = [IO.Path]::GetPathRoot($full)
    $home = if ($HOME) { [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/') } else { '' }
    $normalized = $full.TrimEnd('\', '/')
    $rootNormalized = $root.TrimEnd('\', '/')
    $relativeToRoot = [IO.Path]::GetRelativePath($root, $full)
    $segments = @($relativeToRoot -split '[\\/]' | Where-Object { $_ })
    $manifestDirectory = [IO.Path]::GetFullPath($base).TrimEnd('\', '/')
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $containsManifest = $manifestDirectory.Equals($normalized, $comparison) -or $manifestDirectory.StartsWith("$normalized$([IO.Path]::DirectorySeparatorChar)", $comparison)
    if ($normalized -eq $rootNormalized -or $normalized -eq $home -or $segments.Count -lt 2 -or $containsManifest) {
        throw "Unsafe outputDirectory '$full'. It cannot be a filesystem root, home directory, shallow system path, or contain the manifest."
    }
    $relativeToRepository = [IO.Path]::GetRelativePath($repositoryRoot, $full)
    $outsideRepository = [IO.Path]::IsPathRooted($relativeToRepository) -or
        $relativeToRepository -eq '..' -or
        $relativeToRepository.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", $comparison)
    $isRepositoryRoot = $relativeToRepository -eq '.'
    $allowOutside = (Get-RdProperty $Manifest 'allowOutputOutsideRepository' $false) -eq $true
    if ($isRepositoryRoot) {
        throw "Unsafe outputDirectory '$full'. The repository root itself cannot be used as dependency output."
    }
    if ($outsideRepository -and -not $allowOutside) {
        throw "outputDirectory '$full' is outside repositoryRoot '$repositoryRoot'. Set allowOutputOutsideRepository to true only when this is intentional."
    }
    if (-not $allowOutside) {
        $cursor = $full
        while (-not $cursor.Equals($repositoryRoot.TrimEnd('\', '/'), $comparison)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "outputDirectory '$full' traverses reparse point '$cursor', which is not allowed inside the repository safety boundary."
                }
            }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent.Equals($cursor, $comparison)) { break }
            $cursor = $parent
        }
    }
    return $full
}

function Clear-RdOutput {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $normalized = $full.TrimEnd('\', '/')
    if (-not $normalized -or $normalized -eq $root -or ($HOME -and $normalized -eq [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/'))) {
        throw "Refusing to clear unsafe path '$full'."
    }
    if ($PSCmdlet.ShouldProcess($full, 'Clear dependency output')) {
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }
}

function Get-RdGitHubToken {
    param([switch]$Required)
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    if ($Required) {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if ($gh) {
            $token = (& $gh.Source auth token 2>$null)
            if ($LASTEXITCODE -eq 0 -and $token) { return ($token | Select-Object -First 1).Trim() }
        }
    }
    if ($Required) { throw 'GitHub authentication required. Set GH_TOKEN/GITHUB_TOKEN or authenticate gh first. No token was saved.' }
    return $null
}

function Invoke-RdJsonRequest {
    param([Parameter(Mandatory)][string]$Uri, [string]$Token)
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'rust-dependencies-toolkit' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Save-RdUri {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination, [string]$Token, [switch]$Api)
    $headers = @{ 'User-Agent' = 'rust-dependencies-toolkit' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    if ($Api) { $headers.Accept = 'application/octet-stream' }
    Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $Destination
}

function Invoke-RdTar {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) { throw "tar is required to extract '$([IO.Path]::GetFileName($Archive))'." }
    & $tar.Source -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) { throw "tar failed to extract '$([IO.Path]::GetFileName($Archive))' (exit $LASTEXITCODE)." }
}

function Resolve-RdReleaseAsset {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [string]$Token,
        [ValidateSet('Production', 'Staging')][string]$Channel = 'Production'
    )
    $url = Get-RdProperty $Descriptor 'url'
    if ($url) {
        $name = Get-RdProperty $Descriptor 'name' ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
        if (-not $name) { throw 'URL release descriptors with no filename in the path require a name.' }
        Assert-RdSafeSegment ([string]$name) 'Release asset name'
        return [pscustomobject]@{ Url = [string]$url; Name = [string]$name; Api = $false }
    }
    $repo = Get-RdProperty $Descriptor 'repo'
    $asset = Get-RdProperty $Descriptor 'asset'
    $assetPattern = Get-RdProperty $Descriptor 'assetPattern'
    if (-not $repo -or (-not $asset -and -not $assetPattern)) { throw 'Release descriptor requires url, or repo plus asset/assetPattern.' }
    $tag = Get-RdProperty $Descriptor 'tag' 'latest'
    $api = if ($tag -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" } else { "https://api.github.com/repos/$repo/releases/tags/$tag" }
    $release = Invoke-RdJsonRequest -Uri $api -Token $Token
    $matches = @($release.assets | Where-Object {
        if ($asset) { $_.name -eq $asset } else { $_.name -match $assetPattern }
    })
    if ($matches.Count -ne 1) { throw "Expected one matching asset in $repo release '$tag'; found $($matches.Count)." }
    Assert-RdSafeSegment ([string]$matches[0].name) 'Release asset name'
    [pscustomobject]@{ Url = $matches[0].url; Name = $matches[0].name; Api = $true }
}

function Expand-RdArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $name = [IO.Path]::GetFileName($Archive)
    if ($name -match '\.zip$|\.nupkg$') {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    }
    elseif ($name -match '\.(tar\.gz|tgz)$') {
        Invoke-RdTar -Archive $Archive -Destination $Destination
    }
    else { throw "Unsupported archive format '$name'. Expected .zip, .nupkg, .tar.gz, or .tgz." }
}

function Test-RdExcluded {
    param([string]$RelativePath, $Manifest)
    $normalizedRelativePath = $RelativePath.Replace('\', '/')
    $patterns = @(
        '*.so', '*.dylib', '*.a', '*.lib', '*.exe',
        '*/native/*', '*/runtimes/*/native/*', '*/win-x64/*', '*/linux-x64/*'
    )
    $configured = Get-RdProperty $Manifest 'exclusions'
    if ($configured) { $patterns += @($configured) }
    foreach ($pattern in $patterns) {
        if ($normalizedRelativePath -like $pattern -or ([IO.Path]::GetFileName($normalizedRelativePath) -like $pattern)) { return $true }
    }
    return $false
}

function Copy-RdManagedDlls {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$Manifest,
        [string[]]$IncludeRoots = @()
    )
    if (-not (Test-Path -LiteralPath $Source)) { throw "Expected extracted source '$Source' was not found." }
    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Filter '*.dll')
    if ($IncludeRoots.Count) {
        $files = @($files | Where-Object {
            $relative = [IO.Path]::GetRelativePath($Source, $_.FullName).Replace('\', '/')
            foreach ($root in $IncludeRoots) { if ($relative -like "$root/*" -or $relative -eq $root) { return $true } }
            return $false
        })
    }
    $copied = 0
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        if (Test-RdExcluded $relative $Manifest) { continue }
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }
    if ($copied -eq 0) { throw "No eligible managed DLLs found under '$Source' after exclusions." }
}

function Invoke-RdDownloadDescriptor {
    param($Descriptor, [string]$Destination, [string]$Token, [string]$Channel = 'Production')
    $resolved = Resolve-RdReleaseAsset -Descriptor $Descriptor -Token $Token -Channel $Channel
    $archive = Join-Path $Destination $resolved.Name
    $assetToken = if ($resolved.Api) { $Token } else { $null }
    Save-RdUri -Uri $resolved.Url -Destination $archive -Token $assetToken -Api:$resolved.Api
    return $archive
}

function Get-RdDepotDownloader {
    param($Manifest, $Platform, [string]$Temp)
    $steam = Get-RdProperty $Manifest.providers 'steam'
    if (-not $steam) { throw "providers.steam is required for Rust downloads." }
    $configured = Get-RdProperty $steam 'depotDownloaderPath'
    if ($configured) {
        $path = if ([IO.Path]::IsPathRooted($configured)) { $configured } else { Join-Path (Split-Path -Parent $Manifest.__Path) $configured }
        if (-not (Test-Path -LiteralPath $path)) { throw "Configured DepotDownloader path '$path' does not exist." }
        return (Resolve-Path -LiteralPath $path).Path
    }
    $descriptor = Get-RdProperty $steam 'depotDownloader'
    if (-not $descriptor) {
        $descriptor = [pscustomobject]@{ repo = 'SteamRE/DepotDownloader'; assetPattern = "DepotDownloader.*$($Platform.HostAsset)\.zip" }
    }
    $archive = Invoke-RdDownloadDescriptor $descriptor $Temp
    $extract = Join-Path $Temp 'depotdownloader'
    Expand-RdArchive $archive $extract
    $dll = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'DepotDownloader.dll' | Select-Object -First 1
    if (-not $dll) { throw 'DepotDownloader.dll was not found in the downloaded host archive.' }
    return $dll.FullName
}

function Invoke-RdRust {
    param($Manifest, $Platform, [string]$Channel, [string]$Output, [string]$Temp)
    $steam = $Manifest.providers.steam
    $appId = [string](Get-RdProperty $steam 'appId' '258550')
    $depots = Get-RdProperty $steam 'depots'
    $depotId = if ($depots -and (Get-RdProperty $depots $Platform.Server)) { [string](Get-RdProperty $depots $Platform.Server) } elseif ($Platform.Server -eq 'Windows') { '258551' } else { '258552' }
    $branches = Get-RdProperty $steam 'branches'
    $branch = if ($branches) { [string](Get-RdProperty $branches $Channel $(if ($Channel -eq 'Staging') { 'staging' } else { 'public' })) } elseif ($Channel -eq 'Staging') { 'staging' } else { 'public' }
    $downloader = Get-RdDepotDownloader $Manifest $Platform $Temp
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw 'dotnet is required to run DepotDownloader but was not found on PATH.' }
    $install = Join-Path $Temp 'rust-server'
    # DepotDownloader defaults to Steam anonymous login when no username is
    # supplied. Omitting credentials is the documented noninteractive path.
    $args = @($downloader, '-app', $appId, '-depot', $depotId, '-dir', $install)
    if ($branch -and $branch -ne 'public') { $args += @('-branch', $branch) }
    & $dotnet.Source @args
    if ($LASTEXITCODE -ne 0) { throw "DepotDownloader failed for app $appId depot $depotId branch $branch (exit $LASTEXITCODE)." }
    $managed = Get-ChildItem -LiteralPath $install -Directory -Recurse | Where-Object Name -eq 'Managed' | Select-Object -First 1
    if (-not $managed) { throw "Rust Managed directory was not found after depot download." }
    Copy-RdManagedDlls $managed.FullName (Join-Path $Output "rust/$($Platform.Folder)/managed") $Manifest
}

function Resolve-RdFrameworkDescriptor {
    param([string]$Name, $Manifest, $Platform, [string]$Channel)
    $provider = Get-RdProperty $Manifest.providers $Name
    if (-not $provider) { throw "providers.$Name is required." }
    $platformAssets = Get-RdProperty $provider 'assets'
    $channelAssets = if ($platformAssets) { Get-RdProperty $platformAssets $Channel } else { $null }
    $descriptor = if ($channelAssets) { Get-RdProperty $channelAssets $Platform.Server } else { $null }
    if (-not $descriptor -and $Name -eq 'carbon') {
        $tag = if ($Channel -eq 'Production') { 'production_build' } else { 'rustbeta_staging_build' }
        $target = if ($Channel -eq 'Production') { 'Release' } else { 'Debug' }
        $asset = if ($Platform.Server -eq 'Windows') { "Carbon.Windows.$target.zip" } else { "Carbon.Linux.$target.tar.gz" }
        $descriptor = [pscustomobject]@{ repo = 'CarbonCommunity/Carbon'; tag = $tag; asset = $asset }
    }
    if (-not $descriptor -and $Name -eq 'oxide' -and $Channel -eq 'Production') {
        $asset = if ($Platform.Server -eq 'Windows') { 'Oxide.Rust.zip' } else { 'Oxide.Rust-linux.zip' }
        $descriptor = [pscustomobject]@{ repo = 'OxideMod/Oxide.Rust'; asset = $asset }
    }
    if (-not $descriptor -and $Name -eq 'oxide' -and $Channel -eq 'Staging') {
        $asset = if ($Platform.Server -eq 'Windows') { 'Oxide.Rust.zip' } else { 'Oxide.Rust-linux.zip' }
        $descriptor = [pscustomobject]@{
            url = "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/$asset"
            name = $asset
        }
    }
    if (-not $descriptor) { throw "No $Name asset configured for channel '$Channel' and target '$($Platform.Server)'." }
    return $descriptor
}

function Invoke-RdFramework {
    param([string]$Name, $Manifest, $Platform, [string]$Channel, [string]$Output, [string]$Temp)
    $descriptor = Resolve-RdFrameworkDescriptor $Name $Manifest $Platform $Channel
    $archive = Invoke-RdDownloadDescriptor $descriptor $Temp $null $Channel
    $extract = Join-Path $Temp "$Name-extracted"
    Expand-RdArchive $archive $extract
    $destination = Join-Path $Output "$Name/$($Platform.Folder)/managed"
    if ($Name -eq 'carbon') {
        $carbonRoot = Get-ChildItem -LiteralPath $extract -Directory -Recurse | Where-Object { $_.FullName.Replace('\','/') -match '/carbon/managed$' } | Select-Object -First 1
        if (-not $carbonRoot) { throw "Carbon archive does not contain carbon/managed." }
        Copy-RdManagedDlls $carbonRoot.FullName $destination $Manifest
    } else {
        $managed = Get-ChildItem -LiteralPath $extract -Directory -Recurse | Where-Object Name -eq 'Managed' | Select-Object -First 1
        if (-not $managed) { throw "Oxide archive does not contain a Managed directory." }
        Copy-RdManagedDlls $managed.FullName $destination $Manifest
    }
}

function Invoke-RdReleaseCollection {
    param([string]$Kind, $Manifest, $Platform, [string]$Output, [string]$Temp)
    $collection = Get-RdProperty $Manifest.providers $Kind
    if (-not $collection) { return }
    $private = $Kind -eq 'privateReleases'
    $token = if ($private) { Get-RdGitHubToken -Required } else { Get-RdGitHubToken }
    foreach ($item in @($collection)) {
        $name = [string](Get-RdProperty $item 'name')
        if (-not $name) { throw "$Kind entries require a name." }
        Assert-RdSafeSegment $name "$Kind name"
        $descriptor = Get-RdProperty $item 'release' $item
        $asset = Invoke-RdDownloadDescriptor $descriptor $Temp $token
        $destination = Join-Path $Output "$Kind/$($Platform.Folder)/$name"
        if ([IO.Path]::GetExtension($asset) -ieq '.dll') {
            $assetName = [IO.Path]::GetFileName($asset)
            if (Test-RdExcluded $assetName $Manifest) { throw "Direct DLL asset '$assetName' is excluded by the manifest." }
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath $asset -Destination (Join-Path $destination $assetName) -Force
        } else {
            $extract = Join-Path $Temp "release-$name"
            Expand-RdArchive $asset $extract
            Copy-RdManagedDlls $extract $destination $Manifest
        }
    }
}

function Invoke-RdNuGetCollection {
    param($Manifest, $Platform, [string]$Output, [string]$Temp)
    $packages = Get-RdProperty $Manifest.providers 'githubNuget'
    if (-not $packages) { return }
    $token = Get-RdGitHubToken -Required
    foreach ($package in @($packages)) {
        $name = [string](Get-RdProperty $package 'name')
        $source = [string](Get-RdProperty $package 'source')
        if (-not $name -or -not $source) { throw 'githubNuget entries require name and source.' }
        Assert-RdSafeSegment $name 'NuGet package name'
        $username = @($env:GITHUB_ACTOR, $env:GH_USERNAME, $env:GITHUB_USER, 'token') | Where-Object { $_ } | Select-Object -First 1
        $headers = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$username`:$token")))"; 'User-Agent' = 'rust-dependencies-toolkit' }
        $index = Invoke-RestMethod -Uri $source -Headers $headers
        $baseResource = $index.resources | Where-Object { (Get-RdProperty $_ '@type') -like 'PackageBaseAddress*' } | Select-Object -First 1
        $base = Get-RdProperty $baseResource '@id'
        if (-not $base) { throw "NuGet source '$source' does not expose PackageBaseAddress." }
        $id = $name.ToLowerInvariant()
        $versions = @((Invoke-RestMethod -Uri "$($base.TrimEnd('/'))/$id/index.json" -Headers $headers).versions)
        $requested = Get-RdProperty $package 'version' 'latest'
        if ($requested -in 'latest', 'stable', 'prerelease') {
            $allowPrerelease = [bool](Get-RdProperty $package 'includePrerelease' $false)
            $candidates = switch ($requested) {
                stable { @($versions | Where-Object { $_ -notmatch '-' }) }
                prerelease { @($versions | Where-Object { $_ -match '-' }) }
                default { if ($allowPrerelease) { $versions } else { @($versions | Where-Object { $_ -notmatch '-' }) } }
            }
            $version = $candidates | Sort-Object { [Management.Automation.SemanticVersion]$_ } | Select-Object -Last 1
        } else { $version = [string]$requested }
        if (-not $version -or $versions -notcontains $version) { throw "No matching version found for NuGet package '$name'." }
        $nupkg = Join-Path $Temp "$id.$version.nupkg"
        Invoke-WebRequest -Uri "$($base.TrimEnd('/'))/$id/$version/$id.$version.nupkg" -Headers $headers -OutFile $nupkg
        $extract = Join-Path $Temp "nuget-$id"
        Expand-RdArchive $nupkg $extract
        Copy-RdManagedDlls $extract (Join-Path $Output "nuget/$($Platform.Folder)/$name") $Manifest -IncludeRoots @('lib', 'ref')
    }
}

function Invoke-RustDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [ValidateSet('Windows', 'Linux')][string]$ServerPlatform,
        [ValidateSet('Production', 'Staging')][string]$Channel = 'Production',
        [ValidateSet('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet')][string[]]$Provider = @('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet'),
        [switch]$ClearOutput
    )
    $manifest = Read-RdManifest $ManifestPath
    $platform = Resolve-RdPlatform -ServerPlatform $ServerPlatform
    $mapping = Get-RdProperty $manifest 'targetPlatformMapping'
    if ($mapping -and (Get-RdProperty $mapping $platform.Server)) {
        $mappedFolder = [string](Get-RdProperty $mapping $platform.Server)
        Assert-RdSafeSegment $mappedFolder 'targetPlatformMapping value'
        $platform.Folder = $mappedFolder
    }
    $output = Resolve-RdOutputPath $manifest
    if ($ClearOutput) { Clear-RdOutput $output -WhatIf:$WhatIfPreference }
    elseif (-not $WhatIfPreference) { New-Item -ItemType Directory -Path $output -Force | Out-Null }
    if ($WhatIfPreference) { return }
    $temp = Join-Path ([IO.Path]::GetTempPath()) "rust-dependencies-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        foreach ($selected in $Provider) {
            $providerTemp = Join-Path $temp $selected
            New-Item -ItemType Directory -Path $providerTemp -Force | Out-Null
            switch ($selected) {
                Rust { Invoke-RdRust $manifest $platform $Channel $output $providerTemp }
                Oxide { Invoke-RdFramework 'oxide' $manifest $platform $Channel $output $providerTemp }
                Carbon { Invoke-RdFramework 'carbon' $manifest $platform $Channel $output $providerTemp }
                Public { Invoke-RdReleaseCollection 'publicReleases' $manifest $platform $output $providerTemp }
                Private { Invoke-RdReleaseCollection 'privateReleases' $manifest $platform $output $providerTemp }
                NuGet { Invoke-RdNuGetCollection $manifest $platform $output $providerTemp }
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Invoke-RustDependencies, Read-RdManifest, Resolve-RdPlatform, Resolve-RdOutputPath, Clear-RdOutput, Expand-RdArchive
