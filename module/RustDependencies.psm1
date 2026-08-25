Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cached optional GitHub token for this process (including empty/anonymous).
$script:RdGitHubTokenCache = $null
$script:RdGitHubTokenCacheResolved = $false
$script:RdGitHubAuthStatusWritten = $false

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
    foreach ($collectionName in 'publicReleases', 'privateReleases', 'githubNuget', 'deleteDlls') {
        $value = Get-RdProperty $manifest $collectionName
        if ($null -eq $value) {
            $manifest | Add-Member -NotePropertyName $collectionName -NotePropertyValue @() -Force
        } elseif ($value -is [string]) {
            throw "Manifest '$collectionName' must be a JSON array."
        }
    }
    foreach ($name in @($manifest.deleteDlls)) {
        $fileName = [string]$name
        if ([string]::IsNullOrWhiteSpace($fileName)) { throw "Manifest 'deleteDlls' entries must be non-empty file names." }
        Assert-RdSafeSegment $fileName 'deleteDlls entry'
    }
    $manifest | Add-Member -NotePropertyName __Path -NotePropertyValue $resolved.Path -Force
    return $manifest
}

function Get-RdBuiltinSteamConfig {
    [pscustomobject]@{
        appId = '258550'
        depots = [pscustomobject]@{ Windows = '258551'; Linux = '258552' }
        branches = [pscustomobject]@{ Production = 'public'; Staging = 'staging' }
        fileList = @('regex:RustDedicated_Data/Managed/.*\.dll')
        depotDownloader = [pscustomobject]@{
            repo = 'SteamRE/DepotDownloader'
        }
    }
}

