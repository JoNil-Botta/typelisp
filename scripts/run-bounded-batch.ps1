# run-bounded-batch.ps1 - run independent chains of bounded commands in parallel
# under isolated Windows Job Objects from a single PowerShell process.
#
# Each phase runs in its own suspended-start Job Object with its own hard memory
# cap, timeout, stdout/stderr file redirection, and schema-v1 report identical
# to scripts/run-bounded-process.ps1. Compiling the Win32 helper once avoids
# hundreds of PowerShell + Add-Type startups while preserving every per-phase
# memory cap, peak measurement, timeout, and output invariant.
#
# Works under Windows PowerShell 5.1 and pwsh 7+.
#
# Request file format (UTF-8, NUL-delimited):
#   tlbb1<NUL>
#   unit-count<NUL>
#   For each unit:
#     phase-count<NUL>
#     For each phase:
#       phase-name<NUL>
#       limit-mib<NUL>
#       timeout-seconds<NUL>
#       expected-exit<NUL>
#       check-executable<NUL>
#       stdout-path<NUL>
#       stderr-path<NUL>
#       report-path<NUL>
#       working-dir<NUL>
#       exe-path<NUL>
#       arg-count<NUL>
#       arg0<NUL>...argN-1<NUL>

$ErrorActionPreference = 'Stop'

$RequestPath = ''
$Workers = 4
$i = 0
while ($i -lt $args.Count) {
    $token = [string]$args[$i]
    if ($token -eq '-RequestPath' -and $i + 1 -lt $args.Count) {
        $RequestPath = [string]$args[$i + 1]
        $i += 2
    } elseif ($token -eq '-Workers' -and $i + 1 -lt $args.Count) {
        $Workers = [int]$args[$i + 1]
        $i += 2
    } else {
        Write-Error "unknown argument: $token"
        exit 2
    }
}

if ([string]::IsNullOrWhiteSpace($RequestPath)) {
    Write-Error 'usage: run-bounded-batch.ps1 -RequestPath FILE [-Workers N]'
    exit 2
}
if ($Workers -le 0) {
    Write-Error '[bounded-batch] Workers must be positive'
    exit 2
}

