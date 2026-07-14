<#
.SYNOPSIS
Runs a bounded Windows self-compile allocator/process reliability campaign.

.DESCRIPTION
Preserves exact per-stage argv, compiler hashes, exit codes, stdout/stderr,
100 ms system commit samples, generated binary hashes, and matching Windows
resource-exhaustion events. It never retries a compiler or changes allocation
policy. Each attempt rebuilds and exercises opt0, opt1, and opt2 stages.
#>
param(
    [string]$Seed = "tools/stage0/typelisp.exe",
    [ValidateRange(1, 1000)][int]$Attempts = 10,
    [string]$OutputDir = "",
    [string]$Bash = "bash"
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "[windows-allocation-campaign] $Message"
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Fail "Windows VirtualAlloc and system commit counters are required"
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$seedCandidate = if ([System.IO.Path]::IsPathRooted($Seed)) {
    $Seed
} else {
    Join-Path $root $Seed
}
$seedPath = [System.IO.Path]::GetFullPath($seedCandidate)
if (-not [System.IO.File]::Exists($seedPath)) {
    Fail "seed compiler does not exist: $seedPath"
}
$bashCommand = (Get-Command $Bash -ErrorAction Stop).Source
if (-not $OutputDir) {
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmssZ")
    $OutputDir = "target/windows-allocation-campaign/$stamp"
}
$outputCandidate = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $root $OutputDir
}
$outputPath = [System.IO.Path]::GetFullPath($outputCandidate)
if ([System.IO.Directory]::Exists($outputPath) -and
    (Get-ChildItem -LiteralPath $outputPath -Force | Select-Object -First 1)) {
    Fail "output directory is not empty; refusing to overwrite evidence: $outputPath"
}
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null

function To-MsysPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):[\\/](.*)$') {
        Fail "campaign paths must be drive-qualified Windows paths: $full"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $tail = $Matches[2].Replace('\', '/')
    return "/$drive/$tail"
}

