param(
    [string]$BenchmarkDir = $(Join-Path $PSScriptRoot "..\target\compile-cli-benchmark"),
    [string]$OutDir = $(Join-Path $PSScriptRoot "..\target\superluminal"),
    [int]$FrequencyHz = 8190,
    [switch]$SkipBenchmark,
    [switch]$SkipCapture,
    [switch]$CaptureOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:Root $Path))
}

function Require-WindowsHost {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "Superluminal profiling is only supported on Windows"
    }
}

function Require-File([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "missing $Description`: $Path"
    }
}

function Resolve-Tool([string]$Name, [string]$FallbackPath) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    if (Test-Path -LiteralPath $FallbackPath -PathType Leaf) {
        return $FallbackPath
    }
    throw "missing required tool: $Name"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-PowerShellString([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Find-MsvcToolsetRoot {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Community\VC\Tools\MSVC")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC")
    }

    $roots = @()
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $roots += Get-ChildItem -LiteralPath $candidate -Directory
        }
    }
    if ($roots.Count -eq 0) {
        throw "could not find an MSVC toolset under Visual Studio 2022"
    }
    return ($roots | Sort-Object Name -Descending | Select-Object -First 1).FullName
}

function Find-WindowsSdkLibRoot {
    $roots = @()
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Lib")
    }
    $roots += (Join-Path ${env:ProgramFiles} "Windows Kits\10\Lib")

    $versions = @()
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $versions += Get-ChildItem -LiteralPath $root -Directory | Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName "ucrt\x64")) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName "um\x64"))
            }
        }
    }
    if ($versions.Count -eq 0) {
        throw "could not find a Windows 10 SDK library directory"
    }
    return ($versions | Sort-Object Name -Descending | Select-Object -First 1).FullName
}

function Invoke-Benchmark {
    $bash = Resolve-Tool "bash.exe" "C:\Program Files\Git\bin\bash.exe"
    Write-Host "[superluminal] running scripts/benchmark-compile-cli.sh"
    & $bash "scripts/benchmark-compile-cli.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "benchmark-compile-cli.sh failed with exit code $LASTEXITCODE"
    }
}

function Write-SymbolMap {
    param(
        [string]$AsmPath,
        [string]$MapPath
    )

    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add("symbol`tfunction")
    foreach ($line in [System.IO.File]::ReadLines($AsmPath)) {
        if ($line -match '^#t\s+(\S+)\s+(.+)$') {
            $rows.Add("$($Matches[1])`t$($Matches[2])")
        }
    }
    [System.IO.File]::WriteAllLines($MapPath, $rows, [System.Text.Encoding]::ASCII)
    Write-Host "[superluminal] wrote symbol map: $MapPath ($($rows.Count - 1) functions)"
}

function Invoke-DebugRelink {
    param(
        [string]$ObjPath,
        [string]$ExePath,
        [string]$PdbPath
    )

    $msvcRoot = Find-MsvcToolsetRoot
    $sdkLibRoot = Find-WindowsSdkLibRoot
    $link = Join-Path $msvcRoot "bin\Hostx64\x64\link.exe"
    Require-File $link "MSVC link.exe"

    $stackReserve = if ($env:TYPELISP_WINDOWS_STACK_RESERVE) {
        [int64]$env:TYPELISP_WINDOWS_STACK_RESERVE
    } else {
        268435456
    }

    Write-Host "[superluminal] relinking stage2 with /DEBUG:FULL"
    & $link `
        /NOLOGO `
        $ObjPath `
        "/OUT:$ExePath" `
        "/PDB:$PdbPath" `
        /DEBUG:FULL `
        /INCREMENTAL:NO `
        /SUBSYSTEM:CONSOLE `
        /DYNAMICBASE:NO `
        "/STACK:$stackReserve" `
        "/LIBPATH:$(Join-Path $msvcRoot "lib\x64")" `
        "/LIBPATH:$(Join-Path $sdkLibRoot "ucrt\x64")" `
        "/LIBPATH:$(Join-Path $sdkLibRoot "um\x64")" `
        msvcrt.lib `
        legacy_stdio_definitions.lib `
        kernel32.lib `
        advapi32.lib `
        ole32.lib `
        oleaut32.lib
    if ($LASTEXITCODE -ne 0) {
        throw "debug relink failed with exit code $LASTEXITCODE"
    }
}

