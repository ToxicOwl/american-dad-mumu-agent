[CmdletBinding()]
param(
    [ValidateSet('CheckCurrent', 'CheckImage', 'StartSound', 'StopSound', 'PlaySound')]
    [string]$Mode = 'CheckCurrent',

    [string]$ImagePath,
    [string]$AdbPath,
    [string]$Device,
    [string]$SoundPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'config.json'
$TemplatePath = Join-Path $ProjectRoot 'assets\haptic-alert-header.png'
$CaptureDirectory = Join-Path $ProjectRoot 'captures\haptic-alert'
$LogPath = Join-Path $ProjectRoot 'logs\haptic-alert.jsonl'
$SoundPidPath = Join-Path $ProjectRoot 'logs\haptic-alert-sound.pid'

function Write-HapticLog {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{}
    )

    $directory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        event = $Event
        data = $Data
    }
    ($record | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Get-HapticSettings {
    $settings = [ordered]@{
        enabled = $true
        threshold = 0.90
        sound_path = (Join-Path $ProjectRoot 'assets\haptic-alert.wav')
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return [PSCustomObject]$settings }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($null -ne $config.PSObject.Properties['haptic_alert']) {
            $configured = $config.haptic_alert
            if ($null -ne $configured.PSObject.Properties['enabled']) { $settings.enabled = [bool]$configured.enabled }
            if ($null -ne $configured.PSObject.Properties['threshold']) { $settings.threshold = [double]$configured.threshold }
            if ($null -ne $configured.PSObject.Properties['sound_path'] -and -not [string]::IsNullOrWhiteSpace([string]$configured.sound_path)) {
                $candidate = [string]$configured.sound_path
                $settings.sound_path = if ([IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $ProjectRoot $candidate }
            }
        }
    }
    catch {
        Write-HapticLog -Event 'settings_read_warning' -Data @{ message = $_.Exception.Message }
    }

    if ($settings.threshold -lt 0.70 -or $settings.threshold -gt 0.99) { $settings.threshold = 0.90 }
    return [PSCustomObject]$settings
}

function Save-AdbScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $AdbPath
    $process.StartInfo.Arguments = "-s $Device exec-out screencap -p"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    [void]$process.Start()

    $stream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $process.StandardOutput.BaseStream.CopyTo($stream) }
    finally { $stream.Dispose() }

    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -lt 1024) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Haptic Alert screenshot failed: $stderr"
    }
}

function Get-HapticVisualScore {
    param(
        [Parameter(Mandatory = $true)][string]$ScreenshotPath,
        [Parameter(Mandatory = $true)][string]$HeaderTemplatePath
    )

    Add-Type -AssemblyName System.Drawing
    $screenshot = [Drawing.Bitmap]::FromFile($ScreenshotPath)
    $template = [Drawing.Bitmap]::FromFile($HeaderTemplatePath)
    try {
        # The template is the fixed blue header/title/close button only. It purposely
        # excludes the randomized haptic grid so changing squares cannot affect a match.
        $templateX = 388
        $templateY = 68
        if ($screenshot.Width -lt ($templateX + $template.Width) -or $screenshot.Height -lt ($templateY + $template.Height)) {
            return 0.0
        }

        [double]$totalDifference = 0
        [int]$sampleCount = 0
        for ($y = 0; $y -lt $template.Height; $y += 3) {
            for ($x = 0; $x -lt $template.Width; $x += 3) {
                $expected = $template.GetPixel($x, $y)
                $actual = $screenshot.GetPixel($templateX + $x, $templateY + $y)
                $totalDifference += [Math]::Abs($expected.R - $actual.R)
                $totalDifference += [Math]::Abs($expected.G - $actual.G)
                $totalDifference += [Math]::Abs($expected.B - $actual.B)
                $sampleCount++
            }
        }
        if ($sampleCount -eq 0) { return 0.0 }
        $normalizedDifference = $totalDifference / ($sampleCount * 3.0 * 255.0)
        return [Math]::Max(0.0, [Math]::Min(1.0, 1.0 - $normalizedDifference))
    }
    finally {
        $template.Dispose()
        $screenshot.Dispose()
    }
}

function Test-HapticAlertScreen {
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = Get-HapticSettings
    if (-not $settings.enabled) {
        return [PSCustomObject]@{ detected = $false; enabled = $false; score = 0.0; threshold = $settings.threshold; reason = 'disabled'; evidence_path = $Path }
    }
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Haptic Alert template is missing: $TemplatePath"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Haptic Alert image is missing: $Path"
    }

    $score = Get-HapticVisualScore -ScreenshotPath $Path -HeaderTemplatePath $TemplatePath
    $detected = $score -ge [double]$settings.threshold
    return [PSCustomObject]@{
        detected = [bool]$detected
        enabled = $true
        score = [Math]::Round($score, 4)
        threshold = [double]$settings.threshold
        reason = if ($detected) { 'fixed_header_matched' } else { 'fixed_header_not_matched' }
        evidence_path = $Path
    }
}

