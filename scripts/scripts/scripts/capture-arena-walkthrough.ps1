[CmdletBinding()]
param(
    [ValidateRange(15, 120)]
    [int]$Seconds = 40,

    [ValidateRange(500, 5000)]
    [int]$IntervalMilliseconds = 1500
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$config = Get-Content '.\config.json' -Raw | ConvertFrom-Json
$adb = [string]$config.emulator.adb_path
$device = [string]$config.emulator.device

if (-not (Test-Path -LiteralPath $adb)) {
    throw "ADB was not found: $adb"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputDirectory = Join-Path $ProjectRoot "captures\arena-walkthrough-$stamp"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

function Save-AdbScreenshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $adb
    $process.StartInfo.Arguments = "-s $device exec-out screencap -p"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true

    [void]$process.Start()
    $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $process.StandardOutput.BaseStream.CopyTo($stream)
    }
    finally {
        $stream.Dispose()
    }

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

Write-Host ''
Write-Host 'Arena walkthrough capture is ready.' -ForegroundColor Cyan
Write-Host '1. Open one opponent detail page in Arena.'
Write-Host '2. Keep the detail page open. The capture starts in 5 seconds.'
Write-Host '3. During capture, press the Arena NEXT arrow manually about once every 2 seconds.'
Write-Host '4. Continue until all 14 opponents have appeared.'
Write-Host ''
Start-Sleep -Seconds 5

$deadline = (Get-Date).AddSeconds($Seconds)
$index = 1
while ((Get-Date) -lt $deadline) {
    $frame = Join-Path $outputDirectory ('frame-{0:D3}.png' -f $index)
    Save-AdbScreenshot -Destination $frame
    Write-Host ("Captured frame {0:D3}" -f $index)
    $index++
    Start-Sleep -Milliseconds $IntervalMilliseconds
}

Write-Host ''
Write-Host "Done. Captures are in: $outputDirectory" -ForegroundColor Green
Write-Host 'Return to the chat and write: arena walkthrough gata'
