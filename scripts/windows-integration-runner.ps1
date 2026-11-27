<#
windows-integration-runner.ps1 - bounded parallel native-process runner for the
Windows integration manifest.

The request file is a NUL-delimited UTF-8 field stream:

  tlwinq4<NUL>
  label<NUL>exe<NUL>stdout<NUL>stderr<NUL>exit-file<NUL>timeout-seconds<NUL>
  expected-exit<NUL>expected-stdout<NUL>expected-stderr<NUL>lock-group<NUL>
  argument-count<NUL>argument...<NUL>

NUL cannot occur in a Windows path or process argument, so Git Bash can append
each already-split value with its `printf` builtin (or awk) without launching
base64/tr helpers or depending on shell quoting, whitespace, path punctuation,
or newlines. `expected-exit` is `-` for a request that should only be captured.

`lock-group` controls concurrency isolation:
- empty or `-`: unconstrained parallel execution up to `-Jobs` (launched in LPT
  order by descending executable size so heavy `src/tests/*` cases start first).
- `serial`: runs exclusively after parallel work drains (used for runner
  self-tests such as the 1 s deadline check).
- any other token (for example `typelisp-fs`): at most one request carrying
  that token runs at a time, while unrelated parallel requests keep running.

A request that has not exited and closed its output streams `timeout-seconds`
after its start is a `timeout`: its process tree is killed, it gets no exit
code or exit file, and the runner moves on to remaining requests.

Results and assertions are always written in original request order even though
independent processes may finish out of order.

The result file is UTF-8 tab-separated:

  label<TAB>ok|launch-failed|timeout<TAB>exit-code<TAB>error64<TAB>elapsed-ms

The assertion file is UTF-8 tab-separated:

  label<TAB>status<TAB>exit-code<TAB>expected-exit<TAB>error64<TAB>run-ms<TAB>
  assert-ms<TAB>exit-match<TAB>stdout-match<TAB>stderr-match

Expected and actual streams are normalized and compared in-process. Their
normalized `.cmp` files are materialized on a mismatch so the shell harness
can print its existing unified diff without paying that I/O for passing cases.

The runner deliberately handles a launch failure as one result and continues
with later queued requests. That preserves per-case attribution without
turning one missing executable into a skipped tail of the manifest.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [Parameter(Mandatory = $true)]
    [string]$AssertionPath,

    [Parameter(Mandatory = $true)]
    [string]$SummaryPath,

    [ValidateRange(1, 64)]
    [int]$Jobs = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Encode-QueueField {
    param([string]$Value)

    $encoded = [System.Convert]::ToBase64String($Utf8.GetBytes($Value))
    if ([string]::IsNullOrEmpty($encoded)) {
        return "~"
    }
    return $encoded
}

function Read-NullDelimitedUtf8Fields {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $fields = New-Object System.Collections.Generic.List[string]
    $start = 0
    for ($index = 0; $index -lt $bytes.Length; $index += 1) {
        if ($bytes[$index] -eq 0) {
            $length = $index - $start
            $fields.Add($Utf8.GetString($bytes, $start, $length))
            $start = $index + 1
        }
    }
    if ($start -ne $bytes.Length) {
        throw "Windows integration request is missing its final NUL delimiter"
    }
    return $fields.ToArray()
}

