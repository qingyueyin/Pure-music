# Windows Build Script for Pure Music

[CmdletBinding()]
param(
    [ValidateSet("portable", "exe")]
    [string]$Distribution = "",

    [string]$Version = "",

    [ValidateSet("Release", "Debug")]
    [string]$BuildMode = "Release",

    [switch]$SkipPubGet,

    [switch]$VerboseBuild
)

try { chcp 65001 | Out-Null } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = "Stop"

$finalOutputDir = Join-Path $PSScriptRoot "output"

try {
    $psv = $PSVersionTable.PSVersion
    $enc = [Console]::OutputEncoding.WebName
    Write-Host ("Env: PowerShell {0}, ConsoleEncoding {1}" -f $psv, $enc) -ForegroundColor Gray
} catch {}

function Get-AppSettingsVersion() {
    $pubspec = Join-Path $PSScriptRoot "pubspec.yaml"
    if (Test-Path $pubspec) {
        $content = Get-Content -Path $pubspec -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $m = [regex]::Match($content, '(?m)^\s*version\s*:\s*([^\r\n]+)\s*$')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
    }

    $p = Join-Path $PSScriptRoot "lib\core\settings.dart"
    if (-not (Test-Path $p)) { return "" }
    $content = Get-Content -Path $p -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return "" }
    $m = [regex]::Match($content, 'static\s+const\s+String\s+version\s*=\s*["'']([^"'']+)["'']')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Update-RunnerRcVersion([string]$version, [string]$buildMode) {
    $runnerRcPath = Join-Path $PSScriptRoot "windows\runner\Runner.rc"
    if (-not (Test-Path $runnerRcPath)) {
        Write-Warning "Runner.rc not found at $runnerRcPath, skipping version sync."
        return
    }

    $cleanVersion = $version -replace '^[a-zA-Z]+', ''
    $parts = $cleanVersion -split '\.'
    $major = if ($parts.Count -ge 1) { $parts[0] } else { "0" }
    $minor = if ($parts.Count -ge 2) { $parts[1] } else { "0" }
    $patch = if ($parts.Count -ge 3) { $parts[2] } else { "0" }
    $build = "0"

    $productVersion = "`"$major.$minor.$patch`""
    $fileVersion = "`"$major.$minor.$patch-$buildMode`""
    $versionAsNumber = "$major,$minor,$patch,$build"

    $content = Get-Content -Path $runnerRcPath -Raw -Encoding UTF8

    $content = $content -replace '(?m)^#define\s+VERSION_AS_NUMBER\s+[\d,]+$', "#define VERSION_AS_NUMBER $versionAsNumber"
    $content = $content -replace '(?m)^#define\s+PRODUCT_VERSION\s+"[^"]*"', "#define PRODUCT_VERSION $productVersion"
    $content = $content -replace '(?m)^#define\s+FILE_VERSION_STR\s+"[^"]*"', "#define FILE_VERSION_STR $fileVersion"

    Set-Content -Path $runnerRcPath -Value $content -Encoding UTF8 -NoNewline
    Write-Host ("Synced Runner.rc: ProductVersion=$major.$minor.$patch, FileVersion=$major.$minor.$patch-$buildMode" -f $version, $buildMode) -ForegroundColor Gray
}

function Read-Input([string]$prompt) {
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v
}

if ([string]::IsNullOrWhiteSpace($Distribution)) {
    $distInput = Read-Input "Distribution: 1)portable  2)exe (non-portable)  (default 1)"
    if ($distInput -eq "2") {
        $dist = "exe"
        $portableBuild = "false"
    }
    else {
        $dist = "portable"
        $portableBuild = "true"
    }
}
else {
    $dist = $Distribution
    if ($dist -eq "portable") {
        $portableBuild = "true"
    }
    else {
        $portableBuild = "false"
    }
}

$tag = "release"

$defaultVersion = Get-AppSettingsVersion
if ([string]::IsNullOrWhiteSpace($defaultVersion)) { $defaultVersion = "unknown" }
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionInput = (Read-Input "Version").Trim()
    if ([string]::IsNullOrWhiteSpace($versionInput)) { $versionInput = $defaultVersion }
    $version = $versionInput
}
else {
    $version = $Version.Trim()
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $defaultVersion }
}

$bassPluginMode = "full"

