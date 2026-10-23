# Arena ADB Auto-Connect Hotfix
# Place this file in D:\Games\AmericanBot\scripts\ and run it once.
# It adds a safe ADB reconnect before Food/Arena screen capture. It sends no game input.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targets = @(
    (Join-Path $PSScriptRoot 'arena-start-food.ps1'),
    (Join-Path $PSScriptRoot 'arena-run.ps1')
)

$functionBlock = @'
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
'@

foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "Skipped missing script: $target" -ForegroundColor Yellow
        continue
    }

    $content = [System.IO.File]::ReadAllText($target)
    if ($content -match 'function Ensure-MuMuAdbConnection') {
        Write-Host "Already patched: $(Split-Path -Leaf $target)" -ForegroundColor Yellow
        continue
    }

    $functionMarker = '# --- Startup and safety gates'
    $functionIndex = $content.IndexOf($functionMarker)
    if ($functionIndex -lt 0) {
        throw "Cannot find the startup marker in $target. Nothing was changed for this file."
    }

    $callMatch = [regex]::Matches($content, '(?m)^Enable-WindowsOcr\s*$') | Select-Object -Last 1
    if ($null -eq $callMatch) {
        throw "Cannot find the OCR startup call in $target. Nothing was changed for this file."
    }

    $backup = [System.IO.Path]::ChangeExtension($target, '.pre-adb-autoconnect.ps1')
    Copy-Item -LiteralPath $target -Destination $backup -Force

    try {
        $updated = $content.Insert($functionIndex, $functionBlock + [Environment]::NewLine)
        # The function insertion occurs before the call, so search again in the updated script.
        $updatedCallMatch = [regex]::Matches($updated, '(?m)^Enable-WindowsOcr\s*$') | Select-Object -Last 1
        $call = 'Ensure-MuMuAdbConnection -AdbPath $adbPath -Device $device' + [Environment]::NewLine
        $updated = $updated.Insert($updatedCallMatch.Index, $call)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($target, $updated, $utf8NoBom)

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            $messages = $errors | ForEach-Object { $_.Message }
            throw "Syntax validation failed: $($messages -join '; ')"
        }

        Write-Host "SUCCESS: Patched $(Split-Path -Leaf $target)" -ForegroundColor Green
        Write-Host "Backup: $backup"
    }
    catch {
        Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
        throw "Hotfix failed for $target; the backup was restored. $($_.Exception.Message)"
    }
}

Write-Host 'ADB auto-connect hotfix installed. Restart the Arena application before the next run.' -ForegroundColor Green
