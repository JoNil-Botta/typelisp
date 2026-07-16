param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [Parameter(Mandatory = $true)][Alias("Input")][string]$Source,
    [string]$OutputDir = "target/compile-memory/windows",
    [ValidateSet(0, 1, 2)][int]$OptLevel = 1,
    [string]$Target = "windows-x86_64",
    [string[]]$StdlibRoot = @("stdlib", "src"),
    [ValidateRange(1, 1000)][int]$SampleMilliseconds = 5,
    [ValidateRange(1048576, [long]::MaxValue)][long]$MaxBytes = 4294967296
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

if (-not ("TypeLispCompileMemoryJob" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class TypeLispCompileMemoryJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, ref ExtendedLimits info, uint length);

    [DllImport("kernel32.dll")]
    static extern bool QueryInformationJobObject(
        IntPtr job, int infoClass, ref ExtendedLimits info, uint length,
        IntPtr returnedLength);

    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    IntPtr handle;

    TypeLispCompileMemoryJob(IntPtr handle) {
        this.handle = handle;
    }

    public static TypeLispCompileMemoryJob Create(ulong maxBytes) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = 0x200;
        limits.JobMemoryLimit = new UIntPtr(maxBytes);
        uint size = (uint)Marshal.SizeOf(limits);
        if (!SetInformationJobObject(job, 9, ref limits, size)) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error);
        }
        return new TypeLispCompileMemoryJob(job);
    }

    public void Assign(IntPtr process) {
        if (!AssignProcessToJobObject(handle, process))
            throw new Win32Exception();
    }

    public ulong PeakJobBytes() {
        var observed = new ExtendedLimits();
        uint size = (uint)Marshal.SizeOf(observed);
        if (!QueryInformationJobObject(
            handle, 9, ref observed, size, IntPtr.Zero))
            throw new Win32Exception();
        return observed.PeakJobMemoryUsed.ToUInt64();
    }

    public void Dispose() {
        if (handle != IntPtr.Zero) {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }
}
'@
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
$memoryJob = [TypeLispCompileMemoryJob]::Create([uint64]$MaxBytes)
if (-not $process.Start()) {
    $memoryJob.Dispose()
    Fail "could not start compiler child"
}
try {
    $memoryJob.Assign($process.Handle)
} catch {
    $process.Kill()
    $process.WaitForExit()
    $memoryJob.Dispose()
    throw
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
$macroSnapshotId = 0L
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
                if ($fields[1] -eq "typecheck.macro.peak" -and
                    $fields[2] -eq "macro-enclosing") {
                    $macroSnapshotId++
                }
                $samples.Add([pscustomobject]@{
                    phase = $fields[1]
                    owner = $fields[2]
                    snapshot_id = if ($fields[1] -eq "typecheck.macro.peak") {
                        $macroSnapshotId
                    } else {
                        0
                    }
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
$jobPeak = $memoryJob.PeakJobBytes()
$memoryJob.Dispose()
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
    $snapshotGroups = @{}
    foreach ($sample in $group) {
        $snapshotKey = "$($sample.snapshot_id)"
        if (-not $snapshotGroups.ContainsKey($snapshotKey)) {
            $snapshotGroups[$snapshotKey] = [System.Collections.Generic.List[object]]::new()
        }
        $snapshotGroups[$snapshotKey].Add($sample)
    }
    $trackedSnapshotId = 0L
    $trackedSnapshotPrivate = -1L
    $trackedUsed = 0L
    $trackedCommitted = -1L
    $trackedReserved = 0L
    foreach ($snapshotKey in $snapshotGroups.Keys) {
        $uniqueRoots = @{}
        foreach ($sample in $snapshotGroups[$snapshotKey]) {
            if ($sample.arena_root -ne 0) {
                $rootKey = "$($sample.arena_root)"
                if (-not $uniqueRoots.ContainsKey($rootKey) -or
                    $sample.committed_bytes -gt $uniqueRoots[$rootKey].committed_bytes) {
                    $uniqueRoots[$rootKey] = $sample
                }
            }
        }
        $snapshotUsed = 0L
        $snapshotCommitted = 0L
        $snapshotReserved = 0L
        $snapshotPrivate = 0L
        foreach ($sample in $uniqueRoots.Values) {
            $snapshotUsed += $sample.bump_bytes
            $snapshotCommitted += $sample.committed_bytes
            $snapshotReserved += $sample.reserved_bytes
        }
        foreach ($sample in $snapshotGroups[$snapshotKey]) {
            $snapshotPrivate = [Math]::Max($snapshotPrivate, $sample.private_bytes)
        }
        if ($snapshotPrivate -gt $trackedSnapshotPrivate -or
            ($snapshotPrivate -eq $trackedSnapshotPrivate -and
                $snapshotCommitted -gt $trackedCommitted)) {
            $trackedSnapshotId = [int64]$snapshotKey
            $trackedSnapshotPrivate = $snapshotPrivate
            $trackedUsed = $snapshotUsed
            $trackedCommitted = $snapshotCommitted
            $trackedReserved = $snapshotReserved
        }
    }
    $phaseWorking = 0L
    $phasePrivate = 0L
    foreach ($sample in $group) {
        $phaseWorking = [Math]::Max($phaseWorking, $sample.working_set_bytes)
        $phasePrivate = [Math]::Max($phasePrivate, $sample.private_bytes)
    }
    $phaseRows.Add([pscustomobject]@{
        phase = $phase
        tracked_snapshot_id = $trackedSnapshotId
        tracked_unique_bump_bytes = $trackedUsed
        tracked_unique_committed_bytes = $trackedCommitted
        tracked_unique_reserved_bytes = $trackedReserved
        private_minus_tracked_committed_bytes = $phasePrivate - $trackedCommitted
        working_set_bytes = $phaseWorking
        private_bytes = $phasePrivate
        process_working_set_peak_bytes = $workingPeak
        process_private_peak_bytes = $privatePeak
    })
}
$phaseRows |
    Export-Csv -LiteralPath $summaryPath -Delimiter "`t" -NoTypeInformation

Write-Output "[compile-memory] elapsed_ms=$($started.ElapsedMilliseconds) working_peak_bytes=$workingPeak private_peak_bytes=$privatePeak job_peak_bytes=$jobPeak max_bytes=$MaxBytes"
Write-Output "[compile-memory] owner samples $samplesPath"
Write-Output "[compile-memory] phase summary $summaryPath"
