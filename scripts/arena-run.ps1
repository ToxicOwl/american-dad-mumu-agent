[CmdletBinding()]
param(
    # Use 1 for the first live validation. A tournament stage visibly shows 1/5,
    # so 5 is the maximum supported automatic sequence in one invocation.
    [ValidateRange(1, 5)]
    [int]$MaxBattles = 1,

    # Scans targets and prints the selected target, but never presses TO BATTLE.
    [switch]$DryRun,

    # Required for any real tap. The profile must also say safety.mode = actions.
    [switch]$Confirm,

    # Restart the persistent strategy sequence at: lowest, lowest, higher rank.
    [switch]$ResetCycle,

    # Time allowed for the automatic battle to reach VICTORY or DEFEAT.
    # Covers non-VIP speed and a small amount of emulator/network lag.
    [ValidateRange(10, 120)]
    [int]$BattleTimeoutSeconds = 75,

    # Includes the complete Next stage in countdown before the next pyramid is ready.
    [ValidateRange(30, 300)]
    [int]$StageWaitTimeoutSeconds = 180
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
$EvidenceDirectory = Join-Path $ProjectRoot "captures\arena-run-$RunStamp"
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

# Tournament-board centers for the 1280x720 landscape profile. The player tile
# is skipped automatically because it does not open an enemy-selection page.
$TournamentSlots = @(
    [PSCustomObject]@{ Rank = 1;  X = 640;  Y = 72  },
    [PSCustomObject]@{ Rank = 2;  X = 505;  Y = 205 },
    [PSCustomObject]@{ Rank = 3;  X = 765;  Y = 205 },
    [PSCustomObject]@{ Rank = 4;  X = 395;  Y = 370 },
    [PSCustomObject]@{ Rank = 5;  X = 635;  Y = 370 },
    [PSCustomObject]@{ Rank = 6;  X = 895;  Y = 370 },
    [PSCustomObject]@{ Rank = 7;  X = 270;  Y = 500 },
    [PSCustomObject]@{ Rank = 8;  X = 505;  Y = 500 },
    [PSCustomObject]@{ Rank = 9;  X = 765;  Y = 500 },
    [PSCustomObject]@{ Rank = 10; X = 1020; Y = 500 },
    [PSCustomObject]@{ Rank = 11; X = 140;  Y = 620 },
    [PSCustomObject]@{ Rank = 12; X = 390;  Y = 620 },
    [PSCustomObject]@{ Rank = 13; X = 635;  Y = 620 },
    [PSCustomObject]@{ Rank = 14; X = 890;  Y = 620 },
    [PSCustomObject]@{ Rank = 15; X = 1125; Y = 620 }
)

$Coordinates = [PSCustomObject]@{
    CloseSelectionX = 1085
    CloseSelectionY = 86
    ToBattleX       = 1000
    ToBattleY       = 608
    ResultHomeX      = 640
    ResultHomeY      = 666
    ClaimRewardX     = 1170
    ClaimRewardY     = 156
    CarouselPreviousX = 405
    CarouselPreviousY = 608
}

# Two lowest-power battles, then three battles against the closest better rank.
$StrategySequence = @('lowest-power', 'lowest-power', 'better-rank', 'better-rank', 'better-rank')

function Write-ArenaLog {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{}
    )

    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        event = $Event
        data = $Data
    }
    $record | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 16
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Get-ArenaState {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($null -ne $state.next_sequence_index -and [int]$state.next_sequence_index -ge 0) {
                return $state
            }
        }
        catch {
            Write-Warning 'Arena state could not be read; starting a fresh strategy cycle.'
        }
    }

    return [PSCustomObject]@{
        version = 1
        next_sequence_index = 0
        updated_utc = $null
    }
}