$artifactRoot = Join-Path $finalOutputDir ("pure_music_{0}_{1}_{2}" -f $version, $tag, $dist)
$finalAppDir = Join-Path $artifactRoot "app"
$finalDllDir = Join-Path $finalAppDir "dll"

Write-Host ("Starting build process ({0} Mode)..." -f $BuildMode) -ForegroundColor Green

# Speed knobs (safe defaults)
# - CMake drives the native Windows build; parallelism can dramatically reduce build time.
#   https://cmake.org/cmake/help/latest/envvar/CMAKE_BUILD_PARALLEL_LEVEL.html
if (-not $env:CMAKE_BUILD_PARALLEL_LEVEL) {
    try {
        $env:CMAKE_BUILD_PARALLEL_LEVEL = [Environment]::ProcessorCount
    } catch {
        $env:CMAKE_BUILD_PARALLEL_LEVEL = 8
    }
}
Write-Host ("CMAKE_BUILD_PARALLEL_LEVEL={0}" -f $env:CMAKE_BUILD_PARALLEL_LEVEL) -ForegroundColor Gray

function Invoke-Step([string]$name, [scriptblock]$action) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("\n>>> {0}" -f $name) -ForegroundColor Cyan
    & $action
    $sw.Stop()
    Write-Host ("<<< {0} done in {1:n1}s" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Gray
}

function Invoke-RoboCopy([string]$src, [string]$dest) {
    if (-not (Test-Path $src)) { throw "Source not found: $src" }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    # robocopy exit codes: 0-7 are success (including copied files).
    robocopy $src $dest /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed (code=$LASTEXITCODE) src=$src dest=$dest"
    }
}

# Check if flutter is available
if (-not (Get-Command "flutter" -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter command not found. Please ensure Flutter is installed and in your PATH."
    Read-Host "Press Enter to exit..."
    exit 1
}

Invoke-Step "pub get" {
    if ($SkipPubGet) {
        Write-Host "Skipping flutter pub get (SkipPubGet)." -ForegroundColor Gray
        return
    }

    # Smart flutter pub get
    $needPubGet = $true
    $packageConfig = ".dart_tool\package_config.json"
    if ((Test-Path "pubspec.lock") -and (Test-Path $packageConfig)) {
        $yamlTime = (Get-Item "pubspec.yaml").LastWriteTime
        $lockTime = (Get-Item "pubspec.lock").LastWriteTime
        if ($yamlTime -le $lockTime) {
            $needPubGet = $false
        }
    }

    if ($needPubGet) {
        flutter pub get
    }
    else {
        Write-Host "Dependencies up to date; skipping pub get." -ForegroundColor Gray
    }
}

# 2. Pre-build: Copy app icon to resources
$appIconSource = Join-Path $PSScriptRoot "app_icon.ico"
$appIconResourceDest = Join-Path $PSScriptRoot "windows\runner\resources\app_icon.ico"
if (Test-Path $appIconSource) {
    Write-Host "Updating application icon ($appIconResourceDest)..." -ForegroundColor Cyan
    Copy-Item -Path $appIconSource -Destination $appIconResourceDest -Force
}
else {
    Write-Warning "app_icon.ico not found in project root. The application icon might be default."
}

Invoke-Step "sync version to Runner.rc" {
    Update-RunnerRcVersion $version $BuildMode
}

Invoke-Step "flutter build windows" {
    Write-Host "Building Windows ($BuildMode)..." -ForegroundColor Cyan
    $modeFlag = "--release"
    if ($BuildMode -ne "Release") {
        $modeFlag = "--debug"
    }
    $flutterArgs = @(
        "build",
        "windows",
        $modeFlag,
        "--no-pub",
        "--dart-define=PORTABLE_BUILD=$portableBuild",
        "--dart-define=APP_VERSION=$version"
    )
    if ($VerboseBuild) {
        $flutterArgs += "--verbose"
    }
$issueReportingEnabled = $false
if ($env:ENABLE_ISSUE_REPORTING) {
    $issueReportingEnabled = $true
}

if ($issueReportingEnabled) {
    if (-not $env:CPFEEDBACK_KEY) {
        Write-Warning "ENABLE_ISSUE_REPORTING is set but CPFEEDBACK_KEY is missing; issue reporting will be disabled."
        $issueReportingEnabled = $false
    }
    else {
        Write-Host "Issue reporting enabled (ENABLE_ISSUE_REPORTING)." -ForegroundColor Gray
        $flutterArgs += "--dart-define=ENABLE_ISSUE_REPORTING=true"
        $flutterArgs += "--dart-define=CPFEEDBACK_KEY=$($env:CPFEEDBACK_KEY)"
    }
}

if (-not $issueReportingEnabled) {
        Write-Host "Issue reporting disabled (default)." -ForegroundColor Gray
    }
    flutter @flutterArgs
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed!"
    Read-Host "Press Enter to exit..."
    exit 1
}

# 4. Prepare Output Directory
$buildDir = "build\windows\x64\runner\$BuildMode"

Write-Host "Preparing Output Directory: $artifactRoot..." -ForegroundColor Cyan

# Check for running instance and kill it
$processName = "pure_music"
if (Get-Process $processName -ErrorAction SilentlyContinue) {
    Write-Host "Stopping running instance of $processName..." -ForegroundColor Yellow
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1 # Wait for file locks to release
}

if (-not (Test-Path $finalOutputDir)) {
    New-Item -ItemType Directory -Force -Path $finalOutputDir | Out-Null
}
if (Test-Path $artifactRoot) {
    Remove-Item -Path $artifactRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
New-Item -ItemType Directory -Force -Path $finalAppDir | Out-Null
New-Item -ItemType Directory -Force -Path $finalDllDir | Out-Null

Invoke-Step "copy build artifacts" {
    Write-Host "Copying build artifacts to output directory..." -ForegroundColor Cyan
    Invoke-RoboCopy $buildDir $finalAppDir
}

Write-Host "Normalizing plugin DLL locations..." -ForegroundColor Cyan
Get-ChildItem -Path $finalAppDir -Recurse -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
    Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
}
Get-ChildItem -Path $finalAppDir -Recurse -File -Filter "msvcp*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
    Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
}
Get-ChildItem -Path $finalAppDir -Recurse -File -Filter "vcruntime*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
    Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
}

