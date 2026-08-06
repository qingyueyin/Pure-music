param(
    [int]$SampleIntervalMs = 500,
    [double]$MaxCpuPercent = 25,
    [double]$MaxGpu3DPercent = 95,
    [double]$MaxWorkingSetMb = 300,
    [double]$MaxFrameP95Ms = 16.67,
    [double]$MaxSmtcSequentialP95Ms = 2,
    [double]$MaxSmtcRepeatGrowthMb = 8
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$reportDir = Join-Path $projectRoot "build\performance"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stdoutPath = Join-Path $reportDir "windows-background-$timestamp.stdout.log"
$stderrPath = Join-Path $reportDir "windows-background-$timestamp.stderr.log"
$csvPath = Join-Path $reportDir "windows-background-$timestamp.samples.csv"
$summaryPath = Join-Path $reportDir "windows-background-$timestamp.summary.json"
$flutterPath = (Get-Command flutter).Source
$startedAt = Get-Date
$arguments = @(
    "run",
    "--profile",
    "--device-id=windows",
    "--no-pub",
    "--target=tool/windows_background_benchmark.dart"
)
$appProcessId = $null

$driveProcess = Start-Process `
    -FilePath $flutterPath `
    -ArgumentList $arguments `
    -WorkingDirectory $projectRoot `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath

try {
    $deadline = (Get-Date).AddMinutes(5)
    $appProcess = $null
    while ((Get-Date) -lt $deadline -and -not $driveProcess.HasExited) {
        $appProcess = Get-Process -Name "pure_music" -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($null -ne $appProcess) {
            break
        }
        Start-Sleep -Milliseconds 500
        $driveProcess.Refresh()
    }

    if ($null -eq $appProcess) {
        throw "The performance test app did not start. See $stdoutPath and $stderrPath."
    }

    $logicalProcessors = [Environment]::ProcessorCount
    $samples = [System.Collections.Generic.List[object]]::new()
    $appProcessId = $appProcess.Id
    $previousCpuSeconds = $appProcess.TotalProcessorTime.TotalSeconds
    $previousSampleTime = Get-Date
    $gpuPaths = @(
        "\GPU Engine(pid_$appProcessId`_*)\Utilization Percentage",
        "\GPU Process Memory(pid_$appProcessId`_*)\Dedicated Usage",
        "\GPU Process Memory(pid_$appProcessId`_*)\Shared Usage"
    )
    $gpuDeadline = (Get-Date).AddSeconds(10)
    $gpuReady = $false
    while ((Get-Date) -lt $gpuDeadline -and -not $gpuReady) {
        try {
            $gpuPreflight = Get-Counter $gpuPaths -ErrorAction Stop
            $gpuReady = @($gpuPreflight.CounterSamples |
                Where-Object { $_.Path -like "*gpu engine*" }).Count -gt 0
        }
        catch {
            $gpuReady = $false
        }
        if (-not $gpuReady) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $gpuReady) {
        throw "The GPU performance counters for process $appProcessId did not appear."
    }

    while ($true) {
        Start-Sleep -Milliseconds ([Math]::Max(100, $SampleIntervalMs))
        $appProcess = Get-Process -Id $appProcessId -ErrorAction SilentlyContinue
        if ($null -eq $appProcess) {
            break
        }

        $sampledAt = Get-Date
        $sampleDuration = ($sampledAt - $previousSampleTime).TotalSeconds
        $cpuSeconds = $appProcess.TotalProcessorTime.TotalSeconds
        $cpuPercent = 0.0
        if ($sampleDuration -gt 0) {
            $cpuPercent = (($cpuSeconds - $previousCpuSeconds) /
                    $sampleDuration / $logicalProcessors) * 100.0
        }
        $previousSampleTime = $sampledAt
        $previousCpuSeconds = $cpuSeconds

        $gpuCounters = $null
        for ($attempt = 0; $attempt -lt 3 -and $null -eq $gpuCounters; $attempt++) {
            try {
                $gpuCounters = Get-Counter $gpuPaths -ErrorAction Stop
            }
            catch {
                if ($null -eq (Get-Process -Id $appProcessId -ErrorAction SilentlyContinue)) {
                    break
                }
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 100 }
            }
        }
        if ($null -eq $gpuCounters) {
            if ($null -eq (Get-Process -Id $appProcessId -ErrorAction SilentlyContinue)) {
                break
            }
            throw "The GPU performance counters for process $appProcessId returned invalid data three times."
        }
        $gpuEngineSamples = @($gpuCounters.CounterSamples |
            Where-Object { $_.Path -like "*gpu engine*" })
        $gpu3DSamples = @($gpuEngineSamples |
            Where-Object { $_.InstanceName -like "*engtype_3D*" })
        if ($gpuEngineSamples.Count -eq 0 -or $gpu3DSamples.Count -eq 0) {
            throw "The GPU performance counters for process $appProcessId disappeared."
        }
        $gpu3DPercent = ($gpu3DSamples | Measure-Object CookedValue -Sum).Sum
        $gpuBusiestPercent = ($gpuEngineSamples |
            Measure-Object CookedValue -Maximum).Maximum
        $gpuDedicatedMb = (($gpuCounters.CounterSamples |
                Where-Object { $_.Path -like "*Dedicated Usage" } |
                Measure-Object CookedValue -Sum).Sum) / 1MB
        $gpuSharedMb = (($gpuCounters.CounterSamples |
                Where-Object { $_.Path -like "*Shared Usage" } |
                Measure-Object CookedValue -Sum).Sum) / 1MB

        $phase = "startup"
        try {
            $phaseOutput = Get-Content -Path $stdoutPath -Raw -Encoding UTF8
            $phaseMatches = [regex]::Matches($phaseOutput, "PERF_PHASE (?<phase>[a-z_]+)")
            if ($phaseMatches.Count -gt 0) {
                $phase = $phaseMatches[$phaseMatches.Count - 1].Groups["phase"].Value
            }
        }
        catch {}

        $samples.Add([pscustomobject]@{
            Timestamp = $sampledAt.ToString("o")
            Phase = $phase
            CpuPercent = [Math]::Round($cpuPercent, 3)
            Gpu3DPercent = [Math]::Round($gpu3DPercent, 3)
            GpuBusiestEnginePercent = [Math]::Round($gpuBusiestPercent, 3)
            WorkingSetMb = [Math]::Round($appProcess.WorkingSet64 / 1MB, 3)
            PrivateMemoryMb = [Math]::Round($appProcess.PrivateMemorySize64 / 1MB, 3)
            GpuDedicatedMb = [Math]::Round($gpuDedicatedMb, 3)
            GpuSharedMb = [Math]::Round($gpuSharedMb, 3)
        })
    }

    $driveProcess.WaitForExit()
    $driveProcess.Refresh()
    $driveExitCode = $driveProcess.ExitCode
    $flutterOutput = Get-Content -Path $stdoutPath -Raw -Encoding UTF8
    $completedSuccessfully = $driveExitCode -eq 0 -or
        ($flutterOutput -match "PERF_REPORT ")
    if (-not $completedSuccessfully) {
        throw "Flutter drive failed with exit code $driveExitCode. See $stdoutPath and $stderrPath."
    }
    if ($samples.Count -eq 0) {
        throw "No performance samples were collected."
    }

    $samples | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    function Get-Percentile([double[]]$values, [double]$percentile) {
        $sorted = $values | Sort-Object
        $index = [Math]::Ceiling($sorted.Count * $percentile) - 1
        return $sorted[[Math]::Max(0, $index)]
    }

    $cpuValues = [double[]]$samples.CpuPercent
    $gpuValues = [double[]]$samples.Gpu3DPercent
    $frameReportMatch = [regex]::Match($flutterOutput, "PERF_REPORT (?<json>\[.*\])")
    [object[]]$frameReport = @()
    if ($frameReportMatch.Success) {
        $frameReport = $frameReportMatch.Groups["json"].Value | ConvertFrom-Json
    }
    $phaseReport = @($samples | Group-Object Phase | ForEach-Object {
        $phaseSamples = @($_.Group)
        [double[]]$phaseCpu = $phaseSamples.CpuPercent
        [double[]]$phaseGpu = $phaseSamples.Gpu3DPercent
        [ordered]@{
            Phase = $_.Name
            SampleCount = $phaseSamples.Count
            CpuAveragePercent = [Math]::Round(($phaseCpu | Measure-Object -Average).Average, 3)
            CpuP95Percent = [Math]::Round((Get-Percentile $phaseCpu 0.95), 3)
            Gpu3DAveragePercent = [Math]::Round(($phaseGpu | Measure-Object -Average).Average, 3)
            Gpu3DP95Percent = [Math]::Round((Get-Percentile $phaseGpu 0.95), 3)
            WorkingSetAverageMb = [Math]::Round(($phaseSamples.WorkingSetMb | Measure-Object -Average).Average, 3)
            WorkingSetPeakMb = [Math]::Round(($phaseSamples.WorkingSetMb | Measure-Object -Maximum).Maximum, 3)
            PrivateMemoryAverageMb = [Math]::Round(($phaseSamples.PrivateMemoryMb | Measure-Object -Average).Average, 3)
            PrivateMemoryPeakMb = [Math]::Round(($phaseSamples.PrivateMemoryMb | Measure-Object -Maximum).Maximum, 3)
            GpuDedicatedAverageMb = [Math]::Round(($phaseSamples.GpuDedicatedMb | Measure-Object -Average).Average, 3)
            GpuDedicatedPeakMb = [Math]::Round(($phaseSamples.GpuDedicatedMb | Measure-Object -Maximum).Maximum, 3)
        }
    })
    $summary = [ordered]@{
        SampleCount = $samples.Count
        LogicalProcessors = $logicalProcessors
        CpuAveragePercent = [Math]::Round(($cpuValues | Measure-Object -Average).Average, 3)
        CpuP95Percent = [Math]::Round((Get-Percentile $cpuValues 0.95), 3)
        Gpu3DAveragePercent = [Math]::Round(($gpuValues | Measure-Object -Average).Average, 3)
        Gpu3DP95Percent = [Math]::Round((Get-Percentile $gpuValues 0.95), 3)
        WorkingSetPeakMb = [Math]::Round(($samples.WorkingSetMb | Measure-Object -Maximum).Maximum, 3)
        PrivateMemoryPeakMb = [Math]::Round(($samples.PrivateMemoryMb | Measure-Object -Maximum).Maximum, 3)
        GpuDedicatedPeakMb = [Math]::Round(($samples.GpuDedicatedMb | Measure-Object -Maximum).Maximum, 3)
        GpuSharedPeakMb = [Math]::Round(($samples.GpuSharedMb | Measure-Object -Maximum).Maximum, 3)
        PhaseReport = $phaseReport
        FrameReport = $frameReport
        Samples = $csvPath
        FlutterOutput = $stdoutPath
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding UTF8
    $summary | Format-List

    $violations = [System.Collections.Generic.List[string]]::new()
    if ($summary.CpuP95Percent -gt $MaxCpuPercent) {
        $violations.Add("CPU p95 $($summary.CpuP95Percent)% exceeds $MaxCpuPercent%")
    }
    if ($summary.Gpu3DP95Percent -gt $MaxGpu3DPercent) {
        $violations.Add("GPU 3D p95 $($summary.Gpu3DP95Percent)% exceeds $MaxGpu3DPercent%")
    }
    if ($summary.WorkingSetPeakMb -gt $MaxWorkingSetMb) {
        $violations.Add("working set peak $($summary.WorkingSetPeakMb) MB exceeds $MaxWorkingSetMb MB")
    }
    foreach ($phase in $frameReport | Where-Object { $null -ne $_.totalP95Ms }) {
        if ([double]$phase.totalP95Ms -gt $MaxFrameP95Ms) {
            $violations.Add("$($phase.phase) frame p95 $($phase.totalP95Ms) ms exceeds $MaxFrameP95Ms ms")
        }
    }
    $smtcReport = $frameReport | Where-Object { $_.phase -eq "smtc_stress" } | Select-Object -First 1
    if ($null -eq $smtcReport) {
        $violations.Add("SMTC performance report is missing")
    }
    else {
        if ([double]$smtcReport.timelineSequentialP95Ms -gt $MaxSmtcSequentialP95Ms) {
            $violations.Add("SMTC timeline p95 $($smtcReport.timelineSequentialP95Ms) ms exceeds $MaxSmtcSequentialP95Ms ms")
        }
        if ([double]$smtcReport.rssRepeatGrowthMb -gt $MaxSmtcRepeatGrowthMb) {
            $violations.Add("SMTC repeat RSS growth $($smtcReport.rssRepeatGrowthMb) MB exceeds $MaxSmtcRepeatGrowthMb MB")
        }
    }
    if ($violations.Count -gt 0) {
        throw ($violations -join "; ")
    }
}
finally {
    if (-not $driveProcess.HasExited) {
        Stop-Process -Id $driveProcess.Id -Force
    }
    if ($null -ne $appProcessId) {
        $ownedAppProcess = Get-Process -Id $appProcessId -ErrorAction SilentlyContinue
        if ($null -ne $ownedAppProcess -and $ownedAppProcess.StartTime -ge $startedAt) {
            Stop-Process -Id $appProcessId -Force
        }
    }
}
