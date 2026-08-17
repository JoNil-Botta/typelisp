# run-bounded-process.ps1 - run a command under a hard Windows Job Object cap.
#
# The command is created suspended, assigned to the capped Job Object, and only
# then resumed. This closes the old start/assign race: no child code can run
# unbounded when Job Object setup or assignment fails. The job is configured to
# kill the complete process tree if this wrapper exits.
#
# A stable key/value report is optional. Wrapped stdout/stderr remain live, so
# callers can preserve compiler diagnostics while separately recording cap,
# peak job memory, elapsed time, exit status, and the normalized result reason.
#
# Works under Windows PowerShell 5.1 and pwsh 7+.
#
# Usage:
#   powershell -ep Bypass -f scripts/run-bounded-process.ps1 `
#     -LimitMiB 8192 -TimeoutSeconds 900 -ReportPath report.txt -- `
#     target\stage0\typelisp.exe compile source.tl -o source.s
#
# Exit codes:
#   wrapped command status  command success/failure
#   124                     timeout (the complete job is terminated)
#   137                     probable Job Object memory-limit termination
#   2                       wrapper/setup/report failure

$ErrorActionPreference = 'Stop'

# Parse $args by hand: a param() block breaks on the `--` separator under
# Windows PowerShell 5.1 -File invocation, and wrapped-command arguments that
# start with '-' must never bind to wrapper parameters.
$LimitMiB = 4096
$TimeoutSeconds = 0
$ReportPath = ''
$WorkingDirectory = (Get-Location).Path
$Command = @()
$i = 0
while ($i -lt $args.Count) {
    $token = [string]$args[$i]
    if ($token -eq '--') {
        $Command = @($args | Select-Object -Skip ($i + 1))
        break
    } elseif ($token -eq '-LimitMiB' -and $i + 1 -lt $args.Count) {
        $LimitMiB = [int]$args[$i + 1]
        $i += 2
    } elseif ($token -eq '-TimeoutSeconds' -and $i + 1 -lt $args.Count) {
        $TimeoutSeconds = [int]$args[$i + 1]
        $i += 2
    } elseif ($token -eq '-ReportPath' -and $i + 1 -lt $args.Count) {
        $ReportPath = [string]$args[$i + 1]
        $i += 2
    } elseif ($token -eq '-WorkingDirectory' -and $i + 1 -lt $args.Count) {
        $WorkingDirectory = [string]$args[$i + 1]
        $i += 2
    } else {
        $Command = @($args | Select-Object -Skip $i)
        break
    }
}
if ($Command.Count -eq 0) {
    Write-Error 'no command given; usage: run-bounded-process.ps1 -LimitMiB 8192 [-TimeoutSeconds 900] [-ReportPath report.txt] -- <command> [args...]'
    exit 2
}
if ($LimitMiB -le 0) {
    Write-Error '[bounded] LimitMiB must be positive'
    exit 2
}
if ($TimeoutSeconds -lt 0) {
    Write-Error '[bounded] TimeoutSeconds must be zero (disabled) or positive'
    exit 2
}

# Quote arguments with the standard Windows rules so the command line survives
# Windows PowerShell 5.1, which lacks ProcessStartInfo.ArgumentList.
function Format-NativeArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Write-BoundedReport(
    [string]$Path,
    [string]$Reason,
    [int]$ExitCode,
    [uint64]$PeakBytes,
    [uint64]$LimitBytes,
    [int64]$WallMs
) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $absolute = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($absolute)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $lines = @(
        'schema_version=1'
        'host=windows'
        'backend=job-object'
        ('reason=' + $Reason)
        ('exit_code=' + $ExitCode)
        ('limit_bytes=' + $LimitBytes)
        ('peak_memory_bytes=' + $PeakBytes)
        ('wall_ms=' + $WallMs)
    )
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($absolute, (($lines -join "`n") + "`n"), $utf8)
}

