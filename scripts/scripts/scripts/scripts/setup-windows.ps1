$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "Python 3 was not found. Install Python 3.10+ from https://www.python.org/downloads/windows/ and run this script again."
}

if (-not (Test-Path '.venv\Scripts\python.exe')) {
    py -3 -m venv .venv
}

& '.venv\Scripts\python.exe' -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) {
    throw "Could not update pip. The agent was not installed."
}
& '.venv\Scripts\python.exe' -m pip install -e .
if ($LASTEXITCODE -ne 0) {
    throw "Could not install the agent dependencies. The agent was not installed."
}

if (-not (Test-Path 'config.json')) {
    Copy-Item 'config.example.json' 'config.json'
    Write-Host 'Created config.json. Review the ADB path and device address before use.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Installation completed.' -ForegroundColor Green
Write-Host 'Next command:'
Write-Host '  .\.venv\Scripts\ad-agent.exe doctor'