function Resolve-RdOutputPath {
    param([Parameter(Mandatory)]$Manifest)
    $raw = [string]$Manifest.outputDirectory
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'outputDirectory cannot be empty.' }
    $base = Split-Path -Parent $Manifest.__Path
    $full = if ([IO.Path]::IsPathRooted($raw)) { [IO.Path]::GetFullPath($raw) } else { [IO.Path]::GetFullPath((Join-Path $base $raw)) }
    $root = [IO.Path]::GetPathRoot($full)
    $home = if ($HOME) { [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/') } else { '' }
    $normalized = $full.TrimEnd('\', '/')
    $rootNormalized = $root.TrimEnd('\', '/')
    # Keep GetPathRoot as-is for GetRelativePath: on Unix TrimEnd would turn '/' into ''.
    $relativeToRoot = [IO.Path]::GetRelativePath($root, $full)
    $segments = @($relativeToRoot -split '[\\/]' | Where-Object { $_ })
    $manifestDirectory = [IO.Path]::GetFullPath($base).TrimEnd('\', '/')
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $containsManifest = $manifestDirectory.Equals($normalized, $comparison) -or $manifestDirectory.StartsWith("$normalized$([IO.Path]::DirectorySeparatorChar)", $comparison)
    if ($normalized -eq $rootNormalized -or $normalized -eq $home -or $segments.Count -lt 2 -or $containsManifest) {
        throw "Unsafe outputDirectory '$full'. It cannot be a filesystem root, home directory, shallow system path, or contain the manifest."
    }
    return $full
}

function Test-RdUnsafeClearPath {
    param([Parameter(Mandatory)][string]$FullPath)
    $root = [IO.Path]::GetPathRoot($FullPath)
    $normalized = $FullPath.TrimEnd('\', '/')
    $rootNormalized = $root.TrimEnd('\', '/')
    $home = if ($HOME) { [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/') } else { '' }
    # Keep GetPathRoot as-is for GetRelativePath: on Unix TrimEnd would turn '/' into ''.
    $relativeToRoot = [IO.Path]::GetRelativePath($root, $FullPath)
    $segments = @($relativeToRoot -split '[\\/]' | Where-Object { $_ })
    return [pscustomobject]@{
        Normalized = $normalized
        IsUnsafeRootOrHome = (-not $normalized -or $normalized -eq $rootNormalized -or ($home -and $normalized -eq $home))
        SegmentCount = $segments.Count
    }
}

function Clear-RdOutput {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $safety = Test-RdUnsafeClearPath $full
    if ($safety.IsUnsafeRootOrHome) {
        throw "Refusing to clear unsafe path '$full'."
    }
    if ($PSCmdlet.ShouldProcess($full, 'Clear dependency output contents')) {
        if (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -Force | Remove-Item -Recurse -Force
        } else {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
    }
}

function Clear-RdProviderSubtree {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $safety = Test-RdUnsafeClearPath $full
    if ($safety.IsUnsafeRootOrHome) {
        throw "Refusing to clear unsafe provider subtree '$full'."
    }
    if ($safety.SegmentCount -lt 2) {
        throw "Refusing to clear shallow provider subtree '$full'."
    }
    if ($PSCmdlet.ShouldProcess($full, 'Clear provider output subtree')) {
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }
}

function Select-RdUniqueDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][scriptblock]$Filter,
        [Parameter(Mandatory)][string]$NoneMessage,
        [Parameter(Mandatory)][string]$AmbiguousMessage
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Expected directory '$Root' was not found."
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $Root -Directory -Recurse |
            Where-Object $Filter |
            Sort-Object { $_.FullName.Replace('\', '/') } -CaseSensitive
    )
    if ($candidates.Count -eq 0) { throw $NoneMessage }
    if ($candidates.Count -gt 1) {
        $relativeCandidates = @($candidates | ForEach-Object {
            [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
        })
        throw "$AmbiguousMessage $($relativeCandidates -join ', '). Refusing ambiguous selection."
    }
    return $candidates[0]
}

function Get-RdGitHubTokenFromGh {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { return $null }
    try {
        $token = (& $gh.Source auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $token) {
            $value = ([string]($token | Select-Object -First 1)).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    } catch {
        # Optional fallback; ignore failures.
    }
    return $null
}

function Get-RdGitHubTokenFromGitCredential {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $null }
    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $previousGcmInteractive = $env:GCM_INTERACTIVE
    try {
        # Optional auth only: never show terminal or GCM GUI login prompts.
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $input = "protocol=https`nhost=github.com`n`n"
        $output = $input | & $git.Source credential fill 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        foreach ($line in @($output)) {
            if ($line -match '^password=(?<token>.+)$') {
                $value = $Matches['token'].Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
        }
    } catch {
        # Optional fallback; ignore failures.
    } finally {
        if ($null -eq $previousPrompt) {
            Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        } else {
            $env:GIT_TERMINAL_PROMPT = $previousPrompt
        }
        if ($null -eq $previousGcmInteractive) {
            Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
        } else {
            $env:GCM_INTERACTIVE = $previousGcmInteractive
        }
    }
    return $null
}

function Set-RdGitHubTokenProcessCache {
    param([AllowNull()][AllowEmptyString()][string]$Token)
    $script:RdGitHubTokenCache = $Token
    $script:RdGitHubTokenCacheResolved = $true
    # Publish to env so parallel ForEach-Object runspaces inherit the result and
    # do not each re-run git credential fill / GCM login prompts.
    $env:RD_GITHUB_TOKEN_RESOLVED = '1'
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $env:RD_GITHUB_TOKEN = ''
    } else {
        $env:RD_GITHUB_TOKEN = $Token
    }
}

function Get-RdGitHubToken {
    param([switch]$Required)
    # Already resolved for this process tree (including parallel children).
    if ($env:RD_GITHUB_TOKEN_RESOLVED -eq '1') {
        $resolved = $env:RD_GITHUB_TOKEN
        if ($Required -and [string]::IsNullOrWhiteSpace($resolved)) {
            throw 'GitHub authentication required. Set GH_TOKEN/GITHUB_TOKEN, authenticate gh, or store github.com credentials via Git Credential Manager. No token was found.'
        }
        if ([string]::IsNullOrWhiteSpace($resolved)) { return $null }
        return [string]$resolved
    }

    # Explicit caller env always wins.
    if ($env:GH_TOKEN) {
        Set-RdGitHubTokenProcessCache ([string]$env:GH_TOKEN)
        return [string]$env:GH_TOKEN
    }
    if ($env:GITHUB_TOKEN) {
        Set-RdGitHubTokenProcessCache ([string]$env:GITHUB_TOKEN)
        return [string]$env:GITHUB_TOKEN
    }

    if (-not $script:RdGitHubTokenCacheResolved) {
        $token = Get-RdGitHubTokenFromGh
        if (-not $token) { $token = Get-RdGitHubTokenFromGitCredential }
        Set-RdGitHubTokenProcessCache $token
    }

    if ($Required -and [string]::IsNullOrWhiteSpace($script:RdGitHubTokenCache)) {
        throw 'GitHub authentication required. Set GH_TOKEN/GITHUB_TOKEN, authenticate gh, or store github.com credentials via Git Credential Manager. No token was found.'
    }
    return $script:RdGitHubTokenCache
}

function Get-RdGitHubAuthHint {
    'GitHub API authentication required or rate limit hit. Set GH_TOKEN/GITHUB_TOKEN, run "gh auth login", then re-run. Anonymous quota is 60 requests/hour.'
}

function Test-RdGitHubRateLimitError {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, $Exception)
    if ($Message -match '(?i)rate limit|API rate limit exceeded|secondary rate limit') { return $true }
    try {
        $response = $Exception.Response
        if ($null -eq $response) { return $false }
        $code = [int]$response.StatusCode
        return ($code -eq 403 -or $code -eq 429)
    } catch {
        return $false
    }
}

function Clear-RdGitHubTokenProcessCache {
    $script:RdGitHubTokenCache = $null
    $script:RdGitHubTokenCacheResolved = $false
    Remove-Item Env:RD_GITHUB_TOKEN_RESOLVED -ErrorAction SilentlyContinue
    Remove-Item Env:RD_GITHUB_TOKEN -ErrorAction SilentlyContinue
}

function Request-RdGitHubAuthentication {
    # Opt out for CI / tests: RD_GITHUB_AUTH_PROMPT=0
    if ($env:RD_GITHUB_AUTH_PROMPT -eq '0') { return $false }
    if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true') { return $false }
    if ($env:RD_BOOTSTRAP_UNITTEST -eq '1') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Host 'Install GitHub CLI (gh), run "gh auth login", or set GH_TOKEN / GITHUB_TOKEN, then re-run.' -ForegroundColor Yellow
        return $false
    }

    try {
        $answer = Read-Host 'Anonymous GitHub API quota is exhausted. Run "gh auth login" now? [y/N]'
    } catch {
        return $false
    }
    if ($answer -notmatch '^(?i:y|yes)$') { return $false }

    & $gh.Source auth login
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'gh auth login did not complete successfully.' -ForegroundColor Yellow
        return $false
    }

    Clear-RdGitHubTokenProcessCache
    $token = Get-RdGitHubToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host 'gh auth login finished, but no token was available to this process yet. Re-run the script.' -ForegroundColor Yellow
        return $false
    }
    Write-Host 'GitHub auth: using token from gh (authenticated API rate limit).'
    return $true
}

function Write-RdGitHubAuthStatus {
    [CmdletBinding()]
    param()
    # Env flag survives parallel runspaces; script flag covers same-runspace repeats.
    if ($script:RdGitHubAuthStatusWritten -or $env:RD_GITHUB_AUTH_STATUS_WRITTEN -eq '1') { return }
    $script:RdGitHubAuthStatusWritten = $true
    $env:RD_GITHUB_AUTH_STATUS_WRITTEN = '1'

    $token = Get-RdGitHubToken
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        Write-Host 'GitHub auth: using token (authenticated API rate limit).'
        return
    }

    $remaining = $null
    $limit = 60
    try {
        $core = (Invoke-RdJsonRequest -Uri 'https://api.github.com/rate_limit' -Token $null).resources.core
        if ($null -ne $core) {
            $remaining = [int]$core.remaining
            $limit = [int]$core.limit
        }
    } catch {
        # Best-effort status only.
    }

    if ($null -ne $remaining) {
        Write-Host "GitHub auth: no token available; anonymous API calls remaining $remaining/$limit."
    } else {
        Write-Host 'GitHub auth: no token available; anonymous API limit is 60/hour (could not query remaining).'
    }

    $exhausted = ($null -eq $remaining) -or ($remaining -le 0)
    if (-not $exhausted) { return }

    Write-Host (Get-RdGitHubAuthHint) -ForegroundColor Yellow
    if (Request-RdGitHubAuthentication) { return }
}

function Invoke-RdJsonRequest {
    param([Parameter(Mandatory)][string]$Uri, [string]$Token)
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'rust-dependencies-toolkit' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    try {
        Invoke-RestMethod -Uri $Uri -Headers $headers
    } catch {
        $message = [string]$_.Exception.Message
        if ((-not $Token) -and (Test-RdGitHubRateLimitError -Message $message -Exception $_.Exception)) {
            throw "$(Get-RdGitHubAuthHint) Failed requesting '$Uri': $message"
        }
        throw
    }
}

function Save-RdUri {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination, [string]$Token, [switch]$Api)
    $headers = @{ 'User-Agent' = 'rust-dependencies-toolkit' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    if ($Api) { $headers.Accept = 'application/octet-stream' }
    try {
        Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $Destination
    } catch {
        $message = [string]$_.Exception.Message
        if ((-not $Token) -and (Test-RdGitHubRateLimitError -Message $message -Exception $_.Exception)) {
            throw "$(Get-RdGitHubAuthHint) Failed downloading '$Uri': $message"
        }
        throw
    }
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
        [ValidateSet('Production', 'Staging')][string]$Channel = 'Production',
        [switch]$AllowLegacyUrlName
    )
    $url = Get-RdProperty $Descriptor 'url'
    if ($url) {
        $name = Get-RdProperty $Descriptor 'assetName'
        if (-not $name -and $AllowLegacyUrlName) { $name = Get-RdProperty $Descriptor 'name' }
        if (-not $name) { $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath) }
        if (-not $name) { throw 'URL release descriptors with no filename in the path require assetName.' }
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
    param([Parameter(Mandatory)][string]$RelativePath)
    $normalizedRelativePath = $RelativePath.Replace('\', '/')
    $patterns = @(
        '*.so', '*.dylib', '*.a', '*.lib', '*.exe',
        '*/native/*', '*/runtimes/*/native/*', '*/win-x64/*', '*/linux-x64/*'
    )
    foreach ($pattern in $patterns) {
        if ($normalizedRelativePath -like $pattern -or ([IO.Path]::GetFileName($normalizedRelativePath) -like $pattern)) { return $true }
    }
    return $false
}

function Get-RdChannelFolder {
    param([Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel)
    switch ($Channel) {
        Production { return 'main' }
        Staging { return 'staging' }
    }
}

function Get-RdSelectedFrameworkFolders {
    param([Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework)
    switch ($Framework) {
        Oxide { return @('oxide') }
        Carbon { return @('carbon') }
        # Include vanilla rust/ so kitchen-sink downloads (all / rust+oxide+carbon)
        # can switch between vanilla, Oxide, and Carbon without a second pass.
        Both { return @('oxide', 'carbon', 'rust') }
        Rust { return @('rust') }
    }
}

function Get-RdModdingFrameworkFolders {
    param([Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework)
    switch ($Framework) {
        Oxide { return @('oxide') }
        Carbon { return @('carbon') }
        Both { return @('oxide', 'carbon') }
        Rust { return @() }
    }
}

function Resolve-RdChannelOutputRoot {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel
    )
    return (Join-Path $Output (Get-RdChannelFolder $Channel))
}

function Resolve-RdFrameworkOutputRoot {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)]$Platform,
        [Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('oxide', 'carbon', 'rust')][string]$FrameworkFolder
    )
    return (Join-Path (Resolve-RdChannelOutputRoot $Output $Channel) "$($Platform.Folder)/$FrameworkFolder")
}

function Get-RdItemFrameworkFolders {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework,
        [Parameter(Mandatory)][string]$Label
    )
    $property = $Item.PSObject.Properties['frameworks']
    if ($null -eq $property) {
        # Shared public/private/nuget deps overlay Oxide/Carbon only — never the
        # vanilla rust/ leaf (that stays Steam-managed DLLs only).
        $modding = @(Get-RdModdingFrameworkFolders $Framework)
        if ($modding.Count -gt 0) { return $modding }
        return @(Get-RdSelectedFrameworkFolders $Framework)
    }
    if ($Framework -eq 'Rust') { return @() }
    if ($property.Value -is [string]) { throw "$Label frameworks must be a JSON array containing Oxide and/or Carbon." }
    $declared = @($property.Value)
    if ($declared.Count -eq 0) { throw "$Label frameworks cannot be empty; omit the property for a shared dependency." }
    $normalized = [Collections.Generic.List[string]]::new()
    foreach ($value in $declared) {
        $name = [string]$value
        if ($name -notin 'Oxide', 'Carbon') { throw "$Label has unsupported framework '$name'. Expected Oxide or Carbon." }
        $folder = $name.ToLowerInvariant()
        if (-not $normalized.Contains($folder)) { $normalized.Add($folder) }
    }
    if ($Framework -eq 'Both') { return @($normalized) }
    $selected = $Framework.ToLowerInvariant()
    if ($normalized.Contains($selected)) { return @($selected) }
    return @()
}

function Copy-RdManagedDlls {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$IncludeRoots = @()
    )
    if (-not (Test-Path -LiteralPath $Source)) { throw "Expected extracted source '$Source' was not found." }
    $files = @(
        Get-ChildItem -LiteralPath $Source -Recurse -File -Filter '*.dll' |
            Sort-Object { $_.FullName.Replace('\', '/') } -CaseSensitive
    )
    if ($IncludeRoots.Count) {
        $files = @($files | Where-Object {
            $relative = [IO.Path]::GetRelativePath($Source, $_.FullName).Replace('\', '/')
            foreach ($root in $IncludeRoots) { if ($relative -like "$root/*" -or $relative -eq $root) { return $true } }
            return $false
        })
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $copied = 0
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        if (Test-RdExcluded $relative) { continue }
        # Flat overlay: same filename from a later provider overwrites earlier copies.
        $target = Join-Path $Destination $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }
    if ($copied -eq 0) { throw "No eligible managed DLLs found under '$Source' after exclusions." }
}

function Invoke-RdDownloadDescriptor {
    param(
        $Descriptor,
        [string]$Destination,
        [string]$Token,
        [string]$Channel = 'Production',
        [switch]$AllowLegacyUrlName
    )
    $resolved = Resolve-RdReleaseAsset -Descriptor $Descriptor -Token $Token -Channel $Channel -AllowLegacyUrlName:$AllowLegacyUrlName
    $archive = Join-Path $Destination $resolved.Name
    $assetToken = if ($resolved.Api) { $Token } else { $null }
    Save-RdUri -Uri $resolved.Url -Destination $archive -Token $assetToken -Api:$resolved.Api
    return $archive
}

function Set-RdLinuxExecutablePermission {
    param([Parameter(Mandatory)][string]$Path)
    $chmod = Get-Command chmod -ErrorAction SilentlyContinue
    if (-not $chmod) { throw "The Linux executable '$Path' is not executable and chmod was not found on PATH." }
    & $chmod.Source 'u+x' '--' $Path
    if ($LASTEXITCODE -ne 0) { throw "Failed to make Linux executable '$Path' (chmod exit $LASTEXITCODE)." }
}

function New-RdDepotDownloaderCommand {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$HostPlatform
    )
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "DepotDownloader path '$resolved' must point to a file."
    }
    $extension = [IO.Path]::GetExtension($resolved)
    if ($extension -ieq '.dll') {
        return [pscustomobject]@{ Path = $resolved; Mode = 'Dotnet' }
    }
    if ($HostPlatform -eq 'Windows' -and $extension -ine '.exe') {
        throw "Configured Windows DepotDownloader '$resolved' must be DepotDownloader.exe or a .dll distribution."
    }
    if ($HostPlatform -eq 'Linux' -and $extension) {
        throw "Configured Linux DepotDownloader '$resolved' must be the extensionless host executable or a .dll distribution."
    }
    if ($HostPlatform -eq 'Linux') { Set-RdLinuxExecutablePermission $resolved }
    return [pscustomobject]@{ Path = $resolved; Mode = 'Executable' }
}

function Get-RdDepotDownloader {
    param($Manifest, $Platform, [string]$Temp)
    $descriptor = [pscustomobject]@{
        repo = 'SteamRE/DepotDownloader'
        assetPattern = "DepotDownloader.*$($Platform.HostAsset)\.zip"
    }
    $token = Get-RdGitHubToken
    $archive = Invoke-RdDownloadDescriptor $descriptor $Temp $token
    $extract = Join-Path $Temp 'depotdownloader'
    Expand-RdArchive $archive $extract
    $candidateNames = if ($Platform.Host -eq 'Windows') {
        @('DepotDownloader.exe', 'DepotDownloader.dll')
    } else {
        @('DepotDownloader', 'DepotDownloader.dll')
    }
    foreach ($candidateName in $candidateNames) {
        $candidate = Get-ChildItem -LiteralPath $extract -Recurse -File |
            Where-Object Name -CEQ $candidateName |
            Select-Object -First 1
        if ($candidate) {
            return New-RdDepotDownloaderCommand -Path $candidate.FullName -HostPlatform $Platform.Host
        }
    }
    throw "Downloaded DepotDownloader $($Platform.HostAsset) archive contained none of the supported host files: $($candidateNames -join ', ')."
}

function Get-RdSteamFileList {
    return @((Get-RdBuiltinSteamConfig).fileList)
}

function Write-RdSteamFileList {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Entries)
    # DepotDownloader consumes one include rule per line. Explicit no-BOM UTF-8
    # behaves consistently on PowerShell 7 across Windows and Linux hosts.
    [IO.File]::WriteAllLines($Path, $Entries, [Text.UTF8Encoding]::new($false))
}

function Invoke-RdDepotDownloaderProcess {
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureContext
    )
    Write-Verbose "Running DepotDownloader for $FailureContext"
    Write-Verbose "DepotDownloader command: $CommandPath $($Arguments -join ' ')"
    & $CommandPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "DepotDownloader failed for $FailureContext (exit $LASTEXITCODE)." }
}