function EpochMilliseconds() {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

# ProcessStartInfo.ArgumentList is unavailable under Windows PowerShell 5.1.
# Quote for the native Windows argv parser so drive paths containing spaces or
# quotes still reach Git Bash as exactly two arguments.
function Quote-NativeArgument([string]$Argument) {
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * ($slashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

if (-not ('TypeLisp.MemoryStatus' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TypeLisp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MemoryStatusEx {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    public static class MemoryStatus {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx status);

        public static MemoryStatusEx Read() {
            var status = new MemoryStatusEx();
            if (!GlobalMemoryStatusEx(status)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return status;
        }
    }
}
'@
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$seedHash = (Get-FileHash -LiteralPath $seedPath -Algorithm SHA256).Hash.ToLowerInvariant()
$summaryPath = Join-Path $outputPath "attempts.tsv"
[System.IO.File]::WriteAllText(
    $summaryPath,
    "attempt`tstart_epoch_ms`tend_epoch_ms`texit_code`tseed`tseed_sha256`tbenchmark_dir`tstdout`tstderr`n",
    $utf8
)
$metadata = [ordered]@{
    schema = "typelisp-windows-allocation-campaign-v1"
    repo_head = (git -C $root rev-parse HEAD).Trim()
    repo_worktree_dirty = [bool](git -C $root status --short)
    campaign_script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    benchmark_script_sha256 = (Get-FileHash -LiteralPath (Join-Path $root "scripts/benchmark-compile-cli.sh") -Algorithm SHA256).Hash.ToLowerInvariant()
    seed = $seedPath
    seed_sha256 = $seedHash
    attempts = $Attempts
    sample_interval_ms = 100
    benchmark = "scripts/benchmark-compile-cli.sh"
    benchmark_ratio_check = $false
    computer_name = [System.Environment]::MachineName
    os_version = [System.Environment]::OSVersion.VersionString
    started_utc = [DateTime]::UtcNow.ToString("o")
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputPath "campaign.json"),
    ($metadata | ConvertTo-Json -Depth 4),
    $utf8
)

$oldBenchOut = $env:TYPELISP_COMPILE_BENCH_OUT
$oldOptLevels = $env:TYPELISP_COMPILE_BENCH_OPT_LEVELS
$oldCheck = $env:TYPELISP_COMPILE_BENCH_CHECK
$hadFailure = $false
try {
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $attemptName = "attempt-{0:D3}" -f $attempt
        $attemptPath = Join-Path $outputPath $attemptName
        $benchmarkPath = Join-Path $attemptPath "benchmark"
        [System.IO.Directory]::CreateDirectory($attemptPath) | Out-Null
        $stdoutPath = Join-Path $attemptPath "campaign.stdout"
        $stderrPath = Join-Path $attemptPath "campaign.stderr"
        $memoryPath = Join-Path $attemptPath "system-memory.tsv"
        $argvPath = Join-Path $attemptPath "campaign.argv"
        [System.IO.File]::WriteAllLines(
            $argvPath,
            @("# argv, one argument per line", $bashCommand, "scripts/benchmark-compile-cli.sh", (To-MsysPath $seedPath)),
            $utf8
        )

        $env:TYPELISP_COMPILE_BENCH_OUT = To-MsysPath $benchmarkPath
        $env:TYPELISP_COMPILE_BENCH_OPT_LEVELS = "0 1 2"
        # The ratio gate is intentionally disabled: scheduler noise around its
        # integer 2x boundary is not an allocator/process failure. The campaign
        # still runs the same opt0/opt1/opt2 build and opt1 profile corpus.
        $env:TYPELISP_COMPILE_BENCH_CHECK = "0"
        $start = EpochMilliseconds
        Write-Output "[windows-allocation-campaign] $attemptName start seed=$seedHash"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $bashCommand
        $startInfo.WorkingDirectory = $root
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = @(
            (Quote-NativeArgument "scripts/benchmark-compile-cli.sh"),
            (Quote-NativeArgument (To-MsysPath $seedPath))
        ) -join ' '
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            Fail "could not start $attemptName"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $memoryWriter = [System.IO.StreamWriter]::new($memoryPath, $false, $utf8)
        try {
            $memoryWriter.WriteLine(
                "epoch_ms`telapsed_ms`tcommitted_bytes`tcommit_limit_bytes`tavailable_commit_bytes`tavailable_physical_bytes`tmemory_load_percent"
            )
            while (-not $process.HasExited) {
                $now = EpochMilliseconds
                $memory = [TypeLisp.MemoryStatus]::Read()
                $committed = $memory.ullTotalPageFile - $memory.ullAvailPageFile
                $memoryWriter.WriteLine(
                    "$now`t$($now - $start)`t$committed`t$($memory.ullTotalPageFile)`t$($memory.ullAvailPageFile)`t$($memory.ullAvailPhys)`t$($memory.dwMemoryLoad)"
                )
                $memoryWriter.Flush()
                Start-Sleep -Milliseconds 100
            }
            $process.WaitForExit()
        } finally {
            $memoryWriter.Dispose()
        }
        [System.IO.File]::WriteAllText(
            $stdoutPath,
            $stdoutTask.GetAwaiter().GetResult(),
            $utf8
        )
        [System.IO.File]::WriteAllText(
            $stderrPath,
            $stderrTask.GetAwaiter().GetResult(),
            $utf8
        )
        $end = EpochMilliseconds
        $code = $process.ExitCode
        if ($code -ne 0) {
            $hadFailure = $true
        }
        [System.IO.File]::AppendAllText(
            $summaryPath,
            "$attemptName`t$start`t$end`t$code`t$seedPath`t$seedHash`t$benchmarkPath`t$stdoutPath`t$stderrPath`n",
            $utf8
        )

        $binaryRows = [System.Collections.Generic.List[string]]::new()
        $binaryRows.Add("path`tsha256`tbytes")
        $binaryRows.Add("$seedPath`t$seedHash`t$((Get-Item -LiteralPath $seedPath).Length)")
        if ([System.IO.Directory]::Exists($benchmarkPath)) {
            foreach ($binary in Get-ChildItem -LiteralPath $benchmarkPath -Recurse -File -Filter "*.exe") {
                $hash = (Get-FileHash -LiteralPath $binary.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                $binaryRows.Add("$($binary.FullName)`t$hash`t$($binary.Length)")
            }
        }
        [System.IO.File]::WriteAllLines((Join-Path $attemptPath "binaries.tsv"), $binaryRows, $utf8)

        $eventRows = [System.Collections.Generic.List[string]]::new()
        $eventRows.Add("time_utc`tid`tprovider`tmessage")
        try {
            $eventStart = [DateTimeOffset]::FromUnixTimeMilliseconds($start).LocalDateTime.AddSeconds(-5)
            $eventEnd = [DateTimeOffset]::FromUnixTimeMilliseconds($end).LocalDateTime.AddSeconds(5)
            $events = Get-WinEvent -FilterHashtable @{
                LogName = "System"
                ProviderName = "Microsoft-Windows-Resource-Exhaustion-Detector"
                StartTime = $eventStart
                EndTime = $eventEnd
            } -ErrorAction SilentlyContinue
            foreach ($event in $events) {
                $message = ($event.Message -replace '[\r\n\t]+', ' ').Trim()
                $time = $event.TimeCreated.ToUniversalTime().ToString("o")
                $eventRows.Add("$time`t$($event.Id)`t$($event.ProviderName)`t$message")
            }
        } catch {
            # Event data is corroborating evidence. Lack of log access must not
            # erase the compiler exit, argv, hashes, or commit samples.
        }
        [System.IO.File]::WriteAllLines(
            (Join-Path $attemptPath "windows-events.tsv"),
            $eventRows,
            $utf8
        )

        $allocationRows = [System.Collections.Generic.List[string]]::new()
        $allocationRows.Add("log`tmessage")
        foreach ($log in Get-ChildItem -LiteralPath $attemptPath -Recurse -File) {
            if ($log.Name -notmatch '(stderr|\.stderr)$') {
                continue
            }
            foreach ($line in Get-Content -LiteralPath $log.FullName) {
                if ($line -like 'tl: allocation failed:*') {
                    $relative = $log.FullName.Substring($attemptPath.Length).TrimStart([char[]]"\/")
                    $allocationRows.Add("$relative`t$line")
                }
            }
        }
        [System.IO.File]::WriteAllLines(
            (Join-Path $attemptPath "allocation-failures.tsv"),
            $allocationRows,
            $utf8
        )
        Write-Output "[windows-allocation-campaign] $attemptName exit=$code elapsed_ms=$($end - $start)"
    }
} finally {
    $env:TYPELISP_COMPILE_BENCH_OUT = $oldBenchOut
    $env:TYPELISP_COMPILE_BENCH_OPT_LEVELS = $oldOptLevels
    $env:TYPELISP_COMPILE_BENCH_CHECK = $oldCheck
}

Write-Output "[windows-allocation-campaign] evidence: $outputPath"
if ($hadFailure) {
    exit 1
}
