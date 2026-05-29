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
    $SingleAsset = "typelisp-stage0-windows.exe"
    $BundleAsset = $null
    $Output = "typelisp.exe"
} elseif ($IsLinuxHost) {
    $SingleAsset = "typelisp-stage0-linux"
    $BundleAsset = "typelisp-stage0-linux-bundle.tar.gz"
    $Output = "typelisp"
} else {
    throw "stage0 fetch is unsupported on this host"
}

function Join-Stage0BundlePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $RelativePath
    )

    $Path = $Root
    foreach ($Part in ($RelativePath -split "/")) {
        $Path = Join-Path $Path $Part
    }
    $Path
}

function Install-LinuxStage0Bundle {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Archive,

        [Parameter(Mandatory = $true)]
        [string] $OutputDirFull,

        [Parameter(Mandatory = $true)]
        [string] $Dest,

        [Parameter(Mandatory = $true)]
        [string] $TempDir
    )

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        throw "Linux stage0 bundle install requires tar"
    }

    $ExtractDir = Join-Path $TempDir "extract"
    $InstallTmp = Join-Path $TempDir "install"
    New-Item -ItemType Directory -Path $ExtractDir -Force -Confirm:$false | Out-Null
    New-Item -ItemType Directory -Path $InstallTmp -Force -Confirm:$false | Out-Null

    & tar -xzf $Archive -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        throw "failed to extract Linux stage0 bundle"
    }

    $WrappedRoot = Join-Path $ExtractDir "typelisp-stage0-linux-bundle"
    $BundleRoot = if (Test-Path -LiteralPath $WrappedRoot -PathType Container) {
        $WrappedRoot
    } else {
        $ExtractDir
    }

    $Manifest = Join-Stage0BundlePath $BundleRoot "STAGE0_BUNDLE"
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        throw "Linux stage0 bundle is missing STAGE0_BUNDLE manifest"
    }
    $FirstLine = Get-Content -LiteralPath $Manifest -TotalCount 1
    if ($FirstLine -ne "typelisp-stage0-bundle v1") {
        throw "unsupported Linux stage0 bundle manifest: $FirstLine"
    }

    $RequiredPaths = @(
        "typelisp",
        "scripts/stage1-typelisp-wrapper.sh",
        "lib/stage1/typelisp-stage1",
        "lib/stage1/drivers/selfhost-doc",
        "lib/stage1/drivers/selfhost-build",
        "lib/stage1/drivers/selfhost-repl"
    )
    foreach ($Required in $RequiredPaths) {
        $Path = Join-Stage0BundlePath $BundleRoot $Required
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Linux stage0 bundle is missing required path: $Required"
        }
    }

    $RequiredFiles = @(
        "typelisp",
        "scripts/stage1-typelisp-wrapper.sh",
        "lib/stage1/typelisp-stage1",
        "lib/stage1/drivers/selfhost-doc",
        "lib/stage1/drivers/selfhost-build",
        "lib/stage1/drivers/selfhost-repl"
    )
    foreach ($Required in $RequiredFiles) {
        $Path = Join-Stage0BundlePath $BundleRoot $Required
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Linux stage0 bundle required path is not a file: $Required"
        }
        if ((Get-Item -LiteralPath $Path).Length -le 0) {
            throw "Linux stage0 bundle contains an empty required file: $Required"
        }
    }
    foreach ($Required in @("selfhost", "stdlib")) {
        $Path = Join-Stage0BundlePath $BundleRoot $Required
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Linux stage0 bundle is missing required directory: $Required"
        }
    }

    Get-ChildItem -LiteralPath $BundleRoot -Force |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $InstallTmp -Recurse -Force -Confirm:$false }

    Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $OutputDirFull "STAGE0_BUNDLE") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Stage0BundlePath $OutputDirFull "lib/stage1") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Stage0BundlePath $OutputDirFull "scripts/stage1-typelisp-wrapper.sh") -Force -ErrorAction SilentlyContinue

    Get-ChildItem -LiteralPath $InstallTmp -Force |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $OutputDirFull -Recurse -Force -Confirm:$false }

    $ExecutablePaths = @(
        "typelisp",
        "scripts/stage1-typelisp-wrapper.sh",
        "lib/stage1/typelisp-stage1",
        "lib/stage1/drivers/selfhost-doc",
        "lib/stage1/drivers/selfhost-build",
        "lib/stage1/drivers/selfhost-repl"
    )
    foreach ($Executable in $ExecutablePaths) {
        & chmod +x (Join-Stage0BundlePath $OutputDirFull $Executable)
    }
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
    $SumsTmp = Join-Path $TempDir "SHA256SUMS"
    $Dest = Join-Path $OutputDirFull $Output
    $Asset = $null
    $AssetTmp = $null
    $AssetKind = "single"

    function Download-Stage0Asset {
        param([Parameter(Mandatory = $true)] [string] $AssetName)

        $Target = Join-Path $TempDir $AssetName
        try {
            Invoke-WebRequest -Uri "$BaseUrl/$AssetName" -OutFile $Target -UseBasicParsing
            if ((Get-Item -LiteralPath $Target).Length -le 0) {
                throw "downloaded stage0 asset is empty: $AssetName"
            }
            $Target
        } catch {
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    if ($BundleAsset) {
        Write-Host "[stage0] downloading $BundleAsset from $Repo@$Tag"
        try {
            $AssetTmp = Download-Stage0Asset -AssetName $BundleAsset
            $Asset = $BundleAsset
            $AssetKind = "bundle"
        } catch {
            $StatusCode = $null
            $Response = $null
            if ($_.Exception.PSObject.Properties.Name -contains "Response") {
                $Response = $_.Exception.Response
            }
            if ($null -ne $Response -and ($Response.PSObject.Properties.Name -contains "StatusCode")) {
                $StatusCode = [int] $Response.StatusCode
            }
            if ($StatusCode -eq 404) {
                Write-Host "[stage0] bundled Linux stage0 asset not found; falling back to $SingleAsset"
                $AssetTmp = $null
            } else {
                throw ("failed to download {0}/{1}: {2}" -f $BaseUrl, $BundleAsset, $_.Exception.Message)
            }
        }
    }

    if (-not $AssetTmp) {
        Write-Host "[stage0] downloading $SingleAsset from $Repo@$Tag"
        try {
            $AssetTmp = Download-Stage0Asset -AssetName $SingleAsset
            $Asset = $SingleAsset
        } catch {
            throw ("failed to download {0}/{1}: {2}" -f $BaseUrl, $SingleAsset, $_.Exception.Message)
        }
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

    if ($AssetKind -eq "bundle") {
        Write-Host "[stage0] installing bundled Linux stage0 asset"
        Install-LinuxStage0Bundle -Archive $AssetTmp -OutputDirFull $OutputDirFull -Dest $Dest -TempDir $TempDir
    } else {
        Move-Item -LiteralPath $AssetTmp -Destination $Dest -Force -Confirm:$false

        if ($IsWindowsHost) {
            Unblock-File -LiteralPath $Dest -ErrorAction SilentlyContinue
        } else {
            & chmod +x $Dest
        }
    }

    if ((Get-Item -LiteralPath $Dest).Length -le 0) {
        throw "stage0 compiler is empty after install: $Dest"
    }

    Write-Host "[stage0] installed $Dest"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $TempDir -ErrorAction SilentlyContinue
}