function Resolve-RdDepotDownloaderInvocation {
    param([Parameter(Mandatory)]$Downloader)
    if ($Downloader.Mode -eq 'Executable') {
        return [pscustomobject]@{ CommandPath = $Downloader.Path; PrefixArguments = @() }
    }
    if ($Downloader.Mode -eq 'Dotnet') {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) { throw "dotnet is required to run DepotDownloader DLL '$($Downloader.Path)' but was not found on PATH." }
        return [pscustomobject]@{ CommandPath = $dotnet.Source; PrefixArguments = @($Downloader.Path) }
    }
    throw "Unsupported DepotDownloader command mode '$($Downloader.Mode)'. Expected Executable or Dotnet."
}

function Resolve-RdRustManagedDirectory {
    param([Parameter(Mandatory)][string]$InstallPath)
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container)) {
        throw "Rust depot output directory '$InstallPath' was not created."
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $InstallPath -Directory -Recurse |
            Where-Object {
                $relative = [IO.Path]::GetRelativePath($InstallPath, $_.FullName).Replace('\', '/')
                $components = @($relative -split '/')
                $isMetadata = $components -contains '.DepotDownloader'
                $isRustManaged = $relative -match '(^|/)RustDedicated_Data/Managed$'
                $hasDll = $null -ne (Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.dll' | Select-Object -First 1)
                -not $isMetadata -and $isRustManaged -and $hasDll
            } |
            Sort-Object { $_.FullName.Replace('\', '/') } -CaseSensitive
    )
    if ($candidates.Count -eq 0) {
        throw "No real RustDedicated_Data/Managed directory containing DLL files was found under '$InstallPath'. .DepotDownloader metadata paths are intentionally ignored."
    }
    if ($candidates.Count -gt 1) {
        $relativeCandidates = @($candidates | ForEach-Object {
            [IO.Path]::GetRelativePath($InstallPath, $_.FullName).Replace('\', '/')
        })
        throw "Multiple real Rust Managed directories containing DLL files were found under '$InstallPath': $($relativeCandidates -join ', '). Refusing ambiguous selection."
    }
    return $candidates[0]
}

function Invoke-RdRust {
    param(
        $Manifest,
        $Platform,
        [string]$Channel,
        [string]$Output,
        [string]$Temp,
        [ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework = 'Both'
    )
    $steam = Get-RdBuiltinSteamConfig
    $appId = [string]$steam.appId
    $depotId = [string](Get-RdProperty $steam.depots $Platform.Server)
    $branch = [string](Get-RdProperty $steam.branches $Channel)
    $fileListEntries = @(Get-RdSteamFileList)
    $fileListPath = Join-Path $Temp 'rust-managed-dlls.filelist.txt'
    Write-RdSteamFileList -Path $fileListPath -Entries $fileListEntries
    $hostLabel = if ($Platform.PSObject.Properties['HostAsset']) { $Platform.HostAsset } else { $Platform.Host }
    Write-Verbose "Acquiring DepotDownloader for host $hostLabel"
    $downloader = Get-RdDepotDownloader $Manifest $Platform $Temp
    $invocation = Resolve-RdDepotDownloaderInvocation $downloader
    $install = Join-Path $Temp 'rust-server'
    # DepotDownloader defaults to Steam anonymous login when no username is
    # supplied. Omitting credentials is the documented noninteractive path.
    $args = @($invocation.PrefixArguments) + @('-app', $appId, '-depot', $depotId, '-dir', $install, '-filelist', $fileListPath)
    if ($branch -and $branch -ne 'public') { $args += @('-branch', $branch) }
    Invoke-RdDepotDownloaderProcess -CommandPath $invocation.CommandPath -Arguments $args -FailureContext "app $appId depot $depotId branch $branch"
    $managed = Resolve-RdRustManagedDirectory $install
    foreach ($frameworkFolder in Get-RdSelectedFrameworkFolders $Framework) {
        $destination = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $frameworkFolder
        Write-Verbose "Overlaying Rust managed DLLs into '$destination'"
        Copy-RdManagedDlls $managed.FullName $destination
    }
}

function Resolve-RdFrameworkDescriptor {
    param([string]$Name, $Manifest, $Platform, [string]$Channel)
    if ($Name -eq 'carbon') {
        $tag = if ($Channel -eq 'Production') { 'production_build' } else { 'rustbeta_staging_build' }
        $target = if ($Channel -eq 'Production') { 'Release' } else { 'Debug' }
        $asset = if ($Platform.Server -eq 'Windows') { "Carbon.Windows.$target.zip" } else { "Carbon.Linux.$target.tar.gz" }
        return [pscustomobject]@{ repo = 'CarbonCommunity/Carbon'; tag = $tag; asset = $asset }
    }
    if ($Name -eq 'oxide' -and $Channel -eq 'Production') {
        $asset = if ($Platform.Server -eq 'Windows') { 'Oxide.Rust.zip' } else { 'Oxide.Rust-linux.zip' }
        return [pscustomobject]@{ repo = 'OxideMod/Oxide.Rust'; asset = $asset }
    }
    if ($Name -eq 'oxide' -and $Channel -eq 'Staging') {
        $asset = if ($Platform.Server -eq 'Windows') { 'Oxide.Rust.zip' } else { 'Oxide.Rust-linux.zip' }
        return [pscustomobject]@{
            url = "https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/$asset"
            assetName = $asset
        }
    }
    throw "No $Name asset configured for channel '$Channel' and target '$($Platform.Server)'."
}

function Resolve-RdFrameworkManagedDirectory {
    param(
        [Parameter(Mandatory)][ValidateSet('oxide', 'carbon')][string]$Name,
        [Parameter(Mandatory)][string]$ExtractPath
    )
    if ($Name -eq 'carbon') {
        return Select-RdUniqueDirectory -Root $ExtractPath -Filter {
            $_.FullName.Replace('\', '/') -match '/carbon/managed$'
        } -NoneMessage "Carbon archive does not contain carbon/managed." `
            -AmbiguousMessage "Multiple carbon/managed directories were found under '$ExtractPath':"
    }
    return Select-RdUniqueDirectory -Root $ExtractPath -Filter {
        $_.Name -eq 'Managed'
    } -NoneMessage "Oxide archive does not contain a Managed directory." `
        -AmbiguousMessage "Multiple Managed directories were found under '$ExtractPath':"
}

function Invoke-RdFramework {
    param([string]$Name, $Manifest, $Platform, [string]$Channel, [string]$Output, [string]$Temp)
    Write-Verbose "Downloading $Name $Channel asset for $($Platform.Server)"
    $descriptor = Resolve-RdFrameworkDescriptor $Name $Manifest $Platform $Channel
    $token = Get-RdGitHubToken
    $archive = Invoke-RdDownloadDescriptor $descriptor $Temp $token $Channel
    $extract = Join-Path $Temp "$Name-extracted"
    Expand-RdArchive $archive $extract
    $managed = Resolve-RdFrameworkManagedDirectory -Name $Name -ExtractPath $extract
    $destination = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $Name
    Write-Verbose "Overlaying $Name managed DLLs into '$destination'"
    Copy-RdManagedDlls $managed.FullName $destination
}

function Invoke-RdReleaseCollection {
    param(
        [string]$Kind,
        $Manifest,
        $Platform,
        [ValidateSet('Production', 'Staging')][string]$Channel,
        [string]$Output,
        [string]$Temp,
        [ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework
    )
    $collection = Get-RdProperty $Manifest $Kind
    if (-not $collection) { return }
    $selectedItems = [Collections.Generic.List[object]]::new()
    foreach ($item in @($collection)) {
        $name = [string](Get-RdProperty $item 'name')
        if (-not $name) { throw "$Kind entries require a name." }
        Assert-RdSafeSegment $name "$Kind name"
        $folders = @(Get-RdItemFrameworkFolders $item $Framework "$Kind entry '$name'")
        if ($folders.Count -gt 0) {
            $selectedItems.Add([pscustomobject]@{ Item = $item; Name = $name; Folders = $folders })
        }
    }
    if ($selectedItems.Count -eq 0) { return }
    $private = $Kind -eq 'privateReleases'
    $token = if ($private) { Get-RdGitHubToken -Required } else { Get-RdGitHubToken }
    foreach ($selectedItem in $selectedItems) {
        $item = $selectedItem.Item
        $name = $selectedItem.Name
        $releaseProperty = $item.PSObject.Properties['release']
        $descriptor = if ($null -ne $releaseProperty) { $releaseProperty.Value } else { $item }
        Write-Verbose "Downloading $Kind entry '$name'"
        $asset = Invoke-RdDownloadDescriptor $descriptor $Temp $token -AllowLegacyUrlName:($null -ne $releaseProperty)
        if ([IO.Path]::GetExtension($asset) -ieq '.dll') {
            $assetName = [IO.Path]::GetFileName($asset)
            if (Test-RdExcluded $assetName) { throw "Direct DLL asset '$assetName' is excluded." }
            foreach ($folder in $selectedItem.Folders) {
                $destination = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $folder
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Write-Verbose "Overlaying $Kind '$name' DLL into '$destination'"
                Copy-Item -LiteralPath $asset -Destination (Join-Path $destination $assetName) -Force
            }
        } else {
            $extract = Join-Path $Temp "release-$name"
            Expand-RdArchive $asset $extract
            foreach ($folder in $selectedItem.Folders) {
                $destination = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $folder
                Write-Verbose "Overlaying $Kind '$name' archive DLLs into '$destination'"
                Copy-RdManagedDlls $extract $destination
            }
        }
    }
}

function Invoke-RdNuGetCollection {
    param(
        $Manifest,
        $Platform,
        [ValidateSet('Production', 'Staging')][string]$Channel,
        [string]$Output,
        [string]$Temp,
        [ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework
    )
    $packages = Get-RdProperty $Manifest 'githubNuget'
    if (-not $packages) { return }
    $selectedPackages = [Collections.Generic.List[object]]::new()
    foreach ($package in @($packages)) {
        $name = [string](Get-RdProperty $package 'name')
        $source = [string](Get-RdProperty $package 'source')
        if (-not $name -or -not $source) { throw 'githubNuget entries require name and source.' }
        Assert-RdSafeSegment $name 'NuGet package name'
        $folders = @(Get-RdItemFrameworkFolders $package $Framework "githubNuget entry '$name'")
        if ($folders.Count -gt 0) {
            $selectedPackages.Add([pscustomobject]@{ Package = $package; Name = $name; Source = $source; Folders = $folders })
        }
    }
    if ($selectedPackages.Count -eq 0) { return }
    $token = Get-RdGitHubToken -Required
    foreach ($selectedPackage in $selectedPackages) {
        $package = $selectedPackage.Package
        $name = $selectedPackage.Name
        $source = $selectedPackage.Source
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
        Write-Verbose "Downloading NuGet package '$name' version $version"
        $nupkg = Join-Path $Temp "$id.$version.nupkg"
        Invoke-WebRequest -Uri "$($base.TrimEnd('/'))/$id/$version/$id.$version.nupkg" -Headers $headers -OutFile $nupkg
        $extract = Join-Path $Temp "nuget-$id"
        Expand-RdArchive $nupkg $extract
        foreach ($folder in $selectedPackage.Folders) {
            $destination = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $folder
            Write-Verbose "Overlaying NuGet package '$name' into '$destination'"
            Copy-RdManagedDlls $extract $destination -IncludeRoots @('lib', 'ref')
        }
    }
}

function Get-RdPublicizerModes {
    param([ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework)
    switch ($Framework) {
        Oxide { return @('Oxide') }
        Carbon { return @('Carbon') }
        Both { return @('Oxide', 'Carbon') }
        Rust { return @() }
    }
}

function Resolve-RdPublicizerCommand {
    $moduleRoot = $PSScriptRoot
    $repoRoot = Split-Path -Parent $moduleRoot
    $rid = if ($IsWindows) { 'win-x64' } elseif ($IsLinux) { 'linux-x64' } else {
        throw 'Unsupported host OS for RdPublicizer.'
    }
    $publishedDir = Join-Path $repoRoot 'tools' 'RdPublicizer' 'bin' $rid
    $exeName = if ($IsWindows) { 'RdPublicizer.exe' } else { 'RdPublicizer' }
    $exePath = Join-Path $publishedDir $exeName
    if (Test-Path -LiteralPath $exePath -PathType Leaf) {
        if ($IsLinux) { Set-RdLinuxExecutablePermission $exePath }
        return [pscustomobject]@{ CommandPath = $exePath; PrefixArguments = @() }
    }
    $dllPath = Join-Path $publishedDir 'RdPublicizer.dll'
    if (Test-Path -LiteralPath $dllPath -PathType Leaf) {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) { throw "dotnet is required to run RdPublicizer DLL '$dllPath' but was not found on PATH." }
        return [pscustomobject]@{ CommandPath = $dotnet.Source; PrefixArguments = @($dllPath) }
    }
    $projectPath = Join-Path $repoRoot 'tools' 'RdPublicizer' 'RdPublicizer.csproj'
    if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) { throw "dotnet is required to run RdPublicizer from source but was not found on PATH." }
        return [pscustomobject]@{
            CommandPath = $dotnet.Source
            PrefixArguments = @('run', '--project', $projectPath, '-c', 'Release', '--')
            ProjectPath = $projectPath
        }
    }
    throw "RdPublicizer was not found under '$publishedDir' and tools/RdPublicizer/RdPublicizer.csproj is missing."
}

function Invoke-RdPublicizer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ManagedDirectory,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon')][string]$Mode
    )
    if (-not (Test-Path -LiteralPath $ManagedDirectory -PathType Container)) {
        throw "Managed directory '$ManagedDirectory' was not found. Download dependencies before publicizing."
    }
    $command = Resolve-RdPublicizerCommand
    $args = @($command.PrefixArguments) + @('--mode', $Mode, '--input', $ManagedDirectory, '--output', $OutputDirectory)
    if (-not $PSCmdlet.ShouldProcess("$Mode publicize -> $OutputDirectory", 'Invoke RdPublicizer')) { return }
    Write-Verbose "Publicizing Rust managed DLLs with $Mode rules into '$OutputDirectory'"
    & $command.CommandPath @args
    if ($LASTEXITCODE -ne 0) { throw "RdPublicizer failed for mode '$Mode' (exit $LASTEXITCODE)." }
}

function Remove-RdDeletedDlls {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)]$Platform,
        [Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework
    )
    $names = @($Manifest.deleteDlls)
    if ($names.Count -eq 0) { return }
    foreach ($frameworkFolder in Get-RdSelectedFrameworkFolders $Framework) {
        $root = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $frameworkFolder
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($name in $names) {
            $fileName = [string]$name
            $path = Join-Path $root $fileName
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ($PSCmdlet.ShouldProcess($path, 'Delete conflicting dependency DLL')) {
                Remove-Item -LiteralPath $path -Force
                Write-Verbose "Deleted '$fileName' from '$root'"
            }
        }
    }
}

function Invoke-RdPublicizeOutput {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)]$Platform,
        [Parameter(Mandatory)][ValidateSet('Production', 'Staging')][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework
    )
    foreach ($mode in Get-RdPublicizerModes $Framework) {
        $frameworkFolder = $mode.ToLowerInvariant()
        $managed = Resolve-RdFrameworkOutputRoot $Output $Platform $Channel $frameworkFolder
        if (-not (Test-Path -LiteralPath $managed -PathType Container)) {
            throw "Framework root '$managed' was not found. Download dependencies before publicizing."
        }
        # RdPublicizer clears its output directory; write to temp then overlay so
        # publicized assemblies replace the flat-root originals in place.
        $temp = Join-Path ([IO.Path]::GetTempPath()) "rd-publicize-$frameworkFolder-$([guid]::NewGuid().ToString('N'))"
        try {
            if (-not $PSCmdlet.ShouldProcess($managed, "Publicize $mode assemblies in place")) { continue }
            Invoke-RdPublicizer -ManagedDirectory $managed -OutputDirectory $temp -Mode $mode
            $written = @(Get-ChildItem -LiteralPath $temp -File -Filter '*.dll' -ErrorAction SilentlyContinue)
            if ($written.Count -eq 0) {
                throw "RdPublicizer produced no assemblies for mode '$mode' under '$managed'."
            }
            foreach ($file in $written) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $managed $file.Name) -Force
            }
            Write-Verbose "Overlaid $($written.Count) publicized $mode DLL(s) into '$managed'"
        }
        finally {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-RustDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform = $(if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } else { throw 'Unsupported host OS.' }),
        [ValidateSet('Production', 'Staging')][string]$Channel = 'Production',
        [ValidateSet('Oxide', 'Carbon', 'Both', 'Rust')][string]$Framework = 'Both',
        [ValidateSet('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet')][string[]]$Provider = @('Rust', 'Oxide', 'Carbon', 'Public', 'Private', 'NuGet'),
        [switch]$ClearOutput,
        [switch]$Publicize
    )
    Write-RdGitHubAuthStatus
    if ($ServerPlatform -eq 'All') {
        $index = 0
        foreach ($target in @('Windows', 'Linux')) {
            $invoke = @{
                ManifestPath = $ManifestPath
                ServerPlatform = $target
                Channel = $Channel
                Framework = $Framework
                Provider = $Provider
                ClearOutput = ($ClearOutput -and $index -eq 0)
                Publicize = $Publicize
            }
            if ($WhatIfPreference) { $invoke.WhatIf = $true }
            Invoke-RustDependencies @invoke
            $index++
        }
        return
    }

    $manifest = Read-RdManifest $ManifestPath
    $platform = Resolve-RdPlatform -ServerPlatform $ServerPlatform
    $output = Resolve-RdOutputPath $manifest
    $channelRoot = Resolve-RdChannelOutputRoot $output $Channel
    $modes = @(Get-RdPublicizerModes $Framework)
    $frameworkFolders = @(Get-RdSelectedFrameworkFolders $Framework)
    $effectiveProviders = [Collections.Generic.List[string]]::new()
    foreach ($selected in @($Provider)) { $effectiveProviders.Add($selected) }
    if (('Oxide' -in $effectiveProviders -or 'Carbon' -in $effectiveProviders) -and 'Rust' -notin $effectiveProviders) {
        $effectiveProviders.Insert(0, 'Rust')
    }
    $rootsToRebuild = [Collections.Generic.List[string]]::new()
    if ('Rust' -in $effectiveProviders) {
        foreach ($folder in $frameworkFolders) { $rootsToRebuild.Add($folder) }
    } else {
        if ('Oxide' -in $effectiveProviders -and $frameworkFolders -contains 'oxide') { $rootsToRebuild.Add('oxide') }
        if ('Carbon' -in $effectiveProviders -and $frameworkFolders -contains 'carbon') { $rootsToRebuild.Add('carbon') }
    }
    $planParts = [Collections.Generic.List[string]]::new()
    $planParts.AddRange([string[]]@(
        "ServerPlatform=$($platform.Server)"
        "Channel=$Channel"
        "Framework=$Framework"
        "Providers=$($effectiveProviders -join ',')"
        "Output=$channelRoot"
        "ClearOutput=$([bool]$ClearOutput)"
        "Publicize=$([bool]$Publicize)"
    ))
    if ($Publicize) { $planParts.Add("PublicizerModes=$($modes -join ',')") }
    $plan = $planParts -join '; '
    if ($WhatIfPreference) {
        Write-Host "WhatIf: would run Invoke-RustDependencies with $plan"
        if ($ClearOutput) {
            Write-Host "WhatIf: would clear channel output directory '$channelRoot'"
        } elseif ($rootsToRebuild.Count -gt 0) {
            foreach ($folder in $rootsToRebuild) {
                $root = Resolve-RdFrameworkOutputRoot $output $platform $Channel $folder
                Write-Host "WhatIf: would clear framework root '$root'"
            }
        }
        foreach ($name in @($manifest.deleteDlls)) {
            foreach ($folder in $frameworkFolders) {
                $root = Resolve-RdFrameworkOutputRoot $output $platform $Channel $folder
                Write-Host "WhatIf: would delete '$name' from '$root' if present"
            }
        }
        if ($Publicize) {
            foreach ($mode in $modes) {
                $frameworkFolder = $mode.ToLowerInvariant()
                $managed = Resolve-RdFrameworkOutputRoot $output $platform $Channel $frameworkFolder
                Write-Host "WhatIf: would publicize '$managed' with $mode rules and overlay publicized DLLs in place"
            }
        }
        return
    }
    if ($ClearOutput) {
        Clear-RdOutput $channelRoot
    } else {
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        foreach ($folder in $rootsToRebuild) {
            Clear-RdProviderSubtree (Resolve-RdFrameworkOutputRoot $output $platform $Channel $folder)
        }
    }
    Write-Verbose "Invoke-RustDependencies: $plan"
    $temp = Join-Path ([IO.Path]::GetTempPath()) "rust-dependencies-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        foreach ($selected in $effectiveProviders) {
            $providerTemp = Join-Path $temp $selected
            New-Item -ItemType Directory -Path $providerTemp -Force | Out-Null
            Write-Verbose "Running provider '$selected'"
            switch ($selected) {
                Rust { Invoke-RdRust $manifest $platform $Channel $output $providerTemp $Framework }
                Oxide { if ($Framework -in 'Oxide', 'Both') { Invoke-RdFramework 'oxide' $manifest $platform $Channel $output $providerTemp } }
                Carbon { if ($Framework -in 'Carbon', 'Both') { Invoke-RdFramework 'carbon' $manifest $platform $Channel $output $providerTemp } }
                Public { Invoke-RdReleaseCollection 'publicReleases' $manifest $platform $Channel $output $providerTemp $Framework }
                Private { Invoke-RdReleaseCollection 'privateReleases' $manifest $platform $Channel $output $providerTemp $Framework }
                NuGet { Invoke-RdNuGetCollection $manifest $platform $Channel $output $providerTemp $Framework }
            }
        }
        # Delete before publicize so RdPublicizer does not spend time on removed DLLs.
        Remove-RdDeletedDlls -Manifest $manifest -Output $output -Platform $platform -Channel $Channel -Framework $Framework
        if ($Publicize) {
            Invoke-RdPublicizeOutput -Output $output -Platform $platform -Channel $Channel -Framework $Framework
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Invoke-RustDependencies, Read-RdManifest, Resolve-RdPlatform, Resolve-RdOutputPath, Clear-RdOutput, Expand-RdArchive, Invoke-RdPublicizer, Write-RdGitHubAuthStatus
