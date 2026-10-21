[CmdletBinding()]
param(
    # Checks the current screen and describes the approved Food route, but sends no input.
    [switch]$DryRun,

    # Required for the real route. The profile must also have safety.mode = actions.
    [switch]$Confirm,

    # Opens Tournament through MAP and Morning Mimosa, then stops before Food is used.
    [switch]$NavigateOnly,

    [ValidateRange(15, 180)]
    [int]$MatchmakingTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$ConfigPath = Join-Path $ProjectRoot 'config.json'
$StatePath = Join-Path $ProjectRoot 'logs\arena-state.json'
$LogPath = Join-Path $ProjectRoot 'logs\arena.jsonl'
$CapturesRoot = Join-Path $ProjectRoot 'captures'
$HudScript = Join-Path $PSScriptRoot 'arena-hud.ps1'
$RetentionScript = Join-Path $PSScriptRoot 'arena-capture-retention.ps1'
if (-not (Test-Path -LiteralPath $RetentionScript)) { throw "Missing capture-retention script: $RetentionScript" }
. $RetentionScript
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$EvidenceDirectory = Join-Path $ProjectRoot "captures\arena-start-food-$RunStamp"
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

# Calibrated only for the 1280x720 MuMu profile used in this workspace.
$Coordinates = [PSCustomObject]@{
    MapX = 84; MapY = 692
    # To move the camera toward the right-hand map area, drag the map left.
    MapSwipeRightStartX = 1080; MapSwipeRightStartY = 355
    MapSwipeRightEndX = 260; MapSwipeRightEndY = 355
    UseFoodX = 225; UseFoodY = 232
    ParticipateX = 326; ParticipateY = 568
    ConfirmSquadX = 990; ConfirmSquadY = 646
}

function Write-ArenaLog {
    param([Parameter(Mandatory = $true)][string]$Event, [hashtable]$Data = @{})
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        event = $Event
        data = $Data
    }
    $record | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Refresh-HudFood {
    if (-not (Test-Path -LiteralPath $HudScript)) { return }
    try {
        # Read-only ADB screenshot. HUD failures must never block the Food route.
        & $HudScript -RefreshFood | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "HUD food refresh exited with code $LASTEXITCODE." }
    }
    catch {
        Write-Warning ("HUD Food refresh skipped: {0}" -f $_.Exception.Message)
    }
}

function Save-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 16
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
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

function Get-OcrLines {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    $file = $null; $stream = $null; $bitmap = $null
    try {
        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) { throw 'Windows OCR does not have an installed language engine.' }
        $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $result.Lines) {
            $words = @($line.Words)
            if ($words.Count -gt 0) { (($words | ForEach-Object Text) -join ' ') }
        }
    }
    finally {
        if ($null -ne $bitmap -and $bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        if ($null -ne $stream -and $stream -is [System.IDisposable]) { $stream.Dispose() }
    }
}

function Get-MorningMimosaTap {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $file = $null; $stream = $null; $bitmap = $null
    try {
        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) { throw 'Windows OCR does not have an installed language engine.' }
        $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

        foreach ($line in $result.Lines) {
            $words = @($line.Words)
            $lineText = (($words | ForEach-Object Text) -join ' ')
            if ($lineText -notmatch '(?i)Morning\s+Mimosa') { continue }
            $rectangles = @($words | ForEach-Object { $_.BoundingRect })
            $left = [double](($rectangles | Measure-Object -Property X -Minimum).Minimum)
            $right = [double](($rectangles | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum)
            $top = [double](($rectangles | Measure-Object -Property Y -Minimum).Minimum)

            # The building lies just above the map label. Its label position varies
            # with swipe distance, so calculate the tap dynamically.
            return [PSCustomObject]@{
                X = [int][Math]::Round(($left + $right) / 2)
                Y = [int][Math]::Max(100, [Math]::Round($top - 60))
            }
        }
        return $null
    }
    finally {
        if ($null -ne $bitmap -and $bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        if ($null -ne $stream -and $stream -is [System.IDisposable]) { $stream.Dispose() }
    }
}

function Get-ScreenKind {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines)
    $text = [string]::Join([Environment]::NewLine, [string[]]$Lines)
    if ($text -match '(?i)Time left to select an opponent') { return 'active-tournament-map' }
    if ($text -match '(?i)Players found') { return 'matchmaking' }
    if ($text -match '(?i)CREATE SQUAD' -and $text -match '(?i)CONFIRM') { return 'squad-confirm' }
    if ($text -match '(?i)TOURNAMENT' -and $text -match '(?i)Select participation type' -and $text -match '(?i)Use food' -and $text -match '(?i)PARTICIPATE') { return 'food-menu' }
    if ($text -match '(?i)Select the next opponent' -and $text -match '(?i)Stage') { return 'bracket' }
    if ($text -match '(?i)Morning Mimosa|Chimdale Prison|Pearl Bailey High|CIA Office|Route 666|North Pole|Shopping Mall|Bazooka Sharks') { return 'map' }
    if ($text -match '(?i)\bMAP\b' -and $text -match '(?i)MARKET') { return 'base' }
    return 'unknown'
}