function Get-NormalizedStreamBytes {
    param([string]$Path)

    $source = [System.IO.File]::ReadAllBytes($Path)
    $carriageReturns = 0
    foreach ($value in $source) {
        if ($value -eq 13) {
            $carriageReturns += 1
        }
    }
    if ($carriageReturns -eq 0) {
        return ,$source
    }

    $normalized = New-Object byte[] ($source.Length - $carriageReturns)
    $target = 0
    foreach ($value in $source) {
        if ($value -ne 13) {
            $normalized[$target] = $value
            $target += 1
        }
    }
    return ,$normalized
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index += 1) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function ConvertTo-WindowsCommandLineArgument {
    param([string]$Argument)

    if ($Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $out = New-Object System.Text.StringBuilder
    [void]$out.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $slashes += 1
        }
        elseif ($character -eq '"') {
            [void]$out.Append('\', ($slashes * 2) + 1)
            [void]$out.Append('"')
            $slashes = 0
        }
        else {
            if ($slashes -gt 0) {
                [void]$out.Append('\', $slashes)
                $slashes = 0
            }
            [void]$out.Append($character)
        }
    }
    if ($slashes -gt 0) {
        [void]$out.Append('\', $slashes * 2)
    }
    [void]$out.Append('"')
    return $out.ToString()
}

function Set-ProcessArguments {
    param(
        [System.Diagnostics.ProcessStartInfo]$ProcessStartInfo,
        [string[]]$Arguments
    )

    $argumentListProperty = $ProcessStartInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) {
            [void]$ProcessStartInfo.ArgumentList.Add($argument)
        }
    }
    else {
        # Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList. Keep its
        # fallback equivalent to CommandLineToArgvW so the request queue still
        # represents an exact argument vector on that host.
        $quoted = @()
        foreach ($argument in $Arguments) {
            $quoted += ConvertTo-WindowsCommandLineArgument $argument
        }
        $ProcessStartInfo.Arguments = $quoted -join ' '
    }
}

# taskkill /T walks the live parent chain from the case on Windows, so the case
# and every descendant still attached to it at the deadline are terminated.
# Returns whether the case process itself has exited.
function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $killStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $killStartInfo.FileName = "taskkill.exe"
        $killStartInfo.Arguments = "/T /F /PID " +
            $Process.Id.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $killStartInfo.UseShellExecute = $false
        $killStartInfo.CreateNoWindow = $true
        $killStartInfo.RedirectStandardOutput = $true
        $killStartInfo.RedirectStandardError = $true
        $killProcess = [System.Diagnostics.Process]::Start($killStartInfo)
        try {
            $killStderrTask = $killProcess.StandardError.ReadToEndAsync()
            [void]$killProcess.StandardOutput.ReadToEnd()
            [void]$killStderrTask.Result
            $killProcess.WaitForExit()
        }
        finally {
            $killProcess.Dispose()
        }
    }
    else {
        try {
            $Process.Kill($true)
        }
        catch {
            try {
                $Process.Kill()
            }
            catch {
            }
        }
    }
    return $Process.WaitForExit(10000)
}

