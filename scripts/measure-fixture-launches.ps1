param(
    [Parameter(Mandatory=$true)][string]$Shell,
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string]$OutputPrefix,
    [int]$ExpectedFixtureLaunches = -1
)
$ErrorActionPreference = 'Stop'

# Reconstruct start-event ancestry by generation, including MSYS fork/exec
# intermediates. A reused PID replaces its prior node without changing it.
function Get-FixtureProcessTree {
    param([object[]]$Records, [UInt32]$RootId, [UInt32]$ObserverId)
    $nodes = @{}
    $nodes[$RootId] = [pscustomobject]@{ owned=$true; event_index=-1; depth=0; root_branch=-1; name='bash.exe' }
    $owned = [System.Collections.Generic.List[object]]::new()
    $rootSeen = $false
    $rootIndex = -1
    $eventIndex = 0
    foreach ($record in ($Records | Sort-Object { [UInt64]$_.ticks })) {
        $parentId = [UInt32]$record.parent
        $parentNode = $nodes[$parentId]
        $isRoot = [UInt32]$record.id -eq $RootId -and $parentId -eq $ObserverId -and -not $rootSeen
        $isOwned = $isRoot -or ($null -ne $parentNode -and $parentNode.owned)
        $depth = -1
        $branch = -1
        if ($isRoot) {
            $rootSeen = $true
            $rootIndex = $eventIndex
            $depth = 0
            $branch = $eventIndex
        } elseif ($isOwned) {
            $depth = $parentNode.depth + 1
            $branch = $parentNode.root_branch
            if ($parentNode.depth -eq 0) { $branch = $eventIndex }
        }
        $node = [pscustomobject]@{
            ticks=[UInt64]$record.ticks; id=[UInt32]$record.id; parent=$parentId; name=[string]$record.name
            event_index=$eventIndex; parent_event_index=$(if ($null -ne $parentNode) { $parentNode.event_index } else { -1 })
            parent_name=$(if ($null -ne $parentNode) { $parentNode.name } else { '' })
            owned=$isOwned; depth=$depth; root_branch=$branch
        }
        $nodes[[UInt32]$record.id] = $node
        if ($isOwned) { $owned.Add($node) }
        $eventIndex++
    }
    # The driver places each cmd sentinel in its own root branch. MSYS may
    # start an intermediate bash process before that branch's cmd.exe.
    $sentinelLeaves = @($owned | Where-Object {
        $_.name -ieq 'cmd.exe' -and ($_.depth -eq 1 -or ($_.depth -eq 2 -and $_.parent_name -ieq 'bash.exe'))
    })
    $sentinelBranches = @($sentinelLeaves | Select-Object -ExpandProperty root_branch -Unique)
    $sentinelStarts = @($owned | Where-Object { $_.root_branch -in $sentinelBranches })
    $fixtureStarts = @($owned | Where-Object { $_.event_index -ne $rootIndex -and $_.root_branch -notin $sentinelBranches })
    return [pscustomobject]@{
        Owned=$owned; RootSeen=$rootSeen; SentinelLeaves=$sentinelLeaves.Count; SentinelBranches=$sentinelBranches.Count
        SentinelStarts=$sentinelStarts.Count; FixtureStarts=$fixtureStarts
    }
}

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
    $nextDrainCheckAt = $null
    while ($true) {
        if ($process.HasExited -and $null -eq $exitAt) {
            $exitAt = $clock.ElapsedMilliseconds
            $nextDrainCheckAt = $exitAt + 1000
        }
        if ($null -ne $exitAt -and $clock.ElapsedMilliseconds -ge $nextDrainCheckAt) {
            # WMI delivery can lag process exit. Keep consuming until the
            # trailing sentinel branch arrives, with a bounded failure window.
            $draining = Get-FixtureProcessTree -Records $events.ToArray() -RootId $rootId -ObserverId $PID
            if ($draining.RootSeen -and $draining.SentinelLeaves -eq 2 -and $draining.SentinelBranches -eq 2) { break }
            if ($clock.ElapsedMilliseconds - $exitAt -ge 15000) { break }
            $nextDrainCheckAt = $clock.ElapsedMilliseconds + 1000
        }
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
    $drainMs = $clock.ElapsedMilliseconds - $exitAt
    $process.WaitForExit()
    $stdout.Result | Set-Content -LiteralPath "$OutputPrefix.stdout" -Encoding utf8
    $stderr.Result | Set-Content -LiteralPath "$OutputPrefix.stderr" -Encoding utf8
    $events | Export-Csv -LiteralPath "$OutputPrefix.all-processes.csv" -NoTypeInformation -Encoding utf8
    $tree = Get-FixtureProcessTree -Records $events.ToArray() -RootId $rootId -ObserverId $PID
    $owned = $tree.Owned
    $rootSeen = $tree.RootSeen
    $sentinels = $tree.SentinelLeaves
    $owned | Export-Csv -LiteralPath "$OutputPrefix.processes.csv" -NoTypeInformation -Encoding utf8
    $owned | Group-Object name | Sort-Object name | ForEach-Object {
        "{0}`t{1}" -f $_.Name, $_.Count
    } | Set-Content -LiteralPath "$OutputPrefix.counts.tsv" -Encoding utf8
    $launches = $tree.FixtureStarts.Count
    @(
        'schema_version=1', 'host=windows', 'observer=Win32_ProcessStartTrace',
        "shell_path=$Shell", "shell_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $Shell).Hash)",
        "powershell_version=$($PSVersionTable.PSVersion)", "os_version=$([Environment]::OSVersion.VersionString)",
        "processor_identifier=$env:PROCESSOR_IDENTIFIER", "runner_name=$env:RUNNER_NAME",
        "root_pid=$rootId", "observed_owned_process_starts=$($owned.Count)",
        "observer_pid=$PID", "excluded_sentinel_process_starts=$($tree.SentinelStarts)",
        "root_start_seen=$rootSeen", "expected_fixture_launches=$ExpectedFixtureLaunches",
        "fixture_launches=$launches", "sentinels=$sentinels",
        "event_drain_ms=$drainMs", 'event_drain_limit_ms=15000', "observed_process_starts=$($events.Count)",
        "wall_ms=$exitAt", "exit=$($process.ExitCode)",
        'scope=fixture descendants including fork/exec intermediates; excludes root wrapper and both sentinel branches',
        'timing=observer run; canonical same-run gate attribution is recorded separately'
    ) | Set-Content -LiteralPath "$OutputPrefix.report" -Encoding utf8
    if (-not $rootSeen -or $sentinels -ne 2 -or $tree.SentinelBranches -ne 2) {
        throw "Incomplete process-start observation: root=$rootSeen sentinels=$sentinels (expected 2)"
    }
    if ($ExpectedFixtureLaunches -ge 0 -and $launches -ne $ExpectedFixtureLaunches) {
        throw "Known process tree: observed $launches fixture launches, expected $ExpectedFixtureLaunches"
    }
    if ($ExpectedFixtureLaunches -ge 0) {
        $known = $tree.FixtureStarts
        if ($owned.Count -ne 7 -or $owned[0].depth -ne 0 -or $owned[0].name -ine 'bash.exe' -or
            $tree.SentinelStarts -ne 4 -or $known.Count -ne 2 -or
            $known[0].name -ine 'bash.exe' -or $known[0].depth -ne 1 -or
            $known[0].parent_event_index -ne $owned[0].event_index -or
            $known[1].name -ine 'sh.exe' -or $known[1].depth -ne 2 -or
            $known[1].parent_event_index -ne $known[0].event_index) {
            throw 'Known MSYS process tree did not preserve its fork/exec ancestry'
        }
    }
    if ($process.ExitCode -ne 0) { throw "Observed fixture failed with exit $($process.ExitCode)" }
    Write-Output "[fixture-processes] fixture_launches=$launches wall_ms=$exitAt evidence=$OutputPrefix"
} finally {
    $watcher.Stop()
    $watcher.Dispose()
    $process.Dispose()
}
