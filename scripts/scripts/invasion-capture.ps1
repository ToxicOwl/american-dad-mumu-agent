[CmdletBinding()]
param(
    [ValidateSet(
        '01-map-invasion-icon',
        '02-invasion-panel',
        '03-show-ufo-list',
        '04-attack-choice-x10-or-attack',
        '05-final-result-menu',
        '99-current-screen'
    )]
    [string]$Step = '99-current-screen'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$ConfigPath = Join-Path $ProjectRoot 'config.json'
$CaptureDirectory = Join-Path $ProjectRoot 'captures\invasion-calibration'

function Ensure-MuMuAdbConnection {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    # ADB writes normal daemon-start information to stderr. Capture it with a
    # non-terminating preference and decide solely from the native exit code.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $startOutput = @(& $AdbPath start-server 2>&1)
        $startExitCode = $LASTEXITCODE
        $connectOutput = @(& $AdbPath connect $Device 2>&1)
        $connectExitCode = $LASTEXITCODE
        $devicesOutput = @(& $AdbPath devices 2>&1)
        $devicesExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($startExitCode -ne 0) { throw ("ADB server could not be started: {0}" -f ($startOutput -join ' ')) }
    if ($connectExitCode -ne 0) { throw ("ADB could not connect to {0}: {1}" -f $Device, ($connectOutput -join ' ')) }
    if ($devicesExitCode -ne 0) { throw ("ADB could not list devices: {0}" -f ($devicesOutput -join ' ')) }
    $devices = $devicesOutput -join [Environment]::NewLine
    $pattern = ('(?m)^' + [regex]::Escape($Device) + '\s+device\s*$')
    if ($devices -notmatch $pattern) {
        throw "MuMu device $Device is unavailable. Open MuMu and the game, then retry."
    }
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

    $fileStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $process.StandardOutput.BaseStream.CopyTo($fileStream) }
    finally { $fileStream.Dispose() }

    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "ADB screenshot failed: $stderr"
    }
    if ((Get-Item -LiteralPath $Destination).Length -lt 1024) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw 'ADB did not return a valid screenshot.'
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$adbPath = [string]$config.emulator.adb_path
$device = [string]$config.emulator.device
$expectedWidth = [int]$config.emulator.expected_screenshot.width
$expectedHeight = [int]$config.emulator.expected_screenshot.height

if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB was not found: $adbPath" }
if ($expectedWidth -le 0 -or $expectedHeight -le 0) { throw 'Expected screenshot dimensions are missing from config.json.' }

New-Item -ItemType Directory -Path $CaptureDirectory -Force | Out-Null
Ensure-MuMuAdbConnection -AdbPath $adbPath -Device $device

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$path = Join-Path $CaptureDirectory ("$timestamp-$Step.png")
Save-AdbScreenshot -Destination $path -AdbPath $adbPath -Device $device

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($path)
try {
    if ($image.Width -ne $expectedWidth -or $image.Height -ne $expectedHeight) {
        throw "Screenshot size is $($image.Width)x$($image.Height), expected $expectedWidth`x$expectedHeight. No Invasion automation was configured."
    }
}
finally { $image.Dispose() }

Write-Output 'SAFE INVASION CALIBRATION: screenshot only. No tap, swipe, attack, x10, Food, Ticket, or diamond action was sent.'
Write-Output ("Step: {0}" -f $Step)
Write-Output ("Capture: {0}" -f $path)