Write-Host "Organizing DLLs into: $finalDllDir" -ForegroundColor Cyan
$keepDllsInRoot = @(
    "flutter_windows.dll"
)
function ShouldKeep-DllInRoot([string]$name) {
    $n = $name.ToLowerInvariant()
    if ($keepDllsInRoot -contains $name) { return $true }
    if ($n -like "*_plugin.dll") { return $true }
    if ($n -like "msvcp*.dll") { return $true }
    if ($n -like "vcruntime*.dll") { return $true }
    return $false
}

Get-ChildItem -Path $finalAppDir -File -Filter "*.dll" | ForEach-Object {
    if (ShouldKeep-DllInRoot $_.Name) { return }
    Move-Item -Path $_.FullName -Destination (Join-Path $finalDllDir $_.Name) -Force
}

Get-ChildItem -Path $finalAppDir -File -Include "*.exp","*.lib" | ForEach-Object {
    Remove-Item -Path $_.FullName -Force
}

Get-ChildItem -Path $finalAppDir -Recurse -File -Include "*.pdb","*.ilk" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
}

$buildInfoPath = Join-Path $artifactRoot "build_info.txt"
$buildInfoText = @(
    "version=$version",
    "tag=$tag",
    "dist=$dist",
    "portable_build=$portableBuild",
    "bass_plugins=$bassPluginMode",
    "build_time=$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))"
) -join "`n"
Set-Content -Path $buildInfoPath -Value $buildInfoText -Encoding UTF8

# 6. Copy Additional Dependencies to Output Directory