$RequestFullPath = [IO.Path]::GetFullPath($RequestPath)
if (-not (Test-Path -LiteralPath $RequestFullPath -PathType Leaf)) {
    Write-Error "[bounded-batch] request file not found: $RequestFullPath"
    exit 2
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TypeLispBoundedBatch
{
    public sealed class PhaseSpec
    {
        public string Name;
        public ulong LimitBytes;
        public int TimeoutSeconds;
        public int ExpectedExit;
        public string CheckExecutable;
        public string StdoutPath;
        public string StderrPath;
        public string ReportPath;
        public string WorkingDirectory;
        public string Executable;
        public string[] Args;
    }

    public sealed class UnitSpec
    {
        public PhaseSpec[] Phases;
    }

    sealed class RunResult
    {
        public int ExitCode;
        public ulong PeakJobMemoryUsed;
        public long WallMs;
        public bool TimedOut;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes
    {
        public uint nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public uint cb;
        public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize;
        public uint dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation
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
    const uint GenericRead = 0x80000000;
    const uint GenericWrite = 0x40000000;
    const uint FileShareRead = 0x00000001;
    const uint FileShareWrite = 0x00000002;
    const uint CreateAlways = 2;
    const uint OpenExisting = 3;
    const uint FileAttributeNormal = 0x00000080;
    static readonly IntPtr InvalidHandleValue = new IntPtr(-1);
    static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
    static readonly object SpawnLock = new object();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(
        string fileName, uint desiredAccess, uint shareMode,
        ref SecurityAttributes securityAttributes, uint creationDisposition,
        uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, ref ExtendedLimits info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(
        IntPtr job, int infoClass, ref ExtendedLimits info, uint length,
        IntPtr returnedLength);

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
    static extern bool CloseHandle(IntPtr handle);

    static void ThrowLast(string operation)
    {
        throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }

    static string FormatNativeArgument(string value)
    {
        if (value.Length > 0)
        {
            bool needsQuotes = false;
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (char.IsWhiteSpace(c) || c == '"')
                {
                    needsQuotes = true;
                    break;
                }
            }
            if (!needsQuotes) return value;
        }
        var sb = new StringBuilder(value.Length + 4);
        sb.Append('"');
        int backslashes = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
            }
            else if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
            }
            else
            {
                if (backslashes > 0)
                {
                    sb.Append('\\', backslashes);
                    backslashes = 0;
                }
                sb.Append(c);
            }
        }
        if (backslashes > 0) sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    static string BuildCommandLine(string exe, string[] args)
    {
        var sb = new StringBuilder();
        sb.Append(FormatNativeArgument(exe));
        for (int i = 0; i < args.Length; i++)
        {
            sb.Append(' ');
            sb.Append(FormatNativeArgument(args[i]));
        }
        return sb.ToString();
    }

    static void EnsureParentDir(string path)
    {
        string parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }
    }

    static void WriteReport(
        string path, string reason, int exitCode,
        ulong peakBytes, ulong limitBytes, long wallMs)
    {
        EnsureParentDir(path);
        string content =
            "schema_version=1\n" +
            "host=windows\n" +
            "backend=job-object\n" +
            "reason=" + reason + "\n" +
            "exit_code=" + exitCode + "\n" +
            "limit_bytes=" + limitBytes + "\n" +
            "peak_memory_bytes=" + peakBytes + "\n" +
            "wall_ms=" + wallMs + "\n";
        File.WriteAllText(path, content, Utf8NoBom);
    }

    static RunResult ExecutePhase(PhaseSpec spec)
    {
        string exe = Path.GetFullPath(spec.Executable);
        string commandLine = BuildCommandLine(exe, spec.Args);
        string stdoutPath = Path.GetFullPath(spec.StdoutPath);
        string stderrPath = Path.GetFullPath(spec.StderrPath);
        string reportPath = Path.GetFullPath(spec.ReportPath);
        EnsureParentDir(stdoutPath);
        EnsureParentDir(stderrPath);
        EnsureParentDir(reportPath);
        if (File.Exists(reportPath)) File.Delete(reportPath);
        if (File.Exists(stdoutPath)) File.Delete(stdoutPath);
        if (File.Exists(stderrPath)) File.Delete(stderrPath);

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
            limits.ProcessMemoryLimit = new UIntPtr(spec.LimitBytes);
            limits.JobMemoryLimit = new UIntPtr(spec.LimitBytes);
            uint limitSize = (uint)Marshal.SizeOf(typeof(ExtendedLimits));
            if (!SetInformationJobObject(job, ExtendedLimitClass, ref limits, limitSize))
                ThrowLast("SetInformationJobObject");

            // Serialize only the brief inheritable-handle creation + suspended
            // process launch + parent handle close so no concurrent child can
            // inherit another thread's stdout/stderr capture handle.
            lock (SpawnLock)
            {
                IntPtr hIn = InvalidHandleValue;
                IntPtr hOut = InvalidHandleValue;
                IntPtr hErr = InvalidHandleValue;
                try
                {
                    var sa = new SecurityAttributes();
                    sa.nLength = (uint)Marshal.SizeOf(typeof(SecurityAttributes));
                    sa.bInheritHandle = true;

                    hIn = CreateFile(
                        "NUL", GenericRead, FileShareRead | FileShareWrite,
                        ref sa, OpenExisting, FileAttributeNormal, IntPtr.Zero);
                    if (hIn == InvalidHandleValue) ThrowLast("CreateFile(NUL)");

                    hOut = CreateFile(
                        stdoutPath, GenericWrite, FileShareRead | FileShareWrite,
                        ref sa, CreateAlways, FileAttributeNormal, IntPtr.Zero);
                    if (hOut == InvalidHandleValue) ThrowLast("CreateFile(stdout)");

                    hErr = CreateFile(
                        stderrPath, GenericWrite, FileShareRead | FileShareWrite,
                        ref sa, CreateAlways, FileAttributeNormal, IntPtr.Zero);
                    if (hErr == InvalidHandleValue) ThrowLast("CreateFile(stderr)");

                    var startup = new StartupInfo();
                    startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
                    startup.dwFlags = StartfUseStdHandles;
                    startup.hStdInput = hIn;
                    startup.hStdOutput = hOut;
                    startup.hStdError = hErr;

                    var mutableCommand = new StringBuilder(commandLine);
                    if (!CreateProcess(
                        exe, mutableCommand, IntPtr.Zero, IntPtr.Zero, true,
                        CreateSuspended, IntPtr.Zero, spec.WorkingDirectory,
                        ref startup, out pi))
                        ThrowLast("CreateProcess");
                    processCreated = true;
                }
                finally
                {
                    if (hIn != InvalidHandleValue) CloseHandle(hIn);
                    if (hOut != InvalidHandleValue) CloseHandle(hOut);
                    if (hErr != InvalidHandleValue) CloseHandle(hErr);
                }
            }

            if (!AssignProcessToJobObject(job, pi.hProcess))
                ThrowLast("AssignProcessToJobObject");
            if (ResumeThread(pi.hThread) == 0xffffffff)
                ThrowLast("ResumeThread");

            uint waitMs = spec.TimeoutSeconds <= 0
                ? Infinite
                : checked((uint)Math.Min((long)spec.TimeoutSeconds * 1000L, uint.MaxValue - 1L));
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

    static bool RunPhaseAndReport(PhaseSpec spec)
    {
        try
        {
            RunResult result = ExecutePhase(spec);
            string reason = "success";
            int exitCode = result.ExitCode;
            if (result.TimedOut)
            {
                reason = "timeout";
                exitCode = 124;
            }
            else if (exitCode != 0 &&
                result.PeakJobMemoryUsed >= (spec.LimitBytes - (spec.LimitBytes / 20UL)))
            {
                reason = "memory-limit";
                exitCode = 137;
            }
            else if (exitCode != 0)
            {
                reason = "command-failure";
            }
            WriteReport(
                spec.ReportPath, reason, exitCode,
                result.PeakJobMemoryUsed, spec.LimitBytes, result.WallMs);

            string expectedReason = spec.ExpectedExit == 0 ? "success" : "command-failure";
            if (exitCode != spec.ExpectedExit || reason != expectedReason) return false;
            var stderrInfo = new FileInfo(spec.StderrPath);
            if (stderrInfo.Exists && stderrInfo.Length > 0) return false;
            if (!string.IsNullOrEmpty(spec.CheckExecutable))
            {
                var exeInfo = new FileInfo(spec.CheckExecutable);
                if (!exeInfo.Exists || exeInfo.Length == 0) return false;
            }
            return true;
        }
        catch (Exception ex)
        {
            try
            {
                WriteReport(spec.ReportPath, "wrapper-failure", 2, 0, spec.LimitBytes, 0);
            }
            catch { }
            try
            {
                EnsureParentDir(spec.StderrPath);
                File.AppendAllText(
                    spec.StderrPath,
                    "[bounded-batch] wrapper/setup failure for " + spec.Name + ": " + ex.Message + "\n",
                    Utf8NoBom);
            }
            catch { }
            return false;
        }
    }

    static string[] ReadNullDelimitedFields(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        var fields = new List<string>();
        int start = 0;
        for (int i = 0; i < bytes.Length; i++)
        {
            if (bytes[i] == 0)
            {
                fields.Add(Utf8NoBom.GetString(bytes, start, i - start));
                start = i + 1;
            }
        }
        if (start != bytes.Length)
            throw new InvalidDataException("request file is missing its final NUL delimiter");
        return fields.ToArray();
    }

    public static UnitSpec[] ParseRequest(string path)
    {
        string[] fields = ReadNullDelimitedFields(path);
        int pos = 0;
        if (fields.Length < 2 || fields[pos++] != "tlbb1")
            throw new InvalidDataException("invalid bounded-batch header");
        int unitCount = int.Parse(fields[pos++]);
        var units = new UnitSpec[unitCount];
        for (int u = 0; u < unitCount; u++)
        {
            int phaseCount = int.Parse(fields[pos++]);
            var phases = new PhaseSpec[phaseCount];
            for (int p = 0; p < phaseCount; p++)
            {
                var spec = new PhaseSpec();
                spec.Name = fields[pos++];
                ulong limitMiB = ulong.Parse(fields[pos++]);
                if (limitMiB == 0) throw new InvalidDataException("limitMiB must be positive");
                spec.LimitBytes = limitMiB * 1024UL * 1024UL;
                spec.TimeoutSeconds = int.Parse(fields[pos++]);
                spec.ExpectedExit = int.Parse(fields[pos++]);
                spec.CheckExecutable = fields[pos++];
                spec.StdoutPath = fields[pos++];
                spec.StderrPath = fields[pos++];
                spec.ReportPath = fields[pos++];
                spec.WorkingDirectory = fields[pos++];
                spec.Executable = fields[pos++];
                int argCount = int.Parse(fields[pos++]);
                spec.Args = new string[argCount];
                for (int a = 0; a < argCount; a++) spec.Args[a] = fields[pos++];
                phases[p] = spec;
            }
            units[u] = new UnitSpec { Phases = phases };
        }
        if (pos != fields.Length)
            throw new InvalidDataException("unexpected trailing fields in bounded-batch request");
        return units;
    }

    public static int RunAll(string requestPath, int workers)
    {
        UnitSpec[] units = ParseRequest(requestPath);
        if (units.Length == 0) return 0;
        int workerCount = Math.Min(workers, units.Length);
        int nextIndex = -1;
        int failures = 0;
        var threads = new Thread[workerCount];
        for (int w = 0; w < workerCount; w++)
        {
            threads[w] = new Thread(() =>
            {
                while (true)
                {
                    int idx = Interlocked.Increment(ref nextIndex);
                    if (idx >= units.Length) break;
                    PhaseSpec[] phases = units[idx].Phases;
                    for (int p = 0; p < phases.Length; p++)
                    {
                        if (!RunPhaseAndReport(phases[p]))
                        {
                            Interlocked.Increment(ref failures);
                            break;
                        }
                    }
                }
            });
            threads[w].IsBackground = false;
            threads[w].Start();
        }
        for (int w = 0; w < workerCount; w++)
        {
            threads[w].Join();
        }
        return failures;
    }
}
'@

try {
    $failures = [TypeLispBoundedBatch]::RunAll($RequestFullPath, $Workers)
    if ($failures -gt 0) {
        [Console]::Error.WriteLine("[bounded-batch] $failures unit(s) reported failure; see phase reports")
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[bounded-batch] fatal wrapper error: " + $_.Exception.Message)
    exit 2
}