function Start-HapticSoundLoop {
    param([string]$RequestedSoundPath)

    $settings = Get-HapticSettings
    $audio = if ([string]::IsNullOrWhiteSpace($RequestedSoundPath)) { [string]$settings.sound_path } else { $RequestedSoundPath }
    if (-not [IO.Path]::IsPathRooted($audio)) { $audio = Join-Path $ProjectRoot $audio }
    if (-not (Test-Path -LiteralPath $audio)) {
        Write-HapticLog -Event 'sound_not_started' -Data @{ reason = 'missing_file'; sound_path = $audio }
        return [PSCustomObject]@{ started = $false; reason = 'sound_file_missing'; sound_path = $audio }
    }
    if ([IO.Path]::GetExtension($audio).ToLowerInvariant() -ne '.wav') {
        Write-HapticLog -Event 'sound_not_started' -Data @{ reason = 'wav_required'; sound_path = $audio }
        return [PSCustomObject]@{ started = $false; reason = 'wav_required'; sound_path = $audio }
    }

    if (Test-Path -LiteralPath $SoundPidPath) {
        $existingPid = Get-Content -LiteralPath $SoundPidPath -Raw
        $existing = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            return [PSCustomObject]@{ started = $true; reason = 'already_playing'; sound_path = $audio; process_id = $existing.Id }
        }
        Remove-Item -LiteralPath $SoundPidPath -Force -ErrorAction SilentlyContinue
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode PlaySound -SoundPath "' + $audio + '"'
    $player = Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $SoundPidPath -Value $player.Id -Encoding ascii
    Write-HapticLog -Event 'sound_started' -Data @{ sound_path = $audio; process_id = $player.Id }
    return [PSCustomObject]@{ started = $true; reason = 'started'; sound_path = $audio; process_id = $player.Id }
}

function Stop-HapticSoundLoop {
    if (-not (Test-Path -LiteralPath $SoundPidPath)) {
        return [PSCustomObject]@{ stopped = $false; reason = 'not_running' }
    }
    $pidText = Get-Content -LiteralPath $SoundPidPath -Raw
    $process = Get-Process -Id $pidText -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $process.Id -Force
        Write-HapticLog -Event 'sound_stopped' -Data @{ process_id = $process.Id }
    }
    Remove-Item -LiteralPath $SoundPidPath -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ stopped = $true; reason = 'stopped' }
}

if ($Mode -eq 'PlaySound') {
    if ([string]::IsNullOrWhiteSpace($SoundPath) -or -not (Test-Path -LiteralPath $SoundPath)) { exit 2 }
    if ([IO.Path]::GetExtension($SoundPath).ToLowerInvariant() -ne '.wav') { exit 3 }
    Add-Type -AssemblyName System.Windows.Forms
    $player = New-Object System.Media.SoundPlayer $SoundPath
    $player.Load()
    $player.PlayLooping()
    try { while ($true) { Start-Sleep -Seconds 1 } }
    finally { $player.Stop() }
    exit 0
}

$result = $null
switch ($Mode) {
    'CheckImage' {
        if ([string]::IsNullOrWhiteSpace($ImagePath)) { throw 'CheckImage requires -ImagePath.' }
        $result = Test-HapticAlertScreen -Path $ImagePath
    }
    'CheckCurrent' {
        if ([string]::IsNullOrWhiteSpace($AdbPath) -or [string]::IsNullOrWhiteSpace($Device)) { throw 'CheckCurrent requires -AdbPath and -Device.' }
        if (-not (Test-Path -LiteralPath $AdbPath)) { throw "ADB was not found: $AdbPath" }
        New-Item -ItemType Directory -Path $CaptureDirectory -Force | Out-Null
        $current = Join-Path $CaptureDirectory 'current-check.png'
        Save-AdbScreenshot -Destination $current -AdbPath $AdbPath -Device $Device
        $result = Test-HapticAlertScreen -Path $current
        if ($result.detected) {
            $evidence = Join-Path $CaptureDirectory ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-detected.png')
            Copy-Item -LiteralPath $current -Destination $evidence -Force
            $result.evidence_path = $evidence
            Write-HapticLog -Event 'detected' -Data @{ score = $result.score; threshold = $result.threshold; evidence_path = $evidence }
        }
    }
    'StartSound' { $result = Start-HapticSoundLoop -RequestedSoundPath $SoundPath }
    'StopSound' { $result = Stop-HapticSoundLoop }
}

$result | ConvertTo-Json -Compress -Depth 8
