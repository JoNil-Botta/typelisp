param(
    [int]$Runs = $(if ($env:TYPELISP_BOOTSTRAP_BENCH_RUNS) { [int]$env:TYPELISP_BOOTSTRAP_BENCH_RUNS } else { 3 }),
    [string]$Compiler = $env:TYPELISP_BIN,
    [string]$Target = $env:TYPELISP_BOOTSTRAP_BENCH_TARGET,
    [string]$OptLevel = $env:TYPELISP_BOOTSTRAP_BENCH_OPT_LEVEL,
    [string]$WorkDir = $(Join-Path $PSScriptRoot "..\target\bootstrap-bench"),
    [string]$Source = "selfhost\compile.tl",
    [string]$StdlibRoot = "stdlib"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-WindowsHost {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:Root $Path))
}

function Require-Command([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "missing required tool: $Name"
    }
}

function Resolve-Tool([string]$Name) {
    if (Test-Path $Name) {
        return (Resolve-Path $Name).Path
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "tool does not exist or is not on PATH: $Name"
}

function Invoke-TimedCommand {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $FilePath @Arguments > $StdoutPath 2> $StderrPath
    $exitCode = $LASTEXITCODE
    $watch.Stop()

    if ($exitCode -ne 0) {
        $stderrText = ""
        if (Test-Path $StderrPath) {
            $stderrText = (Get-Content $StderrPath -Raw)
        }
        throw "$Label failed with exit code $exitCode`n$stderrText"
    }

    return [pscustomobject]@{
        Label = $Label
        Ms = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    }
}

function Invoke-AssembleAndLink {
    param(
        [string]$Prefix,
        [string]$AsmPath,
        [string]$ObjPath,
        [string]$BinPath,
        [string]$RunDir
    )

    if ($script:Target -eq "windows-x86_64" -or $script:Target -eq "windows_x86_64") {
        $assemble = Invoke-TimedCommand `
            "$Prefix assemble" `
            "clang" `
            @("--target=x86_64-pc-windows-msvc", "-c", $AsmPath, "-o", $ObjPath) `
            (Join-Path $RunDir "assemble.stdout") `
            (Join-Path $RunDir "assemble.stderr")
        $link = Invoke-TimedCommand `
            "$Prefix link" `
            "lld-link" `
            @(
                "/NOLOGO",
                $ObjPath,
                "/OUT:$BinPath",
                "/SUBSYSTEM:CONSOLE",
                "/DYNAMICBASE:NO",
                "/STACK:16777216",
                "msvcrt.lib",
                "legacy_stdio_definitions.lib",
                "kernel32.lib",
                "advapi32.lib",
                "ole32.lib",
                "oleaut32.lib"
            ) `
            (Join-Path $RunDir "link.stdout") `
            (Join-Path $RunDir "link.stderr")
    } elseif ($script:Target -eq "linux-x86_64" -or $script:Target -eq "linux_x86_64") {
        $assemble = Invoke-TimedCommand `
            "$Prefix assemble" `
            "as" `
            @($AsmPath, "-o", $ObjPath) `
            (Join-Path $RunDir "assemble.stdout") `
            (Join-Path $RunDir "assemble.stderr")
        $link = Invoke-TimedCommand `
            "$Prefix link" `
            "ld" `
            @($ObjPath, "-o", $BinPath, "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc") `
            (Join-Path $RunDir "link.stdout") `
            (Join-Path $RunDir "link.stderr")
    } else {
        throw "unsupported target '$script:Target'; expected linux-x86_64 or windows-x86_64"
    }

    return [pscustomobject]@{
        AssembleMs = $assemble.Ms
        LinkMs = $link.Ms
    }
}

function Invoke-CompilerBuild {
    param(
        [string]$CompilerKind,
        [string]$CompilerPath,
        [int]$Run,
        [string]$OutputStem
    )

    $runDir = Join-Path $script:SessionDir "$CompilerKind-$Run"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    $asmPath = Join-Path $runDir "$OutputStem.s"
    $objExt = if ($script:Target -like "windows*") { ".obj" } else { ".o" }
    $exeExt = if ($script:Target -like "windows*") { ".exe" } else { "" }
    $objPath = Join-Path $runDir "$OutputStem$objExt"
    $binPath = Join-Path $runDir "$OutputStem$exeExt"

    if ($CompilerKind -eq "stage0-rust") {
        $compileArgs = @(
            "compile",
            $script:SourcePath,
            "--target",
            $script:Target,
            "--stdlib-root",
            $script:StdlibPath,
            "-o",
            $asmPath
        )
    } else {
        $compileArgs = @(
            $script:SourcePath,
            "--target",
            $script:Target,
            "--stdlib-root",
            $script:StdlibPath,
            "-o",
            $asmPath
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($script:OptLevel)) {
        $compileArgs += @("--opt-level", $script:OptLevel)
    }

    $compile = Invoke-TimedCommand `
        "$CompilerKind compile run $Run" `
        $CompilerPath `
        $compileArgs `
        (Join-Path $runDir "compile.stdout") `
        (Join-Path $runDir "compile.stderr")

    $native = Invoke-AssembleAndLink $CompilerKind $asmPath $objPath $binPath $runDir
    $asmInfo = Get-Item $asmPath
    $binInfo = Get-Item $binPath

    return [pscustomobject]@{
        compiler = $CompilerKind
        run = $Run
        compile_ms = $compile.Ms
        assemble_ms = $native.AssembleMs
        link_ms = $native.LinkMs
        build_ms = [math]::Round($compile.Ms + $native.AssembleMs + $native.LinkMs, 3)
        asm_bytes = $asmInfo.Length
        exe_bytes = $binInfo.Length
        binary = $binInfo.FullName
    }
}

function Get-Stats {
    param([double[]]$Values)

    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    if ($count -eq 0) {
        throw "cannot summarize an empty value set"
    }
    $median = if (($count % 2) -eq 1) {
        $sorted[[int][math]::Floor($count / 2)]
    } else {
        ($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2.0
    }
    $sum = 0.0
    foreach ($value in $Values) {
        $sum += $value
    }

    return [pscustomobject]@{
        min_ms = [math]::Round($sorted[0], 3)
        median_ms = [math]::Round($median, 3)
        avg_ms = [math]::Round($sum / $count, 3)
    }
}

if ($Runs -lt 1) {
    throw "Runs must be greater than zero"
}

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $script:Root

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = if (Test-WindowsHost) { "windows-x86_64" } else { "linux-x86_64" }
}
$script:Target = $Target
$script:OptLevel = $OptLevel
$script:SourcePath = (Resolve-Path (Resolve-RepoPath $Source)).Path
$script:StdlibPath = (Resolve-Path (Resolve-RepoPath $StdlibRoot)).Path

if (-not [string]::IsNullOrWhiteSpace($script:OptLevel)) {
    if ($script:OptLevel -notin @("0", "1", "2", "3")) {
        throw "unsupported opt level '$script:OptLevel'; expected 0, 1, 2, or 3"
    }
}

if ($script:Target -eq "windows-x86_64" -or $script:Target -eq "windows_x86_64") {
    Require-Command "clang"
    Require-Command "lld-link"
} elseif ($script:Target -eq "linux-x86_64" -or $script:Target -eq "linux_x86_64") {
    Require-Command "as"
    Require-Command "ld"
} else {
    throw "unsupported target '$script:Target'; expected linux-x86_64 or windows-x86_64"
}

if ([string]::IsNullOrWhiteSpace($Compiler)) {
    Require-Command "cargo"
    Write-Host "Building release stage0 with Cargo (not timed)..."
    & cargo build --release --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build --release failed with exit code $LASTEXITCODE"
    }
    $Compiler = if (Test-WindowsHost) {
        Join-Path $script:Root "target\release\typelisp.exe"
    } else {
        Join-Path $script:Root "target/release/typelisp"
    }
}
$stage0Compiler = Resolve-Tool $Compiler

$workRoot = Resolve-RepoPath $WorkDir
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:SessionDir = Join-Path $workRoot $timestamp
New-Item -ItemType Directory -Force -Path $script:SessionDir | Out-Null

Write-Host "Bootstrap compiler benchmark"
Write-Host "source: $script:SourcePath"
Write-Host "target: $script:Target"
if (-not [string]::IsNullOrWhiteSpace($script:OptLevel)) {
    Write-Host "opt-level: $script:OptLevel"
}
Write-Host "stage0: $stage0Compiler"
Write-Host "runs: $Runs"
Write-Host ""

$rows = @()
for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "[stage0-rust] run $i/$Runs"
    $rows += Invoke-CompilerBuild "stage0-rust" $stage0Compiler $i "stage1"
}

$stage1Compiler = ($rows | Where-Object { $_.compiler -eq "stage0-rust" } | Select-Object -First 1).binary
Write-Host ""
Write-Host "stage1 seed: $stage1Compiler"
Write-Host "[stage1-bootstrap] building stage2 seed"
$stage2Seed = Invoke-CompilerBuild "stage1-bootstrap" $stage1Compiler 1 "stage2-seed"
$stage2Compiler = $stage2Seed.binary
Write-Host "stage2 seed: $stage2Compiler"

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "[stage2-selfhost] run $i/$Runs"
    $rows += Invoke-CompilerBuild "stage2-selfhost" $stage2Compiler $i "stage3"
}

$reportCsv = Join-Path $script:SessionDir "report.csv"
$rows | Export-Csv -NoTypeInformation -Path $reportCsv

$summary = foreach ($kind in @("stage0-rust", "stage2-selfhost")) {
    $kindRows = @($rows | Where-Object { $_.compiler -eq $kind })
    $compileStats = Get-Stats ([double[]]($kindRows | ForEach-Object { $_.compile_ms }))
    $buildStats = Get-Stats ([double[]]($kindRows | ForEach-Object { $_.build_ms }))
    [pscustomobject]@{
        compiler = $kind
        compile_min_s = [math]::Round($compileStats.min_ms / 1000.0, 3)
        compile_median_s = [math]::Round($compileStats.median_ms / 1000.0, 3)
        build_min_s = [math]::Round($buildStats.min_ms / 1000.0, 3)
        build_median_s = [math]::Round($buildStats.median_ms / 1000.0, 3)
        asm_bytes = ($kindRows | Select-Object -First 1).asm_bytes
        exe_bytes = ($kindRows | Select-Object -First 1).exe_bytes
    }
}

Write-Host ""
$summary | Format-Table -AutoSize

$stage0BuildMin = ($summary | Where-Object { $_.compiler -eq "stage0-rust" }).build_min_s
$selfhostBuildMin = ($summary | Where-Object { $_.compiler -eq "stage2-selfhost" }).build_min_s
if ($stage0BuildMin -gt 0) {
    $ratio = [math]::Round($selfhostBuildMin / $stage0BuildMin, 2)
    Write-Host "stage2/stage0 build min ratio: ${ratio}x"
}

Write-Host "artifacts: $script:SessionDir"
Write-Host "csv: $reportCsv"
