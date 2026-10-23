Set-StrictMode -Version Latest

function Limit-ArenaCaptureRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CapturesDirectory,
        [ValidateRange(1, 1000)][int]$Keep = 20
    )

    if (-not (Test-Path -LiteralPath $CapturesDirectory)) {
        return [PSCustomObject]@{ Kept = 0; Removed = 0; BytesFreed = 0L }
    }

    # Only generated evidence runs are eligible. Manual calibration and screenshots
    # stored directly in captures\ are deliberately never touched.
    $managedFiles = @(
        Get-ChildItem -LiteralPath $CapturesDirectory -Recurse -File -Filter '*.png' |
            Where-Object {
                $_.Directory.Name -match '^arena-(run|start-food)-\d{8}-\d{6}$'
            } |
            Sort-Object LastWriteTime -Descending
    )

    $remove = @($managedFiles | Select-Object -Skip $Keep)
    [long]$bytesFreed = 0
    foreach ($file in $remove) {
        $bytesFreed += $file.Length
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    }

    # Remove only empty, generated evidence folders after their old frames are gone.
    Get-ChildItem -LiteralPath $CapturesDirectory -Directory |
        Where-Object { $_.Name -match '^arena-(run|start-food)-\d{8}-\d{6}$' } |
        ForEach-Object {
            if ($null -eq (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

    return [PSCustomObject]@{
        Kept = [Math]::Min($managedFiles.Count, $Keep)
        Removed = $remove.Count
        BytesFreed = $bytesFreed
    }
}
