#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath,
    [string]$StagingManifestPath,
    [ValidateSet('Windows', 'Linux', 'All')][string]$ServerPlatform,
    [switch]$Publicize
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    throw "ManifestPath is required. Pass -ManifestPath (bootstrap always supplies the project manifest)."
}
if ([string]::IsNullOrWhiteSpace($StagingManifestPath)) {
    $StagingManifestPath = $ManifestPath
}

$work = @(
    [pscustomobject]@{
        Label = 'production'
        ScriptPath = (Join-Path $PSScriptRoot 'rust+oxide+carbon.ps1')
        ManifestPath = $ManifestPath
    }
    [pscustomobject]@{
        Label = 'staging'
        ScriptPath = (Join-Path $PSScriptRoot 'rust-staging+oxide+carbon.ps1')
        ManifestPath = $StagingManifestPath
    }
)

$serverPlatform = $ServerPlatform
$usePublicize = [bool]$Publicize
$useWhatIf = [bool]$WhatIfPreference

Import-Module (Join-Path $PSScriptRoot '..' 'module' 'RustDependencies.psd1') -Force
Write-RdGitHubAuthStatus

Write-Host "Running production and staging in parallel..."
$results = @(
    $work | ForEach-Object -ThrottleLimit 2 -Parallel {
        $ErrorActionPreference = 'Stop'
        $label = $_.Label
        try {
            $invoke = @{ ManifestPath = $_.ManifestPath }
            if ($using:serverPlatform) { $invoke.ServerPlatform = $using:serverPlatform }
            if ($using:usePublicize) { $invoke.Publicize = $true }
            if ($using:useWhatIf) { $invoke.WhatIf = $true }
            Write-Host "Starting $label ($($_.ManifestPath))..."
            # Discard success-stream noise from child scripts so StrictMode result
            # aggregation only sees our channel outcome objects.
            $null = & $_.ScriptPath @invoke
            [pscustomobject]@{ RdChannelResult = $true; Label = $label; Ok = $true; ErrorMessage = $null }
        } catch {
            $message = $_.Exception.Message
            Write-Host "ERROR ($label): $message" -ForegroundColor Red
            [pscustomobject]@{ RdChannelResult = $true; Label = $label; Ok = $false; ErrorMessage = $message }
        }
    }
)

$channelResults = @($results | Where-Object { $_.PSObject.Properties['RdChannelResult'] -and $_.RdChannelResult })
if ($channelResults.Count -lt $work.Count) {
    throw "Parallel all download returned $($channelResults.Count) channel result(s); expected $($work.Count)."
}

$failed = @($channelResults | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
    $details = ($failed | ForEach-Object { "$($_.Label): $($_.ErrorMessage)" }) -join [Environment]::NewLine
    $hint = ''
    if ($details -match '(?i)rate limit|403') {
        $hint = [Environment]::NewLine + 'GitHub API rate limit hit. Set GH_TOKEN/GITHUB_TOKEN, run gh auth login, or ensure Git Credential Manager has github.com credentials.'
    }
    throw "Parallel all download failed:$([Environment]::NewLine)$details$hint"
}
