#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version = "",
    [ValidateSet(0, 1, 2, 3, 4, 5)]
    [int]$Mode = 0,
    [switch]$NonInteractive
)

try { chcp 65001 | Out-Null } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = "Stop"

$finalOutputDir = Join-Path $PSScriptRoot "output"
$script:stagingContainer = $null

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
    return ""
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

    while ($parts.Count -lt 3) { $parts += "0" }
    $normalized = ($parts -join '.')

    if ($normalized -ne $version) {
        Write-Host "Version auto-normalized: '$version' -> '$normalized'" -ForegroundColor Yellow
    }
    return $normalized
}

function Test-Version([string]$version) {
    $normalized = ConvertTo-NormalizedVersion $version
    $parts = $normalized -split '\.'
    if ([int]$parts[0] -gt 999 -or [int]$parts[1] -gt 999 -or [int]$parts[2] -gt 999) {
        throw "Version segments cannot exceed 999: '$version'"
    }
    Write-Host "Version validation passed: $normalized" -ForegroundColor Green
    return $normalized
}

function Read-Input([string]$prompt) {
    if ($NonInteractive) { return "" }
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v
}

function Wait-ForExitPrompt() {
    if (-not $NonInteractive) {
        Read-Host "Press Enter to exit..." | Out-Null
    }
}

function Invoke-Step([string]$name, [scriptblock]$action) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("`n>>> {0}" -f $name) -ForegroundColor Cyan
    & $action
    $sw.Stop()
    Write-Host ("<<< {0} done in {1:n1}s" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Gray
}

function Invoke-RoboCopy([string]$src, [string]$dest) {
    if (-not (Test-Path $src)) { throw "Source not found: $src" }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    robocopy $src $dest /E /COPY:DAT /DCOPY:DAT /XJ /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed (code=$LASTEXITCODE) src=$src dest=$dest"
    }
}

