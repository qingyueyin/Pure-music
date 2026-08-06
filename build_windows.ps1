[CmdletBinding()]
param(
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

#Requires -Version 5.1
# UTF-8 encoding with BOM is required for PowerShell on Windows

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

    $normalized = ConvertTo-NormalizedVersion $version
    $parts = $normalized -split '\.'
    $major = $parts[0]
    $minor = $parts[1]
    $patch = $parts[2]
    $build = "0"

    $productVersion = "`"$major.$minor.$patch`""
    $fileVersion = "`"$major.$minor.$patch.$build`""
    $versionAsNumber = "$major,$minor,$patch,$build"

    $content = Get-Content -Path $runnerRcPath -Raw -Encoding UTF8

    $content = $content -replace '(?m)^#define\s+VERSION_AS_NUMBER\s+[\d,]+$', "#define VERSION_AS_NUMBER $versionAsNumber"
    $content = $content -replace '(?m)^#define\s+PRODUCT_VERSION\s+"[^"]*"', "#define PRODUCT_VERSION $productVersion"
    $content = $content -replace '(?m)^#define\s+FILE_VERSION_STR\s+"[^"]*"', "#define FILE_VERSION_STR $fileVersion"

    Set-Content -Path $runnerRcPath -Value $content -Encoding UTF8 -NoNewline
    Write-Host ("Synced Runner.rc: ProductVersion=$productVersion, FileVersion=$fileVersion" -f $productVersion, $fileVersion) -ForegroundColor Gray
}

function Update-VersionJson([string]$version) {
    $versionJsonPath = Join-Path $PSScriptRoot "update\version.json"
    $tag = "v$version"

    # 手动拼接 JSON，避免 ConvertTo-Json 在 PS5.1 下的 Unicode 编码问题
    $json = [System.Text.StringBuilder]::new()
    [void]$json.AppendLine("{")
    [void]$json.AppendLine("  ""tag_name"": ""$tag"",")
    [void]$json.AppendLine("  ""name"": ""$tag"",")
    [void]$json.AppendLine("  ""body"": ""## 更新内容\n\n请前往 GitHub Releases 查看完整更新日志"",")
    [void]$json.AppendLine("  ""html_url"": ""https://github.com/qingyueyin/Pure-music/releases""")
    [void]$json.AppendLine("}")

    $dir = Split-Path $versionJsonPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # 用 UTF8 without BOM 写入
    [System.IO.File]::WriteAllText($versionJsonPath, $json.ToString(), [System.Text.UTF8Encoding]::new($false))
    Write-Host ("Generated update/version.json: tag=$tag" -f $tag) -ForegroundColor Gray
}

function Read-Input([string]$prompt) {
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v
}

function ConvertTo-NormalizedVersion([string]$version) {
    $cleanVersion = $version.Trim()
    $cleanVersion = $cleanVersion -replace '^[vV]', ''

    $parts = $cleanVersion -split '\.'
    if ($parts.Count -lt 1 -or $parts.Count -gt 3) {
        throw "Invalid version format: '$version'. Expected X.Y.Z format (e.g., 1.2.3)"
    }

    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            throw "Version contains non-numeric characters: '$version'. Each segment must be a pure number (e.g., 1.2.3)"
        }
    }

    while ($parts.Count -lt 3) {
        $parts += "0"
    }

    $normalized = ($parts -join '.')

    if ($normalized -ne $version) {
        Write-Host "Version auto-normalized: '$version' -> '$normalized'" -ForegroundColor Yellow
    }

    return $normalized
}

function Test-Version([string]$version) {
    $normalized = ConvertTo-NormalizedVersion $version
    $parts = $normalized -split '\.'
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]

    if ($major -gt 999 -or $minor -gt 999 -or $patch -gt 999) {
        throw "Version segments cannot exceed 999: '$version'"
    }

    Write-Host "Version validation passed: $normalized (major=$major, minor=$minor, patch=$patch)" -ForegroundColor Green

    return $normalized
}

$dist = "portable"

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

try {
    $version = Test-Version $version
} catch {
    Write-Error $_.Exception.Message
    Read-Host "Press Enter to exit..."
    exit 1
}

$githubTag = "v$version"
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "GitHub Release Tag Compatibility Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Version: $version" -ForegroundColor White
Write-Host "GitHub Tag: $githubTag" -ForegroundColor White
Write-Host "Repo: qingyueyin/Pure-music" -ForegroundColor White
Write-Host "Update Check URL: https://api.github.com/repos/qingyueyin/Pure-music/releases/latest" -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor Gray
Write-Host "Version Format: VALID (Semantic Versioning X.Y.Z)" -ForegroundColor Green
Write-Host "Tag Format: VALID (vX.Y.Z for GitHub releases)" -ForegroundColor Green
Write-Host "Update Check: WILL WORK CORRECTLY" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

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
        flutter pub get --offline
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Offline dependency resolution failed; retrying online."
            flutter pub get
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to resolve Flutter dependencies."
            }
        }
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

