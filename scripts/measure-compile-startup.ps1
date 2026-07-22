param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [Parameter(Mandatory = $true)][Alias("Input")][string]$Source,
    [string]$OutputDir = "target/compile-startup/windows",
    [string]$WorkingDirectory = "",
    [ValidateSet(0, 1, 2)][int]$OptLevel = 0,
    [ValidateRange(1, 1000)][int]$Iterations = 41,
    [ValidateRange(0, 100)][int]$Warmups = 5,
    [string]$BaselineCompiler = "",
    [string[]]$StdlibRoot = @(),
    [switch]$SkipFirstLaunch
)

# The profiled compiler must be built with `--cfg compile-startup-profile` and,
# for the primary no-root hydration measurement, `--cfg embedded-stdlib-tlci`.
# `BaselineCompiler` is optional; when supplied, measured profile/control runs
# alternate order to bound instrumentation perturbation.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "[compile-startup] $Message"
}

function Resolve-FullPath([string]$Path, [string]$Base) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function ConvertTo-NativeArgument([string]$Argument) {
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Convert-TicksToMilliseconds([long]$Start, [long]$End, [long]$Frequency) {
    return ([double]($End - $Start) * 1000.0) / [double]$Frequency
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if ($Values.Count -eq 0) {
        return [double]::NaN
    }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }
    $position = ($sorted.Count - 1) * $Percentile
    $lower = [Math]::Floor($position)
    $upper = [Math]::Ceiling($position)
    if ($lower -eq $upper) {
        return [double]$sorted[$lower]
    }
    $weight = $position - $lower
    return ([double]$sorted[$lower] * (1.0 - $weight)) +
        ([double]$sorted[$upper] * $weight)
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Fail "Windows QueryPerformanceCounter correlation is required"
}

$script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $WorkingDirectory = $script:Root
}
$WorkingDirectory = Resolve-FullPath $WorkingDirectory $script:Root
$Compiler = Resolve-FullPath $Compiler $WorkingDirectory
$Source = Resolve-FullPath $Source $WorkingDirectory
$OutputDir = Resolve-FullPath $OutputDir $WorkingDirectory
if (-not [string]::IsNullOrWhiteSpace($BaselineCompiler)) {
    $BaselineCompiler = Resolve-FullPath $BaselineCompiler $WorkingDirectory
}

foreach ($file in @($Compiler, $Source)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Fail "missing required file: $file"
    }
}
if ($BaselineCompiler -and -not (Test-Path -LiteralPath $BaselineCompiler -PathType Leaf)) {
    Fail "missing baseline compiler: $BaselineCompiler"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$script:ChildFrequency = [Diagnostics.Stopwatch]::Frequency
$script:Rows = New-Object System.Collections.Generic.List[object]
$script:Runs = New-Object System.Collections.Generic.List[object]
$requiredMarkers = @(
    "globals.start",
    "main.entry",
    "cli.compile_action",
    "driver_state.begin",
    "driver_state.end",
    "preflight.begin",
    "preflight.end",
    "file_state_reset.end",
    "compile_driver.start",
    "prelude.begin",
    "surface.begin",
    "surface.end",
    "prelude.end",
    "user_entry.start"
)

function New-CompileArguments([string]$OutputPath) {
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @("compile", $Source, "-o", $OutputPath, "--opt-level", "$OptLevel")) {
        $arguments.Add($argument)
    }
    foreach ($root in $StdlibRoot) {
        $arguments.Add("--stdlib-root")
        $arguments.Add($root)
    }
    return $arguments
}

function Read-ProfileMarkers([string]$Stderr) {
    $markers = @{}
    $frequency = 0L
    foreach ($line in ($Stderr -split "`r?`n")) {
        if (-not $line.StartsWith("compile-startup-profile|")) {
            continue
        }
        $fields = $line.Split('|')
        if ($fields.Count -ne 4 -or $fields[1] -eq "marker") {
            continue
        }
        $tick = 0L
        $rowFrequency = 0L
        if (-not [long]::TryParse($fields[2], [ref]$tick)) {
            Fail "invalid marker tick: $line"
        }
        if (-not [long]::TryParse($fields[3], [ref]$rowFrequency)) {
            Fail "invalid marker frequency: $line"
        }
        if ($frequency -eq 0) {
            $frequency = $rowFrequency
        } elseif ($frequency -ne $rowFrequency) {
            Fail "marker frequency changed within one process"
        }
        $markers[$fields[1]] = $tick
    }
    return [pscustomobject]@{ Markers = $markers; Frequency = $frequency }
}

