[CmdletBinding()]
param(
    [ValidateSet('Check', 'Install')]
    [string]$Mode = 'Check',

    [string]$Repository = 'ToxicOwl/american-dad-mumu-agent',
    [string]$AssetName = 'AmericanDadArena-Windows.zip',
    [string]$CurrentVersion = '1.4.0',
    [int]$ParentProcessId = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Get-LatestRelease {
    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $uri -Headers @{
            'User-Agent' = 'AmericanDadArena-Updater'
            'Accept' = 'application/vnd.github+json'
        } -ErrorAction Stop
    }
    catch {
        throw "Could not check GitHub releases for $Repository. $($_.Exception.Message)"
    }

    if ($release.draft -or $release.prerelease) { throw 'The latest GitHub release is not a stable public release.' }
    $tag = [string]$release.tag_name
    $normalizedTag = $tag.TrimStart([char[]]@('v', 'V'))
    [version]$latestVersion = $null
    if (-not [version]::TryParse($normalizedTag, [ref]$latestVersion)) {
        throw "Release tag '$tag' is not a valid version."
    }

    $asset = @($release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1)
    if ($asset.Count -ne 1) { throw "Release $tag does not contain required asset '$AssetName'." }

    return [PSCustomObject]@{
        Version = $latestVersion
        Tag = $tag
        Notes = [string]$release.body
        DownloadUrl = [string]$asset[0].browser_download_url
        PublishedAt = [string]$release.published_at
    }
}

function Wait-ForParentExit {
    if ($ParentProcessId -le 0) { return }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
        if ($null -eq $parent) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'The application did not close within 60 seconds. Update cancelled without replacing files.'
}

function Install-LatestRelease {
    param([Parameter(Mandatory = $true)]$Release)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('american-dad-update-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempRoot $AssetName
    $payloadPath = Join-Path $tempRoot 'payload'
    $backupPath = Join-Path $ProjectRoot ('backups\update-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

    try {
        New-Item -ItemType Directory -Path $tempRoot, $payloadPath, $backupPath -Force | Out-Null
        Write-Host "Downloading release $($Release.Tag)..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $Release.DownloadUrl -Headers @{ 'User-Agent' = 'AmericanDadArena-Updater' } -OutFile $zipPath -ErrorAction Stop
        if ((Get-Item -LiteralPath $zipPath).Length -lt 1024) { throw 'Downloaded update archive is unexpectedly small.' }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $payloadPath -Force
        $required = @('AmericanDadArena.exe', 'scripts\arena-cycle.ps1', 'scripts\update-agent.ps1', 'release.json')
        foreach ($relativePath in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $payloadPath $relativePath))) {
                throw "Update archive is missing required file: $relativePath"
            }
        }

        foreach ($protected in @('config.json', 'captures', 'logs', '.venv')) {
            if (Test-Path -LiteralPath (Join-Path $payloadPath $protected)) {
                throw "Unsafe update archive: it contains protected local path '$protected'."
            }
        }

        Wait-ForParentExit

        $oldExecutable = Join-Path $ProjectRoot 'AmericanDadArena.exe'
        if (Test-Path -LiteralPath $oldExecutable) {
            Copy-Item -LiteralPath $oldExecutable -Destination (Join-Path $backupPath 'AmericanDadArena.exe') -Force
        }
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'scripts')) {
            Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts') -Destination (Join-Path $backupPath 'scripts') -Recurse -Force
        }

        Get-ChildItem -LiteralPath $payloadPath -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ProjectRoot $_.Name) -Recurse -Force
        }

        $message = "Updated to $($Release.Tag). Backup: $backupPath"
        Write-Host $message -ForegroundColor Green
        Start-Process -FilePath (Join-Path $ProjectRoot 'AmericanDadArena.exe') -WorkingDirectory $ProjectRoot
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[version]$installedVersion = $null
if (-not [version]::TryParse($CurrentVersion, [ref]$installedVersion)) {
    throw "CurrentVersion '$CurrentVersion' is invalid."
}

$latest = Get-LatestRelease
$available = $latest.Version -gt $installedVersion

if ($Mode -eq 'Check') {
    [PSCustomObject]@{
        installed_version = $installedVersion.ToString()
        latest_version = $latest.Version.ToString()
        latest_tag = $latest.Tag
        update_available = $available
        notes = $latest.Notes
        published_at = $latest.PublishedAt
    } | ConvertTo-Json -Compress
    exit 0
}

if (-not $available) {
    Write-Host "Already up to date ($($installedVersion.ToString()))." -ForegroundColor Green
    exit 0
}

Install-LatestRelease -Release $latest
