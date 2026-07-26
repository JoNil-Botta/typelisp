[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Work = Join-Path $Root "target\windows integration linker self test"
$Runner = Join-Path $PSScriptRoot "windows-integration-linker.ps1"
$Fixture = Join-Path $PSScriptRoot "windows-integration-linker-fixture.ps1"
$Request = Join-Path $Work "link requests.bin"
$Result = Join-Path $Work "link results.tsv"
$Summary = Join-Path $Work "link summary.txt"

if ([System.IO.Directory]::Exists($Work)) {
    [System.IO.Directory]::Delete($Work, $true)
}
[System.IO.Directory]::CreateDirectory($Work) | Out-Null

function Add-Field {
    param(
        [System.IO.Stream]$Stream,
        [string]$Value
    )

    $bytes = $Utf8.GetBytes($Value)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.WriteByte(0)
}

function Add-Request {
    param(
        [System.IO.Stream]$Stream,
        [string]$Label,
        [string]$Executable,
        [string]$Output,
        [string]$Stdout,
        [string]$Stderr,
        [string[]]$Arguments
    )

    Add-Field $Stream $Label
    Add-Field $Stream $Executable
    Add-Field $Stream $Output
    Add-Field $Stream $Stdout
    Add-Field $Stream $Stderr
    Add-Field $Stream $Arguments.Count.ToString(
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    foreach ($argument in $Arguments) {
        Add-Field $Stream $argument
    }
}

function Read-Summary {
    param([string]$Path)

    $values = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $Utf8)) {
        $separator = $line.IndexOf("=")
        if ($separator -lt 1) {
            throw "invalid linker summary line: $line"
        }
        $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
    return $values
}

$PowerShellExe = (Get-Process -Id $PID).Path
$RepeatedObject = "C:\objects with spaces\same input.obj"
$SecondObject = "D:\SDK path\second input.obj"
$successOutput = Join-Path $Work "successful output\program.exe"
$successLog = Join-Path $Work "successful output\arguments.txt"
$failureOutput = Join-Path $Work "failure output\program.exe"
$failureLog = Join-Path $Work "failure output\arguments.txt"
$missingOutput = Join-Path $Work "missing output\program.exe"
$missingLog = Join-Path $Work "missing output\arguments.txt"
$slowOutput = Join-Path $Work "second successful output\program.exe"
$slowLog = Join-Path $Work "second successful output\arguments.txt"

$stream = [System.IO.File]::Open(
    $Request,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
)
try {
    Add-Field $stream "tlwinlink1"
    Add-Request $stream "success_spaces" $PowerShellExe $successOutput `
        (Join-Path $Work "successful output\link.stdout") `
        (Join-Path $Work "successful output\link.stderr") `
        @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $Fixture,
            "-Mode",
            "success",
            "-OutputPath",
            $successOutput,
            "-ArgumentLogPath",
            $successLog,
            "-DelayMilliseconds",
            "350",
            $RepeatedObject,
            $SecondObject,
            $RepeatedObject
        )
    Add-Request $stream "failure_case" $PowerShellExe $failureOutput `
        (Join-Path $Work "failure output\link.stdout") `
        (Join-Path $Work "failure output\link.stderr") `
        @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $Fixture,
            "-Mode",
            "failure",
            "-OutputPath",
            $failureOutput,
            "-ArgumentLogPath",
            $failureLog
        )
    Add-Request $stream "missing_output" $PowerShellExe $missingOutput `
        (Join-Path $Work "missing output\link.stdout") `
        (Join-Path $Work "missing output\link.stderr") `
        @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $Fixture,
            "-Mode",
            "missing-output",
            "-OutputPath",
            $missingOutput,
            "-ArgumentLogPath",
            $missingLog
        )
    Add-Request $stream "second_success" $PowerShellExe $slowOutput `
        (Join-Path $Work "second successful output\link.stdout") `
        (Join-Path $Work "second successful output\link.stderr") `
        @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $Fixture,
            "-Mode",
            "success",
            "-OutputPath",
            $slowOutput,
            "-ArgumentLogPath",
            $slowLog,
            "-DelayMilliseconds",
            "350",
            "E:\ordered\last.obj"
        )
    Add-Request $stream "launch_failure" `
        (Join-Path $Work "missing executable\lld-link.exe") `
        (Join-Path $Work "launch failure\program.exe") `
        (Join-Path $Work "launch failure\link.stdout") `
        (Join-Path $Work "launch failure\link.stderr") `
        @("-NOLOGO")
}
finally {
    $stream.Dispose()
}

# A successful child that emits nothing must not inherit a stale executable
# from an earlier run.
[System.IO.Directory]::CreateDirectory(
    [System.IO.Path]::GetDirectoryName($missingOutput)
) | Out-Null
[System.IO.File]::WriteAllText($missingOutput, "stale", $Utf8)

& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Runner `
    -RequestPath $Request `
    -ResultPath $Result `
    -SummaryPath $Summary `
    -Jobs 2
if ($LASTEXITCODE -ne 0) {
    throw "Windows integration linker self-test runner exited $LASTEXITCODE"
}

$rows = @([System.IO.File]::ReadAllLines($Result, $Utf8))
if ($rows.Count -ne 5) {
    throw "expected 5 deterministic result rows, got $($rows.Count)"
}
$expectedLabels = @(
    "success_spaces",
    "failure_case",
    "missing_output",
    "second_success",
    "launch_failure"
)
$expectedStatuses = @("ok", "failed", "missing-output", "ok", "launch-failed")
$expectedExits = @("0", "23", "0", "0", "-")
for ($index = 0; $index -lt $rows.Count; $index += 1) {
    $fields = $rows[$index].Split("`t")
    if ($fields.Count -ne 6) {
        throw "result row $index has $($fields.Count) fields"
    }
    if ($fields[0] -ne $expectedLabels[$index]) {
        throw "result order mismatch at ${index}: $($fields[0])"
    }
    if ($fields[1] -ne $expectedStatuses[$index]) {
        throw "status mismatch for $($fields[0]): $($fields[1])"
    }
    if ($fields[2] -ne $expectedExits[$index]) {
        throw "exit mismatch for $($fields[0]): $($fields[2])"
    }
}

