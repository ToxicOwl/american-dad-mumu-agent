[CmdletBinding()]
param(
    # Explicit finite count. The launcher never runs indefinitely by default.
    [ValidateRange(1, 10)]
    [int]$Tournaments = 1,

    # Arena stages attempted per started tournament. Five matches the calibrated strategy.
    [ValidateRange(1, 5)]
    [int]$BattlesPerTournament = 5,

    # Includes the full in-game "Next stage in" countdown.
    [ValidateRange(30, 300)]
    [int]$StageWaitTimeoutSeconds = 180,

    [ValidateRange(15, 180)]
    [int]$MatchmakingTimeoutSeconds = 120,

    # Shows the Food-start plan only. No taps, Food spend, or battles are sent.
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$ConfigPath = Join-Path $ProjectRoot 'config.json'
$FoodScript = Join-Path $PSScriptRoot 'arena-start-food.ps1'
$ArenaScript = Join-Path $PSScriptRoot 'arena-run.ps1'

function Save-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 16
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Set-ActionSafety {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $config.safety.mode = 'actions'
    $config.safety.forbid_diamond_spend = $true
    Save-JsonFile -Path $ConfigPath -Value $config
}

function Set-MonitorSafety {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $config.safety.mode = 'monitor'
    $config.safety.forbid_diamond_spend = $true
    Save-JsonFile -Path $ConfigPath -Value $config
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing configuration: $ConfigPath" }
if (-not (Test-Path -LiteralPath $FoodScript)) { throw "Missing Food module: $FoodScript" }
if (-not (Test-Path -LiteralPath $ArenaScript)) { throw "Missing Arena module: $ArenaScript" }

if ($DryRun) {
    Write-Host 'CYCLE DRY RUN: no input will be sent.' -ForegroundColor Yellow
    & $FoodScript -DryRun
    return
}

try {
    for ($number = 1; $number -le $Tournaments; $number++) {
        Write-Host ''
        Write-Host ("=== Arena Food tournament {0}/{1} ===" -f $number, $Tournaments) -ForegroundColor Cyan

        # The Food module is the only module allowed to spend Food 10 000.
        # It never uses tickets or diamonds.
        Set-ActionSafety
        & $FoodScript -Confirm -MatchmakingTimeoutSeconds $MatchmakingTimeoutSeconds

        # Each Food start resets the strategy: lowest, lowest, better rank x3.
        Set-ActionSafety
        & $ArenaScript -MaxBattles $BattlesPerTournament -Confirm -StageWaitTimeoutSeconds $StageWaitTimeoutSeconds

        Write-Host ("Tournament {0}/{1} finished or stopped safely." -f $number, $Tournaments) -ForegroundColor Green
    }
}
finally {
    # A failed or interrupted child script always leaves the shared profile unable
    # to send new input until this launcher is run again deliberately.
    Set-MonitorSafety
    Write-Host 'Safety restored: config.json is now in monitor mode.' -ForegroundColor Cyan
}
