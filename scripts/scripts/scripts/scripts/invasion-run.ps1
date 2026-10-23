[CmdletBinding()]
param(
    # AllRemaining means the currently visible BATTLE XN button, never a hard-coded X10.
    [ValidateSet('AllRemaining', 'Single')]
    [string]$Mode = 'AllRemaining',

    # Dry run takes one safe screenshot and describes the next action; it sends no ADB input.
    [switch]$DryRun,

    # Real navigation and a single battle action require this explicit switch.
    [switch]$Confirm,

    # Validates only the currently visible completed-Invasion screen and presses
    # its centered HOME button once. It never starts or continues a battle.
    [switch]$FinalizeCurrent,

    [ValidateRange(30, 240)]
    [int]$ResultTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$ConfigPath = Join-Path $ProjectRoot 'config.json'
$LogPath = Join-Path $ProjectRoot 'logs\invasion.jsonl'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$EvidenceDirectory = Join-Path $ProjectRoot "captures\invasion-run-$RunStamp"
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

# All coordinates are calibrated for the user's locked 1280x720 MuMu profile.
# No coordinate points at diamonds, tickets, the ADD power button, or a shop.
$Coordinates = [PSCustomObject]@{
    MapX = 84; MapY = 692
    # Fixed event button in the lower-right world-map HUD, not the Collector's building.
    InvasionEventIconX = 1218; InvasionEventIconY = 657
    ShowX = 640; ShowY = 598
    AllRemainingX = 790; AllRemainingY = 612
    SingleX = 1008; SingleY = 612
    ContinueWithoutPowerX = 530; ContinueWithoutPowerY = 478
    FinalHomeX = 640; FinalHomeY = 666
    FinalOkX = 640; FinalOkY = 526
}

function Write-InvasionLog {
    param([Parameter(Mandatory = $true)][string]$Event, [hashtable]$Data = @{})
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        event = $Event
        data = $Data
    }
    $record | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Save-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 16
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Set-MonitorSafety {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $config.safety.mode = 'monitor'
    $config.safety.forbid_diamond_spend = $true
    Save-JsonFile -Path $ConfigPath -Value $config
}

function Set-ActionSafety {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $config.safety.mode = 'actions'
    $config.safety.forbid_diamond_spend = $true
    Save-JsonFile -Path $ConfigPath -Value $config
}

function Assert-ActionsAllowed {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($config.safety.mode -ne 'actions') { throw "Blocked: config.json has safety.mode '$($config.safety.mode)'." }
    if ($config.safety.forbid_diamond_spend -ne $true) { throw 'Blocked: diamond-spend protection must be true.' }
}

function Enable-WindowsOcr {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage, ContentType = WindowsRuntime]
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

function Get-OcrResult {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    $file = $null; $stream = $null; $bitmap = $null
    try {
        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) { throw 'Windows OCR does not have an installed language engine.' }
        return Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    }
    finally {
        if ($null -ne $bitmap -and $bitmap -is [System.IDisposable]) { $bitmap.Dispose() }
        if ($null -ne $stream -and $stream -is [System.IDisposable]) { $stream.Dispose() }
    }
}

function Get-OcrLines {
    param([Parameter(Mandatory = $true)]$OcrResult)
    foreach ($line in $OcrResult.Lines) {
        $words = @($line.Words)
        if ($words.Count -gt 0) { (($words | ForEach-Object Text) -join ' ') }
    }
}

