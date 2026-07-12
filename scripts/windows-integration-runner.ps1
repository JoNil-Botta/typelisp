<#
windows-integration-runner.ps1 - serial native-process runner for the Windows
integration manifest.

The request file is UTF-8, one tab-separated request per line:

  label<TAB>exe64<TAB>stdout64<TAB>stderr64<TAB>exit64<TAB>arg64,arg64,...

Each path and argument is UTF-8 base64 encoded so the queue does not depend on
shell quoting or path punctuation. Empty arguments use `~`; an empty argument
vector uses `-`. The result file is UTF-8 tab-separated:

  label<TAB>ok|launch-failed<TAB>exit-code<TAB>error64<TAB>elapsed-ms

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
    [string]$SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Decode-QueueField {
    param([string]$Value)

    return $Utf8.GetString([System.Convert]::FromBase64String($Value))
}

function Encode-QueueField {
    param([string]$Value)

    return [System.Convert]::ToBase64String($Utf8.GetBytes($Value))
}

function Decode-QueueArguments {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value) -or $Value -eq "-") {
        return @()
    }

    $decoded = @()
    foreach ($part in $Value.Split(',')) {
        if ($part -eq "~") {
            $decoded += ""
        }
        else {
            $decoded += Decode-QueueField $part
        }
    }
    return $decoded
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
$summaryDirectory = [System.IO.Path]::GetDirectoryName($SummaryPath)
if (-not [string]::IsNullOrEmpty($summaryDirectory)) {
    [System.IO.Directory]::CreateDirectory($summaryDirectory) | Out-Null
}

$requestLines = [System.IO.File]::ReadAllLines($RequestPath, $Utf8)
$resultWriter = New-Object System.IO.StreamWriter -ArgumentList @(
    $ResultPath,
    $false,
    $Utf8
)
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$requestCount = 0
$childStarts = 0
$launchFailures = 0

try {
    foreach ($line in $requestLines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $fields = $line.Split([char]9)
        if ($fields.Count -ne 6) {
            throw "invalid Windows integration runner request (expected 6 fields): $line"
        }

        $label = $fields[0]
        if ($label -notmatch '^[A-Za-z0-9_]+$') {
            throw "invalid Windows integration runner label: $label"
        }

        $exe = Decode-QueueField $fields[1]
        $stdout = Decode-QueueField $fields[2]
        $stderr = Decode-QueueField $fields[3]
        $exitFile = Decode-QueueField $fields[4]
        $arguments = @(Decode-QueueArguments $fields[5])
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
        $resultWriter.Flush()
    }
}
finally {
    $resultWriter.Dispose()
}

$totalStopwatch.Stop()
[System.IO.File]::WriteAllLines(
    $SummaryPath,
    @(
        "requests=$requestCount",
        "child_starts=$childStarts",
        "launch_failures=$launchFailures",
        "elapsed_ms=$($totalStopwatch.ElapsedMilliseconds)"
    ),
    $Utf8
)

exit 0
