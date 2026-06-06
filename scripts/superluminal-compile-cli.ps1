param(
    [string]$BenchmarkDir = $(Join-Path $PSScriptRoot "..\target\compile-cli-benchmark"),
    [string]$OutDir = $(Join-Path $PSScriptRoot "..\target\superluminal"),
    [int]$OptLevel = 2,
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

function Resolve-BenchmarkBash {
    $fallback = "C:\Program Files\Git\bin\bash.exe"
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }

    $commands = @(Get-Command "bash.exe" -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        $source = $command.Source
        if ($source -match "\\Windows\\System32\\bash\.exe$") {
            continue
        }

        try {
            $uname = & $source -lc "uname -s" 2>$null
            if (($LASTEXITCODE -eq 0) -and ($uname -match "^(MINGW|MSYS|CYGWIN)")) {
                return $source
            }
        } catch {
        }
    }

    throw "missing required Git Bash/MSYS bash.exe for Windows benchmark capture"
}

function Resolve-Clang {
    $command = Get-Command "clang.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $fallbacks = @(
        "C:\Program Files\LLVM\bin\clang.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\Llvm\x64\bin\clang.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\Llvm\x64\bin\clang.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin\clang.exe"
    )
    foreach ($fallback in $fallbacks) {
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            return $fallback
        }
    }
    throw "missing required tool: clang.exe"
}

function Resolve-Xperf {
    $command = Get-Command "xperf.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $fallback = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }
    return ""
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
    param(
        [int]$OptLevel
    )

    $bash = Resolve-BenchmarkBash
    Write-Host "[superluminal] running scripts/benchmark-compile-cli.sh"
    $oldOptLevels = ${env:TYPELISP_COMPILE_BENCH_OPT_LEVELS}
    try {
        $env:TYPELISP_COMPILE_BENCH_OPT_LEVELS = "$OptLevel"
        & $bash "scripts/benchmark-compile-cli.sh"
        if ($LASTEXITCODE -ne 0) {
            throw "benchmark-compile-cli.sh failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $oldOptLevels) {
            Remove-Item Env:TYPELISP_COMPILE_BENCH_OPT_LEVELS -ErrorAction SilentlyContinue
        } else {
            $env:TYPELISP_COMPILE_BENCH_OPT_LEVELS = $oldOptLevels
        }
    }
}

function Convert-ProfileSymbolName {
    param(
        [string]$CompactSymbol,
        [string]$SemanticSymbol
    )

    $compact = $CompactSymbol
    if ($compact.StartsWith("_tl_")) {
        $compact = $compact.Substring(4)
    }

    $semantic = $SemanticSymbol
    if ($semantic.StartsWith("_tl_")) {
        $semantic = $semantic.Substring(4)
    }
    $semantic = [regex]::Replace($semantic, "[^A-Za-z0-9_]", "_")

    return "_tlp_${compact}_${semantic}"
}