function Add-MetricRows([object]$Run) {
    $m = $Run.Markers
    $f = $Run.Frequency
    $metrics = [ordered]@{
        "launch_to_globals" = @( $Run.LaunchTick, $m["globals.start"] )
        "global_initializers" = @( $m["globals.start"], $m["main.entry"] )
        "launch_to_main" = @( $Run.LaunchTick, $m["main.entry"] )
        "main_to_driver_state" = @( $m["main.entry"], $m["driver_state.begin"] )
        "driver_state" = @( $m["driver_state.begin"], $m["driver_state.end"] )
        "state_install" = @( $m["driver_state.end"], $m["preflight.begin"] )
        "preflight" = @( $m["preflight.begin"], $m["preflight.end"] )
        "reset_and_cfg" = @( $m["preflight.end"], $m["compile_driver.start"] )
        "driver_setup" = @( $m["compile_driver.start"], $m["prelude.begin"] )
        "prelude_before_surface" = @( $m["prelude.begin"], $m["surface.begin"] )
        "surface_hydration" = @( $m["surface.begin"], $m["surface.end"] )
        "prelude_after_surface" = @( $m["surface.end"], $m["prelude.end"] )
        "prelude" = @( $m["prelude.begin"], $m["prelude.end"] )
        "post_prelude" = @( $m["prelude.end"], $m["user_entry.start"] )
        "launch_to_user_entry" = @( $Run.LaunchTick, $m["user_entry.start"] )
        "process_wall" = @( $Run.LaunchTick, $Run.ExitTick )
    }
    foreach ($metric in $metrics.GetEnumerator()) {
        $script:Rows.Add([pscustomobject]@{
            Cohort = $Run.Cohort
            Kind = $Run.Kind
            Iteration = $Run.Iteration
            Metric = $metric.Key
            ElapsedMs = Convert-TicksToMilliseconds $metric.Value[0] $metric.Value[1] $f
        })
    }
}