function Set-ArenaState {
    param([Parameter(Mandatory = $true)]$State)
    $State.updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    Save-JsonFile -Path $StatePath -Value $State
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
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][Type]$ResultType
    )

    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetGenericArguments().Count -eq 1 -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if ($null -eq $method) {
        throw 'Windows Runtime task helper was not found.'
    }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-OcrLines {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $file = $null
    $stream = $null
    $bitmap = $null
    try {
        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) {
            throw 'Windows OCR does not have an installed language engine.'
        }
        $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

        foreach ($line in $result.Lines) {
            $words = @($line.Words)
            if ($words.Count -eq 0) { continue }
            $rectangles = @($words | ForEach-Object { $_.BoundingRect })
            [PSCustomObject]@{
                Text = (($words | ForEach-Object Text) -join ' ')
                Left = [double](($rectangles | Measure-Object -Property X -Minimum).Minimum)
                Top = [double](($rectangles | Measure-Object -Property Y -Minimum).Minimum)
                Right = [double](($rectangles | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum)
                Bottom = [double](($rectangles | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum)
            }
        }
    }
    finally {
        if ($null -ne $bitmap -and $bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        if ($null -ne $stream -and $stream -is [System.IDisposable]) { $stream.Dispose() }
    }
}

function Get-OcrRegionText {
    param(
        [Parameter(Mandatory = $true)][array]$Lines,
        [Parameter(Mandatory = $true)][double]$Left,
        [Parameter(Mandatory = $true)][double]$Top,
        [Parameter(Mandatory = $true)][double]$Right,
        [Parameter(Mandatory = $true)][double]$Bottom
    )

    return (($Lines | Where-Object {
        $_.Left -ge $Left -and $_.Right -le $Right -and
        $_.Top -ge $Top -and $_.Bottom -le $Bottom
    } | ForEach-Object Text) -join ' ')
}

function Convert-OcrNumber {
    param([string]$Text)
    $digits = ($Text -replace '[^0-9]', '')
    [long]$number = 0
    if ([long]::TryParse($digits, [ref]$number)) {
        return $number
    }
    return $null
}

function Get-PlaceFromRegion {
    param(
        [Parameter(Mandatory = $true)][array]$Lines,
        [Parameter(Mandatory = $true)][double]$Top,
        [Parameter(Mandatory = $true)][double]$Bottom
    )

    $text = Get-OcrRegionText -Lines $Lines -Left 950 -Top $Top -Right 1140 -Bottom $Bottom
    if ($text -match '(?i)Place\s*:\s*(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Get-OcrText {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines)

    $texts = @(
        $Lines |
            Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Text'] } |
            ForEach-Object { [string]$_.Text }
    )
    return ($texts -join [Environment]::NewLine)
}

function Get-ScreenKind {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines)
    $text = Get-OcrText -Lines $Lines
    if ($text -match '(?i)Opponent selection' -and $text -match '(?i)Enemy squad' -and $text -match '(?i)TO BATTLE') { return 'selection' }
    if ($text -match '(?i)Tournament ended' -and ($text -match '(?i)CLAIM\s+REWARD' -or $text -match '(?i)NO\s+REWARDS')) { return 'tournament-ended' }
    # A bracket may contain cards labelled Victory!/Defeat. It must be classified
    # before the full-screen battle result, otherwise the scan would stop safely
    # but unnecessarily after an earlier battle.
    if (($text -match '(?i)Select the next opponent' -or $text -match '(?i)Next stage in') -and $text -match '(?i)Stage') { return 'bracket' }
    if ($text -match '(?i)VICTORY') { return 'victory' }
    if ($text -match '(?i)DEFEAT') { return 'defeat' }
    if ($text -match '(?i)\bVS\b') { return 'fight' }
    return 'unknown'
}

function Test-ToBattleActive {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    try {
        # Sample only the green interior of TO BATTLE, avoiding its text and border.
        # Active button: ~90% bright green. Won/inactive button: 0% bright green.
        $sampleCount = 0
        $brightGreenCount = 0
        for ($x = 920; $x -le 1080; $x += 4) {
            for ($y = 580; $y -le 630; $y += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                $sampleCount++
                if ($pixel.G -gt 170 -and $pixel.G -gt ($pixel.R + 35) -and $pixel.G -gt ($pixel.B + 35)) {
                    $brightGreenCount++
                }
            }
        }
        return ($sampleCount -gt 0 -and (($brightGreenCount / $sampleCount) -ge 0.65))
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-SelectionInfo {
    param(
        [Parameter(Mandatory = $true)][array]$Lines,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][int]$SourceRank,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y
    )

    if ((Get-ScreenKind -Lines $Lines) -ne 'selection') {
        return $null
    }
    if (-not (Test-ToBattleActive -ImagePath $ImagePath)) {
        return $null
    }

    $ownPlace = Get-PlaceFromRegion -Lines $Lines -Top 110 -Bottom 190
    $enemyPlace = Get-PlaceFromRegion -Lines $Lines -Top 470 -Bottom 560
    $ownPowerText = Get-OcrRegionText -Lines $Lines -Left 400 -Top 285 -Right 620 -Bottom 370
    $ownPower = Convert-OcrNumber $ownPowerText
    $powerText = Get-OcrRegionText -Lines $Lines -Left 620 -Top 285 -Right 850 -Bottom 370
    $enemyPower = Convert-OcrNumber $powerText

    if ($null -eq $ownPlace -or $null -eq $ownPower -or $ownPower -le 0 -or $null -eq $enemyPlace -or $null -eq $enemyPower -or $enemyPower -le 0) {
        return $null
    }

    return [PSCustomObject]@{
        SourceRank = $SourceRank
        X = $X
        Y = $Y
        OwnPlace = $ownPlace
        OwnPower = $ownPower
        EnemyPlace = $enemyPlace
        EnemyPower = $enemyPower
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
    try {
        $process.StandardOutput.BaseStream.CopyTo($fileStream)
    }
    finally {
        $fileStream.Dispose()
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

function Send-AdbTap {
    param(
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $output = & $AdbPath -s $Device shell input tap $X $Y 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ADB tap at ($X, $Y) failed: $output"
    }
}

function Capture-And-Read {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $file = Join-Path $EvidenceDirectory ((Get-Date -Format 'HHmmssfff') + "-$Label.png")
    Save-AdbScreenshot -Destination $file -AdbPath $AdbPath -Device $Device
    $lines = @(Get-OcrLines -ImagePath $file)
    return [PSCustomObject]@{ Path = $file; Lines = $lines; Kind = (Get-ScreenKind -Lines $lines) }
}

function Wait-ForScreen {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bracket', 'victory', 'defeat')][string[]]$ExpectedKinds,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device
        if ($ExpectedKinds -contains $capture.Kind) { return $capture }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Wait-ForReadyBracket {
    param(
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $reportedWaiting = $false
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device
        if ($capture.Kind -eq 'tournament-ended') { return $capture }
        if ($capture.Kind -eq 'bracket') {
            $text = Get-OcrText -Lines $capture.Lines
            if ($text -match '(?i)Select the next opponent') { return $capture }
            if ($text -match '(?i)Next stage in' -and -not $reportedWaiting) {
                Write-Host 'Arena is between stages. Waiting for the next opponent selection...' -ForegroundColor Yellow
                $reportedWaiting = $true
            }
        }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Claim-TournamentReward {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $verification = Capture-And-Read -Label 'before-claim-reward' -AdbPath $AdbPath -Device $Device
    if ($verification.Kind -ne 'tournament-ended') { throw 'Tournament end screen was not recognized. No final button was pressed.' }
    $finalText = Get-OcrText -Lines $verification.Lines
    if ($finalText -match '(?i)CLAIM\s+REWARD') { $action = 'CLAIM REWARD' }
    elseif ($finalText -match '(?i)NO\s+REWARDS') { $action = 'NO REWARDS' }
    else { throw 'Tournament end button was not recognized. No final button was pressed.' }
    Send-AdbTap -X $Coordinates.ClaimRewardX -Y $Coordinates.ClaimRewardY -AdbPath $AdbPath -Device $Device
    Start-Sleep -Milliseconds 900
    $after = Capture-And-Read -Label 'after-tournament-end' -AdbPath $AdbPath -Device $Device
    return [PSCustomObject]@{ Action = $action; Path = $after.Path }
}

function Record-HudTournamentFinish {
    param([Parameter(Mandatory = $true)][array]$Lines)
    if (-not (Test-Path -LiteralPath $HudScript)) { return }
    try {
        $text = Get-OcrText -Lines $Lines
        if ($text -notmatch '(?i)Your\s+position\s*:\s*(\d+)') {
            Write-Warning 'HUD stats were not updated because the final position was unreadable.'
            return
        }
        $place = [int]$Matches[1]
        if ($place -lt 1 -or $place -gt 15) { throw "Final position $place is outside the expected Arena range." }
        & $HudScript -RecordPlace $place | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "HUD result update exited with code $LASTEXITCODE." }
    }
    catch {
        Write-Warning ("HUD Arena result update skipped: {0}" -f $_.Exception.Message)
    }
}

function Scan-TournamentOpponents {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    $initial = Wait-ForReadyBracket -TimeoutSeconds $StageWaitTimeoutSeconds -Label 'before-scan' -AdbPath $AdbPath -Device $Device
    if ($null -eq $initial) {
        throw ('A ready Arena bracket was not recognized within {0} seconds. No battle was started.' -f $StageWaitTimeoutSeconds)
    }

    $found = @()
    $ownPlace = $null
    $ownPower = $null
    foreach ($slot in $TournamentSlots) {
        Send-AdbTap -X $slot.X -Y $slot.Y -AdbPath $AdbPath -Device $Device
        Start-Sleep -Milliseconds 350
        $capture = Capture-And-Read -Label ('scan-rank-{0:D2}' -f $slot.Rank) -AdbPath $AdbPath -Device $Device
        $info = Get-SelectionInfo -Lines $capture.Lines -ImagePath $capture.Path -SourceRank $slot.Rank -X $slot.X -Y $slot.Y
        $selectionOpen = ((Get-ScreenKind -Lines $capture.Lines) -eq 'selection')

        if ($null -ne $info) {
            if ($null -eq $ownPlace) { $ownPlace = $info.OwnPlace }
            if ($null -eq $ownPower) { $ownPower = $info.OwnPower }
            if ($info.EnemyPlace -ne $info.OwnPlace -and -not ($found | Where-Object { $_.EnemyPlace -eq $info.EnemyPlace })) {
                $found += $info
            }
        }
        if ($selectionOpen) {
            Send-AdbTap -X $Coordinates.CloseSelectionX -Y $Coordinates.CloseSelectionY -AdbPath $AdbPath -Device $Device
            Start-Sleep -Milliseconds 220
        }
    }

    if ($null -eq $ownPlace -or $null -eq $ownPower) {
        throw 'No valid opponent-selection page was recognized during scan. No battle was started.'
    }
    if ($found.Count -eq 0) {
        throw 'No active opponents were found during scan. No battle was started.'
    }

    return [PSCustomObject]@{
        OwnPlace = $ownPlace
        OwnPower = $ownPower
        Opponents = @($found)
    }
}

function Choose-ArenaTarget {
    param(
        [Parameter(Mandatory = $true)][array]$Opponents,
        [Parameter(Mandatory = $true)][int]$OwnPlace,
        [Parameter(Mandatory = $true)][long]$OwnPower,
        [Parameter(Mandatory = $true)][ValidateSet('lowest-power', 'better-rank')][string]$Mode
    )

    # Primary safety rule: prefer every active opponent at or below your power.
    $powerSafe = @($Opponents | Where-Object { $_.EnemyPower -le $OwnPower })
    if ($powerSafe.Count -gt 0) {
        if ($Mode -eq 'lowest-power') {
            $target = $powerSafe | Sort-Object EnemyPower, EnemyPlace | Select-Object -First 1
        }
	        else {
	            $betterSafe = @($powerSafe | Where-Object { $_.EnemyPlace -lt $OwnPlace })
	            if ($betterSafe.Count -gt 0) {
	                # Better-rank mode still favors the weakest eligible target.
	                # A nearby rank breaks only an equal-power tie; it must never
	                # make a 1.01M opponent win over an available 800k opponent.
	                $sortProperties = @(
	                    @{ Expression = 'EnemyPower'; Descending = $false }
	                    @{ Expression = 'EnemyPlace'; Descending = $true }
	                )
	                $target = $betterSafe | Sort-Object -Property $sortProperties | Select-Object -First 1
            }
            else {
                Write-Warning 'No better-ranked opponent is at or below your squad power; falling back to minimum power.'
                $target = $powerSafe | Sort-Object EnemyPower, EnemyPlace | Select-Object -First 1
            }
        }
        $target | Add-Member -NotePropertyName HigherPowerFallback -NotePropertyValue $false -Force
        return $target
    }

    # If all active opponents are stronger, allow only a better-ranked opponent
    # and choose the smallest absolute power difference from your squad.
    $betterRanked = @($Opponents | Where-Object { $_.EnemyPlace -lt $OwnPlace })
    if ($betterRanked.Count -gt 0) {
        $fallbackSort = @(
            @{ Expression = { [Math]::Abs([long]$_.EnemyPower - $OwnPower) }; Descending = $false }
            @{ Expression = 'EnemyPower'; Descending = $false }
            @{ Expression = 'EnemyPlace'; Descending = $true }
        )
        $target = $betterRanked | Sort-Object -Property $fallbackSort | Select-Object -First 1
        $target | Add-Member -NotePropertyName HigherPowerFallback -NotePropertyValue $true -Force
        Write-Warning ("No active opponent is at or below your power ({0}); choosing better-ranked Place {1} with closest power {2}." -f $OwnPower, $target.EnemyPlace, $target.EnemyPower)
        return $target
    }

    # Final fallback requested by the player: if every active opponent is above
    # your power and none has a better rank, choose the smallest available power.
    $target = $Opponents | Sort-Object EnemyPower, EnemyPlace | Select-Object -First 1
    $target | Add-Member -NotePropertyName HigherPowerFallback -NotePropertyValue $true -Force
    Write-Warning ("No active opponent is at or below your power ({0}) and no better rank exists; choosing minimum available power {1} at Place {2}." -f $OwnPower, $target.EnemyPower, $target.EnemyPlace)
    return $target
}

function Start-SelectedBattle {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    Send-AdbTap -X $Target.X -Y $Target.Y -AdbPath $AdbPath -Device $Device
    Start-Sleep -Milliseconds 400

    # The map's slot hit-area can shift slightly after a modal closes. Verify the
    # opened page, then use the opponent carousel to reach the exact scanned target.
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $label = if ($attempt -eq 0) { 'selected-target' } else { ('reselect-target-{0:D2}' -f $attempt) }
        $verification = Capture-And-Read -Label $label -AdbPath $AdbPath -Device $Device
        $actual = Get-SelectionInfo -Lines $verification.Lines -ImagePath $verification.Path -SourceRank $Target.SourceRank -X $Target.X -Y $Target.Y
        if ($null -ne $actual -and $actual.EnemyPlace -eq $Target.EnemyPlace -and $actual.EnemyPower -eq $Target.EnemyPower) {
            if ($actual.EnemyPower -gt $actual.OwnPower -and -not [bool]$Target.HigherPowerFallback) {
                throw ('Safety block: target power {0} exceeds your squad power {1}. TO BATTLE was not pressed.' -f $actual.EnemyPower, $actual.OwnPower)
            }
            Send-AdbTap -X $Coordinates.ToBattleX -Y $Coordinates.ToBattleY -AdbPath $AdbPath -Device $Device
            return $verification.Path
        }

        # On the calibrated carousel, the previous arrow reaches the preceding
        # place first (e.g., opened Place 14 -> scanned Place 13). It wraps safely.
        Send-AdbTap -X $Coordinates.CarouselPreviousX -Y $Coordinates.CarouselPreviousY -AdbPath $AdbPath -Device $Device
        Start-Sleep -Milliseconds 250
    }

    throw "Exact scanned target was not found after safe carousel verification. Expected Place $($Target.EnemyPlace), power $($Target.EnemyPower). TO BATTLE was not pressed."
}

function Ensure-MuMuAdbConnection {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device
    )

    # Re-establish the TCP link after MuMu or the ADB server restarts.
    # This sends only ADB server/connect commands; it never sends game input.
    $null = & $AdbPath start-server 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'ADB server could not be started.' }

    $null = & $AdbPath connect $Device 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB could not connect to $Device." }

    $devices = (& $AdbPath devices 2>&1) -join [Environment]::NewLine
    $devicePattern = ('(?m)^' + [regex]::Escape($Device) + '\s+device\s*$')
    if ($devices -notmatch $devicePattern) {
        throw "MuMu device $Device is unavailable after automatic reconnect. Open MuMu and the game, then retry."
    }

    Write-Host "ADB ready: $Device" -ForegroundColor DarkCyan
}
# --- Startup and safety gates -------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$adbPath = [string]$config.emulator.adb_path
$device = [string]$config.emulator.device
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB was not found: $adbPath" }
if ([int]$config.emulator.expected_screenshot.width -ne 1280 -or [int]$config.emulator.expected_screenshot.height -ne 720) {
    throw 'Arena module is calibrated only for 1280x720 screenshots. No tap was sent.'
}

if (-not $DryRun) {
    if (-not $Confirm) {
        throw 'Real battle mode is blocked. First run with -DryRun, then use -Confirm explicitly.'
    }
    if ([string]$config.safety.mode -ne 'actions') {
        throw "Real battle mode is blocked: config.json has safety.mode '$($config.safety.mode)'. Set it to 'actions' only after a successful dry run."
    }
    if (-not [bool]$config.safety.forbid_diamond_spend) {
        throw 'Real battle mode is blocked: safety.forbid_diamond_spend must remain true.'
    }
}

Ensure-MuMuAdbConnection -AdbPath $adbPath -Device $device
Enable-WindowsOcr
$state = Get-ArenaState
if ($ResetCycle) {
    $state.next_sequence_index = 0
    Set-ArenaState -State $state
}

Write-Host ''
Write-Host 'Arena module — local OCR, no diamonds, no QUICK ATTACK.' -ForegroundColor Cyan
if ($DryRun) {
    Write-Host 'DRY RUN: targets will be scanned, but TO BATTLE will never be pressed.' -ForegroundColor Yellow
}
else {
    Write-Host "LIVE RUN: at most $MaxBattles battle(s); mode returns to monitor at the end." -ForegroundColor Yellow
}

$restoreMonitor = -not $DryRun
try {
    $startup = Capture-And-Read -Label 'startup' -AdbPath $adbPath -Device $device
    if ($startup.Kind -eq 'tournament-ended') {
        if ($DryRun) {
            Write-Host 'DRY RUN PASSED: Tournament ended screen recognized. Would tap its final button once.' -ForegroundColor Green
        }
        else {
            Record-HudTournamentFinish -Lines $startup.Lines
            $afterClaim = Claim-TournamentReward -AdbPath $adbPath -Device $device
            $state.next_sequence_index = 0
            Set-ArenaState -State $state
            Write-ArenaLog -Event 'tournament_finished' -Data @{ final_action = $afterClaim.Action; before = $startup.Path; after = $afterClaim.Path; next_sequence_index = 0 }
            Write-Host ("Tournament ended. {0} was pressed once; strategy reset for the next Food tournament." -f $afterClaim.Action) -ForegroundColor Green
        }
        return
    }

    for ($battleIndex = 1; $battleIndex -le $MaxBattles; $battleIndex++) {
        $sequenceIndex = ([int]$state.next_sequence_index) % $StrategySequence.Count
        $mode = $StrategySequence[$sequenceIndex]
        Write-Host ''
        Write-Host "[$battleIndex/$MaxBattles] Scanning current tournament board for strategy: $mode"

        $scan = Scan-TournamentOpponents -AdbPath $adbPath -Device $device
        $target = Choose-ArenaTarget -Opponents $scan.Opponents -OwnPlace $scan.OwnPlace -OwnPower $scan.OwnPower -Mode $mode

        Write-Host "Your Place: $($scan.OwnPlace)"
        Write-Host "Your squad power: $($scan.OwnPower)"
        Write-Host "Eligible opponents scanned: $($scan.Opponents.Count)"
        Write-Host "Selected: Place $($target.EnemyPlace), power $($target.EnemyPower), board slot $($target.SourceRank)"
        if ([bool]$target.HigherPowerFallback) {
            Write-Host 'Fallback: no opponent at or below your power; using closest-power better-ranked opponent.' -ForegroundColor Yellow
        }
        Write-ArenaLog -Event 'target_selected' -Data @{
            strategy = $mode
            own_place = $scan.OwnPlace
            own_power = $scan.OwnPower
            selected_place = $target.EnemyPlace
            selected_power = $target.EnemyPower
            selected_slot = $target.SourceRank
            higher_power_fallback = [bool]$target.HigherPowerFallback
            dry_run = [bool]$DryRun
        }

        if ($DryRun) {
            Write-Host 'DRY RUN PASSED: no tap on TO BATTLE was sent.' -ForegroundColor Green
            break
        }

        $selectionEvidence = Start-SelectedBattle -Target $target -AdbPath $adbPath -Device $device
        Write-Host 'TO BATTLE pressed once. Waiting for automatic battle result...'
        $result = Wait-ForScreen -ExpectedKinds @('victory', 'defeat') -TimeoutSeconds $BattleTimeoutSeconds -Label 'wait-result' -AdbPath $adbPath -Device $device
        if ($null -eq $result) {
            throw "Battle result was not recognized within $BattleTimeoutSeconds seconds. The bot stopped without another tap."
        }

        Write-Host "Battle result: $($result.Kind). Pressing HOME once."
        Send-AdbTap -X $Coordinates.ResultHomeX -Y $Coordinates.ResultHomeY -AdbPath $adbPath -Device $device
        $bracket = Wait-ForReadyBracket -TimeoutSeconds $StageWaitTimeoutSeconds -Label 'return-bracket' -AdbPath $adbPath -Device $device
        if ($null -eq $bracket) {
            throw 'A ready tournament bracket was not recognized after HOME. The bot stopped without another tap.'
        }
        if ($bracket.Kind -eq 'tournament-ended') {
            Record-HudTournamentFinish -Lines $bracket.Lines
            $afterClaim = Claim-TournamentReward -AdbPath $adbPath -Device $device
            $state.next_sequence_index = 0
            Set-ArenaState -State $state
            Write-ArenaLog -Event 'tournament_finished' -Data @{ result = $result.Kind; final_action = $afterClaim.Action; before = $bracket.Path; after = $afterClaim.Path; next_sequence_index = 0 }
            Write-Host ("Tournament ended. {0} was pressed once; strategy reset for the next Food tournament." -f $afterClaim.Action) -ForegroundColor Green
            break
        }

        $state.next_sequence_index = ($sequenceIndex + 1) % $StrategySequence.Count
        Set-ArenaState -State $state
        Write-ArenaLog -Event 'battle_completed' -Data @{
            strategy = $mode
            result = $result.Kind
            selected_place = $target.EnemyPlace
            selected_power = $target.EnemyPower
            selection_evidence = $selectionEvidence
            result_evidence = $result.Path
            bracket_evidence = $bracket.Path
            next_sequence_index = $state.next_sequence_index
        }
        Write-Host "Completed. Next strategy: $($StrategySequence[$state.next_sequence_index])" -ForegroundColor Green
    }
}
finally {
    if ($restoreMonitor) {
        # A live run always leaves the shared profile unable to send future taps.
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