function Write-SemanticProfileAssembly {
    param(
        [string]$AsmPath,
        [string]$ProfileAsmPath,
        [string]$MapPath
    )

    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add("symbol`tprofile_symbol`tfunction")
    $out = New-Object System.Collections.Generic.List[string]
    $pendingCompact = ""
    $pendingSemantic = ""

    foreach ($line in [System.IO.File]::ReadLines($AsmPath)) {
        if ($line -match '^#t\s+(\S+)\s+(.+)$') {
            $pendingCompact = $Matches[1]
            $pendingSemantic = $Matches[2]
            $out.Add($line)
        } elseif (($pendingCompact.Length -gt 0) -and ($line -eq ".globl $pendingCompact")) {
            $profileSymbol = Convert-ProfileSymbolName $pendingCompact $pendingSemantic
            $rows.Add("$pendingCompact`t$profileSymbol`t$pendingSemantic")
            $out.Add(".globl $profileSymbol")
            $out.Add("${profileSymbol}:")
            $pendingCompact = ""
            $pendingSemantic = ""
        } else {
            $out.Add($line)
            if ($pendingCompact.Length -gt 0) {
                $pendingCompact = ""
                $pendingSemantic = ""
            }
        }
    }

    [System.IO.File]::WriteAllLines($ProfileAsmPath, $out, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllLines($MapPath, $rows, [System.Text.Encoding]::ASCII)
    Write-Host "[superluminal] wrote semantic profile assembly: $ProfileAsmPath"
    Write-Host "[superluminal] wrote symbol map: $MapPath ($($rows.Count - 1) functions)"
}

function Invoke-ProfileAssemble {
    param(
        [string]$AsmPath,
        [string]$ObjPath
    )

    $clang = Resolve-Clang
    Write-Host "[superluminal] assembling semantic-symbol stage2 with clang"
    & $clang --target=x86_64-pc-windows-msvc -c $AsmPath -o $ObjPath
    if ($LASTEXITCODE -ne 0) {
        throw "semantic-symbol assembly failed with exit code $LASTEXITCODE"
    }
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
        /ENTRY:_tl_start `
        /NODEFAULTLIB `
        /DYNAMICBASE:NO `
        "/STACK:$stackReserve" `
        "/LIBPATH:$(Join-Path $sdkLibRoot "um\x64")" `
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
        [int]$OptLevel,
        [int]$FrequencyHz
    )

    $sl = Resolve-Tool "SuperluminalCmd.exe" "C:\Program Files\Superluminal\Performance\SuperluminalCmd.exe"
    $symbolCache = Join-Path $OutDir "symbol-cache"
    New-Item -ItemType Directory -Force -Path $symbolCache | Out-Null

    $stdout = Join-Path $OutDir "stage2-profile.superluminal.stdout"
    $stderr = Join-Path $OutDir "stage2-profile.superluminal.stderr"
    $capture = Join-Path $OutDir "stage2-profile.etl"
    $stage3 = Join-Path $OutDir "stage3-super.s"
    Remove-Item -LiteralPath $stage3 -ErrorAction SilentlyContinue

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
        "--opt-level", "$OptLevel"
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
    if (-not (Test-Path -LiteralPath $stage3 -PathType Leaf)) {
        throw "captured compile did not produce stage3 assembly: $stage3"
    }
}

function Invoke-ElevatedCapture {
    param(
        [string]$BenchmarkDir,
        [string]$OutDir,
        [int]$OptLevel,
        [int]$FrequencyHz
    )

    if (Test-Administrator) {
        & $PSCommandPath `
            -BenchmarkDir $BenchmarkDir `
            -OutDir $OutDir `
            -OptLevel $OptLevel `
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
        " -OptLevel $OptLevel -FrequencyHz $FrequencyHz -SkipBenchmark -CaptureOnly"
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

function Read-ProfileSymbolMap {
    param(
        [string]$MapPath
    )

    $map = @{}
    if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
        return $map
    }

    foreach ($line in [System.IO.File]::ReadLines($MapPath)) {
        if ($line -eq "symbol`tprofile_symbol`tfunction") {
            continue
        }
        $parts = $line -split "`t", 3
        if ($parts.Count -eq 3) {
            $map[$parts[1]] = $parts[2]
        }
    }

    return $map
}

function Convert-GeneratedSymbolToName {
    param(
        [string]$Symbol
    )

    $name = $Symbol
    if ($name.StartsWith("_tl_")) {
        $name = $name.Substring(4)
    }

    $name = $name.Replace("_question", "?")
    $name = $name.Replace("_bang", "!")
    $name = $name.Replace("_plus", "+")
    $name = $name.Replace("_star", "*")
    $name = $name.Replace("_slash", "/")
    $name = $name.Replace("_eq", "=")
    $name = $name.Replace("_lt", "<")
    $name = $name.Replace("_gt", ">")
    $name = $name.Replace("_colon", ":")
    $name = [regex]::Replace($name, "_u([0-9a-fA-F]{2})", {
        param($match)
        [char][Convert]::ToInt32($match.Groups[1].Value, 16)
    })
    return $name
}

function Resolve-ProfileFunctionName {
    param(
        [string]$Symbol,
        [hashtable]$SymbolMap
    )

    if ($SymbolMap.ContainsKey($Symbol)) {
        return $SymbolMap[$Symbol]
    }
    if ($Symbol.StartsWith("_tl_")) {
        return Convert-GeneratedSymbolToName $Symbol
    }
    return $Symbol
}