function Get-UnsignedExitCode {
    param([int]$ExitCode)

    return [System.BitConverter]::ToUInt32(
        [System.BitConverter]::GetBytes($ExitCode),
        0
    ).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Ensure-ParentDirectory {
    param([string]$Path)

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
}

function Evaluate-RequestAssertion {
    param(
        [pscustomobject]$Request,
        [string]$Status,
        [string]$ExitCode,
        [string]$EncodedError,
        [long]$RunMilliseconds,
        [System.Diagnostics.Stopwatch]$AssertTotalStopwatch
    )

    if ($Request.ExpectedExit -eq "-") {
        return $null
    }

    $assertionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $AssertTotalStopwatch.Start()
    $exitMatches = $Status -eq "ok" -and $ExitCode -eq $Request.ExpectedExit
    $stdoutMatches = $false
    $stderrMatches = $false
    if ($Status -eq "ok") {
        $expectedStdoutBytes = Get-NormalizedStreamBytes $Request.ExpectedStdout
        $actualStdoutBytes = Get-NormalizedStreamBytes $Request.Stdout
        $expectedStderrBytes = Get-NormalizedStreamBytes $Request.ExpectedStderr
        $actualStderrBytes = Get-NormalizedStreamBytes $Request.Stderr
        $stdoutMatches = Test-ByteArraysEqual `
            ([byte[]]$expectedStdoutBytes) `
            ([byte[]]$actualStdoutBytes)
        $stderrMatches = Test-ByteArraysEqual `
            ([byte[]]$expectedStderrBytes) `
            ([byte[]]$actualStderrBytes)
        if (-not $stdoutMatches) {
            [System.IO.File]::WriteAllBytes(
                "$($Request.ExpectedStdout).cmp",
                [byte[]]$expectedStdoutBytes
            )
            [System.IO.File]::WriteAllBytes(
                "$($Request.Stdout).cmp",
                [byte[]]$actualStdoutBytes
            )
        }
        if (-not $stderrMatches) {
            [System.IO.File]::WriteAllBytes(
                "$($Request.ExpectedStderr).cmp",
                [byte[]]$expectedStderrBytes
            )
            [System.IO.File]::WriteAllBytes(
                "$($Request.Stderr).cmp",
                [byte[]]$actualStderrBytes
            )
        }
    }
    $assertionStopwatch.Stop()
    $AssertTotalStopwatch.Stop()
    return [pscustomobject]@{
        Label = $Request.Label
        Status = $Status
        ExitCode = $ExitCode
        ExpectedExit = $Request.ExpectedExit
        EncodedError = $EncodedError
        RunMilliseconds = $RunMilliseconds
        AssertMilliseconds = $assertionStopwatch.ElapsedMilliseconds
        ExitMatches = $exitMatches
        StdoutMatches = $stdoutMatches
        StderrMatches = $stderrMatches
    }
}

Ensure-ParentDirectory $RequestPath
Ensure-ParentDirectory $ResultPath
Ensure-ParentDirectory $AssertionPath
Ensure-ParentDirectory $SummaryPath

$requestFields = @(Read-NullDelimitedUtf8Fields $RequestPath)
if ($requestFields.Count -eq 0 -or $requestFields[0] -ne "tlwinq4") {
    throw "invalid Windows integration request header"
}

$requests = New-Object System.Collections.Generic.List[object]
$labels = New-Object 'System.Collections.Generic.HashSet[string]' (
    [System.StringComparer]::OrdinalIgnoreCase
)
$outputPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [System.StringComparer]::OrdinalIgnoreCase
)
$cursor = 1
while ($cursor -lt $requestFields.Count) {
    if (($requestFields.Count - $cursor) -lt 11) {
        throw "truncated Windows integration runner request at field $cursor"
    }

    $label = $requestFields[$cursor]
    $exe = $requestFields[$cursor + 1]
    $stdout = $requestFields[$cursor + 2]
    $stderr = $requestFields[$cursor + 3]
    $exitFile = $requestFields[$cursor + 4]
    $timeoutSecondsText = $requestFields[$cursor + 5]
    $expectedExit = $requestFields[$cursor + 6]
    $expectedStdout = $requestFields[$cursor + 7]
    $expectedStderr = $requestFields[$cursor + 8]
    $lockGroupRaw = $requestFields[$cursor + 9]
    $argumentCountText = $requestFields[$cursor + 10]
    $cursor += 11

    if ($label -notmatch '^[A-Za-z0-9_]+$') {
        throw "invalid Windows integration runner label: $label"
    }
    if (-not $labels.Add($label)) {
        throw "duplicate Windows integration runner label: $label"
    }
    $timeoutSeconds = 0
    if (
        -not [int]::TryParse(
            $timeoutSecondsText,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$timeoutSeconds
        ) -or
        $timeoutSeconds -lt 1 -or
        $timeoutSeconds -gt 86400
    ) {
        throw "invalid timeout for Windows integration request '$label'"
    }
    $argumentCount = 0
    if (
        -not [int]::TryParse(
            $argumentCountText,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$argumentCount
        ) -or
        $argumentCount -lt 0
    ) {
        throw "invalid argument count for Windows integration request '$label'"
    }
    if (($requestFields.Count - $cursor) -lt $argumentCount) {
        throw "truncated argument vector for Windows integration request '$label'"
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    for ($argumentIndex = 0; $argumentIndex -lt $argumentCount; $argumentIndex += 1) {
        $arguments.Add($requestFields[$cursor + $argumentIndex])
    }
    $cursor += $argumentCount

    foreach ($artifactPath in @($stdout, $stderr, $exitFile)) {
        if ([string]::IsNullOrEmpty($artifactPath)) {
            throw "empty output path for Windows integration request '$label'"
        }
        $fullArtifactPath = [System.IO.Path]::GetFullPath($artifactPath)
        if (-not $outputPaths.Add($fullArtifactPath)) {
            throw "shared output path in Windows integration runner queue: $fullArtifactPath"
        }
    }

    $lockGroup = ""
    if (-not [string]::IsNullOrEmpty($lockGroupRaw) -and $lockGroupRaw -ne "-") {
        $lockGroup = $lockGroupRaw
    }

    $exeBytes = [long]0
    if (-not [string]::IsNullOrEmpty($exe) -and [System.IO.File]::Exists($exe)) {
        $exeBytes = (New-Object System.IO.FileInfo $exe).Length
    }

    $requests.Add([pscustomobject]@{
        Index = $requests.Count
        Label = $label
        Exe = $exe
        Stdout = $stdout
        Stderr = $stderr
        ExitFile = $exitFile
        TimeoutSeconds = $timeoutSeconds
        TimeoutMilliseconds = [long]$timeoutSeconds * 1000
        ExpectedExit = $expectedExit
        ExpectedStdout = $expectedStdout
        ExpectedStderr = $expectedStderr
        LockGroup = $lockGroup
        ExeBytes = $exeBytes
        Arguments = $arguments.ToArray()
    })
}

$parallelRequests = New-Object System.Collections.Generic.List[object]
$serialRequests = New-Object System.Collections.Generic.List[object]
foreach ($request in $requests) {
    if ($request.LockGroup -eq "serial") {
        $serialRequests.Add($request)
    }
    else {
        $parallelRequests.Add($request)
    }
}

$pending = New-Object System.Collections.Generic.List[object]
if ($parallelRequests.Count -gt 0) {
    $orderedParallel = @(
        $parallelRequests | Sort-Object -Property `
            @{ Expression = { $_.ExeBytes }; Descending = $true }, `
            @{ Expression = { $_.Index }; Ascending = $true }
    )
    foreach ($request in $orderedParallel) {
        $pending.Add($request)
    }
}
foreach ($request in $serialRequests) {
    $pending.Add($request)
}

$results = New-Object object[] $requests.Count
$assertions = New-Object object[] $requests.Count
$active = New-Object System.Collections.ArrayList
$activeLockGroups = New-Object 'System.Collections.Generic.HashSet[string]' (
    [System.StringComparer]::Ordinal
)
$serialActive = $false
$workingDirectory = (Get-Location).Path

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$assertTotalStopwatch = New-Object System.Diagnostics.Stopwatch
$childStarts = 0
$launchFailures = 0
$timeouts = 0
$assertionCount = 0
$peakConcurrency = 0
$childMilliseconds = [long]0

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
    if (-not $serialActive -and $active.Count -lt $Jobs -and $pending.Count -gt 0) {
        $scanIndex = 0
        while ($scanIndex -lt $pending.Count -and $active.Count -lt $Jobs) {
            $request = $pending[$scanIndex]
            if ($request.LockGroup -eq "serial") {
                if ($active.Count -gt 0) {
                    # Serial requests sit after all parallel requests in $pending,
                    # so wait for active parallel work to drain before launching.
                    break
                }
            }
            elseif (
                -not [string]::IsNullOrEmpty($request.LockGroup) -and
                $activeLockGroups.Contains($request.LockGroup)
            ) {
                $scanIndex += 1
                continue
            }

            $pending.RemoveAt($scanIndex)
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $process = $null
            $stdoutFile = $null
            $stderrFile = $null

            try {
                Ensure-ParentDirectory $request.Stdout
                Ensure-ParentDirectory $request.Stderr
                Ensure-ParentDirectory $request.ExitFile
                if ([System.IO.File]::Exists($request.ExitFile)) {
                    [System.IO.File]::Delete($request.ExitFile)
                }

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $request.Exe
                $psi.WorkingDirectory = $workingDirectory
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                Set-ProcessArguments $psi $request.Arguments

                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $psi
                $stdoutFile = [System.IO.File]::Open(
                    $request.Stdout,
                    [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read
                )
                $stderrFile = [System.IO.File]::Open(
                    $request.Stderr,
                    [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read
                )

                if (-not $process.Start()) {
                    throw "Process.Start returned false for '$($request.Exe)'"
                }
                $childStarts += 1
                $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
                $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
                $streamTasks = [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)

                [void]$active.Add([pscustomobject]@{
                    Request = $request
                    Process = $process
                    StdoutFile = $stdoutFile
                    StderrFile = $stderrFile
                    StdoutTask = $stdoutTask
                    StderrTask = $stderrTask
                    StreamTasks = $streamTasks
                    Stopwatch = $stopwatch
                })
                $process = $null
                $stdoutFile = $null
                $stderrFile = $null

                if ($request.LockGroup -eq "serial") {
                    $serialActive = $true
                    if ($active.Count -gt $peakConcurrency) {
                        $peakConcurrency = $active.Count
                    }
                    break
                }
                elseif (-not [string]::IsNullOrEmpty($request.LockGroup)) {
                    [void]$activeLockGroups.Add($request.LockGroup)
                }
                if ($active.Count -gt $peakConcurrency) {
                    $peakConcurrency = $active.Count
                }
            }
            catch {
                $stopwatch.Stop()
                $launchFailures += 1
                if ($null -ne $stdoutFile) {
                    $stdoutFile.Dispose()
                }
                if ($null -ne $stderrFile) {
                    $stderrFile.Dispose()
                }
                if ($null -ne $process) {
                    $process.Dispose()
                }
                $encodedError = Encode-QueueField $_.Exception.Message
                $results[$request.Index] = [pscustomobject]@{
                    Label = $request.Label
                    Status = "launch-failed"
                    ExitCode = "-"
                    EncodedError = $encodedError
                    ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                }
                $assertionRecord = Evaluate-RequestAssertion `
                    $request "launch-failed" "-" $encodedError `
                    $stopwatch.ElapsedMilliseconds $assertTotalStopwatch
                if ($null -ne $assertionRecord) {
                    $assertions[$request.Index] = $assertionRecord
                    $assertionCount += 1
                }
            }
        }
    }

    if ($active.Count -eq 0) {
        continue
    }

    $completedOne = $false
    for ($activeIndex = $active.Count - 1; $activeIndex -ge 0; $activeIndex -= 1) {
        $job = $active[$activeIndex]
        $isFinished = (
            $job.Process.HasExited -and
            $job.StdoutTask.IsCompleted -and
            $job.StderrTask.IsCompleted
        )
        $isTimedOut = (
            -not $isFinished -and
            $job.Stopwatch.ElapsedMilliseconds -ge $job.Request.TimeoutMilliseconds
        )
        if (-not $isFinished -and -not $isTimedOut) {
            continue
        }

        $completedOne = $true
        $status = "ok"
        $exitCode = "-"
        $errorMessage = ""

        if ($isFinished) {
            $job.Process.WaitForExit()
            $job.StdoutTask.Wait()
            $job.StderrTask.Wait()
            $job.Stopwatch.Stop()
            $exitCode = Get-UnsignedExitCode $job.Process.ExitCode
            $job.StdoutFile.Dispose()
            $job.StderrFile.Dispose()
            $job.Process.Dispose()
            [System.IO.File]::WriteAllText($job.Request.ExitFile, $exitCode, $Utf8)
        }
        else {
            $status = "timeout"
            $timeouts += 1
            $errorMessage = "timeout after $($job.Request.TimeoutSeconds) s"
            if (-not (Stop-ProcessTree $job.Process)) {
                $errorMessage += "; the case survived its tree kill"
            }
            elseif (-not [System.Threading.Tasks.Task]::WaitAll($job.StreamTasks, 10000)) {
                $errorMessage += "; a descendant kept its output open after the tree kill"
            }
            $job.Stopwatch.Stop()
            $job.StdoutFile.Dispose()
            $job.StderrFile.Dispose()
            $job.Process.Dispose()
        }

        $elapsedMilliseconds = $job.Stopwatch.ElapsedMilliseconds
        $childMilliseconds += $elapsedMilliseconds
        $encodedError = Encode-QueueField $errorMessage
        $results[$job.Request.Index] = [pscustomobject]@{
            Label = $job.Request.Label
            Status = $status
            ExitCode = $exitCode
            EncodedError = $encodedError
            ElapsedMilliseconds = $elapsedMilliseconds
        }
        $assertionRecord = Evaluate-RequestAssertion `
            $job.Request $status $exitCode $encodedError `
            $elapsedMilliseconds $assertTotalStopwatch
        if ($null -ne $assertionRecord) {
            $assertions[$job.Request.Index] = $assertionRecord
            $assertionCount += 1
        }

        if ($job.Request.LockGroup -eq "serial") {
            $serialActive = $false
        }
        elseif (-not [string]::IsNullOrEmpty($job.Request.LockGroup)) {
            [void]$activeLockGroups.Remove($job.Request.LockGroup)
        }
        $active.RemoveAt($activeIndex)
    }

    if (-not $completedOne) {
        Start-Sleep -Milliseconds 1
    }
}

$totalStopwatch.Stop()
$resultProcessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$resultWriter = New-Object System.IO.StreamWriter -ArgumentList @(
    $ResultPath,
    $false,
    $Utf8
)
$resultWriter.NewLine = "`n"
$assertionWriter = New-Object System.IO.StreamWriter -ArgumentList @(
    $AssertionPath,
    $false,
    $Utf8
)
$assertionWriter.NewLine = "`n"
try {
    foreach ($result in $results) {
        $resultWriter.WriteLine((
            "{0}`t{1}`t{2}`t{3}`t{4}" -f
                $result.Label,
                $result.Status,
                $result.ExitCode,
                $result.EncodedError,
                $result.ElapsedMilliseconds
        ))
    }
    foreach ($assertion in $assertions) {
        if ($null -eq $assertion) {
            continue
        }
        $assertionWriter.WriteLine((
            "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f
                $assertion.Label,
                $assertion.Status,
                $assertion.ExitCode,
                $assertion.ExpectedExit,
                $assertion.EncodedError,
                $assertion.RunMilliseconds,
                $assertion.AssertMilliseconds,
                $(if ($assertion.ExitMatches) { 1 } else { 0 }),
                $(if ($assertion.StdoutMatches) { 1 } else { 0 }),
                $(if ($assertion.StderrMatches) { 1 } else { 0 })
        ))
    }
}
finally {
    $resultWriter.Dispose()
    $assertionWriter.Dispose()
}
$resultProcessStopwatch.Stop()

[System.IO.File]::WriteAllText(
    $SummaryPath,
    (@(
        "requests=$($requests.Count)",
        "child_starts=$childStarts",
        "launch_failures=$launchFailures",
        "timeouts=$timeouts",
        "assertions=$assertionCount",
        "jobs=$Jobs",
        "peak_concurrency=$peakConcurrency",
        "child_ms=$childMilliseconds",
        "result_process_ms=$($resultProcessStopwatch.ElapsedMilliseconds)",
        "assert_ms=$($assertTotalStopwatch.ElapsedMilliseconds)",
        "elapsed_ms=$($totalStopwatch.ElapsedMilliseconds)"
    ) -join "`n") + "`n",
    $Utf8
)

exit 0
