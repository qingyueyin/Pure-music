param(
    [switch] $NoPause,
    # 跳过同步到主程序（仅构建 lyric 自身 output/）
    [switch] $SkipSync,
    # 不重新编译，只把已有产物同步到 Pure-music（用 output/ 或 Release 构建目录）
    [switch] $SyncOnly,
    # monorepo / 主程序仓库根目录；默认从 apps/pure_player_lyric 向上解析
    [string] $MusicRoot = ""
)

$ErrorActionPreference = "Stop"

Set-Location -Path $PSScriptRoot

$BuildMode = "Release"
$finalOutputDir = Join-Path $PSScriptRoot "output"
$ephemeralDir = "windows\flutter\ephemeral"
$logsDir = Join-Path $PSScriptRoot "logs"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logsDir "build_$timestamp.log"

if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $Message | Tee-Object -FilePath $logFile -Append | Out-Null
}

function Test-IsMusicMonorepoRoot {
    param([string]$Candidate)

    if (-not $Candidate) { return $false }
    $pubspec = Join-Path $Candidate "pubspec.yaml"
    $lyricApp = Join-Path $Candidate "apps\pure_player_lyric"
    return (Test-Path -LiteralPath $pubspec) -and (Test-Path -LiteralPath $lyricApp)
}

function Resolve-MusicRoot {
    param([string]$Override)

    if ($Override -and (Test-Path $Override)) {
        return (Resolve-Path $Override).Path
    }

    # monorepo：apps/pure_player_lyric 的上两级即为仓根
    $monorepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (Test-IsMusicMonorepoRoot -Candidate $monorepoRoot) {
        return (Resolve-Path $monorepoRoot).Path
    }

    # 兼容：从当前目录向上查找含 pubspec.yaml + apps/pure_player_lyric 的根
    $probe = $PSScriptRoot
    while ($probe) {
        if (Test-IsMusicMonorepoRoot -Candidate $probe) {
            return (Resolve-Path $probe).Path
        }
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    # 已废弃：旧 sibling 布局 pure-player-lyric 与 Pure-music 同级
    $sibling = Join-Path (Split-Path $PSScriptRoot -Parent) "Pure-music"
    if (Test-Path (Join-Path $sibling "pubspec.yaml")) {
        Write-Warning "Using deprecated sibling layout ../Pure-music. Prefer monorepo apps/pure_player_lyric."
        return (Resolve-Path $sibling).Path
    }

    return $null
}

function Stop-DesktopLyricProcess {
    $processName = "desktop_lyric"
    if (Get-Process $processName -ErrorAction SilentlyContinue) {
        Write-Host "Stopping running instance of $processName..." -ForegroundColor Yellow
        Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

function Sync-DesktopLyricToMusic {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$MusicRepoRoot
    )

    $exeName = "desktop_lyric.exe"
    $srcExe = Join-Path $SourceDir $exeName
    if (-not (Test-Path -LiteralPath $srcExe)) {
        throw "Sync source missing $exeName under: $SourceDir"
    }

    Stop-DesktopLyricProcess

    $destinations = New-Object System.Collections.Generic.List[string]
    $destinations.Add((Join-Path $MusicRepoRoot "desktop_lyric"))

    $runnerRoot = Join-Path $MusicRepoRoot "build\windows\x64\runner"
    if (Test-Path $runnerRoot) {
        foreach ($mode in @("Debug", "Profile", "Release")) {
            $modeDir = Join-Path $runnerRoot $mode
            if (Test-Path $modeDir) {
                $destinations.Add((Join-Path $modeDir "desktop_lyric"))
            }
        }
    }

    foreach ($dest in $destinations) {
        Write-Host "Syncing desktop lyric -> $dest" -ForegroundColor Cyan
        if (Test-Path $dest) {
            Remove-Item -Path $dest -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path (Join-Path $SourceDir "*") -Destination $dest -Recurse -Force

        $destExe = Join-Path $dest $exeName
        if (-not (Test-Path -LiteralPath $destExe)) {
            throw "Sync failed, missing $exeName at: $destExe"
        }
    }

    Write-Host "Synced desktop lyric to $($destinations.Count) location(s) under Music repo." -ForegroundColor Green
    Write-Host "Note: /desktop_lyric is gitignored build output; do not commit it." -ForegroundColor DarkYellow
}

# --- SyncOnly：跳过编译，复用已有产物 ---
if ($SyncOnly) {
    Write-Host "SyncOnly mode: skipping flutter build." -ForegroundColor Green
    $resolvedMusic = Resolve-MusicRoot -Override $MusicRoot
    if (-not $resolvedMusic) {
        Write-Error "Cannot find monorepo root. Pass -MusicRoot <path> (expected repo root with pubspec.yaml + apps/pure_player_lyric)."
        if (-not $NoPause) { Read-Host "Press Enter to exit..." }
        exit 1
    }

    $syncSource = $null
    if (Test-Path (Join-Path $finalOutputDir "desktop_lyric.exe")) {
        $syncSource = $finalOutputDir
    }
    else {
        $releaseDir = Join-Path $PSScriptRoot "build\windows\x64\runner\$BuildMode"
        if (Test-Path (Join-Path $releaseDir "desktop_lyric.exe")) {
            $syncSource = $releaseDir
        }
    }

    if (-not $syncSource) {
        Write-Error "No built desktop_lyric.exe found. Run a full build first, or point to artifacts."
        if (-not $NoPause) { Read-Host "Press Enter to exit..." }
        exit 1
    }

    Sync-DesktopLyricToMusic -SourceDir $syncSource -MusicRepoRoot $resolvedMusic
    if (-not $NoPause) { Read-Host "Press Enter to exit..." }
    exit 0
}

Write-Host "Starting build process ($BuildMode Mode)..." -ForegroundColor Green

if (-not (Get-Command "flutter" -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter command not found. Please ensure Flutter is installed and in your PATH."
    if (-not $NoPause) { Read-Host "Press Enter to exit..." }
    exit 1
}

if (Test-Path $ephemeralDir) {
    Write-Host "Cleaning ephemeral directory to avoid symlink conflicts..." -ForegroundColor Yellow
    Remove-Item -Path $ephemeralDir -Recurse -Force
}

$VerbosePreference = "Continue"
$DebugPreference = "Continue"

$needPubGet = $true
$packageConfig = ".dart_tool\package_config.json"

if ((Test-Path "pubspec.yaml") -and (Test-Path "pubspec.lock") -and (Test-Path $packageConfig)) {
    $yamlTime = (Get-Item "pubspec.yaml").LastWriteTime
    $lockTime = (Get-Item "pubspec.lock").LastWriteTime
    if ($yamlTime -le $lockTime) {
        $needPubGet = $false
    }
}

if ($needPubGet) {
    Write-Host "Running flutter pub get..." -ForegroundColor Cyan
    flutter pub get
}
else {
    Write-Host "Skipping flutter pub get (dependencies are up to date)." -ForegroundColor Gray
}

$appIconResourcePath = "windows\runner\resources\app_icon.ico"
$buildRoot = "build\windows"
$exePath = "build\windows\x64\runner\$BuildMode\desktop_lyric.exe"

function Update-RcVersion {
    $pubspec = Join-Path $PSScriptRoot "pubspec.yaml"
    if (-not (Test-Path $pubspec)) { return }

    $content = Get-Content -Path $pubspec -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return }

    $m = [regex]::Match($content, '(?m)^\s*version\s*:\s*([^\r\n]+)\s*$')
    if (-not $m.Success) { return }

    $version = $m.Groups[1].Value.Trim()

    $rcPath = Join-Path $PSScriptRoot "windows\runner\Runner.rc"
    if (-not (Test-Path $rcPath)) { return }

    $rcContent = Get-Content -Path $rcPath -Raw

    $parts = $version -split '\+'
    $verNum = $parts[0]
    $verParts = $verNum -split '\.'

    $major = if ($verParts.Length -gt 0) { $verParts[0] } else { "0" }
    $minor = if ($verParts.Length -gt 1) { $verParts[1] } else { "0" }
    $patch = if ($verParts.Length -gt 2) { $verParts[2] } else { "0" }
    $build = if ($parts.Length -gt 1) { $parts[1] } else { "0" }

    $newNumber = "$major,$minor,$patch,$build"
    $newString = """$version"""

    $rcContent = $rcContent -replace '#define VERSION_AS_NUMBER .+', "#define VERSION_AS_NUMBER $newNumber"
    $rcContent = $rcContent -replace '#define VERSION_AS_STRING ".+"', "#define VERSION_AS_STRING $newString"

    Set-Content -Path $rcPath -Value $rcContent -NoNewline -ErrorAction SilentlyContinue
    Write-Host "Updated Runner.rc version to $version" -ForegroundColor Green
}

Update-RcVersion

if (-not (Test-Path $appIconResourcePath)) {
    Write-Warning "Icon not found: $appIconResourcePath. The application icon might be default."
}
else {
    # Always clear the previous build artifacts so that any changes
    # to the resource files (icon/manifest) are picked up.  Without this step
    # the cached object files can keep the previous icon which results in the
    # compiled executable showing the wrong icon in Explorer.
    if (Test-Path $buildRoot) {
        Write-Host "Cleaning $buildRoot to ensure resources are rebuilt..." -ForegroundColor Yellow
        Remove-Item -Path $buildRoot -Recurse -Force
    }
}

Write-Host "Building Windows ($BuildMode)..." -ForegroundColor Cyan
flutter build windows --release

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed!"
    if (-not $NoPause) { Read-Host "Press Enter to exit..." }
    exit 1
}

$buildDir = "build\windows\x64\runner\$BuildMode"
if (-not (Test-Path $buildDir)) {
    Write-Error "Build output directory not found: $buildDir"
    if (-not $NoPause) { Read-Host "Press Enter to exit..." }
    exit 1
}

Write-Host "Preparing Output Directory: $finalOutputDir..." -ForegroundColor Cyan

Stop-DesktopLyricProcess

if (Test-Path $finalOutputDir) {
    Remove-Item -Path $finalOutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $finalOutputDir | Out-Null

Write-Host "Copying build artifacts to output directory..." -ForegroundColor Cyan
Copy-Item -Path "$buildDir\*" -Destination $finalOutputDir -Recurse -Force

if (-not $SkipSync) {
    $resolvedMusic = Resolve-MusicRoot -Override $MusicRoot
    if ($resolvedMusic) {
        Sync-DesktopLyricToMusic -SourceDir $finalOutputDir -MusicRepoRoot $resolvedMusic
    }
    else {
        Write-Warning "Monorepo root not found; skipped auto-sync. Use -MusicRoot <path> or run from apps/pure_player_lyric inside the Pure-music repo."
    }
}
else {
    Write-Host "SkipSync set; not copying into monorepo desktop_lyric/." -ForegroundColor DarkYellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "All files have been output to: $finalOutputDir" -ForegroundColor Yellow
Write-Host "  - Main: desktop_lyric.exe (icon embedded via Runner.rc)`n" -ForegroundColor Yellow

if (-not $NoPause) { Read-Host "Press Enter to exit..." }