function Write-HotFunctionReport {
    param(
        [string]$DetailCsvPath,
        [string]$MapPath,
        [string]$ReportPath
    )

    $symbolMap = Read-ProfileSymbolMap $MapPath
    $weights = @{}
    [int64]$stage2Weight = 0
    [int64]$stage2CodeWeight = 0

    foreach ($line in [System.IO.File]::ReadLines($DetailCsvPath)) {
        if ($line -match '^\s*stage2-profile\.exe\s+\(\s*\d+\),\s*([0-9]+),\s*[0-9.]+,\s*(.+)$') {
            $weight = [int64]$Matches[1]
            $moduleFunc = $Matches[2].Trim()
            $stage2Weight += $weight
            if ($moduleFunc -match '^stage2-profile\.exe!((_tlp_|_tl_).+)$') {
                $profileSymbol = $Matches[1]
                $stage2CodeWeight += $weight
                if ($weights.ContainsKey($profileSymbol)) {
                    $weights[$profileSymbol] = [int64]$weights[$profileSymbol] + $weight
                } else {
                    $weights[$profileSymbol] = $weight
                }
            }
        }
    }

    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add("weight`tpercent_user_code`tprofile_symbol`tfunction")

    $sorted = foreach ($key in $weights.Keys) {
        [pscustomobject]@{
            Symbol = $key
            Weight = [int64]$weights[$key]
        }
    }
    $sorted = $sorted | Sort-Object Weight -Descending

    foreach ($row in $sorted) {
        $percent = if ($stage2CodeWeight -gt 0) {
            "{0:N2}" -f (($row.Weight * 100.0) / $stage2CodeWeight)
        } else {
            "0.00"
        }
        $function = Resolve-ProfileFunctionName $row.Symbol $symbolMap
        $rows.Add("$($row.Weight)`t$percent`t$($row.Symbol)`t$function")
    }

    $rows.Add("")
    $rows.Add("stage2_total_weight`t$stage2Weight")
    $rows.Add("stage2_user_code_weight`t$stage2CodeWeight")
    [System.IO.File]::WriteAllLines($ReportPath, $rows, [System.Text.Encoding]::ASCII)
    Write-Host "[superluminal] wrote hot function report: $ReportPath"
}

function Convert-StackHtmlCellText([string]$Html) {
    $text = [regex]::Replace($Html, "<[^>]+>", "")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, "\s+", " ")
    return $text.Trim()
}

function Convert-SymbolToSafeFileName([string]$Symbol) {
    $safe = [regex]::Replace($Symbol, "[^A-Za-z0-9_.-]", "_")
    if ($safe.Length -gt 140) {
        return $safe.Substring(0, 140)
    }
    return $safe
}

function Get-StackRelatedSymbol([string]$Text) {
    $name = $Text
    $name = [regex]::Replace($name, "^(-->|<--)\s*", "")
    $bang = $name.LastIndexOf("!")
    if ($bang -ge 0) {
        return $name.Substring($bang + 1)
    }
    return $name
}

function Read-XperfStackRows {
    param(
        [string]$HtmlPath,
        [string]$ProfileSymbol,
        [string]$FunctionName,
        [string]$StackHtmlName,
        [hashtable]$SymbolMap
    )

    $rows = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
        return $rows
    }

    $html = [System.IO.File]::ReadAllText($HtmlPath)
    $targetPattern = "<tr><td><a id='#[^']+' href='#[^']+'>stage2-profile\.exe</a>!" +
        [regex]::Escape($ProfileSymbol) + "</td>"
    $targetBlock = ""
    foreach ($match in [regex]::Matches($html, "<tbody>.*?</tbody>", "Singleline")) {
        $block = $match.Value
        if ([regex]::IsMatch($block, $targetPattern)) {
            $targetBlock = $block
            break
        }
    }

    if ($targetBlock.Length -eq 0) {
        return $rows
    }

    foreach ($row in [regex]::Matches(
        $targetBlock,
        "<tr class='(fu|fd|fi)'><td>(.*?)</td><td>([0-9]+)</td><td>(.*?)</td><td>(.*?)</td>",
        "Singleline")) {
        $kind = $row.Groups[1].Value
        $relation = if ($kind -eq "fu") {
            "caller"
        } elseif ($kind -eq "fd") {
            "callee"
        } else {
            "self"
        }
        $text = Convert-StackHtmlCellText $row.Groups[2].Value
        $hits = $row.Groups[3].Value
        $totalPercent = Convert-StackHtmlCellText $row.Groups[4].Value
        $edgePercent = Convert-StackHtmlCellText $row.Groups[5].Value
        $relatedSymbol = Get-StackRelatedSymbol $text
        $relatedFunction = if ($relatedSymbol -eq "***itself***") {
            $FunctionName
        } else {
            Resolve-ProfileFunctionName $relatedSymbol $SymbolMap
        }
        $rows.Add(
            "$ProfileSymbol`t$FunctionName`t$relation`t$hits`t$totalPercent`t$edgePercent`t$relatedSymbol`t$relatedFunction`t$StackHtmlName")
    }

    return $rows
}

