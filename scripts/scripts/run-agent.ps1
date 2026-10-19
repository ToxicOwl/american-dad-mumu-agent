$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path '.venv\Scripts\ad-agent.exe')) {
    throw "The agent is not installed. First run: .\scripts\setup-windows.ps1"
}

& '.venv\Scripts\ad-agent.exe' @args
