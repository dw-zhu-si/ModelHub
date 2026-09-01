[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('win-x64', 'win-arm64')] [string] $Runtime,
    [Parameter(Mandatory = $true)] [string] $PublishRoot,
    [Parameter(Mandatory = $true)] [string] $ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SafeAbsolutePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ParameterName
    )
    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) {
        throw "$ParameterName must be an absolute path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$ParameterName must not be a filesystem root."
    }
    return $fullPath
}

function Assert-PeMachine {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Architecture
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'The native acceptance executable has an invalid DOS header.'
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw 'The native acceptance executable has an invalid PE signature.'
    }
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $expectedMachine = if ($Architecture -eq 'X64') { 0x8664 } else { 0xAA64 }
    if ($machine -ne $expectedMachine) {
        throw "The executable machine type does not match native $Architecture acceptance."
    }
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Native Windows acceptance must run on Windows.'
}

$expectedArchitecture = if ($Runtime -eq 'win-x64') { 'X64' } else { 'Arm64' }
$actualArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if (-not $actualArchitecture.Equals($expectedArchitecture, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The runner architecture $actualArchitecture does not match $Runtime. Emulation is not accepted."
}

$fullPublishRoot = Resolve-SafeAbsolutePath -Path $PublishRoot -ParameterName 'PublishRoot'
$fullReceiptPath = Resolve-SafeAbsolutePath -Path $ReceiptPath -ParameterName 'ReceiptPath'
if (-not (Test-Path -LiteralPath $fullPublishRoot -PathType Container)) {
    throw 'PublishRoot does not exist.'
}
if (Test-Path -LiteralPath $fullReceiptPath) {
    throw 'ReceiptPath already exists; overwrite is blocked.'
}
$receiptDirectory = [System.IO.Path]::GetDirectoryName($fullReceiptPath)
if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
    throw 'ReceiptPath parent directory does not exist.'
}

$mainExecutable = Join-Path $fullPublishRoot 'ModelHub.Windows.exe'
if (-not (Test-Path -LiteralPath $mainExecutable -PathType Leaf)) {
    throw 'ModelHub.Windows.exe is missing from the publish directory.'
}
Assert-PeMachine -Path $mainExecutable -Architecture $expectedArchitecture

$process = Start-Process -FilePath $mainExecutable `
    -ArgumentList @('--acceptance-probe-output', "`"$fullReceiptPath`"") `
    -Wait -PassThru
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $fullReceiptPath -PathType Leaf)) {
    throw "The native ModelHub acceptance probe failed with exit code $($process.ExitCode)."
}
if ((Get-Item -LiteralPath $fullReceiptPath).Length -gt 1048576) {
    throw 'The native acceptance receipt exceeds the 1 MiB safety limit.'
}
$receipt = Get-Content -LiteralPath $fullReceiptPath -Raw | ConvertFrom-Json
if ([int]$receipt.SchemaVersion -ne 1 -or
    [string]$receipt.Product -ne 'ModelHub.Windows' -or
    [string]$receipt.Version -ne '1.10.0' -or
    [string]$receipt.FileVersion -ne '1.10.0.67' -or
    [string]$receipt.InformationalVersion -ne '1.10.0+build.67' -or
    -not [bool]$receipt.IsWindows -or
    -not [bool]$receipt.Is64BitProcess -or
    -not ([string]$receipt.OSArchitecture).Equals($expectedArchitecture, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not ([string]$receipt.ProcessArchitecture).Equals($expectedArchitecture, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The native acceptance receipt does not match ModelHub 1.10.0 build 67 or the requested architecture.'
}

Write-Output "Native $Runtime probe passed: $fullReceiptPath"
