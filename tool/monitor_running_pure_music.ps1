param(
    [int]$ProcessId = 0,
    [ValidateRange(2, 86400)]
    [int]$DurationSeconds = 120,
    [ValidateRange(1, 60)]
    [int]$SampleIntervalSeconds = 1,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot "build\performance"
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [ValidateRange(0, 1)]
        [double]$Percentile
    )

    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($sorted.Count * $Percentile) - 1
    return [double]$sorted[[Math]::Max(0, $index)]
}

function Get-Distribution {
    param(
        [object[]]$Samples,
        [string]$PropertyName,
        [string]$Unit
    )

    [double[]]$values = @($Samples | ForEach-Object { [double]$_.$PropertyName })
    $measurement = $values | Measure-Object -Average -Maximum -Minimum
    return [ordered]@{
        Unit = $Unit
        Minimum = [Math]::Round($measurement.Minimum, 3)
        Average = [Math]::Round($measurement.Average, 3)
        P50 = [Math]::Round((Get-Percentile -Values $values -Percentile 0.50), 3)
        P95 = [Math]::Round((Get-Percentile -Values $values -Percentile 0.95), 3)
        Peak = [Math]::Round($measurement.Maximum, 3)
    }
}

function Get-Growth {
    param(
        [object[]]$Samples,
        [string]$PropertyName
    )

    [double[]]$x = @($Samples | ForEach-Object { [double]$_.ElapsedSeconds / 60.0 })
    [double[]]$y = @($Samples | ForEach-Object { [double]$_.$PropertyName })
    $meanX = ($x | Measure-Object -Average).Average
    $meanY = ($y | Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    for ($index = 0; $index -lt $x.Count; $index++) {
        $xDelta = $x[$index] - $meanX
        $numerator += $xDelta * ($y[$index] - $meanY)
        $denominator += $xDelta * $xDelta
    }
    $slope = 0.0
    if ($denominator -gt 0) {
        $slope = $numerator / $denominator
    }

    return [ordered]@{
        Unit = "MB"
        Start = [Math]::Round($y[0], 3)
        End = [Math]::Round($y[-1], 3)
        Delta = [Math]::Round($y[-1] - $y[0], 3)
        LinearTrendPerMinute = [Math]::Round($slope, 3)
    }
}

if ($ProcessId -gt 0) {
    $target = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if ($null -eq $target) {
        throw "Process $ProcessId does not exist."
    }
}
else {
    $target = Get-CimInstance Win32_Process -Filter "Name='pure_music.exe'" |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1
    if ($null -eq $target) {
        throw "No running pure_music.exe process was found."
    }
    $ProcessId = [int]$target.ProcessId
}

if ($target.Name -ne "pure_music.exe") {
    throw "Process $ProcessId is $($target.Name), not pure_music.exe."
}

$process = Get-Process -Id $ProcessId
$expectedStartTime = $process.StartTime

$gpuPaths = @(
    "\GPU Engine(pid_$($ProcessId)_*)\Utilization Percentage",
    "\GPU Process Memory(pid_$($ProcessId)_*)\Dedicated Usage",
    "\GPU Process Memory(pid_$($ProcessId)_*)\Shared Usage"
)
$gpuPreflight = Get-Counter -Counter $gpuPaths
$gpuEnginePreflight = @($gpuPreflight.CounterSamples | Where-Object { $_.Path -match "\\gpu engine\(" })
$gpuDedicatedPreflight = @($gpuPreflight.CounterSamples | Where-Object { $_.Path -match "\\dedicated usage$" })
$gpuSharedPreflight = @($gpuPreflight.CounterSamples | Where-Object { $_.Path -match "\\shared usage$" })
if ($gpuEnginePreflight.Count -eq 0 -or $gpuDedicatedPreflight.Count -eq 0 -or $gpuSharedPreflight.Count -eq 0) {
    throw "Windows GPU counters for PID $ProcessId are incomplete."
}

$logicalProcessors = [Environment]::ProcessorCount
$sampleCount = [Math]::Max(2, [Math]::Ceiling($DurationSeconds / $SampleIntervalSeconds))
$startedAt = Get-Date
$previousSampleTime = $startedAt
$previousCpuSeconds = $process.TotalProcessorTime.TotalSeconds
$samples = [System.Collections.Generic.List[object]]::new()

Get-Counter -Counter $gpuPaths -SampleInterval $SampleIntervalSeconds -MaxSamples $sampleCount |
    ForEach-Object {
        $counterSet = $_
        $sampledAt = Get-Date
        $processSample = Get-Process -Id $ProcessId
        if ($processSample.StartTime -ne $expectedStartTime) {
            throw "PID $ProcessId was reused during sampling."
        }

        $gpuEngineSamples = @($counterSet.CounterSamples | Where-Object { $_.Path -match "\\gpu engine\(" })
        $gpu3DSamples = @($gpuEngineSamples | Where-Object { $_.InstanceName -like "*engtype_3D*" })
        if ($gpuEngineSamples.Count -eq 0 -or $gpu3DSamples.Count -eq 0) {
            throw "Windows GPU engine counters for PID $ProcessId disappeared during sampling."
        }

        $sampleDurationSeconds = ($sampledAt - $previousSampleTime).TotalSeconds
        $cpuSeconds = $processSample.TotalProcessorTime.TotalSeconds
        $cpuPercent = 0.0
        if ($sampleDurationSeconds -gt 0) {
            $cpuPercent = (($cpuSeconds - $previousCpuSeconds) / $sampleDurationSeconds / $logicalProcessors) * 100.0
        }
        $previousSampleTime = $sampledAt
        $previousCpuSeconds = $cpuSeconds
        $gpuDedicatedBytes = ($counterSet.CounterSamples |
            Where-Object { $_.Path -match "\\dedicated usage$" } |
            Measure-Object CookedValue -Sum).Sum
        $gpuSharedBytes = ($counterSet.CounterSamples |
            Where-Object { $_.Path -match "\\shared usage$" } |
            Measure-Object CookedValue -Sum).Sum
        $gpuTotalPercent = ($gpuEngineSamples | Measure-Object CookedValue -Sum).Sum
        $gpu3DPercent = ($gpu3DSamples | Measure-Object CookedValue -Sum).Sum
        $gpuBusiestPercent = ($gpuEngineSamples | Measure-Object CookedValue -Maximum).Maximum

        $samples.Add([pscustomobject][ordered]@{
            Timestamp = $sampledAt.ToString("o")
            ElapsedSeconds = [Math]::Round(($sampledAt - $startedAt).TotalSeconds, 3)
            CpuPercent = [Math]::Round([Math]::Max(0, $cpuPercent), 3)
            GpuBusiestEnginePercent = [Math]::Round([Math]::Max(0, $gpuBusiestPercent), 3)
            Gpu3DPercent = [Math]::Round([Math]::Max(0, $gpu3DPercent), 3)
            GpuAllEnginesPercent = [Math]::Round([Math]::Max(0, $gpuTotalPercent), 3)
            WorkingSetMB = [Math]::Round($processSample.WorkingSet64 / 1MB, 3)
            PrivateMemoryMB = [Math]::Round($processSample.PrivateMemorySize64 / 1MB, 3)
            GpuDedicatedMemoryMB = [Math]::Round($gpuDedicatedBytes / 1MB, 3)
            GpuSharedMemoryMB = [Math]::Round($gpuSharedBytes / 1MB, 3)
            ThreadCount = $processSample.Threads.Count
            HandleCount = $processSample.HandleCount
        })
    }

if ($samples.Count -eq 0) {
    throw "No samples were collected for PID $ProcessId."
}

$process = Get-Process -Id $ProcessId
if ($process.StartTime -ne $expectedStartTime) {
    throw "PID $ProcessId was reused during sampling."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutputDirectory = (Resolve-Path $OutputDirectory).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $resolvedOutputDirectory "running-pure-music-$ProcessId-$timestamp.samples.csv"
$summaryPath = Join-Path $resolvedOutputDirectory "running-pure-music-$ProcessId-$timestamp.summary.json"
$samples | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$summary = [ordered]@{
    GeneratedAt = (Get-Date).ToString("o")
    Target = [ordered]@{
        ProcessId = $ProcessId
        ExecutablePath = $target.ExecutablePath
        CreationDate = ([datetime]$target.CreationDate).ToString("o")
        MainWindowTitle = $process.MainWindowTitle
        Responding = $process.Responding
    }
    Sampling = [ordered]@{
        RequestedDurationSeconds = $DurationSeconds
        IntervalSeconds = $SampleIntervalSeconds
        SampleCount = $samples.Count
        ObservedDurationSeconds = [Math]::Round($samples[-1].ElapsedSeconds - $samples[0].ElapsedSeconds, 3)
        LogicalProcessorCount = $logicalProcessors
    }
    Metrics = [ordered]@{
        CpuPercent = Get-Distribution -Samples $samples -PropertyName "CpuPercent" -Unit "% of total CPU"
        GpuBusiestEnginePercent = Get-Distribution -Samples $samples -PropertyName "GpuBusiestEnginePercent" -Unit "%"
        Gpu3DPercent = Get-Distribution -Samples $samples -PropertyName "Gpu3DPercent" -Unit "%"
        GpuAllEnginesPercent = Get-Distribution -Samples $samples -PropertyName "GpuAllEnginesPercent" -Unit "% summed across engines"
        WorkingSetMB = Get-Distribution -Samples $samples -PropertyName "WorkingSetMB" -Unit "MB"
        PrivateMemoryMB = Get-Distribution -Samples $samples -PropertyName "PrivateMemoryMB" -Unit "MB"
        GpuDedicatedMemoryMB = Get-Distribution -Samples $samples -PropertyName "GpuDedicatedMemoryMB" -Unit "MB"
        GpuSharedMemoryMB = Get-Distribution -Samples $samples -PropertyName "GpuSharedMemoryMB" -Unit "MB"
    }
    Growth = [ordered]@{
        WorkingSet = Get-Growth -Samples $samples -PropertyName "WorkingSetMB"
        PrivateMemory = Get-Growth -Samples $samples -PropertyName "PrivateMemoryMB"
        GpuDedicatedMemory = Get-Growth -Samples $samples -PropertyName "GpuDedicatedMemoryMB"
        GpuSharedMemory = Get-Growth -Samples $samples -PropertyName "GpuSharedMemoryMB"
    }
    Samples = $csvPath
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 8
Write-Host "Summary: $summaryPath"
Write-Host "Samples: $csvPath"