function Write-Utf8NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-InnoSetupCompilerPath() {
    foreach ($candidate in @(
        "D:\App\Inno Setup 7\ISCC.exe",
        "C:\Program Files\Inno Setup 7\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 7\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Assert-PathWithin([string]$path, [string]$parent) {
    $fullPath = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    $fullParent = [System.IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'
    if (-not ($fullPath + '\').StartsWith($fullParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $fullPath"
    }
}

function Update-PubspecVersion([string]$version) {
    $pubspecPath = Join-Path $PSScriptRoot "pubspec.yaml"
    if (-not (Test-Path $pubspecPath)) { throw "pubspec.yaml not found." }

    $content = Get-Content -Path $pubspecPath -Raw -Encoding UTF8
    $pattern = [regex]::new('(?m)^version\s*:\s*[^\r\n]+$')
    if (-not $pattern.IsMatch($content)) {
        throw "Version field not found in pubspec.yaml."
    }
    $content = $pattern.Replace($content, "version: $version", 1)
    [System.IO.File]::WriteAllText($pubspecPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Synced pubspec.yaml: version=$version" -ForegroundColor Gray
}

function Update-RunnerRcVersion([string]$version) {
    $runnerRcPath = Join-Path $PSScriptRoot "windows\runner\Runner.rc"
    if (-not (Test-Path $runnerRcPath)) {
        Write-Warning "Runner.rc not found at $runnerRcPath, skipping version sync."
        return
    }

    $parts = $version -split '\.'
    $major = $parts[0]
    $minor = $parts[1]
    $patch = $parts[2]
    $build = "0"

    $content = Get-Content -Path $runnerRcPath -Raw -Encoding UTF8
    $content = $content -replace '(?m)^#define\s+VERSION_AS_NUMBER\s+[\d,]+$', "#define VERSION_AS_NUMBER $major,$minor,$patch,$build"
    $content = $content -replace '(?m)^#define\s+PRODUCT_VERSION\s+"[^"]*"', "#define PRODUCT_VERSION `"$major.$minor.$patch`""
    $content = $content -replace '(?m)^#define\s+FILE_VERSION_STR\s+"[^"]*"', "#define FILE_VERSION_STR `"$major.$minor.$patch.$build`""

    Set-Content -Path $runnerRcPath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Synced Runner.rc: ProductVersion=$major.$minor.$patch, FileVersion=$major.$minor.$patch.$build" -ForegroundColor Gray
}

function Update-VersionJson([string]$version) {
    $versionJsonPath = Join-Path $PSScriptRoot "update\version.json"
    $json = [System.Text.StringBuilder]::new()
    [void]$json.AppendLine("{")
    [void]$json.AppendLine("  ""tag_name"": ""v$version"",")
    [void]$json.AppendLine("  ""name"": ""v$version"",")
    [void]$json.AppendLine("  ""body"": ""## 更新内容\n\n请前往 GitHub Releases 查看完整更新日志"",")
    [void]$json.AppendLine("  ""html_url"": ""https://github.com/qingyueyin/Pure-music/releases""")
    [void]$json.AppendLine("}")
    Write-Utf8NoBom $versionJsonPath $json.ToString()
    Write-Host "Generated update/version.json: tag=v$version" -ForegroundColor Gray
}

function New-StagingContainer() {
    if (-not (Test-Path -LiteralPath $finalOutputDir)) {
        New-Item -ItemType Directory -Force -Path $finalOutputDir | Out-Null
    }
    $script:stagingContainer = Join-Path $finalOutputDir (".staging-{0}" -f [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:stagingContainer | Out-Null
    return $script:stagingContainer
}

function Remove-StagingContainer() {
    if ($script:stagingContainer -and (Test-Path -LiteralPath $script:stagingContainer)) {
        Assert-PathWithin $script:stagingContainer $finalOutputDir
        Remove-Item -LiteralPath $script:stagingContainer -Recurse -Force -ErrorAction SilentlyContinue
        $script:stagingContainer = $null
    }
}

function Update-BuildVersionFiles([string]$version) {
    Update-PubspecVersion $version
    Update-RunnerRcVersion $version
    Update-VersionJson $version
}

function Invoke-Build([string]$version, [bool]$isPortable) {
    if (-not (Get-Command "flutter" -ErrorAction SilentlyContinue)) {
        throw "flutter command not found in PATH."
    }

    Invoke-Step "pub get" {
        $needPubGet = $true
        $packageConfig = Join-Path $PSScriptRoot ".dart_tool\package_config.json"
        if ((Test-Path (Join-Path $PSScriptRoot "pubspec.lock")) -and (Test-Path $packageConfig)) {
            $yamlTime = (Get-Item (Join-Path $PSScriptRoot "pubspec.yaml")).LastWriteTime
            $lockTime = (Get-Item (Join-Path $PSScriptRoot "pubspec.lock")).LastWriteTime
            if ($yamlTime -le $lockTime) { $needPubGet = $false }
        }
        if ($needPubGet) {
            Push-Location $PSScriptRoot
            try {
                flutter pub get --offline
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Offline dependency resolution failed; retrying online."
                    flutter pub get
                    if ($LASTEXITCODE -ne 0) { throw "Failed to resolve Flutter dependencies." }
                }
            }
            finally { Pop-Location }
        }
        else {
            Write-Host "Dependencies up to date; skipping pub get." -ForegroundColor Gray
        }
    }

    $appIconSource = Join-Path $PSScriptRoot "app_icon.ico"
    $appIconResourceDest = Join-Path $PSScriptRoot "windows\runner\resources\app_icon.ico"
    if (Test-Path $appIconSource) {
        Write-Host "Updating application icon..." -ForegroundColor Cyan
        Copy-Item -Path $appIconSource -Destination $appIconResourceDest -Force
    }
    else {
        Write-Warning "app_icon.ico not found in project root."
    }

    Invoke-Step "sync version files" {
        Update-BuildVersionFiles $version
    }

    Invoke-Step "flutter build windows" {
        $pluginSymlinkDir = Join-Path $PSScriptRoot "windows\flutter\ephemeral\.plugin_symlinks"
        if (Test-Path $pluginSymlinkDir) {
            Assert-PathWithin $pluginSymlinkDir $PSScriptRoot
            Remove-Item -LiteralPath $pluginSymlinkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $buildDir = Join-Path $PSScriptRoot "build\windows"
        if (Test-Path $buildDir) {
            Assert-PathWithin $buildDir $PSScriptRoot
            Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $flutterArgs = @(
            "build",
            "windows",
            "--release",
            "--no-pub",
            "--dart-define=APP_VERSION=$version",
            "--dart-define=PORTABLE_BUILD=$($isPortable.ToString().ToLowerInvariant())"
        )
        Push-Location $PSScriptRoot
        try {
            flutter @flutterArgs
            if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed with exit code $LASTEXITCODE." }
        }
        finally { Pop-Location }
    }
}

function New-AppPackage([string]$artifactRoot, [string]$version) {
    $buildDir = Join-Path $PSScriptRoot "build\windows\x64\runner\Release"
    if (-not (Test-Path -LiteralPath (Join-Path $buildDir "pure_music.exe") -PathType Leaf)) {
        throw "Build output is incomplete: $buildDir"
    }

    $finalAppDir = Join-Path $artifactRoot "app"
    $finalDllDir = Join-Path $finalAppDir "dll"
    New-Item -ItemType Directory -Force -Path $finalDllDir | Out-Null

    Invoke-Step "copy build artifacts" {
        Invoke-RoboCopy $buildDir $finalAppDir
    }

    Write-Host "Normalizing plugin DLL locations..." -ForegroundColor Cyan
    Get-ChildItem -Path $finalAppDir -Recurse -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
        Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
    }
    foreach ($pattern in @("msvcp*.dll", "vcruntime*.dll")) {
        Get-ChildItem -Path $finalAppDir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
            Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
        }
    }

    Write-Host "Organizing DLLs into: $finalDllDir" -ForegroundColor Cyan
    function Test-DllInRoot([string]$name) {
        if ($name -eq "flutter_windows.dll") { return $true }
        if ($name -like "*_plugin.dll") { return $true }
        if ($name -like "msvcp*.dll") { return $true }
        if ($name -like "vcruntime*.dll") { return $true }
        return $false
    }
    Get-ChildItem -Path $finalAppDir -File -Filter "*.dll" | ForEach-Object {
        if (Test-DllInRoot $_.Name) { return }
        Move-Item -Path $_.FullName -Destination (Join-Path $finalDllDir $_.Name) -Force
    }

    Get-ChildItem -Path $finalAppDir -Recurse -File -Include "*.pdb","*.ilk","*.exp","*.lib" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }

    Invoke-Step "copy BASS DLLs" {
        $bassSrcDir = Join-Path $PSScriptRoot "BASS"
        $bassDestDir = Join-Path $finalDllDir "BASS"
        if (-not (Test-Path $bassSrcDir)) {
            throw "BASS directory not found in project root: $bassSrcDir"
        }
        New-Item -ItemType Directory -Force -Path $bassDestDir | Out-Null
        foreach ($dll in @("bass.dll", "basswasapi.dll", "bass_fx.dll")) {
            $src = Join-Path $bassSrcDir $dll
            if (-not (Test-Path $src)) { throw "$dll not found in source BASS folder: $bassSrcDir" }
            Copy-Item -Path $src -Destination (Join-Path $bassDestDir $dll) -Force
        }
        Invoke-RoboCopy $bassSrcDir $bassDestDir
        foreach ($dll in @("bass.dll", "basswasapi.dll", "bass_fx.dll")) {
            if (-not (Test-Path "$bassDestDir\$dll")) { throw "Missing BASS DLL: $dll" }
        }
    }

    Invoke-Step "copy desktop_lyric" {
        $desktopLyricSrc = Join-Path $PSScriptRoot "desktop_lyric"
        $desktopLyricDest = Join-Path $finalAppDir "desktop_lyric"
        if (-not (Test-Path $desktopLyricSrc)) {
            throw "desktop_lyric directory not found in project root: $desktopLyricSrc"
        }
        Invoke-RoboCopy $desktopLyricSrc $desktopLyricDest
    }

    return $finalAppDir
}

function Test-KeyFiles([string]$appDir) {
    $required = @(
        "pure_music.exe",
        "flutter_windows.dll",
        "data\app.so",
        "dll\rust_lib_pure_music.dll",
        "dll\BASS\bass.dll",
        "dll\BASS\basswasapi.dll",
        "dll\BASS\bass_fx.dll",
        "desktop_lyric\desktop_lyric.exe"
    )
    $missing = @()
    foreach ($rp in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $rp) -PathType Leaf)) { $missing += $rp }
    }
    $pluginCount = @(Get-ChildItem -LiteralPath $appDir -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue).Count
    if ($pluginCount -eq 0) { $missing += "*_plugin.dll (none found)" }

    if ($missing.Count -gt 0) {
        throw "Package missing required files: $($missing -join ', ')"
    }
    Write-Host "Key file check passed." -ForegroundColor Green
}

function Write-BuildInfo([string]$packageRoot, [string]$version, [string]$dist) {
    $buildInfo = @(
        "version=$version",
        "tag=release",
        "dist=$dist",
        "architecture=x64",
        "build_mode=Release",
        "build_time=$([DateTimeOffset]::Now.ToString('o'))"
    ) -join "`n"
    Write-Utf8NoBom (Join-Path $packageRoot "build_info.txt") $buildInfo
}

function New-PortablePackage([string]$version, [bool]$buildFirst, [bool]$makeZip) {
    $dist = "portable"
    if ($buildFirst) { Invoke-Build $version $true }
    $artifactName = "pure_music_{0}_release_portable" -f $version
    $publishedRoot = Join-Path $finalOutputDir $artifactName
    $publishedZip = Join-Path $finalOutputDir "$artifactName.zip"

    if (Test-Path -LiteralPath $publishedRoot) {
        Assert-PathWithin $publishedRoot $finalOutputDir
        Remove-Item -LiteralPath $publishedRoot -Recurse -Force
    }
    if ($makeZip -and (Test-Path -LiteralPath $publishedZip)) {
        Assert-PathWithin $publishedZip $finalOutputDir
        Remove-Item -LiteralPath $publishedZip -Force
    }

    $staging = New-StagingContainer
    try {
        $artifactRoot = Join-Path $staging $artifactName
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $finalAppDir = New-AppPackage $artifactRoot $version

        Invoke-Step "copy portable upgrade helper" {
            foreach ($item in @(
                @{ src = Join-Path $PSScriptRoot "tool\upgrade_from_previous.ps1"; name = "upgrade_from_previous.ps1" },
                @{ src = Join-Path $PSScriptRoot "tool\PORTABLE_README.txt"; name = "PORTABLE_README.txt" }
            )) {
                if (-not (Test-Path -LiteralPath $item.src -PathType Leaf)) {
                    throw "Missing portable helper file: $($item.src)"
                }
                Copy-Item -LiteralPath $item.src -Destination (Join-Path $artifactRoot $item.name) -Force
            }
        }

        Write-BuildInfo $artifactRoot $version $dist

        Invoke-Step "validate portable package" {
            Test-KeyFiles $finalAppDir
        }

        if ($makeZip) {
            Invoke-Step "create portable archive" {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::CreateFromDirectory(
                    $artifactRoot,
                    $publishedZip,
                    [System.IO.Compression.CompressionLevel]::Optimal,
                    $false
                )
            }
        }

        Move-Item -LiteralPath $artifactRoot -Destination $publishedRoot
    }
    finally {
        Remove-StagingContainer
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Portable package completed successfully." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Folder:   $publishedRoot" -ForegroundColor Yellow
    if ($makeZip) {
        Write-Host "Archive:  $publishedZip" -ForegroundColor Yellow
    }
}

function New-InstallerPackage([string]$version, [bool]$buildFirst) {
    $dist = "installer"
    if ($buildFirst) { Invoke-Build $version $false }
    $artifactName = "pure_music_{0}_release_installer" -f $version
    $publishedInstaller = Join-Path $finalOutputDir "$artifactName.exe"
    $publishedChecksum = "$publishedInstaller.sha256"

    $innoCompiler = Get-InnoSetupCompilerPath
    if (-not $innoCompiler) {
        throw "Inno Setup compiler not found. Install Inno Setup 7 or add ISCC.exe to PATH."
    }

    $installerScript = Join-Path $PSScriptRoot "installer\pure_music.iss"
    if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
        throw "Inno Setup script not found: $installerScript"
    }

    $staging = New-StagingContainer
    try {
        $artifactRoot = Join-Path $staging $artifactName
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $finalAppDir = New-AppPackage $artifactRoot $version
        Write-BuildInfo $artifactRoot $version $dist

        Invoke-Step "validate installer application" {
            Test-KeyFiles $finalAppDir
        }

        Invoke-Step "create Inno Setup installer" {
            $compiledOutputDir = Join-Path $staging "compiled"
            New-Item -ItemType Directory -Force -Path $compiledOutputDir | Out-Null
            $innoArgs = @(
                "/DSourceDir=$finalAppDir",
                "/DAppVersion=$version",
                "/O$compiledOutputDir",
                "/F$artifactName",
                $installerScript
            )
            & $innoCompiler @innoArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
            }

            $compiledInstaller = Join-Path $compiledOutputDir "$artifactName.exe"
            if (-not (Test-Path -LiteralPath $compiledInstaller -PathType Leaf)) {
                throw "Inno Setup did not create the expected installer."
            }

            foreach ($path in @($publishedInstaller, $publishedChecksum)) {
                if (Test-Path -LiteralPath $path) {
                    Assert-PathWithin $path $finalOutputDir
                    Remove-Item -LiteralPath $path -Force
                }
            }
            Move-Item -LiteralPath $compiledInstaller -Destination $publishedInstaller

            $hash = (Get-FileHash -LiteralPath $publishedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Utf8NoBom $publishedChecksum ("{0} *{1}`n" -f $hash, [System.IO.Path]::GetFileName($publishedInstaller))
        }
    }
    finally {
        Remove-StagingContainer
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Installer completed successfully." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Installer: $publishedInstaller" -ForegroundColor Yellow
    Write-Host "SHA256:   $publishedChecksum" -ForegroundColor Yellow
}

# ---------- entry ----------

$script:exitCode = 0

trap {
    Remove-StagingContainer
    Write-Host $_.Exception.Message -ForegroundColor Red
    $script:exitCode = 1
    Wait-ForExitPrompt
    exit 1
}

Write-Host "`n===== Pure Music Build =====" -ForegroundColor Cyan
Write-Host "  1. 编译便携版（只出文件夹，不打包）" -ForegroundColor White
Write-Host "  2. 编译便携版并打包 zip" -ForegroundColor White
Write-Host "  3. 编译并制作 Inno Setup 安装器" -ForegroundColor White
Write-Host "  4. 跳过编译，打包已有产物（便携版 zip）" -ForegroundColor White
Write-Host "  5. 跳过编译，使用已有产物制作安装器" -ForegroundColor White
Write-Host "===========================" -ForegroundColor Cyan

if ($Mode -eq 0) {
    $modeInput = (Read-Input "请选择 [1/2/3/4/5]").Trim()
    if ([string]::IsNullOrWhiteSpace($modeInput)) { $modeInput = "2" }
    if ($modeInput -notin @("1", "2", "3", "4", "5")) {
        throw "Invalid selection: $modeInput"
    }
    $selectedMode = [int]$modeInput
}
else {
    $selectedMode = $Mode
}

$defaultVersion = Get-AppSettingsVersion
if ([string]::IsNullOrWhiteSpace($defaultVersion)) { $defaultVersion = "unknown" }

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $version = $Version.Trim()
}
else {
    $version = (Read-Input "Version (default $defaultVersion)").Trim()
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $defaultVersion }
}
$version = Test-Version $version

switch ($selectedMode) {
    1 { New-PortablePackage $version $true $false }
    2 { New-PortablePackage $version $true $true }
    3 { New-InstallerPackage $version $true }
    4 { New-PortablePackage $version $false $true }
    5 { New-InstallerPackage $version $false }
}

Write-Host "The running Pure Music process was not stopped." -ForegroundColor Gray
Wait-ForExitPrompt
exit 0
