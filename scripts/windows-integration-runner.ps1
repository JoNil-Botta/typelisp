<#
windows-integration-runner.ps1 - serial native-process runner for the Windows
integration manifest.

The request file is a NUL-delimited UTF-8 field stream:

  tlwinq2<NUL>
  label<NUL>exe<NUL>stdout<NUL>stderr<NUL>exit-file<NUL>
  expected-exit<NUL>expected-stdout<NUL>expected-stderr<NUL>
  argument-count<NUL>argument...<NUL>

NUL cannot occur in a Windows path or process argument, so Git Bash can append
each already-split value with its `printf` builtin without launching base64/tr
helpers or depending on shell quoting, whitespace, path punctuation, or
newlines. `expected-exit` is `-` for a request that should only be captured.

The result file is UTF-8 tab-separated:

  label<TAB>ok|launch-failed<TAB>exit-code<TAB>error64<TAB>elapsed-ms

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
    [string]$SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Encode-QueueField {
    param([string]$Value)

    return [System.Convert]::ToBase64String($Utf8.GetBytes($Value))
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

function Get-UnsignedExitCode {
    param([int]$ExitCode)

    return [System.BitConverter]::ToUInt32(
        [System.BitConverter]::GetBytes($ExitCode),
        0
    ).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

$requestDirectory = [System.IO.Path]::GetDirectoryName($RequestPath)
if (-not [string]::IsNullOrEmpty($requestDirectory)) {
    [System.IO.Directory]::CreateDirectory($requestDirectory) | Out-Null
}
$resultDirectory = [System.IO.Path]::GetDirectoryName($ResultPath)
if (-not [string]::IsNullOrEmpty($resultDirectory)) {
    [System.IO.Directory]::CreateDirectory($resultDirectory) | Out-Null
}
$assertionDirectory = [System.IO.Path]::GetDirectoryName($AssertionPath)
if (-not [string]::IsNullOrEmpty($assertionDirectory)) {
    [System.IO.Directory]::CreateDirectory($assertionDirectory) | Out-Null
}
$summaryDirectory = [System.IO.Path]::GetDirectoryName($SummaryPath)
if (-not [string]::IsNullOrEmpty($summaryDirectory)) {
    [System.IO.Directory]::CreateDirectory($summaryDirectory) | Out-Null
}

$requestFields = @(Read-NullDelimitedUtf8Fields $RequestPath)
if ($requestFields.Count -eq 0 -or $requestFields[0] -ne "tlwinq2") {
    throw "invalid Windows integration request header"
}
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
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$requestCount = 0
$childStarts = 0
$launchFailures = 0
$assertionCount = 0
$resultProcessStopwatch = New-Object System.Diagnostics.Stopwatch
$assertTotalStopwatch = New-Object System.Diagnostics.Stopwatch
$cursor = 1

try {
    while ($cursor -lt $requestFields.Count) {
        if (($requestFields.Count - $cursor) -lt 9) {
            throw "truncated Windows integration runner request at field $cursor"
        }

        $label = $requestFields[$cursor]
        $exe = $requestFields[$cursor + 1]
        $stdout = $requestFields[$cursor + 2]
        $stderr = $requestFields[$cursor + 3]
        $exitFile = $requestFields[$cursor + 4]
        $expectedExit = $requestFields[$cursor + 5]
        $expectedStdout = $requestFields[$cursor + 6]
        $expectedStderr = $requestFields[$cursor + 7]
        $argumentCountText = $requestFields[$cursor + 8]
        $cursor += 9
        if ($label -notmatch '^[A-Za-z0-9_]+$') {
            throw "invalid Windows integration runner label: $label"
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
        $arguments = @()
        for ($argumentIndex = 0; $argumentIndex -lt $argumentCount; $argumentIndex += 1) {
            $arguments += $requestFields[$cursor + $argumentIndex]
        }
        $cursor += $argumentCount
        $requestCount += 1

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = "ok"
        $exitCode = "-"
        $errorMessage = ""
        $process = $null
        $stdoutFile = $null
        $stderrFile = $null

        try {
            $stdoutDirectory = [System.IO.Path]::GetDirectoryName($stdout)
            if (-not [string]::IsNullOrEmpty($stdoutDirectory)) {
                [System.IO.Directory]::CreateDirectory($stdoutDirectory) | Out-Null
            }
            $stderrDirectory = [System.IO.Path]::GetDirectoryName($stderr)
            if (-not [string]::IsNullOrEmpty($stderrDirectory)) {
                [System.IO.Directory]::CreateDirectory($stderrDirectory) | Out-Null
            }
            $exitDirectory = [System.IO.Path]::GetDirectoryName($exitFile)
            if (-not [string]::IsNullOrEmpty($exitDirectory)) {
                [System.IO.Directory]::CreateDirectory($exitDirectory) | Out-Null
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.WorkingDirectory = (Get-Location).Path
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            Set-ProcessArguments $psi $arguments

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $stdoutFile = [System.IO.File]::Open(
                $stdout,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $stderrFile = [System.IO.File]::Open(
                $stderr,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )

            if (-not $process.Start()) {
                throw "Process.Start returned false for '$exe'"
            }
            $childStarts += 1
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
            $process.WaitForExit()
            $stdoutTask.Wait()
            $stderrTask.Wait()

            $exitCode = Get-UnsignedExitCode $process.ExitCode
            [System.IO.File]::WriteAllText($exitFile, $exitCode, $Utf8)
        }
        catch {
            $status = "launch-failed"
            $launchFailures += 1
            $errorMessage = $_.Exception.Message
        }
        finally {
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

        $stopwatch.Stop()
        $resultProcessStopwatch.Start()
        $encodedError = Encode-QueueField $errorMessage
        if ([string]::IsNullOrEmpty($encodedError)) {
            $encodedError = "~"
        }
        $resultWriter.WriteLine((
            "{0}`t{1}`t{2}`t{3}`t{4}" -f
                $label,
                $status,
                $exitCode,
                $encodedError,
                $stopwatch.ElapsedMilliseconds
        ))
        $resultProcessStopwatch.Stop()

        if ($expectedExit -ne "-") {
            $assertionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $assertTotalStopwatch.Start()
            $exitMatches = $status -eq "ok" -and $exitCode -eq $expectedExit
            $stdoutMatches = $false
            $stderrMatches = $false
            if ($status -eq "ok") {
                $expectedStdoutBytes = Get-NormalizedStreamBytes $expectedStdout
                $actualStdoutBytes = Get-NormalizedStreamBytes $stdout
                $expectedStderrBytes = Get-NormalizedStreamBytes $expectedStderr
                $actualStderrBytes = Get-NormalizedStreamBytes $stderr
                $stdoutMatches = Test-ByteArraysEqual `
                    ([byte[]]$expectedStdoutBytes) `
                    ([byte[]]$actualStdoutBytes)
                $stderrMatches = Test-ByteArraysEqual `
                    ([byte[]]$expectedStderrBytes) `
                    ([byte[]]$actualStderrBytes)
                if (-not $stdoutMatches) {
                    [System.IO.File]::WriteAllBytes(
                        "$expectedStdout.cmp",
                        [byte[]]$expectedStdoutBytes
                    )
                    [System.IO.File]::WriteAllBytes(
                        "$stdout.cmp",
                        [byte[]]$actualStdoutBytes
                    )
                }
                if (-not $stderrMatches) {
                    [System.IO.File]::WriteAllBytes(
                        "$expectedStderr.cmp",
                        [byte[]]$expectedStderrBytes
                    )
                    [System.IO.File]::WriteAllBytes(
                        "$stderr.cmp",
                        [byte[]]$actualStderrBytes
                    )
                }
            }
            $assertionStopwatch.Stop()
            $assertTotalStopwatch.Stop()
            $assertionCount += 1
            $assertionWriter.WriteLine((
                "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f
                    $label,
                    $status,
                    $exitCode,
                    $expectedExit,
                    $encodedError,
                    $stopwatch.ElapsedMilliseconds,
                    $assertionStopwatch.ElapsedMilliseconds,
                    $(if ($exitMatches) { 1 } else { 0 }),
                    $(if ($stdoutMatches) { 1 } else { 0 }),
                    $(if ($stderrMatches) { 1 } else { 0 })
            ))
        }
    }
}
finally {
    $resultWriter.Dispose()
    $assertionWriter.Dispose()
}

$totalStopwatch.Stop()
[System.IO.File]::WriteAllText(
    $SummaryPath,
    (@(
        "requests=$requestCount",
        "child_starts=$childStarts",
        "launch_failures=$launchFailures",
        "assertions=$assertionCount",
        "result_process_ms=$($resultProcessStopwatch.ElapsedMilliseconds)",
        "assert_ms=$($assertTotalStopwatch.ElapsedMilliseconds)",
        "elapsed_ms=$($totalStopwatch.ElapsedMilliseconds)"
    ) -join "`n") + "`n",
    $Utf8
)

exit 0