function Get-InvasionMapTap {
    param([Parameter(Mandatory = $true)]$OcrResult)
    foreach ($line in $OcrResult.Lines) {
        $words = @($line.Words)
        $text = (($words | ForEach-Object Text) -join ' ')
        if ($text -notmatch '(?i)^Invasion!?$') { continue }
        $rectangles = @($words | ForEach-Object { $_.BoundingRect })
        $left = [double](($rectangles | Measure-Object -Property X -Minimum).Minimum)
        $right = [double](($rectangles | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum)
        $top = [double](($rectangles | Measure-Object -Property Y -Minimum).Minimum)
        # The UFO sits directly above its Invasion! label in the calibrated map screen.
        return [PSCustomObject]@{
            X = [int][Math]::Round(($left + $right) / 2)
            Y = [int][Math]::Max(100, [Math]::Round($top - 60))
        }
    }
    return $null
}

function Get-ScreenKind {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines)
    $text = [string]::Join([Environment]::NewLine, [string[]]$Lines)
    if ($text -match '(?i)EQUIP POWERS FOR BATTLE' -and $text -match '(?i)\bADD\b' -and $text -match '(?i)\bATTACK\b') { return 'power-prompt' }
    if ($text -match '(?i)STOP THE INVASION' -and $text -match '(?i)Victories won' -and $text -match '(?i)\bSHOW\b') { return 'invasion-panel' }
    # Windows OCR can miss the small "Your squad" / "Enemy squad" labels.
    # BATTLE XN together with ATTACK is sufficient and remains distinct from
    # the optional-power modal, which has ATTACK but never BATTLE XN.
    if ($text -match '(?i)\bBATTLE\s*X\s*\d+' -and $text -match '(?i)\bATTACK\b') { return 'attack-choice' }
    # On the world map the target has a separate OCR line: Invasion!.
    # Check this only after the panel and attack-choice signatures so their title
    # "Invasion!" cannot be mistaken for the random map target.
    if ($text -match '(?im)^\s*Invasion!?\s*$') { return 'invasion-map' }
    # Collector's Flying Saucer is used only as a read-only signature that the
    # world map has loaded. It is never selected by this script.
    if ($text -match "(?i)Collector'?s\s+Flying\s+Saucer") { return 'invasion-world-map' }
    if ($text -match '(?i)\bMAP\b' -and $text -match '(?i)\bMARKET\b') { return 'base' }
    return 'unknown'
}

function Get-BattleMultiplier {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines)
    $text = [string]::Join([Environment]::NewLine, [string[]]$Lines)
    $match = [regex]::Match($text, '(?i)\bBATTLE\s*X\s*(\d+)\b')
    if (-not $match.Success) { return $null }
    [int]$count = 0
    if (-not [int]::TryParse($match.Groups[1].Value, [ref]$count) -or $count -lt 1 -or $count -gt 10) { return $null }
    return $count
}

function Test-InvasionAttackChoiceVisual {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    try {
        if ($bitmap.Width -ne 1280 -or $bitmap.Height -ne 720) { return $false }

        function Get-ColorRatio {
            param([int]$Left, [int]$Top, [int]$Right, [int]$Bottom, [scriptblock]$Predicate)
            $total = 0; $matches = 0
            for ($x = $Left; $x -le $Right; $x += 5) {
                for ($y = $Top; $y -le $Bottom; $y += 5) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    $total++
                    if (& $Predicate $pixel) { $matches++ }
                }
            }
            if ($total -eq 0) { return 0.0 }
            return ($matches / $total)
        }

        # Two separate green buttons at the exact BATTLE XN / ATTACK locations,
        # plus blue/red team bars, distinguish this page from every other known
        # Invasion screen. Do not use this visual fallback for power prompts.
        $leftGreen = Get-ColorRatio 700 575 878 648 { param($p) $p.G -gt ($p.R + 38) -and $p.G -gt ($p.B + 25) }
        $rightGreen = Get-ColorRatio 920 575 1098 648 { param($p) $p.G -gt ($p.R + 38) -and $p.G -gt ($p.B + 25) }
        $blueTeamBar = Get-ColorRatio 170 308 590 348 { param($p) $p.B -gt ($p.R + 30) -and $p.B -gt ($p.G + 8) }
        $redEnemyBar = Get-ColorRatio 690 308 1100 348 { param($p) $p.R -gt ($p.G + 35) -and $p.R -gt ($p.B + 35) }
        # EQUIP POWERS FOR BATTLE overlays a large white central card. Its
        # background still shows the same BATTLE/ATTACK buttons, so reject it
        # before an OCR failure can turn it into an attack-choice fallback.
        $centerWhite = Get-ColorRatio 385 250 895 430 { param($p) $p.R -gt 210 -and $p.G -gt 210 -and $p.B -gt 210 }

        return ($leftGreen -ge 0.28 -and $rightGreen -ge 0.28 -and $blueTeamBar -ge 0.25 -and $redEnemyBar -ge 0.25 -and $centerWhite -le 0.15)
    }
    finally { $bitmap.Dispose() }
}

