param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [Parameter(Mandatory = $true)][Alias("Input")][string]$Source,
    [string]$OutputDir = "target/compile-memory/windows",
    [ValidateSet(0, 1, 2)][int]$OptLevel = 1,
    [string]$Target = "windows-x86_64",
    [string[]]$StdlibRoot = @("stdlib", "src"),
    [ValidateRange(1, 1000)][int]$SampleMilliseconds = 5
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "[compile-memory] $Message"
}

function ConvertTo-NativeArgument([string]$Argument) {
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    # CommandLineToArgvW quoting: double backslashes before quotes and before
    # the closing quote. This fallback keeps the sampler usable from Windows
    # PowerShell 5.1, whose ProcessStartInfo has no ArgumentList collection.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Fail "Windows process working-set/private-memory counters are required"
}

$compilerPath = (Resolve-Path -LiteralPath $Compiler -ErrorAction Stop).Path
$inputPath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null

$assemblyPath = Join-Path $outputPath "output.s"
$stdoutPath = Join-Path $outputPath "stdout.log"
$stderrPath = Join-Path $outputPath "stderr.log"
$samplesPath = Join-Path $outputPath "owner-samples.tsv"
$summaryPath = Join-Path $outputPath "phase-summary.tsv"

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $compilerPath
$startInfo.WorkingDirectory = (Get-Location).Path
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$compilerArguments = @(
    "compile",
    $inputPath,
    "-o",
    $assemblyPath,
    "--target",
    $Target,
    "--opt-level",
    "$OptLevel",
    "--profile-allocations"
)
foreach ($root in $StdlibRoot) {
    $compilerArguments += "--stdlib-root"
    $compilerArguments += [System.IO.Path]::GetFullPath($root)
}
if ($null -ne $startInfo.ArgumentList) {
    foreach ($argument in $compilerArguments) {
        $startInfo.ArgumentList.Add($argument)
    }
} else {
    $startInfo.Arguments = ($compilerArguments |
        ForEach-Object { ConvertTo-NativeArgument $_ }) -join " "
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
    Fail "could not start compiler child"
}
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrLineTask = $process.StandardError.ReadLineAsync()
$stderrClosed = $false
$stderrWriter = [System.IO.StreamWriter]::new(
    $stderrPath,
    $false,
    [System.Text.UTF8Encoding]::new($false)
)

$samples = [System.Collections.Generic.List[object]]::new()
$workingPeak = 0L
$privatePeak = 0L
$lastWorking = 0L
$lastPrivate = 0L
$started = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $process.HasExited -or -not $stderrClosed) {
    $working = $lastWorking
    $private = $lastPrivate
    if (-not $process.HasExited) {
        try {
            $process.Refresh()
            $working = [int64]$process.WorkingSet64
            $private = [int64]$process.PrivateMemorySize64
            if ($working -gt 0 -and $private -gt 0) {
                $workingPeak = [Math]::Max($workingPeak, $working)
                $privatePeak = [Math]::Max($privatePeak, $private)
                $lastWorking = $working
                $lastPrivate = $private
            }
        } catch [System.InvalidOperationException] {
            # The process may exit between HasExited and Refresh.
        }
    }

    while (-not $stderrClosed -and $stderrLineTask.IsCompleted) {
        $line = $stderrLineTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            $stderrClosed = $true
        } else {
            $stderrWriter.WriteLine($line)
            if ($line -match '^compile-allocation-profile\|[^|]+\|[^|]+\|[0-9]+\|') {
                $fields = $line.Split('|')
                if ($fields.Count -ne 8) {
                    Fail "invalid allocation profile row: $line"
                }
                $samples.Add([pscustomobject]@{
                    phase = $fields[1]
                    owner = $fields[2]
                    arena_root = [int64]$fields[3]
                    bump_bytes = [int64]$fields[4]
                    committed_bytes = [int64]$fields[5]
                    reserved_bytes = [int64]$fields[6]
                    segments = [int64]$fields[7]
                    elapsed_ms = $started.ElapsedMilliseconds
                    working_set_bytes = $working
                    working_set_peak_bytes = $workingPeak
                    private_bytes = $private
                    private_peak_bytes = $privatePeak
                })
            }
            $stderrLineTask = $process.StandardError.ReadLineAsync()
        }
    }
    Start-Sleep -Milliseconds $SampleMilliseconds
}

$process.WaitForExit()
$started.Stop()
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderrWriter.Dispose()
[System.IO.File]::WriteAllText(
    $stdoutPath,
    $stdout,
    [System.Text.UTF8Encoding]::new($false)
)
if ($process.ExitCode -ne 0) {
    Fail "compiler child exited $($process.ExitCode); see $stderrPath"
}
if ($samples.Count -eq 0) {
    Fail "compiler emitted no allocation profile rows; it must support --profile-allocations"
}
if ($workingPeak -le 0 -or $privatePeak -le 0) {
    Fail "child process did not expose working-set/private-memory counters"
}

$samples |
    Export-Csv -LiteralPath $samplesPath -Delimiter "`t" -NoTypeInformation

$phaseRows = [System.Collections.Generic.List[object]]::new()
$phaseOrder = [System.Collections.Generic.List[string]]::new()
$phaseGroups = @{}
foreach ($sample in $samples) {
    if (-not $phaseGroups.ContainsKey($sample.phase)) {
        $phaseGroups[$sample.phase] = [System.Collections.Generic.List[object]]::new()
        $phaseOrder.Add($sample.phase)
    }
    $phaseGroups[$sample.phase].Add($sample)
}
foreach ($phase in $phaseOrder) {
    $group = $phaseGroups[$phase]
    $uniqueRoots = @{}
    foreach ($sample in $group) {
        if ($sample.arena_root -ne 0) {
            $key = "$($sample.arena_root)"
            if (-not $uniqueRoots.ContainsKey($key) -or
                $sample.committed_bytes -gt $uniqueRoots[$key].committed_bytes) {
                $uniqueRoots[$key] = $sample
            }
        }
    }
    $trackedUsed = 0L
    $trackedCommitted = 0L
    $trackedReserved = 0L
    $phaseWorking = 0L
    $phasePrivate = 0L
    foreach ($sample in $uniqueRoots.Values) {
        $trackedUsed += $sample.bump_bytes
        $trackedCommitted += $sample.committed_bytes
        $trackedReserved += $sample.reserved_bytes
    }
    foreach ($sample in $group) {
        $phaseWorking = [Math]::Max($phaseWorking, $sample.working_set_bytes)
        $phasePrivate = [Math]::Max($phasePrivate, $sample.private_bytes)
    }
    $phaseRows.Add([pscustomobject]@{
        phase = $phase
        tracked_unique_bump_bytes = $trackedUsed
        tracked_unique_committed_bytes = $trackedCommitted
        tracked_unique_reserved_bytes = $trackedReserved
        working_set_bytes = $phaseWorking
        private_bytes = $phasePrivate
        process_working_set_peak_bytes = $workingPeak
        process_private_peak_bytes = $privatePeak
    })
}
$phaseRows |
    Export-Csv -LiteralPath $summaryPath -Delimiter "`t" -NoTypeInformation

Write-Output "[compile-memory] elapsed_ms=$($started.ElapsedMilliseconds) working_peak_bytes=$workingPeak private_peak_bytes=$privatePeak"
Write-Output "[compile-memory] owner samples $samplesPath"
Write-Output "[compile-memory] phase summary $summaryPath"
