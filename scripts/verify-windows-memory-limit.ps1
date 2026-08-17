# verify-windows-memory-limit.ps1 - Job Object wrapper regression coverage.

$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    [Console]::Error.WriteLine('Windows memory-limit verification is unsupported on this host')
    exit 1
}

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Wrapper = Join-Path $Root 'scripts\run-bounded-process.ps1'
$Workdir = Join-Path $Root 'target\windows-memory-limit-verify'
if (Test-Path -LiteralPath $Workdir) {
    Remove-Item -LiteralPath $Workdir -Recurse -Force
}
New-Item -ItemType Directory -Path $Workdir | Out-Null

function Fail([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Read-Report([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "bounded wrapper did not write report: $Path"
    }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0])) {
            Fail "malformed or duplicate report row: $line"
        }
        $values[$parts[0]] = $parts[1]
    }
    $expected = @(
        'schema_version', 'host', 'backend', 'reason', 'exit_code',
        'limit_bytes', 'peak_memory_bytes', 'wall_ms')
    if ($values.Count -ne $expected.Count) {
        Fail "bounded report has $($values.Count) fields, expected $($expected.Count)"
    }
    foreach ($key in $expected) {
        if (-not $values.ContainsKey($key)) { Fail "bounded report is missing $key" }
    }
    if ($values.schema_version -ne '1' -or $values.host -ne 'windows' -or
        $values.backend -ne 'job-object') {
        Fail 'bounded report identity fields are incorrect'
    }
    return $values
}

function Invoke-BoundedCase(
    [string]$Name,
    [int]$LimitMiB,
    [int]$TimeoutSeconds,
    [string[]]$Command
) {
    $report = Join-Path $Workdir "$Name.report"
    $stdout = Join-Path $Workdir "$Name.stdout"
    $stderr = Join-Path $Workdir "$Name.stderr"
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Wrapper `
            -LimitMiB $LimitMiB `
            -TimeoutSeconds $TimeoutSeconds `
            -ReportPath $report `
            -WorkingDirectory $Root `
            -- @Command > $stdout 2> $stderr
        $status = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return [pscustomobject]@{
        Status = $status
        Report = Read-Report $report
        Stdout = $stdout
        Stderr = $stderr
    }
}

$success = Invoke-BoundedCase 'success' 512 30 @(
    'powershell.exe', '-NoProfile', '-Command',
    'Write-Output bounded-child-ok; exit 0')
if ($success.Status -ne 0 -or $success.Report.reason -ne 'success' -or
    $success.Report.exit_code -ne '0') {
    Fail "under-limit command failed: exit=$($success.Status) reason=$($success.Report.reason)"
}
if (-not (Select-String -LiteralPath $success.Stdout -SimpleMatch 'bounded-child-ok' -Quiet)) {
    Fail 'bounded child stdout was not inherited live by the wrapper'
}

$forward = Invoke-BoundedCase 'exit-forward' 512 30 @(
    'powershell.exe', '-NoProfile', '-Command', 'exit 23')
if ($forward.Status -ne 23 -or $forward.Report.reason -ne 'command-failure' -or
    $forward.Report.exit_code -ne '23') {
    Fail "command exit was not forwarded: exit=$($forward.Status) reason=$($forward.Report.reason)"
}

# The allocating process is a grandchild of the wrapper. Reaching the job-wide
# cap proves descendants inherit containment instead of escaping the limit.
$childMemoryScript = @'
$child = Start-Process powershell.exe -PassThru -ArgumentList @(
  '-NoProfile', '-Command',
  '$chunks=@(); while($true){$x=New-Object byte[] (8MB); for($i=0;$i-lt$x.Length;$i+=4096){$x[$i]=1}; $chunks+=$x}')
Wait-Process -Id $child.Id
exit $child.ExitCode
'@
$memory = Invoke-BoundedCase 'child-memory' 96 30 @(
    'powershell.exe', '-NoProfile', '-Command', $childMemoryScript)
if ($memory.Status -ne 137 -or $memory.Report.reason -ne 'memory-limit' -or
    [uint64]$memory.Report.peak_memory_bytes -lt 90000000) {
    Fail "child-process memory cap was not enforced: exit=$($memory.Status) reason=$($memory.Report.reason)"
}
if (-not (Select-String -LiteralPath $memory.Stderr -SimpleMatch 'memory limit exceeded' -Quiet)) {
    Fail 'memory-limit rejection did not emit its specific diagnostic'
}

# Timeout must terminate the whole job, including a sleeping descendant. The
# child writes its PID before the parent waits so cleanup can be checked after
# the wrapper returns.
$pidFile = Join-Path $Workdir 'timeout-child.pid'
$escapedPidFile = $pidFile.Replace("'", "''")
$timeoutScript = @"
`$child = Start-Process powershell.exe -PassThru -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30')
[IO.File]::WriteAllText('$escapedPidFile', [string]`$child.Id)
Wait-Process -Id `$child.Id
"@
$timeout = Invoke-BoundedCase 'timeout-cleanup' 512 1 @(
    'powershell.exe', '-NoProfile', '-Command', $timeoutScript)
if ($timeout.Status -ne 124 -or $timeout.Report.reason -ne 'timeout') {
    Fail "timeout status was not distinguished: exit=$($timeout.Status) reason=$($timeout.Report.reason)"
}
if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    Fail 'timeout fixture did not publish its child PID'
}
$childPid = [int](Get-Content -LiteralPath $pidFile -Raw)
Start-Sleep -Milliseconds 100
if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
    Fail "timed-out job left child process $childPid alive"
}

$wrapperFailure = Invoke-BoundedCase 'wrapper-failure' 512 30 @(
    (Join-Path $Workdir 'missing-command.exe'))
if ($wrapperFailure.Status -ne 2 -or
    $wrapperFailure.Report.reason -ne 'wrapper-failure') {
    Fail "wrapper/setup failure was not distinguished: exit=$($wrapperFailure.Status) reason=$($wrapperFailure.Report.reason)"
}

[Console]::Out.WriteLine('Windows memory-limit helper self-tests passed')
