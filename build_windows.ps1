# Windows Build Script for Pure Music

try { chcp 65001 | Out-Null } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = "Stop"

# Hardcode BuildMode to Release as requested
$BuildMode = "Release"
$finalOutputDir = Join-Path $PSScriptRoot "output"

try {
    $psv = $PSVersionTable.PSVersion
    $enc = [Console]::OutputEncoding.WebName
    Write-Host ("Env: PowerShell {0}, ConsoleEncoding {1}" -f $psv, $enc) -ForegroundColor Gray
} catch {}

function Get-AppSettingsVersion() {
    $p = Join-Path $PSScriptRoot "lib\app_settings.dart"
    if (-not (Test-Path $p)) { return "" }
    $content = Get-Content -Path $p -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return "" }
    $m = [regex]::Match($content, 'static\s+const\s+String\s+version\s*=\s*["'']([^"'']+)["'']')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Read-Input([string]$prompt) {
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v
}

$distInput = Read-Input "Distribution: 1)portable  2)exe (non-portable)  (default 1)"
if ($distInput -eq "2") {
    $dist = "exe"
    $portableBuild = "false"
}
else {
    $dist = "portable"
    $portableBuild = "true"
}

$tag = "release"

$defaultVersion = Get-AppSettingsVersion
if ([string]::IsNullOrWhiteSpace($defaultVersion)) { $defaultVersion = "unknown" }
$versionInput = (Read-Input "Version").Trim()
if ([string]::IsNullOrWhiteSpace($versionInput)) { $versionInput = $defaultVersion }
$version = $versionInput

function Update-AppSettingsVersion([string]$newVersion) {
    $p = Join-Path $PSScriptRoot "lib\app_settings.dart"
    if (-not (Test-Path $p)) {
        Write-Warning "app_settings.dart not found at $p"
        return
    }
    
    try {
        $sr = New-Object System.IO.StreamReader($p, [System.Text.Encoding]::UTF8, $true)
        try {
            $content = $sr.ReadToEnd()
        } finally {
            $sr.Dispose()
        }

        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
            $content = $content.Substring(1)
        }

        # First, remove ALL existing version declarations to prevent duplicates
        $rxRemove = New-Object System.Text.RegularExpressions.Regex('(?m)^\s*static\s+const\s+String\s+version\s*=\s*["''][^"'']*["''];\s*[\r\n]+')
        $content = $rxRemove.Replace($content, '')

        # Then insert a single version declaration after class AppSettings {
        $rxClass = New-Object System.Text.RegularExpressions.Regex('(?m)^(\s*)class\s+AppSettings\s*\{')
        if ($rxClass.IsMatch($content)) {
            $insertLine = "`n  static const String version = `"$newVersion`";`n"
            $content = $rxClass.Replace($content, ('$1class AppSettings {' + $insertLine), 1)
        }
        else {
            Write-Error "Failed to find class AppSettings in app_settings.dart"
            return
        }

        $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($p, $content, $Utf8NoBomEncoding)
        $verify = Get-AppSettingsVersion
        if ($verify -ne $newVersion) {
            Write-Error "Failed to verify updated version in app_settings.dart (expected $newVersion, got $verify)"
            return
        }
        Write-Host "Updated version in app_settings.dart to $newVersion" -ForegroundColor Green
    } catch {
        Write-Error "Failed to update version in app_settings.dart: $_"
    }
}

# Update version in app_settings.dart
Update-AppSettingsVersion $version

$bassPluginMode = "full"

$artifactRoot = Join-Path $finalOutputDir ("pure_music_{0}_{1}_{2}" -f $version, $tag, $dist)
$finalAppDir = Join-Path $artifactRoot "app"
$finalDllDir = Join-Path $finalAppDir "dll"

Write-Host "Starting build process (Release Mode)..." -ForegroundColor Green

