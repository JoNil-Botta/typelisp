<#
windows-integration-legacy-runner.ps1 - one-shot compatibility oracle used only
by verify-integration.sh's Windows queue differential test.

This intentionally retains the previous one-process launch shape. It is not
used by the manifest runner; keeping the oracle separate lets the integration
gate compare legacy and queued stdout/stderr/exit results for representative
already-linked binaries before the old per-case path is retired.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$exe = $args[0]
$stdout = $args[1]
$stderr = $args[2]
$codeFile = $args[3]
$runArgs = @()
if ($args.Length -gt 4) {
    $runArgs = $args[4..($args.Length - 1)]
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
if ($runArgs.Length -gt 0) {
    $psi.Arguments = ($runArgs -join " ")
}

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$stdoutFile = [System.IO.File]::Create($stdout)
$stderrFile = [System.IO.File]::Create($stderr)
try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()
    [System.IO.File]::WriteAllText($codeFile, [string]$process.ExitCode)
}
finally {
    $stdoutFile.Dispose()
    $stderrFile.Dispose()
    $process.Dispose()
}

exit 0
