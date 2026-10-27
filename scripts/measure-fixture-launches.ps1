param(
    [Parameter(Mandatory=$true)][string]$Shell,
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string]$OutputPrefix,
    [int]$ExpectedFixtureLaunches = -1
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Management
$watcher = [System.Management.ManagementEventWatcher]::new('SELECT * FROM Win32_ProcessStartTrace')
$watcher.Options.Timeout = [TimeSpan]::FromMilliseconds(100)
$events = [System.Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::new()
$process.StartInfo.FileName = $Shell
$process.StartInfo.Arguments = '--noprofile --norc "' + $Script.Replace('"', '\"') + '"'
$process.StartInfo.WorkingDirectory = $WorkingDirectory
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.StartInfo.EnvironmentVariables.Remove('BASH_ENV')
function Receive-ProcessStart {
    try { return $watcher.WaitForNextEvent() } catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        if ($exception -isnot [System.Management.ManagementException] -or
            $exception.ErrorCode -ne [System.Management.ManagementStatus]::Timedout) { throw }
        return $null
    }
}
try {
    # Establish the synchronous event subscription before the observed root
    # starts. Its enumerator remains subscribed after a timed-out first read.
    $initialEvent = Receive-ProcessStart
    if ($null -ne $initialEvent) { $initialEvent.Dispose() }
    if (-not $process.Start()) { throw 'Fixture process did not start' }
    $rootId = $process.Id
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $exitAt = $null
    while ($true) {
        if ($process.HasExited -and $null -eq $exitAt) { $exitAt = $clock.ElapsedMilliseconds }
        if ($null -ne $exitAt -and $clock.ElapsedMilliseconds - $exitAt -ge 1000) { break }
        if ($clock.ElapsedMilliseconds -gt 180000) {
            & taskkill.exe /PID $rootId /T /F | Out-Null
            throw 'Fixture launch observation exceeded 180 seconds'
        }
        $event = Receive-ProcessStart
        if ($null -ne $event) {
            $events.Add([pscustomobject]@{
                ticks = [UInt64]$event.Properties['TIME_CREATED'].Value
                id = [UInt32]$event.Properties['ProcessID'].Value
                parent = [UInt32]$event.Properties['ParentProcessID'].Value
                name = [string]$event.Properties['ProcessName'].Value
            })
            $event.Dispose()
        }
    }
    $process.WaitForExit()
    $stdout.Result | Set-Content -LiteralPath "$OutputPrefix.stdout" -Encoding utf8
    $stderr.Result | Set-Content -LiteralPath "$OutputPrefix.stderr" -Encoding utf8
    $owners = @{}
    $owners[[UInt32]$rootId] = $true
    $owned = [System.Collections.Generic.List[object]]::new()
    $rootSeen = $false
    foreach ($record in ($events | Sort-Object ticks)) {
        if ($record.id -eq $rootId -and -not $rootSeen) {
            $isOwned = $true
            $rootSeen = $true
        } else {
            $isOwned = $owners.ContainsKey($record.parent) -and $owners[$record.parent]
        }
        # Reassign on every start, so PID reuse does not retain an old owner.
        $owners[$record.id] = $isOwned
        if ($isOwned) { $owned.Add($record) }
    }
    $sentinels = @($owned | Where-Object { $_.name -ieq 'cmd.exe' }).Count
    $owned | Export-Csv -LiteralPath "$OutputPrefix.processes.csv" -NoTypeInformation -Encoding utf8
    $owned | Group-Object name | Sort-Object name | ForEach-Object {
        "{0}`t{1}" -f $_.Name, $_.Count
    } | Set-Content -LiteralPath "$OutputPrefix.counts.tsv" -Encoding utf8
    $launches = $owned.Count - 3 # observer child wrapper and two known sentinels
    @(
        'schema_version=1', 'host=windows', 'observer=Win32_ProcessStartTrace',
        "shell_path=$Shell", "shell_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $Shell).Hash)",
        "powershell_version=$($PSVersionTable.PSVersion)", "os_version=$([Environment]::OSVersion.VersionString)",
        "processor_identifier=$env:PROCESSOR_IDENTIFIER", "runner_name=$env:RUNNER_NAME",
        "root_pid=$rootId", "observed_owned_process_starts=$($owned.Count)",
        "root_start_seen=$rootSeen", "expected_fixture_launches=$ExpectedFixtureLaunches",
        "fixture_launches=$launches", "sentinels=$sentinels",
        "wall_ms=$exitAt", "exit=$($process.ExitCode)",
        'scope=fixture descendants; excludes root wrapper and two cmd sentinels',
        'timing=observer run; canonical same-run gate attribution is recorded separately'
    ) | Set-Content -LiteralPath "$OutputPrefix.report" -Encoding utf8
    if (-not $rootSeen -or $sentinels -ne 2) {
        throw "Incomplete process-start observation: root=$rootSeen sentinels=$sentinels (expected 2)"
    }
    if ($ExpectedFixtureLaunches -ge 0 -and $launches -ne $ExpectedFixtureLaunches) {
        throw "Known process tree: observed $launches fixture launches, expected $ExpectedFixtureLaunches"
    }
    if ($process.ExitCode -ne 0) { throw "Observed fixture failed with exit $($process.ExitCode)" }
    Write-Output "[fixture-processes] fixture_launches=$launches wall_ms=$exitAt evidence=$OutputPrefix"
} finally {
    $watcher.Stop()
    $watcher.Dispose()
    $process.Dispose()
}