$exe = [string]$Command[0]
if ([IO.Path]::IsPathRooted($exe)) {
    $exe = [IO.Path]::GetFullPath($exe)
} elseif (Test-Path -LiteralPath $exe -PathType Leaf) {
    $exe = [IO.Path]::GetFullPath($exe)
} else {
    $resolvedCommand = Get-Command $exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $exe = $resolvedCommand.Source
}
$Command[0] = $exe
$commandLine = (@($Command) | ForEach-Object { Format-NativeArgument ([string]$_) }) -join ' '
$limitBytes = [uint64]$LimitMiB * 1MB

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class TypeLispBoundedProcess
{
    public sealed class RunResult
    {
        public int ExitCode;
        public ulong PeakJobMemoryUsed;
        public long WallMs;
        public bool TimedOut;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimits
    {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo
    {
        public uint cb;
        public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize;
        public uint dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation
    {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    const uint LimitProcessMemory = 0x100;
    const uint LimitJobMemory = 0x200;
    const uint LimitKillOnJobClose = 0x2000;
    const int ExtendedLimitClass = 9;
    const uint CreateSuspended = 0x00000004;
    const uint StartfUseStdHandles = 0x00000100;
    const uint WaitObject0 = 0x00000000;
    const uint WaitTimeout = 0x00000102;
    const uint Infinite = 0xffffffff;
    const int StdInputHandle = -10, StdOutputHandle = -11, StdErrorHandle = -12;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length, IntPtr returnedLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(
        string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags, IntPtr environment,
        string currentDirectory, ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    static void ThrowLast(string operation)
    {
        throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }

    public static RunResult Run(
        string exe, string commandLine, string cwd,
        ulong limitBytes, int timeoutSeconds)
    {
        IntPtr job = IntPtr.Zero;
        var pi = new ProcessInformation();
        bool processCreated = false;
        var clock = Stopwatch.StartNew();
        try
        {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) ThrowLast("CreateJobObject");

            var limits = new ExtendedLimits();
            limits.BasicLimitInformation.LimitFlags =
                LimitProcessMemory | LimitJobMemory | LimitKillOnJobClose;
            limits.ProcessMemoryLimit = new UIntPtr(limitBytes);
            limits.JobMemoryLimit = new UIntPtr(limitBytes);
            uint limitSize = (uint)Marshal.SizeOf(typeof(ExtendedLimits));
            if (!SetInformationJobObject(job, ExtendedLimitClass, ref limits, limitSize))
                ThrowLast("SetInformationJobObject");

            var startup = new StartupInfo();
            startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.dwFlags = StartfUseStdHandles;
            startup.hStdInput = GetStdHandle(StdInputHandle);
            startup.hStdOutput = GetStdHandle(StdOutputHandle);
            startup.hStdError = GetStdHandle(StdErrorHandle);
            var mutableCommand = new StringBuilder(commandLine);
            if (!CreateProcess(
                exe, mutableCommand, IntPtr.Zero, IntPtr.Zero, true,
                CreateSuspended, IntPtr.Zero, cwd, ref startup, out pi))
                ThrowLast("CreateProcess");
            processCreated = true;

            // The child has executed no user code yet. Any assignment failure
            // is therefore fail-closed: terminate the suspended process before
            // reporting wrapper/setup failure.
            if (!AssignProcessToJobObject(job, pi.hProcess))
                ThrowLast("AssignProcessToJobObject");
            if (ResumeThread(pi.hThread) == 0xffffffff)
                ThrowLast("ResumeThread");

            uint waitMs = timeoutSeconds <= 0
                ? Infinite
                : checked((uint)Math.Min((long)timeoutSeconds * 1000L, uint.MaxValue - 1L));
            uint wait = WaitForSingleObject(pi.hProcess, waitMs);
            bool timedOut = wait == WaitTimeout;
            if (timedOut)
            {
                if (!TerminateJobObject(job, 124)) ThrowLast("TerminateJobObject");
                if (WaitForSingleObject(pi.hProcess, Infinite) != WaitObject0)
                    ThrowLast("WaitForSingleObject after timeout");
            }
            else if (wait != WaitObject0)
            {
                ThrowLast("WaitForSingleObject");
            }

            uint rawExit;
            if (!GetExitCodeProcess(pi.hProcess, out rawExit))
                ThrowLast("GetExitCodeProcess");

            var observed = new ExtendedLimits();
            ulong peak = 0;
            if (QueryInformationJobObject(
                job, ExtendedLimitClass, ref observed, limitSize, IntPtr.Zero))
                peak = observed.PeakJobMemoryUsed.ToUInt64();

            clock.Stop();
            return new RunResult {
                ExitCode = timedOut ? 124 : unchecked((int)rawExit),
                PeakJobMemoryUsed = peak,
                WallMs = clock.ElapsedMilliseconds,
                TimedOut = timedOut
            };
        }
        catch
        {
            if (processCreated && pi.hProcess != IntPtr.Zero)
            {
                if (job != IntPtr.Zero) TerminateJobObject(job, 2);
                TerminateProcess(pi.hProcess, 2);
                WaitForSingleObject(pi.hProcess, 5000);
            }
            throw;
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }
}
'@

try {
    $result = [TypeLispBoundedProcess]::Run(
        $exe,
        $commandLine,
        $WorkingDirectory,
        $limitBytes,
        $TimeoutSeconds)
    $reason = 'success'
    $exitCode = [int]$result.ExitCode
    if ($result.TimedOut) {
        $reason = 'timeout'
        $exitCode = 124
        [Console]::Error.WriteLine(
            ("[bounded] timeout after {0}s; terminated complete job" -f $TimeoutSeconds))
    } elseif ($exitCode -ne 0 -and
        $result.PeakJobMemoryUsed -ge ($limitBytes - [uint64]($limitBytes / 20))) {
        $reason = 'memory-limit'
        $exitCode = 137
        [Console]::Error.WriteLine(
            ("[bounded] memory limit exceeded: peak job memory {0} bytes at cap {1} bytes" -f $result.PeakJobMemoryUsed, $limitBytes))
    } elseif ($exitCode -ne 0) {
        $reason = 'command-failure'
    }
    Write-BoundedReport $ReportPath $reason $exitCode `
        $result.PeakJobMemoryUsed $limitBytes $result.WallMs
    [Console]::Error.WriteLine(
        ("[bounded] reason={0} exit={1} peak_job_bytes={2} cap_bytes={3} wall_ms={4}" -f `
            $reason, $exitCode, $result.PeakJobMemoryUsed, $limitBytes, $result.WallMs))
    exit $exitCode
} catch {
    try {
        Write-BoundedReport $ReportPath 'wrapper-failure' 2 0 $limitBytes 0
    } catch {
        [Console]::Error.WriteLine('[bounded] failed to write wrapper-failure report: ' + $_.Exception.Message)
    }
    [Console]::Error.WriteLine(
        "[bounded] wrapper/setup failure: " + $_.Exception.Message)
    exit 2
}
