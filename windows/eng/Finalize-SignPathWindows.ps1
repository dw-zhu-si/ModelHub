[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $Build,
    [Parameter(Mandatory = $true)] [string] $PackagedRoot,
    [Parameter(Mandatory = $true)] [string] $SignedSetupRoot,
    [Parameter(Mandatory = $true)] [string] $OutputRoot
)

. (Join-Path $PSScriptRoot 'SignPath-WindowsCommon.ps1')
Assert-ModelHubApprovedRelease -Version $Version -Build $Build
Assert-ModelHubWindowsHost
$null = Get-Command signtool -ErrorAction Stop

$fullPackagedRoot = Resolve-ModelHubSafeAbsolutePath -Path $PackagedRoot -ParameterName 'PackagedRoot'
$fullSignedSetupRoot = Resolve-ModelHubSafeAbsolutePath -Path $SignedSetupRoot -ParameterName 'SignedSetupRoot'
$fullOutputRoot = Resolve-ModelHubSafeAbsolutePath -Path $OutputRoot -ParameterName 'OutputRoot'
foreach ($path in @($fullPackagedRoot, $fullSignedSetupRoot, $fullOutputRoot)) {
    Assert-ModelHubNoReparseAncestor -Path $path
}
if (-not (Test-Path -LiteralPath $fullPackagedRoot -PathType Container) -or
    -not (Test-Path -LiteralPath $fullSignedSetupRoot -PathType Container)) {
    throw 'The packaged release or SignPath-signed Setup root is missing.'
}
if (Test-Path -LiteralPath $fullOutputRoot) {
    throw 'The final SignPath output already exists; overwrite is blocked.'
}

$completed = $false
$scratchRoot = Join-Path $fullOutputRoot '.verification-scratch'
try {
    New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
    foreach ($runtime in @('win-x64', 'win-arm64')) {
        $lane = Get-ModelHubReleaseLane -Runtime $runtime
        $sourceRelease = Join-Path $fullPackagedRoot "release/$runtime"
        if (-not (Test-Path -LiteralPath $sourceRelease -PathType Container)) {
            throw "The packaged $runtime release directory is missing."
        }
        $signedSetupDirectory = Join-Path $fullSignedSetupRoot $runtime
        $signedSetups = @(Get-ChildItem -LiteralPath $signedSetupDirectory -Filter '*-Setup.exe' -File)
        if ($signedSetups.Count -ne 1) { throw "SignPath must return exactly one $runtime Setup executable." }
        Assert-ModelHubPeMachine -Path $signedSetups[0].FullName -Architecture $lane.Architecture
        $null = Assert-ModelHubSignPathSignature -Path $signedSetups[0].FullName

        $destinationRelease = Join-Path $fullOutputRoot "stable/$Version/build-$Build/$runtime/release"
        New-Item -ItemType Directory -Path $destinationRelease -Force | Out-Null
        Copy-Item -Path (Join-Path $sourceRelease '*') -Destination $destinationRelease -Recurse
        $unsignedSetups = @(Get-ChildItem -LiteralPath $destinationRelease -Filter '*-Setup.exe' -File)
        if ($unsignedSetups.Count -ne 1 -or $unsignedSetups[0].Name -ne $signedSetups[0].Name) {
            throw 'The signed Setup name does not match the packaged release identity.'
        }
        $unsignedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $unsignedSetups[0].FullName).Hash
        $signedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $signedSetups[0].FullName).Hash
        if ($unsignedHash -eq $signedHash) { throw 'The SignPath Setup result is byte-identical to the unsigned input.' }
        Copy-Item -LiteralPath $signedSetups[0].FullName -Destination $unsignedSetups[0].FullName -Force
        $null = Assert-ModelHubSignPathSignature -Path $unsignedSetups[0].FullName

        $packages = @(Get-ChildItem -LiteralPath $destinationRelease -Filter '*.nupkg' -File)
        $portable = @(Get-ChildItem -LiteralPath $destinationRelease -Filter '*-Portable.zip' -File)
        if ($packages.Count -ne 1 -or $portable.Count -ne 1) {
            throw 'The final release must contain exactly one full package and one portable ZIP.'
        }
        Assert-ModelHubArchiveContainsSignedApp -ArchivePath $packages[0].FullName `
            -Architecture $lane.Architecture -ScratchRoot $scratchRoot
        Assert-ModelHubArchiveContainsSignedApp -ArchivePath $portable[0].FullName `
            -Architecture $lane.Architecture -ScratchRoot $scratchRoot
        Write-ModelHubReleaseMetadata -ReleaseDirectory $destinationRelease `
            -Version $Version -Build $Build -Lane $lane
    }

    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    $completed = $true
    Write-Output "Created SignPath-verified Windows release candidates: $fullOutputRoot"
}
finally {
    if (-not $completed -and (Test-Path -LiteralPath $fullOutputRoot)) {
        Remove-Item -LiteralPath $fullOutputRoot -Recurse -Force
    }
}
