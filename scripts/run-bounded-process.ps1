# run-bounded-process.ps1 - run a command under a hard Windows Job Object memory cap.
#
# Safety guard for potentially explosive compiler jobs: the command and every
# child process run inside a Job Object whose per-process and job-wide
# committed-memory limits are enforced by the OS, so a runaway job fails fast
# instead of triggering a machine-wide OOM. The job is configured to kill the
# whole tree if this wrapper dies. The guard changes no reported benchmark
# metric; the peak/cap report goes to stderr so wrapped stdout stays clean.
#
# Works under both Windows PowerShell 5.1 and pwsh 7+; the wrapped command's
# output streams live to the console (nothing is redirected or buffered).
#
# Usage:
#   powershell -ep Bypass -f scripts/run-bounded-process.ps1 -LimitMiB 4096 -- <command> [args...]
#   powershell -ep Bypass -f scripts/run-bounded-process.ps1 -LimitMiB 8192 -- target\stage0\typelisp.exe compile bench.tl -o bench.s
#
# Exit code: the wrapped command's exit code; 2 for wrapper/setup failures.

$ErrorActionPreference = 'Stop'

# Parse $args by hand: a param() block breaks on the `--` separator under
# Windows PowerShell 5.1 -File invocation, and wrapped-command arguments that
# start with '-' must never bind to wrapper parameters.
$LimitMiB = 4096
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
    } elseif ($token -eq '-WorkingDirectory' -and $i + 1 -lt $args.Count) {
        $WorkingDirectory = [string]$args[$i + 1]
        $i += 2
    } else {
        $Command = @($args | Select-Object -Skip $i)
        break
    }
}
if ($Command.Count -eq 0) {
    Write-Error 'no command given; usage: run-bounded-process.ps1 -LimitMiB 4096 -- <command> [args...]'
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

$exe = $Command[0]
$argLine = (@($Command | Select-Object -Skip 1) | ForEach-Object { Format-NativeArgument $_ }) -join ' '

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class TypeLispBoundedProcess
{
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

    const uint LimitProcessMemory = 0x100;
    const uint LimitJobMemory = 0x200;
    const uint LimitKillOnJobClose = 0x2000;
    const int ExtendedLimitClass = 9;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length, IntPtr returnedLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static int Run(string exe, string argLine, string cwd, ulong limitBytes)
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();

        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = LimitProcessMemory | LimitJobMemory | LimitKillOnJobClose;
        limits.ProcessMemoryLimit = new UIntPtr(limitBytes);
        limits.JobMemoryLimit = new UIntPtr(limitBytes);
        uint size = (uint)Marshal.SizeOf(typeof(ExtendedLimits));
        if (!SetInformationJobObject(job, ExtendedLimitClass, ref limits, size))
            throw new Win32Exception();

        var start = new ProcessStartInfo(exe, argLine);
        start.WorkingDirectory = cwd;
        start.UseShellExecute = false;
        var process = Process.Start(start);
        if (!AssignProcessToJobObject(job, process.Handle))
        {
            int error = Marshal.GetLastWin32Error();
            if (!process.HasExited)
            {
                try { process.Kill(); } catch (Exception) { }
                CloseHandle(job);
                throw new Win32Exception(error, "AssignProcessToJobObject failed; killed the unbounded process");
            }
            Console.Error.WriteLine("[bounded] warning: process exited before the cap could attach (error " + error + ")");
        }

        process.WaitForExit();
        int code = process.ExitCode;
        process.Dispose();

        var observed = new ExtendedLimits();
        if (QueryInformationJobObject(job, ExtendedLimitClass, ref observed, size, IntPtr.Zero))
        {
            ulong peak = observed.PeakJobMemoryUsed.ToUInt64();
            Console.Error.WriteLine("[bounded] peak job memory: " + (peak / (1024 * 1024)) + " MiB (cap " + (limitBytes / (1024 * 1024)) + " MiB)");
            if (code != 0 && peak >= limitBytes - limitBytes / 20)
                Console.Error.WriteLine("[bounded] exit " + code + " with peak at the cap: the memory limit was likely hit");
        }
        CloseHandle(job);
        return code;
    }
}
'@

try {
    $exitCode = [TypeLispBoundedProcess]::Run($exe, $argLine, $WorkingDirectory, [uint64]$LimitMiB * 1MB)
} catch {
    Write-Error ("[bounded] " + $_.Exception.Message)
    exit 2
}
exit $exitCode