$successCommandFields = $rows[0].Split("`t")
$successCommand = $Utf8.GetString(
    [System.Convert]::FromBase64String($successCommandFields[5])
)
if ($successCommand -notmatch '"C:\\objects with spaces\\same input\.obj"') {
    throw "rendered command omitted quoting for the spaced repeated object"
}

if (-not [System.IO.File]::Exists($successOutput)) {
    throw "successful fake link did not produce its output"
}
if ([System.IO.File]::Exists($failureOutput)) {
    throw "failing fake link unexpectedly produced its output"
}
if ([System.IO.File]::Exists($missingOutput)) {
    throw "missing-output fake link unexpectedly produced its output"
}

$loggedArguments = @([System.IO.File]::ReadAllLines($successLog, $Utf8))
$expectedArguments = @($RepeatedObject, $SecondObject, $RepeatedObject)
if ($loggedArguments.Count -ne $expectedArguments.Count) {
    throw "ordered argument count changed: $($loggedArguments.Count)"
}
for ($index = 0; $index -lt $expectedArguments.Count; $index += 1) {
    if ($loggedArguments[$index] -ne $expectedArguments[$index]) {
        throw "ordered argument $index changed: '$($loggedArguments[$index])'"
    }
}

$failureStdout = [System.IO.File]::ReadAllText(
    (Join-Path $Work "failure output\link.stdout"),
    $Utf8
)
$failureStderr = [System.IO.File]::ReadAllText(
    (Join-Path $Work "failure output\link.stderr"),
    $Utf8
)
if ($failureStdout -notmatch "intentional failure stdout") {
    throw "failing fake link stdout was not captured"
}
if ($failureStderr -notmatch "intentional failure stderr") {
    throw "failing fake link stderr was not captured"
}

$summaryValues = Read-Summary $Summary
foreach ($expected in @{
    requests = "5"
    child_starts = "4"
    launch_failures = "1"
    failed_processes = "1"
    missing_outputs = "1"
    jobs = "2"
    peak_concurrency = "2"
}.GetEnumerator()) {
    if ($summaryValues[$expected.Key] -ne $expected.Value) {
        throw "summary $($expected.Key) was '$($summaryValues[$expected.Key])'"
    }
}
if ([long]$summaryValues["child_ms"] -le 0) {
    throw "summed child time was not recorded"
}
if ([long]$summaryValues["elapsed_ms"] -le 0) {
    throw "scheduler wall time was not recorded"
}

$malformed = Join-Path $Work "malformed requests.bin"
[System.IO.File]::WriteAllBytes($malformed, $Utf8.GetBytes("tlwinlink1"))
$malformedResult = Join-Path $Work "malformed results.tsv"
$malformedSummary = Join-Path $Work "malformed summary.txt"
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Runner `
    -RequestPath $malformed `
    -ResultPath $malformedResult `
    -SummaryPath $malformedSummary `
    -Jobs 1 *> (Join-Path $Work "malformed diagnostic.txt")
$malformedStatus = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
if ($malformedStatus -eq 0) {
    throw "malformed queue unexpectedly passed"
}
$malformedDiagnostic = [System.IO.File]::ReadAllText(
    (Join-Path $Work "malformed diagnostic.txt")
)
if ($malformedDiagnostic -notmatch "final NUL delimiter") {
    throw "malformed queue diagnostic did not identify its delimiter"
}

Write-Output "Windows integration linker queue self-test passed."
