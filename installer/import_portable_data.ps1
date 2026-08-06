[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceData,

    [Parameter(Mandatory = $true)]
    [string]$DestinationData
)

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

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

$source = (Resolve-Path -LiteralPath $SourceData).Path
$destination = [System.IO.Path]::GetFullPath($DestinationData).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($destination) -or
    $destination -eq [System.IO.Path]::GetPathRoot($destination) -or
    [System.IO.Path]::GetFileName($destination) -ne "pure_music") {
    throw "安装版数据目录无效：$destination"
}
if (-not (Test-Path -LiteralPath (Join-Path $source "app.so") -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $source "flutter_assets") -PathType Container)) {
    throw "所选目录不是完整的便携版运行数据目录。"
}
if (Test-ProcessFromDirectory (Split-Path $source -Parent)) {
    throw "导入数据前请先关闭正在运行的便携版 Pure Music。"
}
if (Test-Path -LiteralPath $destination) {
    $existing = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($existing.Count -gt 0) {
        throw "安装版数据目录不是空目录，已停止导入以避免覆盖现有数据。"
    }
}

$durableEntries = @(
    "settings",
    "db",
    "index.json",
    "library.sqlite",
    "library.sqlite-wal",
    "library.sqlite-shm",
    "playlists.json",
    "lyric_source.json"
)
$entries = @($durableEntries | ForEach-Object {
    $entry = Join-Path $source $_
    if (Test-Path -LiteralPath $entry) { Get-Item -LiteralPath $entry }
})
if ($entries.Count -eq 0) {
    throw "所选便携版中没有可迁移的用户数据。"
}

$destinationParent = Split-Path $destination -Parent
New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
$staging = Join-Path $destinationParent (".pure_music-import-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($entry in $entries) {
        Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse -Force
    }
    Get-ChildItem -LiteralPath $staging -Recurse -File -Filter "*.tmp.*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination
    }
    Move-Item -LiteralPath $staging -Destination $destination
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "已导入 $($entries.Count) 项持久化数据。"