function Test-FoodParticipationReady {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    try {
        # Food selection is blue; Ticket is gray. Participate is green.
        # This remains visible even while the post-reward mail notification covers
        # central OCR text, so no Ticket tap is needed or permitted.
        $foodSamples = 0; $foodBlue = 0
        for ($x = 155; $x -le 315; $x += 4) {
            for ($y = 210; $y -le 255; $y += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                $foodSamples++
                if ($pixel.B -gt ($pixel.G + 30) -and $pixel.B -gt ($pixel.R + 80)) { $foodBlue++ }
            }
        }

        $participateSamples = 0; $participateGreen = 0
        for ($x = 235; $x -le 415; $x += 4) {
            for ($y = 535; $y -le 600; $y += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                $participateSamples++
                if ($pixel.G -gt ($pixel.R + 45) -and $pixel.G -gt ($pixel.B + 35)) { $participateGreen++ }
            }
        }

        $foodIsSelected = $foodSamples -gt 0 -and (($foodBlue / $foodSamples) -ge 0.30)
        $participateIsReady = $participateSamples -gt 0 -and (($participateGreen / $participateSamples) -ge 0.30)
        return ($foodIsSelected -and $participateIsReady)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Save-AdbScreenshot {
    param([Parameter(Mandatory = $true)][string]$Destination, [Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $AdbPath
    $process.StartInfo.Arguments = "-s $Device exec-out screencap -p"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    [void]$process.Start()
    $fileStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $process.StandardOutput.BaseStream.CopyTo($fileStream) } finally { $fileStream.Dispose() }
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw "ADB screenshot failed: $stderr" }
    if ((Get-Item -LiteralPath $Destination).Length -lt 1024) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw 'ADB did not return a valid screenshot.' }
}

function Send-AdbInput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device)
    $output = & $AdbPath -s $Device @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB input failed: $output" }
}

function Capture-And-Read {
    param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device)
    $path = Join-Path $EvidenceDirectory ((Get-Date -Format 'HHmmssfff') + "-$Label.png")
    Save-AdbScreenshot -Destination $path -AdbPath $AdbPath -Device $Device
    $lines = @(Get-OcrLines -ImagePath $path)
    $kind = Get-ScreenKind -Lines $lines
    # A temporary game toast can cover "Select participation type" or "Use food".
    # In that case accept the Food menu only when both non-spending visual
    # signatures remain visible: selected Food button (blue) and Participate (green).
    if ($kind -eq 'unknown' -and (Test-FoodParticipationReady -ImagePath $path)) {
        $kind = 'food-menu'
        Write-Host 'Food menu recognized by visual fallback while a notification covered OCR text.' -ForegroundColor DarkYellow
    }
    return [PSCustomObject]@{ Path = $path; Lines = $lines; Kind = $kind }
}

