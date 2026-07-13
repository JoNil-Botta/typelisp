param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [Parameter(Mandatory = $true)][string]$Batch,
    [string]$OutputDir = "target/compile-batch-memory/windows",
    [string]$Target = "windows-x86_64",
    [string[]]$StdlibRoot = @("stdlib")
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "[compile-batch-memory] $Message"
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Fail "Windows process working-set/private-memory counters are required"
}

$compilerPath = (Resolve-Path -LiteralPath $Compiler -ErrorAction Stop).Path
$batchPath = (Resolve-Path -LiteralPath $Batch -ErrorAction Stop).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null

$stdoutPath = Join-Path $outputPath "stdout.log"
$stderrPath = Join-Path $outputPath "stderr.log"
$telemetryPath = Join-Path $outputPath "memory.tsv"
$mapPath = Join-Path $outputPath "entry-map.tsv"

$entries = @(
    Get-Content -LiteralPath $batchPath | Where-Object { $_.Trim().Length -gt 0 }
)
"entry_ordinal`tinput`n" | Set-Content -LiteralPath $mapPath -NoNewline -Encoding utf8
for ($ordinal = 0; $ordinal -lt $entries.Count; $ordinal++) {
    $separator = $entries[$ordinal].IndexOf('|')
    if ($separator -le 0) {
        Fail "malformed batch entry $ordinal; expected input|output"
    }
    "$ordinal`t$($entries[$ordinal].Substring(0, $separator))`n" |
        Add-Content -LiteralPath $mapPath -NoNewline -Encoding utf8
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $compilerPath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in @("compile", "--batch", $batchPath, "--target", $Target)) {
    $startInfo.ArgumentList.Add($argument)
}
foreach ($root in $StdlibRoot) {
    $startInfo.ArgumentList.Add("--stdlib-root")
    $startInfo.ArgumentList.Add([System.IO.Path]::GetFullPath($root))
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
    Fail "could not start compiler child"
}
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrLineTask = $process.StandardError.ReadLineAsync()
$stderrClosed = $false
$stderrWriter = [System.IO.StreamWriter]::new(
    $stderrPath,
    $false,
    [System.Text.UTF8Encoding]::new($false)
)

$markerSamples = [System.Collections.Generic.List[object]]::new()
$workingPeak = 0L
$privatePeak = 0L
$lastWorking = 0L
$lastPrivate = 0L
$started = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $process.HasExited -or -not $stderrClosed) {
    $working = $lastWorking
    $private = $lastPrivate
    if (-not $process.HasExited) {
        try {
            $process.Refresh()
            $working = [int64]$process.WorkingSet64
            $private = [int64]$process.PrivateMemorySize64
            if ($working -le 0 -or $private -le 0) {
                Fail "child process did not expose working-set/private-memory counters"
            }
            $workingPeak = [Math]::Max($workingPeak, $working)
            $privatePeak = [Math]::Max($privatePeak, $private)
            $lastWorking = $working
            $lastPrivate = $private
        } catch [System.InvalidOperationException] {
            # The process may exit between HasExited and Refresh.
        }
    }
    while (-not $stderrClosed -and $stderrLineTask.IsCompleted) {
        $line = $stderrLineTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            $stderrClosed = $true
        } else {
            $stderrWriter.WriteLine($line)
            if ($line -match '^compile-batch-profile\|[0-9]+\|') {
                $fields = $line.Split('|')
                if ($fields.Count -ne 7) {
                    Fail "invalid batch profile row: $line"
                }
                $markerSamples.Add([pscustomobject]@{
                    ordinal = $fields[1]
                    marker = $fields[2]
                    elapsed_ms = $fields[3]
                    alloc_delta = $fields[4]
                    live_delta = $fields[5]
                    peak_live_delta = $fields[6]
                    working_set_bytes = $working
                    working_set_peak_bytes = $workingPeak
                    private_bytes = $private
                    private_peak_bytes = $privatePeak
                })
                $workingPeak = $working
                $privatePeak = $private
            }
            $stderrLineTask = $process.StandardError.ReadLineAsync()
        }
    }
    Start-Sleep -Milliseconds 20
}
$process.WaitForExit()
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderrWriter.Dispose()
[System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
if ($process.ExitCode -ne 0) {
    Fail "compiler child exited $($process.ExitCode); see $stderrPath"
}
if ($markerSamples.Count -eq 0) {
    Fail "compiler emitted no batch profile markers; build it with --cfg compile-profile"
}

"entry_ordinal`tmarker`telapsed_ms`talloc_delta_bytes`tlive_delta_bytes`tpeak_live_delta_bytes`tworking_set_bytes`tworking_set_peak_bytes`tprivate_bytes`tprivate_peak_bytes`n" |
    Set-Content -LiteralPath $telemetryPath -NoNewline -Encoding utf8
foreach ($sample in $markerSamples) {
    "$($sample.ordinal)`t$($sample.marker)`t$($sample.elapsed_ms)`t$($sample.alloc_delta)`t$($sample.live_delta)`t$($sample.peak_live_delta)`t$($sample.working_set_bytes)`t$($sample.working_set_peak_bytes)`t$($sample.private_bytes)`t$($sample.private_peak_bytes)`n" |
        Add-Content -LiteralPath $telemetryPath -NoNewline -Encoding utf8
}

Write-Output "[compile-batch-memory] wrote $telemetryPath"
Write-Output "[compile-batch-memory] ordinal map $mapPath"
