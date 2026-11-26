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
    $SysrootTriple = "x86_64-pc-windows-msvc"
} elseif ($IsLinuxHost) {
    $SingleAsset = "typelisp-stage0-linux"
    $BundleAsset = if ($env:TYPELISP_STAGE0_BUNDLE_ASSET) { $env:TYPELISP_STAGE0_BUNDLE_ASSET } else { $null }
    $Output = "typelisp"
    $SysrootTriple = "x86_64-unknown-linux-gnu"
} else {
    throw "stage0 fetch is unsupported on this host"
}
$SysrootTliAsset = "typelisp-stdlib-$SysrootTriple.tli"
$SysrootLibAsset = "libstdlib-$SysrootTriple.a"

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$OutputDirPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $Root $OutputDir
}

# An explicit tag retains its original failure boundary. Only the mutable
# stage0-latest alias falls back to a permanent release on 404 or after
# repeated SHA256SUMS mismatches exhaust its retries.
$RequestedTag = $Tag
$RequireSums = ($Tag -ceq "stage0-latest")

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
    $script:Tag = $Tag
    $script:BaseUrl = "https://github.com/$Repo/releases/download/$($script:Tag)"
    $SumsTmp = Join-Path $TempDir "SHA256SUMS"
    $Dest = Join-Path $OutputDirFull $Output
    $script:Asset = $null
    $script:AssetTmp = $null
    $script:SysrootTliTmp = $null
    $script:SysrootLibTmp = $null
    $script:ReleaseUnavailable = $false
    $script:ChecksumMismatch = $false

    function Clear-Stage0TempFiles {
        if ($BundleAsset) {
            Remove-Item -LiteralPath (Join-Path $TempDir $BundleAsset) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $TempDir $SingleAsset) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $TempDir $SysrootTliAsset) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $TempDir $SysrootLibAsset) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $SumsTmp -Force -ErrorAction SilentlyContinue
    }

    function Download-Stage0Asset {
        param(
            [Parameter(Mandatory = $true)] [string] $AssetName,
            [bool] $MarkMissing = $true
        )

        $Target = Join-Path $TempDir $AssetName
        try {
            Invoke-WebRequest -Uri "$($script:BaseUrl)/$AssetName" -OutFile $Target -UseBasicParsing
            if ((Get-Item -LiteralPath $Target).Length -le 0) {
                throw "downloaded stage0 asset is empty: $AssetName"
            }
            $Target
        } catch {
            if ($MarkMissing -and (Test-Stage0NotFound $_)) { $script:ReleaseUnavailable = $true }
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    function Try-DownloadOptionalAsset {
        param([Parameter(Mandatory = $true)] [string] $AssetName)

        $Target = Join-Path $TempDir $AssetName
        try {
            Invoke-WebRequest -Uri "$($script:BaseUrl)/$AssetName" -OutFile $Target -UseBasicParsing
            if ((Get-Item -LiteralPath $Target).Length -le 0) {
                Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
                throw "downloaded optional asset is empty: $AssetName"
            }
            $Target
        } catch {
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            if (Test-Stage0NotFound $_) { return $null }
            throw
        }
    }

    function Verify-OptionalAssetSum {
        param(
            [Parameter(Mandatory = $true)] [string] $AssetName,
            [Parameter(Mandatory = $true)] [string] $AssetPath,
            [Parameter(Mandatory = $true)] [bool] $HaveSums
        )

        if (-not $HaveSums) { return }
        $AssetPattern = [regex]::Escape($AssetName)
        $Selected = Get-Content -LiteralPath $SumsTmp |
            Where-Object { $_ -match "^\s*[0-9A-Fa-f]{64}\s+$AssetPattern\s*$" } |
            Select-Object -First 1
        if (-not $Selected) { return }
        if ($Selected -notmatch "^\s*([0-9A-Fa-f]{64})\s+") {
            $script:ChecksumMismatch = $true
            throw "invalid SHA256SUMS entry for $AssetName"
        }
        $ExpectedHash = $Matches[1].ToLowerInvariant()
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $AssetPath).Hash.ToLowerInvariant()
        if ($ActualHash -ne $ExpectedHash) {
            $script:ChecksumMismatch = $true
            throw "sha256 mismatch for $AssetName`: expected $ExpectedHash, got $ActualHash"
        }
    }

    function Invoke-Stage0Fetch {
        $script:Asset = $null
        $script:AssetTmp = $null
        $script:SysrootTliTmp = $null
        $script:SysrootLibTmp = $null
        $script:ReleaseUnavailable = $false
        $script:ChecksumMismatch = $false
        Clear-Stage0TempFiles

        if ($BundleAsset) {
            Write-Host "[stage0] downloading $BundleAsset from $Repo@$($script:Tag)"
            try {
                $script:AssetTmp = Download-Stage0Asset -AssetName $BundleAsset -MarkMissing $false
                $script:Asset = $BundleAsset
            } catch {
                Write-Host "[stage0] bundled Linux stage0 asset not present yet; trying $SingleAsset"
            }
        }

        if (-not $script:Asset) {
            Write-Host "[stage0] downloading $SingleAsset from $Repo@$($script:Tag)"
            $script:AssetTmp = Download-Stage0Asset -AssetName $SingleAsset -MarkMissing $true
            $script:Asset = $SingleAsset
        }

        $HaveSums = $false
        try {
            Invoke-WebRequest -Uri "$($script:BaseUrl)/SHA256SUMS" -OutFile $SumsTmp -UseBasicParsing
            $HaveSums = $true
        } catch {
            if (Test-Stage0NotFound $_) { $script:ReleaseUnavailable = $true }
            if ($RequireSums) {
                throw "SHA256SUMS is not visible for $($script:Tag) yet"
            }
            Write-Warning "SHA256SUMS not found for $($script:Tag); verified non-empty asset only"
        }

        if ($HaveSums) {
            $AssetPattern = [regex]::Escape($script:Asset)
            $Selected = Get-Content -LiteralPath $SumsTmp |
                Where-Object { $_ -match "^\s*[0-9A-Fa-f]{64}\s+$AssetPattern\s*$" } |
                Select-Object -First 1

            if (-not $Selected) {
                $script:ChecksumMismatch = $true
                throw "SHA256SUMS does not contain $($script:Asset)"
            }
            if ($Selected -notmatch "^\s*([0-9A-Fa-f]{64})\s+") {
                $script:ChecksumMismatch = $true
                throw "invalid SHA256SUMS entry for $($script:Asset)"
            }

            $ExpectedHash = $Matches[1].ToLowerInvariant()
            $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:AssetTmp).Hash.ToLowerInvariant()
            if ($ActualHash -ne $ExpectedHash) {
                $script:ChecksumMismatch = $true
                throw "sha256 mismatch for $($script:Asset)`: expected $ExpectedHash, got $ActualHash"
            }
        }

        $CandidateTli = Try-DownloadOptionalAsset -AssetName $SysrootTliAsset
        $CandidateLib = Try-DownloadOptionalAsset -AssetName $SysrootLibAsset
        if ($CandidateTli -and $CandidateLib) {
            Verify-OptionalAssetSum -AssetName $SysrootTliAsset -AssetPath $CandidateTli -HaveSums $HaveSums
            Verify-OptionalAssetSum -AssetName $SysrootLibAsset -AssetPath $CandidateLib -HaveSums $HaveSums
            $script:SysrootTliTmp = $CandidateTli
            $script:SysrootLibTmp = $CandidateLib
        } elseif (-not $CandidateTli -and -not $CandidateLib) {
            if ($HaveSums) {
                $TliPat = [regex]::Escape($SysrootTliAsset)
                $LibPat = [regex]::Escape($SysrootLibAsset)
                $ExpectedSysroot = Get-Content -LiteralPath $SumsTmp |
                    Where-Object { $_ -match "^\s*[0-9A-Fa-f]{64}\s+($TliPat|$LibPat)\s*$" } |
                    Select-Object -First 1
                if ($ExpectedSysroot) {
                    $script:ChecksumMismatch = $true
                    throw "SHA256SUMS lists sysroot assets that are not visible yet"
                }
            }
        } else {
            throw "inconsistent prebuilt stdlib sysroot download"
        }
    }

    function Get-Stage0RetryDelay {
        param([Parameter(Mandatory = $true)] [int] $Attempt)

        $Delay = $FetchRetryDelay
        if ($Delay -le 0) { return 0 }
        if ($script:Tag -ceq 'stage0-latest') {
            $Cap = [Math]::Max(30, $Delay)
            for ($i = 1; $i -lt $Attempt -and $Delay -lt $Cap; $i++) {
                $Delay = $Delay * 2
            }
            if ($Delay -gt $Cap) { $Delay = $Cap }
        }
        return $Delay
    }

    function Try-PermanentFallback {
        param([Parameter(Mandatory = $true)] [string] $Reason)

        $FallbackTag = $null
        try {
            $FallbackTag = Get-ImmutableMainRelease
        } catch {
            Write-Warning ("[stage0] immutable fallback unavailable: {0}" -f $_.Exception.Message)
            return $false
        }
        if (-not $FallbackTag) { return $false }
        [Console]::Error.WriteLine("[stage0] $RequestedTag $Reason; falling back to $Repo@$FallbackTag")
        $SavedTag = $script:Tag
        $SavedBaseUrl = $script:BaseUrl
        $script:Tag = $FallbackTag
        $script:BaseUrl = "https://github.com/$Repo/releases/download/$($script:Tag)"
        try {
            Invoke-Stage0Fetch
            return $true
        } catch {
            Write-Warning ("[stage0] immutable fallback {0}@{1} failed: {2}" -f $Repo, $FallbackTag, $_.Exception.Message)
            $script:Tag = $SavedTag
            $script:BaseUrl = $SavedBaseUrl
            Clear-Stage0TempFiles
            return $false
        }
    }

    $FetchSucceeded = $false
    $ChecksumMismatches = 0
    for ($Attempt = 1; $Attempt -le $FetchAttempts; $Attempt++) {
        try {
            Invoke-Stage0Fetch
            $FetchSucceeded = $true
            break
        } catch {
            $FetchError = $_.Exception.Message
            if ($script:ChecksumMismatch) {
                $ChecksumMismatches++
            }
            if ($script:Tag -ceq 'stage0-latest' -and $script:ReleaseUnavailable) {
                if (Try-PermanentFallback -Reason 'unavailable') {
                    $FetchSucceeded = $true
                    break
                }
            }
            Clear-Stage0TempFiles
            if ($Attempt -ge $FetchAttempts) {
                if ($script:Tag -ceq 'stage0-latest' -and $ChecksumMismatches -ge 2) {
                    if (Try-PermanentFallback -Reason 'had repeated SHA256SUMS mismatches') {
                        $FetchSucceeded = $true
                        break
                    }
                }
                throw ("failed to fetch a consistent stage0 from {0}@{1} after {2} attempt(s): {3}" -f $Repo, $script:Tag, $Attempt, $FetchError)
            }
            $RetryDelay = Get-Stage0RetryDelay -Attempt $Attempt
            Write-Warning ("stage0 fetch attempt {0}/{1} was inconsistent ({2}); retrying in {3}s" -f $Attempt, $FetchAttempts, $FetchError, $RetryDelay)
            if ($RetryDelay -gt 0) {
                Start-Sleep -Seconds $RetryDelay
            }
        }
    }

    if (-not $FetchSucceeded -or -not $script:AssetTmp) {
        throw "stage0 fetch exhausted without a verified asset"
    }

    Move-Item -LiteralPath $script:AssetTmp -Destination $Dest -Force -Confirm:$false

    if ($IsWindowsHost) {
        Unblock-File -LiteralPath $Dest -ErrorAction SilentlyContinue
    } else {
        & chmod +x $Dest
    }

    if ((Get-Item -LiteralPath $Dest).Length -le 0) {
        throw "stage0 compiler is empty after install: $Dest"
    }

    $SysrootDir = Join-Path (Join-Path $OutputDirFull "lib") $SysrootTriple
    if ($script:SysrootTliTmp -and $script:SysrootLibTmp) {
        New-Item -ItemType Directory -Path $SysrootDir -Force -Confirm:$false | Out-Null
        Move-Item -LiteralPath $script:SysrootTliTmp -Destination (Join-Path $SysrootDir "stdlib.tli") -Force -Confirm:$false
        Move-Item -LiteralPath $script:SysrootLibTmp -Destination (Join-Path $SysrootDir "libstdlib.a") -Force -Confirm:$false
        Write-Host "[stage0] installed sysroot in $SysrootDir"
    } else {
        Remove-Item -LiteralPath (Join-Path $SysrootDir "stdlib.tli") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $SysrootDir "libstdlib.a") -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[stage0] installed $Dest"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $TempDir -ErrorAction SilentlyContinue
}
