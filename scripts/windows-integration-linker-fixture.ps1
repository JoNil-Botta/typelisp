[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("success", "failure", "missing-output")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$ArgumentLogPath,

    [int]$DelayMilliseconds = 0,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Inputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)

if ($DelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $DelayMilliseconds
}
if ($null -eq $Inputs) {
    $Inputs = @()
}

$argumentDirectory = [System.IO.Path]::GetDirectoryName($ArgumentLogPath)
if (-not [string]::IsNullOrEmpty($argumentDirectory)) {
    [System.IO.Directory]::CreateDirectory($argumentDirectory) | Out-Null
}
[System.IO.File]::WriteAllLines($ArgumentLogPath, $Inputs, $Utf8)

switch ($Mode) {
    "success" {
        $outputDirectory = [System.IO.Path]::GetDirectoryName($OutputPath)
        if (-not [string]::IsNullOrEmpty($outputDirectory)) {
            [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputPath, "linked", $Utf8)
        Write-Output "fake linker stdout"
        [System.Console]::Error.WriteLine("fake linker stderr")
        exit 0
    }
    "failure" {
        Write-Output "intentional failure stdout"
        [System.Console]::Error.WriteLine("intentional failure stderr")
        exit 23
    }
    "missing-output" {
        Write-Output "intentional missing output"
        exit 0
    }
}