function Invoke-XperfHotStackExport {
    param(
        [string]$Xperf,
        [string]$EtlPath,
        [string]$OutDir,
        [string]$HotPath,
        [string]$MapPath,
        [int]$TopCount
    )

    if (-not (Test-Path -LiteralPath $HotPath -PathType Leaf)) {
        return
    }

    $symbolMap = Read-ProfileSymbolMap $MapPath
    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add("profile_symbol`tfunction`trelation`thits`ttotal_percent`tedge_percent`trelated_symbol`trelated_function`tstack_html")

    $hotRows = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadLines($HotPath)) {
        if (($line.Length -eq 0) -or ($line.StartsWith("weight`t"))) {
            continue
        }
        if ($line.StartsWith("stage2_")) {
            break
        }
        $parts = $line -split "`t", 4
        if ($parts.Count -eq 4) {
            $hotRows.Add([pscustomobject]@{
                Symbol = $parts[2]
                Function = $parts[3]
            })
        }
        if ($hotRows.Count -ge $TopCount) {
            break
        }
    }

    $oldSymbolPath = ${env:_NT_SYMBOL_PATH}
    $oldSymcachePath = ${env:_NT_SYMCACHE_PATH}
    try {
        $env:_NT_SYMBOL_PATH = $OutDir
        $env:_NT_SYMCACHE_PATH = Join-Path $OutDir "xperf-symcache"
        foreach ($hotRow in $hotRows) {
            $safe = Convert-SymbolToSafeFileName $hotRow.Symbol
            $htmlName = "stage2-profile.stack-$safe.html"
            $htmlPath = Join-Path $OutDir $htmlName
            $logPath = Join-Path $OutDir "stage2-profile.stack-$safe.log"
            $symbolRegex = [regex]::Escape($hotRow.Symbol)

            $oldErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $output = & $Xperf `
                    -i $EtlPath `
                    -symbols verbose `
                    -o $htmlPath `
                    -a stack `
                    -butterfly 1 `
                    -process stage2-profile.exe `
                    -symbol $symbolRegex 2>&1
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }

            $outputLines = foreach ($item in $output) {
                if ($item -is [System.Management.Automation.ErrorRecord]) {
                    $item.Exception.Message
                } else {
                    [string]$item
                }
            }
            [System.IO.File]::WriteAllLines($logPath, [string[]]$outputLines, [System.Text.Encoding]::ASCII)
            if (($exitCode -ne 0) -and (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf))) {
                continue
            }

            $stackRows = Read-XperfStackRows `
                $htmlPath `
                $hotRow.Symbol `
                $hotRow.Function `
                $htmlName `
                $symbolMap
            foreach ($stackRow in $stackRows) {
                $rows.Add($stackRow)
            }
        }
    } finally {
        if ($null -eq $oldSymbolPath) {
            Remove-Item Env:_NT_SYMBOL_PATH -ErrorAction SilentlyContinue
        } else {
            $env:_NT_SYMBOL_PATH = $oldSymbolPath
        }
        if ($null -eq $oldSymcachePath) {
            Remove-Item Env:_NT_SYMCACHE_PATH -ErrorAction SilentlyContinue
        } else {
            $env:_NT_SYMCACHE_PATH = $oldSymcachePath
        }
    }

    $report = Join-Path $OutDir "stage2-profile.hot-callers.tsv"
    [System.IO.File]::WriteAllLines($report, $rows, [System.Text.Encoding]::ASCII)
    Write-Host "[superluminal] wrote hot caller report: $report"
}