function Invoke-SuperluminalCapture {
    param(
        [string]$Stage2Exe,
        [string]$OutDir,
        [int]$FrequencyHz
    )

    $sl = Resolve-Tool "SuperluminalCmd.exe" "C:\Program Files\Superluminal\Performance\SuperluminalCmd.exe"
    $symbolCache = Join-Path $OutDir "symbol-cache"
    New-Item -ItemType Directory -Force -Path $symbolCache | Out-Null

    $stdout = Join-Path $OutDir "stage2-profile.superluminal.stdout"
    $stderr = Join-Path $OutDir "stage2-profile.superluminal.stderr"
    $capture = Join-Path $OutDir "stage2-profile.etl"
    $stage3 = Join-Path $OutDir "stage3-super.s"

    $args = @(
        "run", "windows",
        "--freq", "$FrequencyHz",
        "--no-cswitch-stacks",
        "--working-dir", $script:Root,
        "--capture-path", $capture,
        "--allow-overwrite",
        "--resolve",
        "--symbol-cache-dir", $symbolCache,
        "--symbol-location", $OutDir,
        "--use-new-pdb-parser",
        "--no-microsoft-symbol-server",
        "--no-nuget-symbol-server",
        $Stage2Exe,
        "compile", "selfhost/cli.tl",
        "-o", $stage3,
        "--target", "windows-x86_64",
        "--cfg", "windows",
        "--cfg", "target-windows",
        "--cfg", "os-windows",
        "--stdlib-root", "stdlib",
        "--stdlib-root", "selfhost",
        "--opt-level", "2"
    )

    Write-Host "[superluminal] capturing stage2 compile"
    & $sl @args > $stdout 2> $stderr
    if ($LASTEXITCODE -ne 0) {
        $text = ""
        if (Test-Path -LiteralPath $stderr) {
            $text = Get-Content -LiteralPath $stderr -Raw
        }
        throw "Superluminal capture failed with exit code $LASTEXITCODE`n$text"
    }
}

function Invoke-ElevatedCapture {
    param(
        [string]$BenchmarkDir,
        [string]$OutDir,
        [int]$FrequencyHz
    )

    if (Test-Administrator) {
        & $PSCommandPath `
            -BenchmarkDir $BenchmarkDir `
            -OutDir $OutDir `
            -FrequencyHz $FrequencyHz `
            -SkipBenchmark `
            -CaptureOnly
        if ($LASTEXITCODE -ne 0) {
            throw "capture child failed with exit code $LASTEXITCODE"
        }
        return
    }

    $command = "& " + (Quote-PowerShellString $PSCommandPath) +
        " -BenchmarkDir " + (Quote-PowerShellString $BenchmarkDir) +
        " -OutDir " + (Quote-PowerShellString $OutDir) +
        " -FrequencyHz $FrequencyHz -SkipBenchmark -CaptureOnly"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Write-Host "[superluminal] requesting UAC elevation for capture"
    $proc = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "elevated capture failed with exit code $($proc.ExitCode)"
    }
}

function Assert-ProfileOutputMatchesBenchmark {
    param(
        [string]$Stage2Asm,
        [string]$Stage3Asm
    )

    Require-File $Stage3Asm "captured stage3 assembly"
    $left = Get-FileHash -Algorithm SHA256 -LiteralPath $Stage2Asm
    $right = Get-FileHash -Algorithm SHA256 -LiteralPath $Stage3Asm
    if ($left.Hash -ne $right.Hash) {
        throw "captured stage3 assembly does not match benchmark stage2 assembly"
    }
    Write-Host "[superluminal] verified captured stage3 assembly hash matches stage2.s"
}

Require-WindowsHost
$script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BenchmarkDir = Resolve-FullPath $BenchmarkDir
$OutDir = Resolve-FullPath $OutDir

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stage2Obj = Join-Path $BenchmarkDir "stage2.obj"
$stage2Asm = Join-Path $BenchmarkDir "stage2.s"
$stage2Exe = Join-Path $OutDir "stage2-profile.exe"
$stage2Pdb = Join-Path $OutDir "stage2-profile.pdb"
$symbolMap = Join-Path $OutDir "stage2-symbol-map.tsv"
$capturedStage3 = Join-Path $OutDir "stage3-super.s"

if ($CaptureOnly) {
    Require-File $stage2Exe "debug-linked stage2 executable"
    Require-File $stage2Pdb "debug-linked stage2 PDB"
    Invoke-SuperluminalCapture $stage2Exe $OutDir $FrequencyHz
    exit 0
}

if (-not $SkipBenchmark) {
    Invoke-Benchmark
}

Require-File $stage2Obj "benchmark stage2 object"
Require-File $stage2Asm "benchmark stage2 assembly"
Invoke-DebugRelink $stage2Obj $stage2Exe $stage2Pdb
Write-SymbolMap $stage2Asm $symbolMap

if (-not $SkipCapture) {
    Invoke-ElevatedCapture $BenchmarkDir $OutDir $FrequencyHz
    Assert-ProfileOutputMatchesBenchmark $stage2Asm $capturedStage3
}

Write-Host "[superluminal] outputs:"
Write-Host "  session:    $(Join-Path $OutDir "stage2-profile")"
Write-Host "  etl:        $(Join-Path $OutDir "stage2-profile.etl")"
Write-Host "  pdb:        $stage2Pdb"
Write-Host "  symbol map: $symbolMap"