function Test-InvasionFinalHomeVisual {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    try {
        if ($bitmap.Width -ne 1280 -or $bitmap.Height -ne 720) { return $false }

        function Get-ColorRatio {
            param([int]$Left, [int]$Top, [int]$Right, [int]$Bottom, [scriptblock]$Predicate)
            $total = 0; $matches = 0
            for ($x = $Left; $x -le $Right; $x += 5) {
                for ($y = $Top; $y -le $Bottom; $y += 5) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    $total++
                    if (& $Predicate $pixel) { $matches++ }
                }
            }
            if ($total -eq 0) { return 0.0 }
            return ($matches / $total)
        }

        # Final Invasion has one large green button in the middle bottom labelled
        # HOME. The ordinary BATTLE XN page has no green button in this region.
        # Its large blue reward panel further distinguishes it from map screens.
        $homeGreen = Get-ColorRatio 550 635 730 697 { param($p) $p.G -gt ($p.R + 40) -and $p.G -gt ($p.B + 25) }
        $rewardBlue = Get-ColorRatio 330 285 950 528 { param($p) $p.B -gt ($p.R + 30) -and $p.B -gt ($p.G + 8) }
        return ($homeGreen -ge 0.30 -and $rewardBlue -ge 0.28)
    }
    finally { $bitmap.Dispose() }
}

function Test-InvasionRepelledOk {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Lines, [Parameter(Mandatory = $true)][string]$ImagePath)

    $text = [string]::Join([Environment]::NewLine, [string[]]$Lines)
    if ($text -notmatch '(?i)INVASION\s+REPELLED') { return $false }

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    try {
        if ($bitmap.Width -ne 1280 -or $bitmap.Height -ne 720) { return $false }
        $total = 0; $green = 0
        for ($x = 550; $x -le 730; $x += 5) {
            for ($y = 495; $y -le 557; $y += 5) {
                $pixel = $bitmap.GetPixel($x, $y)
                $total++
                if ($pixel.G -gt ($pixel.R + 40) -and $pixel.G -gt ($pixel.B + 25)) { $green++ }
            }
        }
        return ($total -gt 0 -and ($green / $total) -ge 0.30)
    }
    finally { $bitmap.Dispose() }
}

