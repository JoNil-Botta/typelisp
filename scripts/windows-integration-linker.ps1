<#
windows-integration-linker.ps1 - bounded native linker queue for the Windows
integration manifest.

The request file is a NUL-delimited UTF-8 field stream:

  tlwinlink1<NUL>
  label<NUL>linker<NUL>output<NUL>stdout<NUL>stderr<NUL>
  argument-count<NUL>argument...<NUL>

Each request owns its output and diagnostic paths. The scheduler rejects
duplicate labels or paths before launching any child. Results are written in
request order even though independent linker processes may finish out of order:

  label<TAB>ok|failed|launch-failed|missing-output<TAB>
  exit-code<TAB>error64<TAB>elapsed-ms<TAB>command64

Errors and rendered commands are base64-encoded UTF-8 so the tab-separated
result stream remains one physical line per request.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [Parameter(Mandatory = $true)]
    [string]$SummaryPath,

    [ValidateRange(1, 64)]
    [int]$Jobs = 4
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
        throw "Windows integration link request is missing its final NUL delimiter"
    }
    return $fields.ToArray()
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
        # fallback equivalent to CommandLineToArgvW so each request remains an
        # exact argv vector.
        $quoted = @()
        foreach ($argument in $Arguments) {
            $quoted += ConvertTo-WindowsCommandLineArgument $argument
        }
        $ProcessStartInfo.Arguments = $quoted -join ' '
    }
}

