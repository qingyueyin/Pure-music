[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PreviousPath,
    [Parameter(Mandatory = $true)]
    [string]$NewPath,
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
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

function Wait-UntilStopped([string]$directory, [int]$timeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while (Test-ProcessFromDirectory $directory) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "The previous application process did not exit in time."
        }
        Start-Sleep -Milliseconds 250
    }
}

function Hide-PortableSupport([string]$directory) {
    $supportDir = Join-Path $directory ".update"
    if (-not (Test-Path -LiteralPath $supportDir -PathType Container)) {
        throw "Portable update directory is missing."
    }

    Get-ChildItem -LiteralPath $supportDir -Force -Recurse | ForEach-Object {
        $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    $support = Get-Item -LiteralPath $supportDir -Force
    $support.Attributes = $support.Attributes -bor [System.IO.FileAttributes]::Hidden
}

$previousAppDir = Resolve-AppDirectory $PreviousPath
$newAppDir = Resolve-AppDirectory $NewPath
if ($previousAppDir.Equals($newAppDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The previous and new package directories are the same."
}

$processDeadline = [DateTime]::UtcNow.AddSeconds(120)
while (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
    if ([DateTime]::UtcNow -ge $processDeadline) {
        throw "The application process did not exit in time."
    }
    Start-Sleep -Milliseconds 250
}
Wait-UntilStopped $previousAppDir 30

$migrationScript = Join-Path $newAppDir ".update\upgrade_from_previous.ps1"
if (-not (Test-Path -LiteralPath $migrationScript -PathType Leaf)) {
    throw "Portable migration script is missing."
}
& $migrationScript -PreviousPath $previousAppDir -NonInteractive
Hide-PortableSupport $newAppDir

$parentDir = Split-Path -Parent $previousAppDir
$leafName = Split-Path -Leaf $previousAppDir
$backupAppDir = Join-Path $parentDir "$leafName.previous-$([Guid]::NewGuid().ToString('N'))"
$movedPrevious = $false
$movedNew = $false

try {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            Move-Item -LiteralPath $previousAppDir -Destination $backupAppDir -ErrorAction Stop
            $movedPrevious = $true
            Move-Item -LiteralPath $newAppDir -Destination $previousAppDir -ErrorAction Stop
            $movedNew = $true
            break
        }
        catch {
            if ($movedPrevious -and
                -not (Test-Path -LiteralPath $previousAppDir) -and
                (Test-Path -LiteralPath $backupAppDir)) {
                Move-Item -LiteralPath $backupAppDir -Destination $previousAppDir -ErrorAction SilentlyContinue
                $movedPrevious = $false
            }
            if ($attempt -eq 30) {
                throw
            }
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $movedNew) {
        throw "The new package could not replace the previous package."
    }

    $newExecutable = Join-Path $previousAppDir "pure_music.exe"
    Start-Process -FilePath $newExecutable -WorkingDirectory $previousAppDir
}
catch {
    if ($movedNew -and (Test-Path -LiteralPath $previousAppDir)) {
        $failedNewDir = Join-Path $parentDir "$leafName.failed-$([Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $previousAppDir -Destination $failedNewDir -ErrorAction SilentlyContinue
    }
    if ($movedPrevious -and
        (Test-Path -LiteralPath $backupAppDir) -and
        -not (Test-Path -LiteralPath $previousAppDir)) {
        Move-Item -LiteralPath $backupAppDir -Destination $previousAppDir -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath "explorer.exe" -ArgumentList @($newAppDir) -WindowStyle Hidden
    throw
}
