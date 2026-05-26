#!/usr/bin/env pwsh
param(
    [Parameter(Position = 0)]
    [string] $Tag,

    [Parameter(Position = 1)]
    [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $PSBoundParameters.ContainsKey("Tag")) {
    $Tag = if ($env:TYPELISP_STAGE0_TAG) { $env:TYPELISP_STAGE0_TAG } else { "stage0-latest" }
}
if (-not $PSBoundParameters.ContainsKey("OutputDir")) {
    $OutputDir = if ($env:TYPELISP_STAGE0_DIR) { $env:TYPELISP_STAGE0_DIR } else { "target/stage0" }
}
$Repo = if ($env:TYPELISP_STAGE0_REPO) { $env:TYPELISP_STAGE0_REPO } else { "JoNil-Botta/typelisp" }

if ([string]::IsNullOrWhiteSpace($Tag)) {
    throw "stage0 tag must not be empty"
}

$IsWindowsHost = ($env:OS -eq "Windows_NT") -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$IsLinuxHost = ((Get-Variable IsLinux -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

if ($IsWindowsHost) {
    $Asset = "typelisp-stage0-windows.exe"
    $Output = "typelisp.exe"
} elseif ($IsLinuxHost) {
    $Asset = "typelisp-stage0-linux"
    $Output = "typelisp"
} else {
    throw "stage0 fetch is unsupported on this host"
}

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$OutputDirPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $Root $OutputDir
}

$OutputDirItem = New-Item -ItemType Directory -Path $OutputDirPath -Force -Confirm:$false
$OutputDirFull = $OutputDirItem.FullName
$TempDir = Join-Path $OutputDirFull (".stage0-download." + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force -Confirm:$false | Out-Null

try {
    $BaseUrl = "https://github.com/$Repo/releases/download/$Tag"
    $AssetTmp = Join-Path $TempDir $Asset
    $SumsTmp = Join-Path $TempDir "SHA256SUMS"
    $Dest = Join-Path $OutputDirFull $Output

    Write-Host "[stage0] downloading $Asset from $Repo@$Tag"
    Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile $AssetTmp -UseBasicParsing

    if ((Get-Item -LiteralPath $AssetTmp).Length -le 0) {
        throw "downloaded stage0 asset is empty: $Asset"
    }

    $HaveSums = $false
    try {
        Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS" -OutFile $SumsTmp -UseBasicParsing
        $HaveSums = $true
    } catch {
        Write-Warning "SHA256SUMS not found for $Tag; verified non-empty asset only"
    }

    if ($HaveSums) {
        $AssetPattern = [regex]::Escape($Asset)
        $Selected = Get-Content -LiteralPath $SumsTmp |
            Where-Object { $_ -match "^\s*[0-9A-Fa-f]{64}\s+$AssetPattern\s*$" } |
            Select-Object -First 1

        if (-not $Selected) {
            throw "SHA256SUMS does not contain $Asset"
        }
        if ($Selected -notmatch "^\s*([0-9A-Fa-f]{64})\s+") {
            throw "invalid SHA256SUMS entry for $Asset"
        }

        $ExpectedHash = $Matches[1].ToLowerInvariant()
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $AssetTmp).Hash.ToLowerInvariant()
        if ($ActualHash -ne $ExpectedHash) {
            throw "sha256 mismatch for $Asset`: expected $ExpectedHash, got $ActualHash"
        }
    }

    Move-Item -LiteralPath $AssetTmp -Destination $Dest -Force -Confirm:$false

    if ($IsWindowsHost) {
        Unblock-File -LiteralPath $Dest -ErrorAction SilentlyContinue
    } else {
        & chmod +x $Dest
    }

    if ((Get-Item -LiteralPath $Dest).Length -le 0) {
        throw "stage0 compiler is empty after install: $Dest"
    }

    Write-Host "[stage0] installed $Dest"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $TempDir -ErrorAction SilentlyContinue
}
