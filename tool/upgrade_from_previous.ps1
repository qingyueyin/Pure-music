[CmdletBinding()]
param(
    [string]$PreviousPath = "",
    [switch]$NonInteractive
)

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

function Resolve-AppDirectory([string]$path) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (Test-Path -LiteralPath (Join-Path $resolved "pure_music.exe") -PathType Leaf) {
        return $resolved
    }
    $nested = Join-Path $resolved "app"
    if (Test-Path -LiteralPath (Join-Path $nested "pure_music.exe") -PathType Leaf) {
        return $nested
    }
    throw "pure_music.exe was not found under: $resolved"
}

function Test-ProcessFromDirectory([string]$directory) {
    $prefix = [System.IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
    foreach ($process in @(Get-Process -Name "pure_music" -ErrorAction SilentlyContinue)) {
        try {
            $processPath = [System.IO.Path]::GetFullPath($process.Path)
            if ($processPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {}
    }
    return $false
}

if ([string]::IsNullOrWhiteSpace($PreviousPath)) {
    if ($NonInteractive) {
        throw "PreviousPath is required in non-interactive mode."
    }
    $PreviousPath = Read-Host "Previous portable package directory"
}

$currentAppDir = Resolve-AppDirectory $PSScriptRoot
$previousAppDir = Resolve-AppDirectory $PreviousPath
if ($currentAppDir.Equals($previousAppDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The previous and current package directories are the same."
}
if ((Test-ProcessFromDirectory $currentAppDir) -or (Test-ProcessFromDirectory $previousAppDir)) {
    throw "Close Pure Music in both package directories before migrating data."
}

$previousDataDir = Join-Path $previousAppDir "data"
$currentDataDir = Join-Path $currentAppDir "data"
foreach ($requiredPath in @(
    (Join-Path $previousDataDir "app.so"),
    (Join-Path $currentDataDir "app.so"),
    (Join-Path $currentDataDir "flutter_assets")
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Portable runtime data is incomplete: $requiredPath"
    }
}

$runtimeEntries = @("app.so", "flutter_assets", "icudtl.dat")
$sourceEntries = @(Get-ChildItem -LiteralPath $previousDataDir -Force | Where-Object {
    $runtimeEntries -notcontains $_.Name
})
$existingUserEntries = @(Get-ChildItem -LiteralPath $currentDataDir -Force | Where-Object {
    $runtimeEntries -notcontains $_.Name
})
if ($existingUserEntries.Count -gt 0) {
    throw "The new package already contains user data: $($existingUserEntries.Name -join ', ')"
}

$copiedPaths = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($entry in $sourceEntries) {
        Copy-Item -LiteralPath $entry.FullName -Destination $currentDataDir -Recurse -Force
        $copiedPaths.Add((Join-Path $currentDataDir $entry.Name))
    }
    Get-ChildItem -LiteralPath $currentDataDir -Recurse -File -Filter "*.tmp.*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
catch {
    foreach ($path in $copiedPaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}

Write-Host "Portable data migration completed." -ForegroundColor Green
Write-Host "Previous: $previousAppDir" -ForegroundColor Gray
Write-Host "Current:  $currentAppDir" -ForegroundColor Gray
Write-Host "Migrated entries: $($sourceEntries.Count)" -ForegroundColor Gray

if (-not $NonInteractive) {
    Read-Host "Press Enter to exit..." | Out-Null
}
