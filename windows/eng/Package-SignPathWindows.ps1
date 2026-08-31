[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $Build,
    [Parameter(Mandatory = $true)] [string] $SignedPublishRoot,
    [Parameter(Mandatory = $true)] [string] $OutputRoot
)

. (Join-Path $PSScriptRoot 'SignPath-WindowsCommon.ps1')
Assert-ModelHubApprovedRelease -Version $Version -Build $Build
Assert-ModelHubWindowsHost
$null = Get-Command signtool -ErrorAction Stop
Assert-ModelHubVelopackToolVersion

$fullSignedPublishRoot = Resolve-ModelHubSafeAbsolutePath -Path $SignedPublishRoot -ParameterName 'SignedPublishRoot'
$fullOutputRoot = Resolve-ModelHubSafeAbsolutePath -Path $OutputRoot -ParameterName 'OutputRoot'
Assert-ModelHubNoReparseAncestor -Path $fullSignedPublishRoot
Assert-ModelHubNoReparseAncestor -Path $fullOutputRoot
if (-not (Test-Path -LiteralPath $fullSignedPublishRoot -PathType Container)) {
    throw 'SignedPublishRoot does not exist.'
}
if (Test-Path -LiteralPath $fullOutputRoot) {
    throw 'The SignPath packaging output already exists; overwrite is blocked.'
}

$releaseRoot = Join-Path $fullOutputRoot 'release'
$unsignedSetupRoot = Join-Path $fullOutputRoot 'unsigned-setups'
$scratchRoot = Join-Path $fullOutputRoot 'verification-scratch'
$completed = $false
try {
    New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
    foreach ($runtime in @('win-x64', 'win-arm64')) {
        $lane = Get-ModelHubReleaseLane -Runtime $runtime
        $publishDirectory = Join-Path $fullSignedPublishRoot $runtime
        Assert-ModelHubSignedPublishDirectory -Path $publishDirectory -Architecture $lane.Architecture

        $releaseDirectory = Join-Path $releaseRoot $runtime
        New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
        & vpk pack --channel $lane.Channel --runtime $runtime --packId $lane.PackId `
            --packVersion $Version --packDir $publishDirectory --mainExe $script:ModelHubMainExe `
            --packTitle $script:ModelHubProductName --packAuthors $script:ModelHubCompanyName `
            --outputDir $releaseDirectory --skip-updates true --yes true
        if ($LASTEXITCODE -ne 0) { throw "Velopack packaging failed for $runtime." }

        $packages = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.nupkg' -File)
        if ($packages.Count -ne 1 -or -not $packages[0].Name.StartsWith("$($lane.PackId)-", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Velopack package identity or architecture is inconsistent with the requested release lane.'
        }
        $setups = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*-Setup.exe' -File)
        if ($setups.Count -ne 1) { throw 'Velopack must produce exactly one Setup executable per architecture.' }
        Assert-ModelHubPeMachine -Path $setups[0].FullName -Architecture $lane.Architecture
        Assert-ModelHubUnsigned -Path $setups[0].FullName
        Assert-ModelHubArchiveContainsSignedApp -ArchivePath $packages[0].FullName `
            -Architecture $lane.Architecture -ScratchRoot $scratchRoot

        $portable = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*-Portable.zip' -File)
        if ($portable.Count -ne 1) { throw 'Velopack must produce exactly one portable ZIP per architecture.' }
        Assert-ModelHubArchiveContainsSignedApp -ArchivePath $portable[0].FullName `
            -Architecture $lane.Architecture -ScratchRoot $scratchRoot

        $setupInputDirectory = Join-Path $unsignedSetupRoot $runtime
        New-Item -ItemType Directory -Path $setupInputDirectory -Force | Out-Null
        Copy-Item -LiteralPath $setups[0].FullName -Destination (Join-Path $setupInputDirectory $setups[0].Name)
    }

    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    [ordered]@{
        SchemaVersion = 1
        Purpose = 'signpath_setup_input_only'
        Version = $Version
        Build = $Build
        Runtimes = @('win-x64', 'win-arm64')
        PublicReleaseAllowed = $false
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $unsignedSetupRoot 'SIGNPATH-INPUT.json') -Encoding utf8NoBOM
    $completed = $true
    Write-Output "Prepared SignPath Setup inputs: $unsignedSetupRoot"
}
finally {
    if (-not $completed -and (Test-Path -LiteralPath $fullOutputRoot)) {
        Remove-Item -LiteralPath $fullOutputRoot -Recurse -Force
    }
}