Invoke-Step "copy BASS DLLs" {
$bassSrcDir = "BASS"
$bassDestDir = Join-Path $finalDllDir "BASS"
if (Test-Path $bassSrcDir) {
    Write-Host "Copying BASS DLLs..." -ForegroundColor Cyan
    if (-not (Test-Path $bassDestDir)) {
        New-Item -ItemType Directory -Force -Path $bassDestDir | Out-Null
    }

    $requiredDLLs = @("bass.dll", "basswasapi.dll", "bass_fx.dll")
    foreach ($dll in $requiredDLLs) {
        $src = Join-Path $bassSrcDir $dll
        if (-not (Test-Path $src)) {
            Write-Error "$dll not found in source BASS folder: $bassSrcDir"
            Read-Host "Press Enter to exit..."
            exit 1
        }
        Copy-Item -Path $src -Destination (Join-Path $bassDestDir $dll) -Force
    }

    if ($bassPluginMode -eq "full") {
        Invoke-RoboCopy $bassSrcDir $bassDestDir
    }
    else {
        $litePlugins = @("bassflac.dll", "bassape.dll", "bassopus.dll")
        foreach ($dll in $litePlugins) {
            $src = Join-Path $bassSrcDir $dll
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination (Join-Path $bassDestDir $dll) -Force
            }
        }
    }

    $missingDLLs = @()
    
    foreach ($dll in $requiredDLLs) {
        if (-not (Test-Path "$bassDestDir\$dll")) {
            $missingDLLs += $dll
            Write-Warning "$dll not found in output directory!"
        }
    }
    
    if ($missingDLLs.Count -gt 0) {
        Write-Error "Missing BASS DLLs: $($missingDLLs -join ', ')`nPlease check if they exist in source BASS folder: $bassSrcDir"
        Read-Host "Press Enter to exit..."
        exit 1
    }
    }
    else {
        Write-Error "BASS directory not found in project root ($bassSrcDir)."
        Write-Error "The application cannot play audio without bass.dll, basswasapi.dll and bass_fx.dll."
        Read-Host "Press Enter to exit..."
        exit 1
    }
}

Invoke-Step "copy desktop_lyric" {
    $desktopLyricSrc = "desktop_lyric"
    $desktopLyricDest = Join-Path $finalAppDir "desktop_lyric"
    if (Test-Path $desktopLyricSrc) {
        Write-Host "Copying desktop_lyric..." -ForegroundColor Cyan
        Invoke-RoboCopy $desktopLyricSrc $desktopLyricDest
    }
    else {
        Write-Warning "desktop_lyric directory not found in project root ($desktopLyricSrc)!"
    }
}

# Note: app_icon.ico is embedded in exe via Runner.rc during compilation
# No separate copy to output directory needed

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "All files have been output to: $artifactRoot" -ForegroundColor Yellow
Write-Host "  - Main: app/pure_music.exe (icon embedded via Runner.rc)"
Write-Host "  - Dependencies: app/dll/*.dll, app/dll/BASS/*.dll, app/desktop_lyric/" -ForegroundColor Yellow
Write-Host "  - Build Info: build_info.txt`n" -ForegroundColor Yellow

Write-Host "Self-check:" -ForegroundColor Cyan
Write-Host "  - version=$version, tag=$tag, dist=$dist, portable_build=$portableBuild, bass_plugins=$bassPluginMode" -ForegroundColor Gray

$failed = @()
function Check-Exists([string]$name, [string]$path) {
    if (Test-Path $path) {
        Write-Host ("  [OK]   {0}: {1}" -f $name, $path) -ForegroundColor Green
        return
    }
    Write-Host ("  [FAIL] {0}: {1}" -f $name, $path) -ForegroundColor Red
    $script:failed += $name
}

Check-Exists "pure_music.exe" (Join-Path $finalAppDir "pure_music.exe")
Check-Exists "flutter_windows.dll" (Join-Path $finalAppDir "flutter_windows.dll")
Check-Exists "dll_dir" $finalDllDir
Check-Exists "bass_dir" (Join-Path $finalDllDir "BASS")
Check-Exists "desktop_lyric.exe" (Join-Path $finalAppDir "desktop_lyric\desktop_lyric.exe")
Check-Exists "build_info.txt" (Join-Path $artifactRoot "build_info.txt")

Check-Exists "bass.dll" (Join-Path $finalDllDir "BASS\bass.dll")
Check-Exists "basswasapi.dll" (Join-Path $finalDllDir "BASS\basswasapi.dll")
Check-Exists "bass_fx.dll" (Join-Path $finalDllDir "BASS\bass_fx.dll")

$pluginDllCount = 0
try {
    $pluginDllCount = (Get-ChildItem -Path $finalAppDir -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue).Count
} catch {}
Write-Host ("  - plugin dlls: {0}" -f $pluginDllCount) -ForegroundColor Gray

if ($pluginDllCount -eq 0) {
    Write-Host "  [FAIL] no *_plugin.dll found next to exe; app will not start." -ForegroundColor Red
    $failed += "plugin_dlls"
}

if ($failed.Count -gt 0) {
    Write-Host ("Self-check failed: {0}" -f ($failed -join ", ")) -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}
Write-Host "Self-check passed." -ForegroundColor Green

Read-Host "Press Enter to exit..."