# Check if flutter is available
if (-not (Get-Command "flutter" -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter command not found. Please ensure Flutter is installed and in your PATH."
    Read-Host "Press Enter to exit..."
    exit 1
}

# 1. Smart flutter pub get
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
    Write-Host "Running flutter pub get..." -ForegroundColor Cyan
    flutter pub get
}
else {
    Write-Host "Skipping flutter pub get (dependencies are up to date)." -ForegroundColor Gray
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

function Set-ExeIcon([string]$exePath, [string]$icoPath) {
    if (-not (Test-Path $exePath)) { return }
    if (-not (Test-Path $icoPath)) { return }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class ExeIconPatcher
{
    private const int RT_ICON = 3;
    private const int RT_GROUP_ICON = 14;

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct ICONDIR
    {
        public UInt16 Reserved;
        public UInt16 Type;
        public UInt16 Count;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct ICONDIRENTRY
    {
        public byte Width;
        public byte Height;
        public byte ColorCount;
        public byte Reserved;
        public UInt16 Planes;
        public UInt16 BitCount;
        public UInt32 BytesInRes;
        public UInt32 ImageOffset;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct GRPICONDIRENTRY
    {
        public byte Width;
        public byte Height;
        public byte ColorCount;
        public byte Reserved;
        public UInt16 Planes;
        public UInt16 BitCount;
        public UInt32 BytesInRes;
        public UInt16 Id;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BeginUpdateResource(string pFileName, [MarshalAs(UnmanagedType.Bool)] bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, UInt16 wLanguage, byte[] lpData, UInt32 cbData);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr hUpdate, [MarshalAs(UnmanagedType.Bool)] bool fDiscard);

    private static IntPtr MakeIntResource(int id)
    {
        return (IntPtr)id;
    }

    public static void SetIcon(string exePath, string icoPath)
    {
        var icoBytes = File.ReadAllBytes(icoPath);
        ICONDIR dir;
        ICONDIRENTRY[] entries;
        byte[][] images;

        using (var ms = new MemoryStream(icoBytes))
        using (var br = new BinaryReader(ms))
        {
            dir = new ICONDIR
            {
                Reserved = br.ReadUInt16(),
                Type = br.ReadUInt16(),
                Count = br.ReadUInt16(),
            };
            if (dir.Reserved != 0 || dir.Type != 1 || dir.Count == 0)
                throw new InvalidDataException("Invalid ico header");

            entries = new ICONDIRENTRY[dir.Count];
            images = new byte[dir.Count][];
            for (int i = 0; i < dir.Count; i++)
            {
                entries[i] = new ICONDIRENTRY
                {
                    Width = br.ReadByte(),
                    Height = br.ReadByte(),
                    ColorCount = br.ReadByte(),
                    Reserved = br.ReadByte(),
                    Planes = br.ReadUInt16(),
                    BitCount = br.ReadUInt16(),
                    BytesInRes = br.ReadUInt32(),
                    ImageOffset = br.ReadUInt32(),
                };
            }

            for (int i = 0; i < dir.Count; i++)
            {
                var e = entries[i];
                if (e.ImageOffset + e.BytesInRes > icoBytes.Length)
                    throw new InvalidDataException("Invalid ico image offset");
                images[i] = new byte[e.BytesInRes];
                Buffer.BlockCopy(icoBytes, (int)e.ImageOffset, images[i], 0, (int)e.BytesInRes);
            }
        }

        var hUpdate = BeginUpdateResource(exePath, false);
        if (hUpdate == IntPtr.Zero)
            throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());

        try
        {
            for (int i = 0; i < images.Length; i++)
            {
                var ok = UpdateResource(
                    hUpdate,
                    MakeIntResource(RT_ICON),
                    MakeIntResource(i + 1),
                    0,
                    images[i],
                    (UInt32)images[i].Length
                );
                if (!ok) throw new Exception("UpdateResource RT_ICON failed: " + Marshal.GetLastWin32Error());
            }

            var grp = BuildGroupIconData(dir, entries);
            {
                var ok = UpdateResource(
                    hUpdate,
                    MakeIntResource(RT_GROUP_ICON),
                    MakeIntResource(1),
                    0,
                    grp,
                    (UInt32)grp.Length
                );
                if (!ok) throw new Exception("UpdateResource RT_GROUP_ICON failed: " + Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            if (!EndUpdateResource(hUpdate, false))
                throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
        }
    }

    private static byte[] BuildGroupIconData(ICONDIR dir, ICONDIRENTRY[] entries)
    {
        using (var ms = new MemoryStream())
        using (var bw = new BinaryWriter(ms))
        {
            bw.Write((UInt16)0);
            bw.Write((UInt16)1);
            bw.Write((UInt16)entries.Length);
            for (int i = 0; i < entries.Length; i++)
            {
                var e = entries[i];
                bw.Write(e.Width);
                bw.Write(e.Height);
                bw.Write(e.ColorCount);
                bw.Write(e.Reserved);
                bw.Write(e.Planes);
                bw.Write(e.BitCount);
                bw.Write(e.BytesInRes);
                bw.Write((UInt16)(i + 1));
            }
            bw.Flush();
            return ms.ToArray();
        }
    }
}
'@ -Language CSharp -ErrorAction Stop

    [ExeIconPatcher]::SetIcon($exePath, $icoPath)
}

# 3. Build Windows
Write-Host "Building Windows ($BuildMode)..." -ForegroundColor Cyan
$flutterArgs = @("build", "windows", "--release", "--dart-define=PORTABLE_BUILD=$portableBuild")
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

# 5. Copy Build Artifacts to Output Directory
Write-Host "Copying build artifacts to output directory..." -ForegroundColor Cyan
Copy-Item -Path "$buildDir\*" -Destination $finalAppDir -Recurse -Force

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

# Copy BASS DLLs
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
        Copy-Item -Path "$bassSrcDir\*" -Destination $bassDestDir -Recurse -Force
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

# Copy desktop_lyric
$desktopLyricSrc = "desktop_lyric"
$desktopLyricDest = Join-Path $finalAppDir "desktop_lyric"
if (Test-Path $desktopLyricSrc) {
    Write-Host "Copying desktop_lyric..." -ForegroundColor Cyan
    if (-not (Test-Path $desktopLyricDest)) {
        New-Item -ItemType Directory -Force -Path $desktopLyricDest | Out-Null
    }
    Copy-Item -Path "$desktopLyricSrc\*" -Destination $desktopLyricDest -Recurse -Force
    $desktopLyricExe = Join-Path $desktopLyricDest "desktop_lyric.exe"
    Set-ExeIcon $desktopLyricExe $appIconSource
}
else {
    Write-Warning "desktop_lyric directory not found in project root ($desktopLyricSrc)!"
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