function Get-UnsignedExitCode {
    param([int]$ExitCode)

    return [System.BitConverter]::ToUInt32(
        [System.BitConverter]::GetBytes($ExitCode),
        0
    ).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Command {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $rendered = @(ConvertTo-WindowsCommandLineArgument $Executable)
    foreach ($argument in $Arguments) {
        $rendered += ConvertTo-WindowsCommandLineArgument $argument
    }
    return $rendered -join ' '
}

function Ensure-ParentDirectory {
    param([string]$Path)

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
}

$requestFields = @(Read-NullDelimitedUtf8Fields $RequestPath)
if ($requestFields.Count -eq 0 -or $requestFields[0] -ne "tlwinlink1") {
    throw "invalid Windows integration link request header"
}

$requests = New-Object System.Collections.Generic.List[object]
$labels = New-Object 'System.Collections.Generic.HashSet[string]' (
    [System.StringComparer]::OrdinalIgnoreCase
)
$artifactPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [System.StringComparer]::OrdinalIgnoreCase
)
$cursor = 1
while ($cursor -lt $requestFields.Count) {
    if (($requestFields.Count - $cursor) -lt 6) {
        throw "truncated Windows integration link request at field $cursor"
    }

    $label = $requestFields[$cursor]
    $linker = $requestFields[$cursor + 1]
    $output = $requestFields[$cursor + 2]
    $stdout = $requestFields[$cursor + 3]
    $stderr = $requestFields[$cursor + 4]
    $argumentCountText = $requestFields[$cursor + 5]
    $cursor += 6

    if ($label -notmatch '^[A-Za-z0-9_]+$') {
        throw "invalid Windows integration linker label: $label"
    }
    if (-not $labels.Add($label)) {
        throw "duplicate Windows integration linker label: $label"
    }
    if ([string]::IsNullOrEmpty($linker)) {
        throw "empty linker executable for Windows integration request '$label'"
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
        throw "invalid argument count for Windows integration link request '$label'"
    }
    if (($requestFields.Count - $cursor) -lt $argumentCount) {
        throw "truncated argument vector for Windows integration link request '$label'"
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    for ($argumentIndex = 0; $argumentIndex -lt $argumentCount; $argumentIndex += 1) {
        $arguments.Add($requestFields[$cursor + $argumentIndex])
    }
    $cursor += $argumentCount

    foreach ($artifactPath in @($output, $stdout, $stderr)) {
        if ([string]::IsNullOrEmpty($artifactPath)) {
            throw "empty artifact path for Windows integration link request '$label'"
        }
        $fullArtifactPath = [System.IO.Path]::GetFullPath($artifactPath)
        if (-not $artifactPaths.Add($fullArtifactPath)) {
            throw "shared artifact path in Windows integration link queue: $fullArtifactPath"
        }
    }

    $requests.Add([pscustomobject]@{
        Index = $requests.Count
        Label = $label
        Linker = $linker
        Output = [System.IO.Path]::GetFullPath($output)
        Stdout = [System.IO.Path]::GetFullPath($stdout)
        Stderr = [System.IO.Path]::GetFullPath($stderr)
        Arguments = $arguments.ToArray()
        Command = Format-Command $linker $arguments.ToArray()
    })
}

Ensure-ParentDirectory $ResultPath
Ensure-ParentDirectory $SummaryPath

$results = New-Object object[] $requests.Count
$active = New-Object System.Collections.ArrayList
$nextRequest = 0
$childStarts = 0
$launchFailures = 0
$failedProcesses = 0
$missingOutputs = 0
$peakConcurrency = 0
$childMilliseconds = [long]0
$schedulerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

while ($nextRequest -lt $requests.Count -or $active.Count -gt 0) {
    while ($nextRequest -lt $requests.Count -and $active.Count -lt $Jobs) {
        $request = $requests[$nextRequest]
        $nextRequest += 1
        $process = $null
        $stdoutFile = $null
        $stderrFile = $null
        $stopwatch = New-Object System.Diagnostics.Stopwatch

        try {
            Ensure-ParentDirectory $request.Output
            Ensure-ParentDirectory $request.Stdout
            Ensure-ParentDirectory $request.Stderr
            if ([System.IO.File]::Exists($request.Output)) {
                [System.IO.File]::Delete($request.Output)
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $request.Linker
            $psi.WorkingDirectory = (Get-Location).Path
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            Set-ProcessArguments $psi $request.Arguments

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $stdoutFile = [System.IO.File]::Open(
                $request.Stdout,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $stderrFile = [System.IO.File]::Open(
                $request.Stderr,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )

            $stopwatch.Start()
            if (-not $process.Start()) {
                throw "Process.Start returned false for '$($request.Linker)'"
            }
            $childStarts += 1
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
            [void]$active.Add([pscustomobject]@{
                Request = $request
                Process = $process
                StdoutFile = $stdoutFile
                StderrFile = $stderrFile
                StdoutTask = $stdoutTask
                StderrTask = $stderrTask
                Stopwatch = $stopwatch
            })
            $process = $null
            $stdoutFile = $null
            $stderrFile = $null
            if ($active.Count -gt $peakConcurrency) {
                $peakConcurrency = $active.Count
            }
        }
        catch {
            $stopwatch.Stop()
            $launchFailures += 1
            $results[$request.Index] = [pscustomobject]@{
                Label = $request.Label
                Status = "launch-failed"
                ExitCode = "-"
                ErrorMessage = $_.Exception.Message
                ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                Command = $request.Command
            }
            if ($null -ne $stdoutFile) {
                $stdoutFile.Dispose()
            }
            if ($null -ne $stderrFile) {
                $stderrFile.Dispose()
            }
            if ($null -ne $process) {
                $process.Dispose()
            }
        }
    }

    if ($active.Count -eq 0) {
        continue
    }

    $completedOne = $false
    for ($activeIndex = $active.Count - 1; $activeIndex -ge 0; $activeIndex -= 1) {
        $job = $active[$activeIndex]
        if (-not $job.Process.HasExited) {
            continue
        }

        $completedOne = $true
        $job.Process.WaitForExit()
        $job.StdoutTask.Wait()
        $job.StderrTask.Wait()
        $job.Stopwatch.Stop()
        $childMilliseconds += $job.Stopwatch.ElapsedMilliseconds
        $exitCode = Get-UnsignedExitCode $job.Process.ExitCode
        $status = "ok"
        $errorMessage = ""
        if ($job.Process.ExitCode -ne 0) {
            $status = "failed"
            $failedProcesses += 1
            $errorMessage = "linker exited with status $exitCode"
        }
        elseif (-not [System.IO.File]::Exists($job.Request.Output)) {
            $status = "missing-output"
            $missingOutputs += 1
            $errorMessage = "linker exited successfully without producing '$($job.Request.Output)'"
        }

        $results[$job.Request.Index] = [pscustomobject]@{
            Label = $job.Request.Label
            Status = $status
            ExitCode = $exitCode
            ErrorMessage = $errorMessage
            ElapsedMilliseconds = $job.Stopwatch.ElapsedMilliseconds
            Command = $job.Request.Command
        }
        $job.StdoutFile.Dispose()
        $job.StderrFile.Dispose()
        $job.Process.Dispose()
        $active.RemoveAt($activeIndex)
    }

    if (-not $completedOne) {
        Start-Sleep -Milliseconds 1
    }
}

$schedulerStopwatch.Stop()
$resultStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$resultWriter = New-Object System.IO.StreamWriter -ArgumentList @(
    $ResultPath,
    $false,
    $Utf8
)
$resultWriter.NewLine = "`n"
try {
    foreach ($result in $results) {
        $resultWriter.WriteLine((
            "{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f
                $result.Label,
                $result.Status,
                $result.ExitCode,
                $(Encode-QueueField $result.ErrorMessage),
                $result.ElapsedMilliseconds,
                $(Encode-QueueField $result.Command)
        ))
    }
}
finally {
    $resultWriter.Dispose()
}
$resultStopwatch.Stop()

[System.IO.File]::WriteAllText(
    $SummaryPath,
    (@(
        "requests=$($requests.Count)",
        "child_starts=$childStarts",
        "launch_failures=$launchFailures",
        "failed_processes=$failedProcesses",
        "missing_outputs=$missingOutputs",
        "jobs=$Jobs",
        "peak_concurrency=$peakConcurrency",
        "child_ms=$childMilliseconds",
        "result_process_ms=$($resultStopwatch.ElapsedMilliseconds)",
        "elapsed_ms=$($schedulerStopwatch.ElapsedMilliseconds)"
    ) -join "`n") + "`n",
    $Utf8
)

exit 0