function Invoke-CompileRun(
    [string]$Kind,
    [string]$Cohort,
    [int]$Iteration,
    [string]$Executable,
    [bool]$RequireMarkers
) {
    $outputPath = Join-Path $OutputDir "$Kind-output.s"
    $arguments = New-CompileArguments $outputPath
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $launchTick = [Diagnostics.Stopwatch]::GetTimestamp()
    if (-not $process.Start()) {
        Fail "Process.Start returned false for $Executable"
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitTick = [Diagnostics.Stopwatch]::GetTimestamp()
    $exitCode = $process.ExitCode
    $process.Dispose()

    if ($exitCode -ne 0) {
        $logStem = Join-Path $OutputDir "$Cohort-$Kind-$Iteration"
        [IO.File]::WriteAllText("$logStem.stdout", $stdout)
        [IO.File]::WriteAllText("$logStem.stderr", $stderr)
        Fail "$Kind compile exited $exitCode; logs: $logStem.stderr"
    }

    $profile = Read-ProfileMarkers $stderr
    if ($RequireMarkers) {
        if ($profile.Frequency -ne $script:ChildFrequency) {
            Fail "child QPC frequency $($profile.Frequency) differs from parent $script:ChildFrequency"
        }
        foreach ($marker in $requiredMarkers) {
            if (-not $profile.Markers.ContainsKey($marker)) {
                Fail "profile output is missing marker '$marker'"
            }
        }
        $previous = $launchTick
        foreach ($marker in $requiredMarkers) {
            $current = [long]$profile.Markers[$marker]
            if ($current -lt $previous) {
                Fail "marker '$marker' is not monotonic"
            }
            $previous = $current
        }
    }

    $run = [pscustomobject]@{
        Cohort = $Cohort
        Kind = $Kind
        Iteration = $Iteration
        LaunchTick = $launchTick
        ExitTick = $exitTick
        ExitCode = $exitCode
        Frequency = if ($RequireMarkers) { $profile.Frequency } else { $script:ChildFrequency }
        Markers = $profile.Markers
    }
    $script:Runs.Add($run)
    if ($RequireMarkers) {
        Add-MetricRows $run
    } else {
        $script:Rows.Add([pscustomobject]@{
            Cohort = $Cohort
            Kind = $Kind
            Iteration = $Iteration
            Metric = "process_wall"
            ElapsedMs = Convert-TicksToMilliseconds $launchTick $exitTick $script:ChildFrequency
        })
    }
}

Write-Host "[compile-startup] compiler: $Compiler"
Write-Host "[compile-startup] source: $Source"
Write-Host "[compile-startup] output: $OutputDir"

if (-not $SkipFirstLaunch) {
    Invoke-CompileRun "profile" "first" 0 $Compiler $true
}

for ($i = 0; $i -lt $Warmups; $i++) {
    Invoke-CompileRun "profile" "warmup" $i $Compiler $true
    if ($BaselineCompiler) {
        Invoke-CompileRun "baseline" "warmup" $i $BaselineCompiler $false
    }
}

for ($i = 0; $i -lt $Iterations; $i++) {
    if ($BaselineCompiler -and (($i % 2) -eq 1)) {
        Invoke-CompileRun "baseline" "measured" $i $BaselineCompiler $false
        Invoke-CompileRun "profile" "measured" $i $Compiler $true
    } else {
        Invoke-CompileRun "profile" "measured" $i $Compiler $true
        if ($BaselineCompiler) {
            Invoke-CompileRun "baseline" "measured" $i $BaselineCompiler $false
        }
    }
}

$sampleLines = New-Object System.Collections.Generic.List[string]
$sampleLines.Add("cohort`tkind`titeration`tmetric`telapsed_ms")
foreach ($row in $script:Rows) {
    $sampleLines.Add("$($row.Cohort)`t$($row.Kind)`t$($row.Iteration)`t$($row.Metric)`t$($row.ElapsedMs.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))")
}
[IO.File]::WriteAllLines((Join-Path $OutputDir "samples.tsv"), $sampleLines)

$markerLines = New-Object System.Collections.Generic.List[string]
$markerLines.Add("cohort`tkind`titeration`tmarker`ttick`tfrequency")
foreach ($run in $script:Runs) {
    $markerLines.Add("$($run.Cohort)`t$($run.Kind)`t$($run.Iteration)`tparent.launch`t$($run.LaunchTick)`t$($run.Frequency)")
    foreach ($marker in $requiredMarkers) {
        if ($run.Markers.ContainsKey($marker)) {
            $markerLines.Add("$($run.Cohort)`t$($run.Kind)`t$($run.Iteration)`t$marker`t$($run.Markers[$marker])`t$($run.Frequency)")
        }
    }
    $markerLines.Add("$($run.Cohort)`t$($run.Kind)`t$($run.Iteration)`tprocess.exit`t$($run.ExitTick)`t$($run.Frequency)")
}
[IO.File]::WriteAllLines((Join-Path $OutputDir "markers.tsv"), $markerLines)

$summaryRows = New-Object System.Collections.Generic.List[object]
$groups = $script:Rows | Where-Object { $_.Cohort -ne "warmup" } |
    Group-Object Cohort, Kind, Metric
foreach ($group in $groups) {
    $first = $group.Group[0]
    [double[]]$values = @($group.Group | ForEach-Object { [double]$_.ElapsedMs })
    $summaryRows.Add([pscustomobject]@{
        Cohort = $first.Cohort
        Kind = $first.Kind
        Metric = $first.Metric
        Count = $values.Count
        P10Ms = Get-Percentile $values 0.10
        MedianMs = Get-Percentile $values 0.50
        P90Ms = Get-Percentile $values 0.90
    })
}

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("cohort`tkind`tmetric`tcount`tp10_ms`tmedian_ms`tp90_ms")
foreach ($row in $summaryRows) {
    $summaryLines.Add("$($row.Cohort)`t$($row.Kind)`t$($row.Metric)`t$($row.Count)`t$($row.P10Ms.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))`t$($row.MedianMs.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))`t$($row.P90Ms.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))")
}
[IO.File]::WriteAllLines((Join-Path $OutputDir "summary.tsv"), $summaryLines)

$defender = "unavailable"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $defender = "antivirus_enabled=$($mp.AntivirusEnabled);real_time_protection=$($mp.RealTimeProtectionEnabled);signature=$($mp.AntivirusSignatureVersion)"
} catch {
}
$metadata = @(
    "key`tvalue",
    "timestamp_utc`t$([DateTime]::UtcNow.ToString('o'))",
    "windows_version`t$([Environment]::OSVersion.VersionString)",
    "processor_count`t$([Environment]::ProcessorCount)",
    "stopwatch_frequency`t$script:ChildFrequency",
    "compiler`t$Compiler",
    "compiler_sha256`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $Compiler).Hash)",
    "baseline_compiler`t$BaselineCompiler",
    "source`t$Source",
    "opt_level`t$OptLevel",
    "iterations`t$Iterations",
    "warmups`t$Warmups",
    "defender`t$defender"
)
[IO.File]::WriteAllLines((Join-Path $OutputDir "metadata.tsv"), $metadata)

Write-Host ""
Write-Host "[compile-startup] measured profile attribution (ms)"
$summaryRows | Where-Object { $_.Cohort -eq "measured" -and $_.Kind -eq "profile" } |
    Select-Object Metric, Count,
        @{Name = "P10Ms"; Expression = { [Math]::Round($_.P10Ms, 3) }},
        @{Name = "MedianMs"; Expression = { [Math]::Round($_.MedianMs, 3) }},
        @{Name = "P90Ms"; Expression = { [Math]::Round($_.P90Ms, 3) }} |
    Format-Table -AutoSize
Write-Host "[compile-startup] wrote markers.tsv, samples.tsv, summary.tsv, and metadata.tsv"
