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
    $Output = "typelisp.exe"
} elseif ($IsLinuxHost) {
    $SingleAsset = "typelisp-stage0-linux"
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

# Only a missing mutable alias selects another release. An explicit tag or
# a checksum mismatch must retain its original failure boundary.
$RequireSums = ($Tag -eq "stage0-latest")

function Test-Stage0NotFound {
    param($Failure)
    $ResponseProperty = $Failure.Exception.PSObject.Properties['Response']
    return $ResponseProperty -and $ResponseProperty.Value -and ([int] $ResponseProperty.Value.StatusCode -eq 404)
}

function Get-ImmutableMainRelease {
    $Api = "https://api.github.com/repos/$Repo"
    for ($Page = 1; ; $Page++) {
        $PageText = (Invoke-WebRequest -Uri "$Api/releases?per_page=100&page=$Page" -UseBasicParsing).Content
        if (-not $PageText.TrimStart().StartsWith('[')) { throw "invalid stage0 release list" }
        $Items = @($PageText | ConvertFrom-Json)
        $Candidates = $Items | Where-Object {
            $_.draft -eq $false -and $_.prerelease -eq $false -and $_.published_at -and
            $_.tag_name -cmatch '^stage0-[0-9]{8}-[0-9]{6}-r[0-9]+$' -and
            $_.target_commitish -cmatch '^[0-9a-f]{40}$' -and
            @($_.assets | Where-Object { $_.name -eq $SingleAsset -and $_.state -eq 'uploaded' -and $_.size -gt 0 }).Count -gt 0 -and
            @($_.assets | Where-Object { $_.name -eq 'SHA256SUMS' -and $_.state -eq 'uploaded' -and $_.size -gt 0 }).Count -gt 0
        } | Sort-Object -Property published_at, tag_name -Descending
        foreach ($Candidate in $Candidates) {
            try {
                $Comparison = (Invoke-WebRequest -Uri "$Api/compare/$($Candidate.tag_name)...main" -UseBasicParsing).Content | ConvertFrom-Json
            } catch {
                if (Test-Stage0NotFound $_) { continue }
                throw
            }
            if ($Comparison.base_commit.sha -ceq $Candidate.target_commitish -and $Comparison.status -cin @('ahead', 'identical')) {
                return $Candidate.tag_name
            }
        }
        if ($Items.Count -lt 100) { break }
    }
    throw "no published immutable main release with $SingleAsset and SHA256SUMS"
}

# Match the POSIX fetcher's bounded whole-generation retry. The prepared-draft
# publication protocol keeps the stage0-latest gap short, but release/tag and
# CDN propagation can still expose a transient 404 or mismatched checksum.
# Validate configuration before allocating download state so invalid settings
# cannot leave a temporary directory behind.
$FetchAttempts = 6
if ($env:TYPELISP_STAGE0_FETCH_ATTEMPTS) {
    if (-not [int]::TryParse($env:TYPELISP_STAGE0_FETCH_ATTEMPTS, [ref] $FetchAttempts) -or $FetchAttempts -le 0) {
        throw "TYPELISP_STAGE0_FETCH_ATTEMPTS must be a positive integer"
    }
}
$FetchRetryDelay = 5
if ($env:TYPELISP_STAGE0_FETCH_RETRY_DELAY) {
    if (-not [int]::TryParse($env:TYPELISP_STAGE0_FETCH_RETRY_DELAY, [ref] $FetchRetryDelay) -or $FetchRetryDelay -lt 0) {
        throw "TYPELISP_STAGE0_FETCH_RETRY_DELAY must be a non-negative integer"
    }
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
            if (Test-Stage0NotFound $_) { $script:ReleaseUnavailable = $true }
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    $FetchSucceeded = $false
    for ($Attempt = 1; $Attempt -le $FetchAttempts; $Attempt++) {
        $Asset = $SingleAsset
        $script:ReleaseUnavailable = $false
        $AssetTmp = $null
        Remove-Item -LiteralPath (Join-Path $TempDir $SingleAsset) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $SumsTmp -Force -ErrorAction SilentlyContinue
        try {
            Write-Host "[stage0] downloading $SingleAsset from $Repo@$Tag"
            $AssetTmp = Download-Stage0Asset -AssetName $SingleAsset

            $HaveSums = $false
            try {
                Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS" -OutFile $SumsTmp -UseBasicParsing
                $HaveSums = $true
            } catch {
                if (Test-Stage0NotFound $_) { $script:ReleaseUnavailable = $true }
                if ($RequireSums) {
                    throw "SHA256SUMS is not visible for $Tag yet"
                }
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

            $FetchSucceeded = $true
            break
        } catch {
            $FetchError = $_.Exception.Message
            if ($Tag -eq 'stage0-latest' -and $script:ReleaseUnavailable) {
                $FallbackTag = Get-ImmutableMainRelease
                [Console]::Error.WriteLine("[stage0] stage0-latest unavailable; falling back to $Repo@$FallbackTag")
                $Tag = $FallbackTag
                $BaseUrl = "https://github.com/$Repo/releases/download/$Tag"
                $Attempt--
                continue
            }
            Remove-Item -LiteralPath (Join-Path $TempDir $SingleAsset) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $SumsTmp -Force -ErrorAction SilentlyContinue
            if ($Attempt -ge $FetchAttempts) {
                throw ("failed to fetch a consistent stage0 from {0}@{1} after {2} attempt(s): {3}" -f $Repo, $Tag, $Attempt, $FetchError)
            }
            Write-Warning ("stage0 fetch attempt {0}/{1} was inconsistent ({2}); retrying in {3}s" -f $Attempt, $FetchAttempts, $FetchError, $FetchRetryDelay)
            if ($FetchRetryDelay -gt 0) {
                Start-Sleep -Seconds $FetchRetryDelay
            }
        }
    }

    if (-not $FetchSucceeded -or -not $AssetTmp) {
        throw "stage0 fetch exhausted without a verified asset"
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