function Ensure-MuMuAdbConnection {
    param([Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device)
    # First use the already-running ADB server, exactly like the manual
    # "adb devices" check. Do not restart a healthy MuMu connection.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $devicesOutput = @(& $AdbPath devices 2>&1)
        $devicesExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $devices = $devicesOutput -join [Environment]::NewLine
    $pattern = ('(?m)^' + [regex]::Escape($Device) + '\s+device\s*$')
    if ($devicesExitCode -eq 0 -and $devices -match $pattern) { return }

    # Only attempt recovery if the normal ADB check does not find MuMu.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $connectOutput = @(& $AdbPath connect $Device 2>&1)
        $connectExitCode = $LASTEXITCODE
        $devicesOutput = @(& $AdbPath devices 2>&1)
        $devicesExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $devices = $devicesOutput -join [Environment]::NewLine
    if ($connectExitCode -ne 0 -or $devicesExitCode -ne 0 -or $devices -notmatch $pattern) {
        throw "MuMu device $Device is unavailable. Check adb devices, then retry."
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

function Send-AdbTap {
    param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, [Parameter(Mandatory = $true)][string]$Reason, [Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device)
    Assert-ActionsAllowed
    $output = & $AdbPath -s $Device shell input tap $X $Y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB tap failed: $output" }
    Write-InvasionLog -Event 'tap_sent' -Data @{ x = $X; y = $Y; reason = $Reason }
    Write-Host ("Tap: {0} at ({1}, {2})" -f $Reason, $X, $Y) -ForegroundColor Yellow
}

function Capture-And-Read {
    param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$AdbPath, [Parameter(Mandatory = $true)][string]$Device, [Parameter(Mandatory = $true)][int]$ExpectedWidth, [Parameter(Mandatory = $true)][int]$ExpectedHeight)
    $path = Join-Path $EvidenceDirectory ((Get-Date -Format 'HHmmssfff') + "-$Label.png")
    Save-AdbScreenshot -Destination $path -AdbPath $AdbPath -Device $Device
    Add-Type -AssemblyName System.Drawing
    $image = [System.Drawing.Image]::FromFile($path)
    try {
        if ($image.Width -ne $ExpectedWidth -or $image.Height -ne $ExpectedHeight) { throw "Screenshot size is $($image.Width)x$($image.Height), expected $ExpectedWidth`x$ExpectedHeight." }
    }
    finally { $image.Dispose() }
    $ocr = Get-OcrResult -ImagePath $path
    $lines = @(Get-OcrLines -OcrResult $ocr)
    $kind = Get-ScreenKind -Lines $lines
    # Preserve explicit OCR results such as EQUIP POWERS FOR BATTLE. The visual
    # fallback is only for an otherwise unknown screen with a weak OCR result.
    if ($kind -eq 'unknown' -and (Test-InvasionAttackChoiceVisual -ImagePath $path)) {
        $kind = 'attack-choice'
        Write-Host 'Invasion attack-choice recognized by verified button-and-team-bar layout while OCR was incomplete.' -ForegroundColor DarkYellow
    }
    return [PSCustomObject]@{ Path = $path; Ocr = $ocr; Lines = $lines; Kind = $kind }
}

function Wait-ForScreen {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('invasion-world-map', 'invasion-map', 'invasion-panel', 'attack-choice', 'power-prompt')][string[]]$ExpectedKinds,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][int]$ExpectedWidth,
        [Parameter(Mandatory = $true)][int]$ExpectedHeight
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device -ExpectedWidth $ExpectedWidth -ExpectedHeight $ExpectedHeight
        if ($ExpectedKinds -contains $capture.Kind) { return $capture }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-ForAttackChoiceVisual {
    param(
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][int]$ExpectedWidth,
        [Parameter(Mandatory = $true)][int]$ExpectedHeight
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device -ExpectedWidth $ExpectedWidth -ExpectedHeight $ExpectedHeight
        # The large title "Invasion!" can make weak OCR classify this page as a
        # map. The exact visual layout is authoritative here: two lower green
        # buttons, blue/red team bars, and no white optional-power popup.
        if (Test-InvasionAttackChoiceVisual -ImagePath $capture.Path) {
            $capture.Kind = 'attack-choice'
            Write-Host 'Verified BATTLE XN button layout. The left green button is ready to press.' -ForegroundColor Green
            return $capture
        }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-ForInvasionRepelledOk {
    param(
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][int]$ExpectedWidth,
        [Parameter(Mandatory = $true)][int]$ExpectedHeight
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $capture = Capture-And-Read -Label $Label -AdbPath $AdbPath -Device $Device -ExpectedWidth $ExpectedWidth -ExpectedHeight $ExpectedHeight
        if (Test-InvasionRepelledOk -Lines $capture.Lines -ImagePath $capture.Path) { return $capture }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Observe-AfterBattle {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][int]$ExpectedWidth,
        [Parameter(Mandatory = $true)][int]$ExpectedHeight,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $index = 0
    $powerPromptHandled = $false
    do {
        Start-Sleep -Seconds 3
        $index++
        $capture = Capture-And-Read -Label ("post-battle-{0:D2}" -f $index) -AdbPath $AdbPath -Device $Device -ExpectedWidth $ExpectedWidth -ExpectedHeight $ExpectedHeight
        Write-Host ("Post-battle screen: {0}" -f $capture.Kind)

        if ($capture.Kind -eq 'power-prompt' -and -not $powerPromptHandled) {
            # Only the green ATTACK button is allowed. ADD remains permanently blocked.
            Send-AdbTap -X $Coordinates.ContinueWithoutPowerX -Y $Coordinates.ContinueWithoutPowerY -Reason 'Continue battle without adding optional power' -AdbPath $AdbPath -Device $Device
            $powerPromptHandled = $true
            continue
        }

        if (Test-InvasionFinalHomeVisual -ImagePath $capture.Path) {
            # Do not react to intermediate VICTORY cards. Only this verified
            # final layout contains the large centered HOME button.
            Write-Host 'Verified final Invasion HOME layout. Pressing HOME once.' -ForegroundColor Green
            Send-AdbTap -X $Coordinates.FinalHomeX -Y $Coordinates.FinalHomeY -Reason 'Return HOME after completed Invasion' -AdbPath $AdbPath -Device $Device
            Write-InvasionLog -Event 'invasion_final_home_pressed' -Data @{ capture = $capture.Path }
            $okCapture = Wait-ForInvasionRepelledOk -TimeoutSeconds 15 -Label 'invasion-repelled-ok' -AdbPath $AdbPath -Device $Device -ExpectedWidth $ExpectedWidth -ExpectedHeight $ExpectedHeight
            if ($null -eq $okCapture) { throw 'INVASION REPELLED dialog with the verified OK button did not appear after HOME. No OK tap was sent.' }
            Write-Host 'Verified INVASION REPELLED dialog. Pressing OK once.' -ForegroundColor Green
            Send-AdbTap -X $Coordinates.FinalOkX -Y $Coordinates.FinalOkY -Reason 'Accept completed Invasion reward with verified OK' -AdbPath $AdbPath -Device $Device
            Write-InvasionLog -Event 'invasion_final_ok_pressed' -Data @{ capture = $okCapture.Path }
            return $okCapture
        }

        Write-Host 'Intermediate battle/result screen observed. Waiting for final HOME; no tap sent.' -ForegroundColor DarkYellow
    } while ((Get-Date) -lt $deadline)
    throw 'Final Invasion HOME layout was not recognized before the timeout. No HOME tap was sent.'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$adbPath = [string]$config.emulator.adb_path
$device = [string]$config.emulator.device
$expectedWidth = [int]$config.emulator.expected_screenshot.width
$expectedHeight = [int]$config.emulator.expected_screenshot.height
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB was not found: $adbPath" }
if ($expectedWidth -ne 1280 -or $expectedHeight -ne 720) { throw "Invasion is calibrated only for 1280x720, but config expects $expectedWidth`x$expectedHeight." }

Enable-WindowsOcr
Ensure-MuMuAdbConnection -AdbPath $adbPath -Device $device

if ($FinalizeCurrent) {
    $current = Capture-And-Read -Label 'finalize-current' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
    $isHome = Test-InvasionFinalHomeVisual -ImagePath $current.Path
    $isOk = Test-InvasionRepelledOk -Lines $current.Lines -ImagePath $current.Path
    if (-not $isHome -and -not $isOk) { throw "Current screen is not the verified final Invasion HOME or INVASION REPELLED OK layout. No tap was sent. Capture: $($current.Path)" }
    if ($DryRun) {
        if ($isHome) { Write-Host ("DRY RUN PASSED: would tap final Invasion HOME at ({0}, {1}), then wait for verified OK. No tap was sent." -f $Coordinates.FinalHomeX, $Coordinates.FinalHomeY) -ForegroundColor Green }
        else { Write-Host ("DRY RUN PASSED: would tap verified INVASION REPELLED OK exactly once at ({0}, {1}). No tap was sent." -f $Coordinates.FinalOkX, $Coordinates.FinalOkY) -ForegroundColor Green }
        exit 0
    }
    if (-not $Confirm) { throw 'Blocked: use -FinalizeCurrent -DryRun first, then pass -Confirm to finish verified HOME/OK once.' }
    Set-ActionSafety
    try {
        if ($isHome) {
            Write-Host 'Verified current final Invasion HOME layout. Pressing HOME once.' -ForegroundColor Green
            Send-AdbTap -X $Coordinates.FinalHomeX -Y $Coordinates.FinalHomeY -Reason 'Return HOME from current completed Invasion' -AdbPath $adbPath -Device $device
            Write-InvasionLog -Event 'invasion_current_home_pressed' -Data @{ capture = $current.Path }
            $current = Wait-ForInvasionRepelledOk -TimeoutSeconds 15 -Label 'finalize-current-ok' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
            if ($null -eq $current) { throw 'Verified INVASION REPELLED dialog did not appear after HOME. No OK tap was sent.' }
        }
        Write-Host 'Verified INVASION REPELLED dialog. Pressing OK once.' -ForegroundColor Green
        Send-AdbTap -X $Coordinates.FinalOkX -Y $Coordinates.FinalOkY -Reason 'Accept current completed Invasion reward with verified OK' -AdbPath $adbPath -Device $device
        Write-InvasionLog -Event 'invasion_current_ok_pressed' -Data @{ capture = $current.Path }
        Write-Host ("Completed: final OK was pressed once. Evidence: {0}" -f $current.Path) -ForegroundColor Green
    }
    finally {
        Set-MonitorSafety
        Write-Host 'Safety restored: config.json is now in monitor mode.' -ForegroundColor Cyan
    }
    exit 0
}

if ($DryRun) {
    $current = Capture-And-Read -Label 'dry-run-current' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
    Write-Host 'SAFE INVASION TEST: no tap, swipe, attack, power, Food, Ticket, or diamond action will be sent.' -ForegroundColor Yellow
    switch ($current.Kind) {
        'base' { Write-Host 'Would tap MAP, tap the fixed lower-right Invasion event icon, press SHOW, then select the exact random Invasion! UFO.' }
        'invasion-world-map' { Write-Host ("Would tap the lower-right Invasion event icon at ({0}, {1}), not Collector's Flying Saucer." -f $Coordinates.InvasionEventIconX, $Coordinates.InvasionEventIconY) }
        'invasion-map' {
            $tap = Get-InvasionMapTap -OcrResult $current.Ocr
            if ($null -eq $tap) { throw 'Invasion map label was recognized but its tap position could not be calculated.' }
            Write-Host ("Would tap the Invasion! UFO at ({0}, {1})." -f $tap.X, $tap.Y)
        }
        'invasion-panel' { Write-Host ("Would tap SHOW at ({0}, {1})." -f $Coordinates.ShowX, $Coordinates.ShowY) }
        'attack-choice' {
            $remaining = Get-BattleMultiplier -Lines $current.Lines
            if ($Mode -eq 'AllRemaining') { Write-Host ("Would choose the current BATTLE X{0} button, not a fixed X10." -f $remaining) }
            else { Write-Host 'Would choose one-round ATTACK.' }
        }
        'power-prompt' { Write-Host ("Would tap only ATTACK at ({0}, {1}) to continue without adding a power. ADD is blocked." -f $Coordinates.ContinueWithoutPowerX, $Coordinates.ContinueWithoutPowerY) }
        default { throw "Invasion screen was not recognized safely. Capture: $($current.Path)" }
    }
    Write-Host ("Evidence: {0}" -f $current.Path)
    exit 0
}

if (-not $Confirm) { throw 'Blocked: use -DryRun first, then pass -Confirm for one authorized Invasion action.' }
Set-ActionSafety
try {
    Write-Host ("INVASION LIVE RUN: mode {0}. Only one BATTLE XN or ATTACK action is permitted; no post-result tap will be sent." -f $Mode) -ForegroundColor Cyan
    $current = Capture-And-Read -Label 'startup' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight

    if ($current.Kind -eq 'base') {
        Send-AdbTap -X $Coordinates.MapX -Y $Coordinates.MapY -Reason 'Open MAP for Invasion' -AdbPath $adbPath -Device $device
        $current = Wait-ForScreen -ExpectedKinds @('invasion-world-map') -TimeoutSeconds 12 -Label 'find-invasion-world-map' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
        if ($null -eq $current) { throw 'World map was not recognized after opening MAP. No battle action was sent.' }
    }

    if ($current.Kind -eq 'invasion-world-map') {
        Send-AdbTap -X $Coordinates.InvasionEventIconX -Y $Coordinates.InvasionEventIconY -Reason 'Open Invasion from lower-right event icon' -AdbPath $adbPath -Device $device
        $current = Wait-ForScreen -ExpectedKinds @('invasion-panel') -TimeoutSeconds 12 -Label 'invasion-panel' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
        if ($null -eq $current) { throw 'STOP THE INVASION panel was not recognized. No battle action was sent.' }
    }

    if ($current.Kind -eq 'invasion-panel') {
        Send-AdbTap -X $Coordinates.ShowX -Y $Coordinates.ShowY -Reason 'SHOW available Invasion UFO' -AdbPath $adbPath -Device $device
        $current = Wait-ForScreen -ExpectedKinds @('invasion-map') -TimeoutSeconds 12 -Label 'show-invasion-ufo' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
        if ($null -eq $current) { throw 'The Invasion! UFO was not recognized after SHOW. No battle action was sent.' }
    }

    if ($current.Kind -ne 'invasion-map') { throw "Expected Invasion map; found $($current.Kind). No battle action was sent." }
    $ufoTap = Get-InvasionMapTap -OcrResult $current.Ocr
    if ($null -eq $ufoTap) { throw 'Could not calculate the shown Invasion! UFO position. No battle action was sent.' }
    Send-AdbTap -X $ufoTap.X -Y $ufoTap.Y -Reason 'Select exact shown Invasion! UFO' -AdbPath $adbPath -Device $device

    $choice = Wait-ForAttackChoiceVisual -TimeoutSeconds 12 -Label 'attack-choice' -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight
    if ($null -eq $choice) { throw 'The BATTLE XN / ATTACK button layout was not recognized. No battle action was sent.' }

    if ($Mode -eq 'AllRemaining') {
        $remaining = Get-BattleMultiplier -Lines $choice.Lines
        if ($null -eq $remaining) {
            Write-Host 'BATTLE XN number was not readable, but the verified left-button/team-bar layout is present. Pressing only the left all-remaining button.' -ForegroundColor DarkYellow
            Send-AdbTap -X $Coordinates.AllRemainingX -Y $Coordinates.AllRemainingY -Reason 'Start verified left BATTLE XN all-remaining action with OCR-unreadable count' -AdbPath $adbPath -Device $device
        }
        else {
            Write-Host ("Current all-remaining action: BATTLE X{0}" -f $remaining) -ForegroundColor Cyan
            Send-AdbTap -X $Coordinates.AllRemainingX -Y $Coordinates.AllRemainingY -Reason ("Start current BATTLE X{0} all-remaining action" -f $remaining) -AdbPath $adbPath -Device $device
        }
    }
    else {
        Send-AdbTap -X $Coordinates.SingleX -Y $Coordinates.SingleY -Reason 'Start one-round ATTACK' -AdbPath $adbPath -Device $device
    }

    $final = Observe-AfterBattle -AdbPath $adbPath -Device $device -ExpectedWidth $expectedWidth -ExpectedHeight $expectedHeight -TimeoutSeconds $ResultTimeoutSeconds
    if ($null -eq $final) { throw 'No post-battle screenshot was captured.' }
    Write-InvasionLog -Event 'invasion_completed_home' -Data @{ mode = $Mode; final_kind = $final.Kind; capture = $final.Path }
    Write-Host ("Invasion completed. HOME was pressed once. Final capture: {0}" -f $final.Path) -ForegroundColor Green
}
finally {
    Set-MonitorSafety
    Write-Host 'Safety restored: config.json is now in monitor mode.' -ForegroundColor Cyan
}