function Wait-ForScreen {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('map', 'food-menu', 'squad-confirm', 'matchmaking', 'bracket')][string[]]$ExpectedKinds,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device
        if ($capture.Kind -eq 'active-tournament-map') { throw 'An Arena selection is already active. The script will not start a new tournament.' }
        if ($ExpectedKinds -contains $capture.Kind) { return $capture }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-ForMorningMimosa {
    param(
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device
        if ($capture.Kind -eq 'active-tournament-map') { throw 'An Arena selection is already active. The script will not start a new tournament.' }
        $mapText = [string]::Join([Environment]::NewLine, [string[]]$capture.Lines)
        if ($capture.Kind -eq 'map' -and $mapText -match '(?i)Morning Mimosa') { return $capture }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $null
}

# --- Startup and safety gates -------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$adbPath = [string]$config.emulator.adb_path
$device = [string]$config.emulator.device
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB was not found: $adbPath" }
if ([int]$config.emulator.expected_screenshot.width -ne 1280 -or [int]$config.emulator.expected_screenshot.height -ne 720) {
    throw 'Food-start module is calibrated only for 1280x720 screenshots. No tap was sent.'
}
if (-not $DryRun) {
    if (-not $Confirm) { throw 'Real start mode is blocked. First run with -DryRun, then use -Confirm explicitly.' }
    if ([string]$config.safety.mode -ne 'actions') { throw "Real start mode is blocked: config.json has safety.mode '$($config.safety.mode)'." }
    if (-not [bool]$config.safety.forbid_diamond_spend) { throw 'Real start mode is blocked: safety.forbid_diamond_spend must remain true.' }
}

Enable-WindowsOcr
$restoreMonitor = -not $DryRun
try {
    $current = Capture-And-Read -Label 'initial' -AdbPath $adbPath -Device $device
    Write-Host ''
    Write-Host ('Arena Food start - current screen: {0}' -f $current.Kind) -ForegroundColor Cyan

    if ($current.Kind -eq 'active-tournament-map') {
        throw 'An Arena selection is already active. No navigation or Food spend was performed.'
    }
    if ($current.Kind -eq 'bracket') {
        Write-Host 'A tournament bracket is already available. No Food spend was performed.' -ForegroundColor Green
        return
    }
    if ($current.Kind -eq 'matchmaking') {
        Write-Host 'Matchmaking is already in progress. Waiting for the tournament bracket.' -ForegroundColor Yellow
        $bracket = Wait-ForScreen -ExpectedKinds @('bracket') -TimeoutSeconds $MatchmakingTimeoutSeconds -Label 'wait-bracket' -AdbPath $adbPath -Device $device
        if ($null -eq $bracket) { throw 'Players 15/15 or the tournament bracket was not recognized before timeout.' }
        Write-Host 'Tournament bracket recognized. No Food spend was performed.' -ForegroundColor Green
        return
    }

    if ($DryRun) {
        switch ($current.Kind) {
            'base' { Write-Host 'DRY RUN PASSED: would tap MAP, swipe right only if Morning Mimosa is absent, then enter Morning Mimosa.' }
            'map' { Write-Host 'DRY RUN PASSED: would tap Morning Mimosa only.' }
            'food-menu' { Write-Host 'DRY RUN PASSED: Food menu verified. Would tap Use food, then Participate for 10 000 Food.' }
            'squad-confirm' { Write-Host 'DRY RUN PASSED: squad confirmation verified. Would tap CONFIRM only.' }
            default { throw ('DRY RUN BLOCKED: expected base, map, Food menu, squad confirmation, matchmaking, or bracket; found {0}.' -f $current.Kind) }
        }
        Write-Host 'No input was sent.'
        return
    }

    if ($current.Kind -eq 'base') {
        Send-AdbInput -Arguments @('shell', 'input', 'tap', $Coordinates.MapX, $Coordinates.MapY) -AdbPath $adbPath -Device $device
        $current = Wait-ForScreen -ExpectedKinds @('map') -TimeoutSeconds 8 -Label 'open-map' -AdbPath $adbPath -Device $device
        if ($null -eq $current) { throw 'Map with Morning Mimosa was not recognized after tapping MAP.' }
    }

    if ($current.Kind -eq 'map') {
        # Morning Mimosa sits to the right of the initial map view; the map
        # itself must be dragged left to move the camera to that right-hand area.
        $mapText = [string]::Join([Environment]::NewLine, [string[]]$current.Lines)
        if ($mapText -notmatch '(?i)Morning Mimosa') {
            Send-AdbInput -Arguments @('shell', 'input', 'swipe', $Coordinates.MapSwipeRightStartX, $Coordinates.MapSwipeRightStartY, $Coordinates.MapSwipeRightEndX, $Coordinates.MapSwipeRightEndY, 700) -AdbPath $adbPath -Device $device
            $current = Wait-ForMorningMimosa -TimeoutSeconds 7 -Label 'find-morning-mimosa' -AdbPath $adbPath -Device $device
            if ($null -eq $current) { throw 'Morning Mimosa was not recognized after the calibrated map swipe.' }
        }
        $morningTap = Get-MorningMimosaTap -ImagePath $current.Path
        if ($null -eq $morningTap) { throw 'Morning Mimosa label was not located precisely. No tap was sent.' }
        Send-AdbInput -Arguments @('shell', 'input', 'tap', $morningTap.X, $morningTap.Y) -AdbPath $adbPath -Device $device
        $current = Wait-ForScreen -ExpectedKinds @('food-menu') -TimeoutSeconds 8 -Label 'open-tournament' -AdbPath $adbPath -Device $device
        if ($null -eq $current) { throw 'Food participation menu was not recognized after Morning Mimosa. No Food was spent.' }
    }

    if ($current.Kind -ne 'food-menu') { throw ('Expected Food participation menu; found {0}. No Food was spent.' -f $current.Kind) }
    if (-not $DryRun) { Refresh-HudFood }
    if ($NavigateOnly) {
        Write-Host 'Navigation test passed: Tournament Food menu recognized. No Food was spent.' -ForegroundColor Green
        Write-ArenaLog -Event 'food_navigation_verified' -Data @{ evidence = $current.Path; food_spend = 0 }
        return
    }
    Send-AdbInput -Arguments @('shell', 'input', 'tap', $Coordinates.UseFoodX, $Coordinates.UseFoodY) -AdbPath $adbPath -Device $device
    Start-Sleep -Milliseconds 900
    $foodVerified = Capture-And-Read -Label 'food-verified' -AdbPath $adbPath -Device $device
    if (-not (Test-FoodParticipationReady -ImagePath $foodVerified.Path)) {
        throw 'Food selection was not verified. PARTICIPATE was not pressed.'
    }

    # This is the only approved resource spend: Food 10 000. Tickets are never tapped.
    Send-AdbInput -Arguments @('shell', 'input', 'tap', $Coordinates.ParticipateX, $Coordinates.ParticipateY) -AdbPath $adbPath -Device $device
    $squad = Wait-ForScreen -ExpectedKinds @('squad-confirm') -TimeoutSeconds 8 -Label 'create-squad' -AdbPath $adbPath -Device $device
    if ($null -eq $squad) { throw 'CREATE SQUAD was not recognized after Food participation. CONFIRM was not pressed.' }
    Refresh-HudFood

    Send-AdbInput -Arguments @('shell', 'input', 'tap', $Coordinates.ConfirmSquadX, $Coordinates.ConfirmSquadY) -AdbPath $adbPath -Device $device
    $ready = Wait-ForScreen -ExpectedKinds @('matchmaking', 'bracket') -TimeoutSeconds $MatchmakingTimeoutSeconds -Label 'matchmaking' -AdbPath $adbPath -Device $device
    if ($null -eq $ready) { throw ('Players 15/15 or the tournament bracket was not recognized within {0} seconds.' -f $MatchmakingTimeoutSeconds) }
    if ($ready.Kind -eq 'matchmaking') {
        $ready = Wait-ForScreen -ExpectedKinds @('bracket') -TimeoutSeconds $MatchmakingTimeoutSeconds -Label 'wait-bracket' -AdbPath $adbPath -Device $device
        if ($null -eq $ready) { throw 'The tournament bracket was not recognized after matchmaking.' }
    }

    $state = [PSCustomObject]@{ version = 1; next_sequence_index = 0; updated_utc = (Get-Date).ToUniversalTime().ToString('o') }
    Save-JsonFile -Path $StatePath -Value $state
    Write-ArenaLog -Event 'food_tournament_started' -Data @{ evidence = $ready.Path; strategy_reset = $true; food_spend = 10000 }
    Write-Host 'Food tournament started and tournament bracket recognized.' -ForegroundColor Green
    Write-Host 'Arena strategy was reset to: lowest-power, lowest-power, better-rank × 3.' -ForegroundColor Green
}
finally {
    if ($restoreMonitor) {
        $config.safety.mode = 'monitor'
        $config.safety.forbid_diamond_spend = $true
        Save-JsonFile -Path $ConfigPath -Value $config
        Write-Host 'Safety restored: config.json is now in monitor mode.' -ForegroundColor Cyan
    }
    $retention = Limit-ArenaCaptureRetention -CapturesDirectory $CapturesRoot -Keep 20
    if ($retention.Removed -gt 0) {
        Write-Host ("Capture cleanup: removed {0} old automatic image(s), freed {1:N1} MB." -f $retention.Removed, ($retention.BytesFreed / 1MB)) -ForegroundColor DarkGray
    }
}