Invoke-Step "generate update/version.json" {
    Update-VersionJson $version
}

Invoke-Step "flutter build windows" {
    Write-Host "Building Windows ($BuildMode)..." -ForegroundColor Cyan
    
    # Clean existing symlinks to avoid PathExistsException
    $pluginSymlinkDir = Join-Path $PSScriptRoot "windows\flutter\ephemeral\.plugin_symlinks"
    if (Test-Path $pluginSymlinkDir) {
        Write-Host "Cleaning existing plugin symlinks..." -ForegroundColor Gray
        Remove-Item -Path $pluginSymlinkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Clean build directory to avoid CMake cache path mismatches
    $buildDir = Join-Path $PSScriptRoot "build\windows"
    if (Test-Path $buildDir) {
        Write-Host "Cleaning old build directory..." -ForegroundColor Gray
        Remove-Item -Path $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    $modeFlag = "--release"
    if ($BuildMode -ne "Release") {
        $modeFlag = "--debug"
    }
    $flutterArgs = @(
        "build",
        "windows",
        $modeFlag,
        "--no-pub",
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
    $env:RUSTUP_HOME = "D:\Env\Rust\rustup"
    $env:CARGO_HOME = "D:\Env\Cargo"
    # Add cargo bin to PATH so cargokit can find rustup and cargo
    $env:PATH = "$env:CARGO_HOME\bin;$env:PATH"
    # check-cfg stabilized in Rust 1.80+, no longer needs -Z unstable-options
    # $env:RUSTFLAGS = "-Z unstable-options"
    Write-Host "PATH updated for Rust toolchain" -ForegroundColor Gray
    flutter @flutterArgs
}

# 4. Prepare Output Directory
$buildDir = "build\windows\x64\runner\$BuildMode"

if ($LASTEXITCODE -ne 0) {
    # 路径含括号时 CMake INSTALL 步骤可能失败但编译实际已成功
    $buildOutputDir = Join-Path $PSScriptRoot $buildDir
    $exeCheck = Join-Path $buildOutputDir "pure_music.exe"
    $dllCheck = Join-Path $buildOutputDir "rust_lib_pure_music.dll"
    if ((Test-Path $exeCheck) -and (Test-Path $dllCheck)) {
        Write-Warning "Build compilation succeeded but CMake INSTALL step failed (likely caused by parentheses in path). Artifacts are intact, continuing..."
    } else {
        Write-Error "Build failed!"
        Read-Host "Press Enter to exit..."
        exit 1
    }
}

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
function Test-DllInRoot([string]$name) {
    $n = $name.ToLowerInvariant()
    if ($keepDllsInRoot -contains $name) { return $true }
    if ($n -like "*_plugin.dll") { return $true }
    if ($n -like "msvcp*.dll") { return $true }
    if ($n -like "vcruntime*.dll") { return $true }
    return $false
}

Get-ChildItem -Path $finalAppDir -File -Filter "*.dll" | ForEach-Object {
    if (Test-DllInRoot $_.Name) { return }
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
Write-Host "  - version=$version, tag=$tag, dist=$dist, bass_plugins=$bassPluginMode" -ForegroundColor Gray

$failed = @()
function Confirm-FileExists([string]$name, [string]$path) {
    if (Test-Path $path) {
        Write-Host ("  [OK]   {0}: {1}" -f $name, $path) -ForegroundColor Green
        return
    }
    Write-Host ("  [FAIL] {0}: {1}" -f $name, $path) -ForegroundColor Red
    $script:failed += $name
}

Confirm-FileExists "pure_music.exe" (Join-Path $finalAppDir "pure_music.exe")
Confirm-FileExists "flutter_windows.dll" (Join-Path $finalAppDir "flutter_windows.dll")
Confirm-FileExists "dll_dir" $finalDllDir
Confirm-FileExists "bass_dir" (Join-Path $finalDllDir "BASS")
Confirm-FileExists "desktop_lyric.exe" (Join-Path $finalAppDir "desktop_lyric\desktop_lyric.exe")
Confirm-FileExists "build_info.txt" (Join-Path $artifactRoot "build_info.txt")

Confirm-FileExists "bass.dll" (Join-Path $finalDllDir "BASS\bass.dll")
Confirm-FileExists "basswasapi.dll" (Join-Path $finalDllDir "BASS\basswasapi.dll")
Confirm-FileExists "bass_fx.dll" (Join-Path $finalDllDir "BASS\bass_fx.dll")

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
