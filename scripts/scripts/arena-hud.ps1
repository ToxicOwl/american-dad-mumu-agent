[CmdletBinding()]
param(
    [switch]$RefreshFood,
    [switch]$ResetStats,
    [long]$SetFood = -1,
    [int]$RecordPlace = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$StatsPath = Join-Path $ProjectRoot 'logs\arena-hud-stats.json'
$ArenaLogPath = Join-Path $ProjectRoot 'logs\arena.jsonl'
$ConfigPath = Join-Path $ProjectRoot 'config.json'

function Save-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Get-HudStats {
    if (Test-Path -LiteralPath $StatsPath) {
        try {
            $stats = Get-Content -LiteralPath $StatsPath -Raw | ConvertFrom-Json
            if ($null -ne $stats.arenas_played -and $null -ne $stats.place_1 -and $null -ne $stats.place_2 -and $null -ne $stats.place_3) {
                return $stats
            }
        }
        catch { }
    }

    $historicalArenaCount = 0
    if (Test-Path -LiteralPath $ArenaLogPath) {
        foreach ($line in Get-Content -LiteralPath $ArenaLogPath) {
            try {
                $record = $line | ConvertFrom-Json
                if ($record.event -in @('tournament_reward_claimed', 'tournament_finished')) { $historicalArenaCount++ }
            }
            catch { }
        }
    }

    return [PSCustomObject]@{
        version = 1
        food_remaining = $null
        food_updated_utc = $null
        arenas_played = $historicalArenaCount
        place_1 = 0
        place_2 = 0
        place_3 = 0
        last_place = $null
        updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Enable-WindowsOcr {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType = WindowsRuntime]
}

function Wait-WinRtOperation {
    param([Parameter(Mandatory = $true)]$Operation, [Parameter(Mandatory = $true)][Type]$ResultType)
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    if ($null -eq $method) { throw 'Windows Runtime task helper was not found.' }
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-FoodFromImage {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    Add-Type -AssemblyName System.Drawing
    $cropPath = Join-Path ([System.IO.Path]::GetTempPath()) ('american-dad-food-' + [guid]::NewGuid().ToString('N') + '.png')
    $original = [System.Drawing.Bitmap]::FromFile($ImagePath)
    $file = $null; $stream = $null; $bitmap = $null
    try {
        # The compact resource font is too small for full-screen Windows OCR.
        # Crop the Food header and enlarge its existing pixels solely for OCR.
        if ($original.Width -lt 455 -or $original.Height -lt 155) { throw 'Screenshot is too small for Food HUD calibration.' }
        $crop = New-Object System.Drawing.Bitmap 210, 60
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($crop)
            try {
                $graphics.DrawImage($original, (New-Object System.Drawing.Rectangle 0, 0, 210, 60), 245, 95, 210, 60, [System.Drawing.GraphicsUnit]::Pixel)
            }
            finally { $graphics.Dispose() }
            $scaled = New-Object System.Drawing.Bitmap 1260, 360
            try {
                $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaled)
                try {
                    $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                    $scaledGraphics.DrawImage($crop, 0, 0, 1260, 360)
                }
                finally { $scaledGraphics.Dispose() }
                $scaled.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $scaled.Dispose() }
        }
        finally { $crop.Dispose() }

        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($cropPath)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) { throw 'Windows OCR does not have an installed language engine.' }
        $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        $text = (($result.Lines | ForEach-Object { ($_.Words | ForEach-Object Text) -join ' ' }) -join ' ')
        $digits = ($text -replace '[^0-9]', '')
        [long]$food = 0
        if ([long]::TryParse($digits, [ref]$food) -and $food -gt 0) { return $food }
        return $null
    }
    finally {
        if ($null -ne $bitmap -and $bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        if ($null -ne $stream -and $stream -is [System.IDisposable]) { $stream.Dispose() }
        $original.Dispose()
        Remove-Item -LiteralPath $cropPath -Force -ErrorAction SilentlyContinue
    }
}

function Refresh-FoodAmount {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $adbPath = [string]$config.emulator.adb_path
    $device = [string]$config.emulator.device
    if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB was not found: $adbPath" }

    $screenshot = Join-Path ([System.IO.Path]::GetTempPath()) ('american-dad-hud-' + [guid]::NewGuid().ToString('N') + '.png')
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = $adbPath
        $process.StartInfo.Arguments = "-s $device exec-out screencap -p"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.CreateNoWindow = $true
        [void]$process.Start()
        $fileStream = [System.IO.File]::Open($screenshot, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try { $process.StandardOutput.BaseStream.CopyTo($fileStream) } finally { $fileStream.Dispose() }
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "ADB screenshot failed: $stderr" }
        if ((Get-Item -LiteralPath $screenshot).Length -lt 1024) { throw 'ADB did not return a valid screenshot.' }
        return Get-FoodFromImage -ImagePath $screenshot
    }
    finally {
        Remove-Item -LiteralPath $screenshot -Force -ErrorAction SilentlyContinue
    }
}

Enable-WindowsOcr
$stats = Get-HudStats

if ($ResetStats) {
    $stats.arenas_played = 0
    $stats.place_1 = 0
    $stats.place_2 = 0
    $stats.place_3 = 0
    $stats.last_place = $null
}

if ($RefreshFood) {
    $food = Refresh-FoodAmount
    if ($null -eq $food) { throw 'Food was not readable on the current screen. Open the base or Food/Ticket selector, then press Refresh Food.' }
    $stats.food_remaining = $food
    $stats.food_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
}

if ($SetFood -ge 0) {
    $stats.food_remaining = $SetFood
    $stats.food_updated_utc = (Get-Date).ToUniversalTime().ToString('o')
}

if ($RecordPlace -ge 1 -and $RecordPlace -le 15) {
    $stats.arenas_played = [int]$stats.arenas_played + 1
    $stats.last_place = $RecordPlace
    switch ($RecordPlace) {
        1 { $stats.place_1 = [int]$stats.place_1 + 1 }
        2 { $stats.place_2 = [int]$stats.place_2 + 1 }
        3 { $stats.place_3 = [int]$stats.place_3 + 1 }
    }
}

$stats.updated_utc = (Get-Date).ToUniversalTime().ToString('o')
Save-JsonFile -Path $StatsPath -Value $stats
Write-Output ('HUD_JSON:' + ($stats | ConvertTo-Json -Compress))