function Invoke-XperfProfileExport {
    param(
        [string]$OutDir,
        [string]$MapPath
    )

    $xperf = Resolve-Xperf
    if ($xperf.Length -eq 0) {
        Write-Warning "xperf.exe was not found; skipping symbolized WPT profile export"
        return
    }

    $etl = Join-Path $OutDir "stage2-profile.etl"
    $detail = Join-Path $OutDir "stage2-profile.xperf-detail.csv"
    $hot = Join-Path $OutDir "stage2-profile.hot-functions.tsv"
    $log = Join-Path $OutDir "stage2-profile.xperf.log"
    $symcache = Join-Path $OutDir "xperf-symcache"
    Require-File $etl "Superluminal ETL capture"
    New-Item -ItemType Directory -Force -Path $symcache | Out-Null

    $oldSymbolPath = ${env:_NT_SYMBOL_PATH}
    $oldSymcachePath = ${env:_NT_SYMCACHE_PATH}
    try {
        $env:_NT_SYMBOL_PATH = $OutDir
        $env:_NT_SYMCACHE_PATH = $symcache
        Write-Host "[superluminal] exporting symbolized sample detail with xperf"
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $xperf -i $etl -symbols verbose -o $detail -a profile -detail 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        $outputLines = foreach ($item in $output) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $item.Exception.Message
            } else {
                [string]$item
            }
        }
        $outputLines = $outputLines | Where-Object { $_.Length -gt 0 }
        [System.IO.File]::WriteAllLines($log, [string[]]$outputLines, [System.Text.Encoding]::ASCII)
        if (($exitCode -ne 0) -and (-not (Test-Path -LiteralPath $detail -PathType Leaf))) {
            throw "xperf profile export failed with exit code $exitCode"
        }
    } finally {
        if ($null -eq $oldSymbolPath) {
            Remove-Item Env:_NT_SYMBOL_PATH -ErrorAction SilentlyContinue
        } else {
            $env:_NT_SYMBOL_PATH = $oldSymbolPath
        }
        if ($null -eq $oldSymcachePath) {
            Remove-Item Env:_NT_SYMCACHE_PATH -ErrorAction SilentlyContinue
        } else {
            $env:_NT_SYMCACHE_PATH = $oldSymcachePath
        }
    }

    Write-HotFunctionReport $detail $MapPath $hot
    Invoke-XperfHotStackExport $xperf $etl $OutDir $hot $MapPath 8
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

function Resolve-BenchmarkOutputDir {
    param(
        [string]$BenchmarkDir,
        [int]$OptLevel
    )

    $directStage2 = Join-Path $BenchmarkDir "stage2.s"
    if (Test-Path -LiteralPath $directStage2 -PathType Leaf) {
        return $BenchmarkDir
    }

    $optDir = Join-Path $BenchmarkDir "opt$OptLevel"
    $optStage2 = Join-Path $optDir "stage2.s"
    if (Test-Path -LiteralPath $optStage2 -PathType Leaf) {
        return $optDir
    }

    return $BenchmarkDir
}

Require-WindowsHost
$script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BenchmarkDir = Resolve-FullPath $BenchmarkDir
$OutDir = Resolve-FullPath $OutDir

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$BenchmarkOutputDir = Resolve-BenchmarkOutputDir $BenchmarkDir $OptLevel
$stage2Asm = Join-Path $BenchmarkOutputDir "stage2.s"
$profileAsm = Join-Path $OutDir "stage2-profile.s"
$profileObj = Join-Path $OutDir "stage2-profile.obj"
$stage2Exe = Join-Path $OutDir "stage2-profile.exe"
$stage2Pdb = Join-Path $OutDir "stage2-profile.pdb"
$symbolMap = Join-Path $OutDir "stage2-symbol-map.tsv"
$capturedStage3 = Join-Path $OutDir "stage3-super.s"

if ($CaptureOnly) {
    Require-File $stage2Exe "debug-linked stage2 executable"
    Require-File $stage2Pdb "debug-linked stage2 PDB"
    Invoke-SuperluminalCapture $stage2Exe $OutDir $OptLevel $FrequencyHz
    exit 0
}

if (-not $SkipBenchmark) {
    Invoke-Benchmark $OptLevel
    $BenchmarkOutputDir = Resolve-BenchmarkOutputDir $BenchmarkDir $OptLevel
    $stage2Asm = Join-Path $BenchmarkOutputDir "stage2.s"
}

Require-File $stage2Asm "benchmark stage2 assembly"
Write-SemanticProfileAssembly $stage2Asm $profileAsm $symbolMap
Invoke-ProfileAssemble $profileAsm $profileObj
Invoke-DebugRelink $profileObj $stage2Exe $stage2Pdb

if (-not $SkipCapture) {
    Invoke-ElevatedCapture $BenchmarkDir $OutDir $OptLevel $FrequencyHz
    Assert-ProfileOutputMatchesBenchmark $stage2Asm $capturedStage3
    Invoke-XperfProfileExport $OutDir $symbolMap
}

Write-Host "[superluminal] outputs:"
Write-Host "  session:    $(Join-Path $OutDir "stage2-profile")"
Write-Host "  etl:        $(Join-Path $OutDir "stage2-profile.etl")"
Write-Host "  pdb:        $stage2Pdb"
Write-Host "  symbol map: $symbolMap"
Write-Host "  hot funcs:  $(Join-Path $OutDir "stage2-profile.hot-functions.tsv")"
Write-Host "  hot callers: $(Join-Path $OutDir "stage2-profile.hot-callers.tsv")"
