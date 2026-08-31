[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $Build,
    [Parameter(Mandatory = $true)] [string] $OutputRoot
)

. (Join-Path $PSScriptRoot 'SignPath-WindowsCommon.ps1')
Assert-ModelHubApprovedRelease -Version $Version -Build $Build
Assert-ModelHubWindowsHost
$null = Get-Command dotnet -ErrorAction Stop

$fullOutputRoot = Resolve-ModelHubSafeAbsolutePath -Path $OutputRoot -ParameterName 'OutputRoot'
Assert-ModelHubNoReparseAncestor -Path $fullOutputRoot
if (Test-Path -LiteralPath $fullOutputRoot) {
    throw 'The SignPath preparation output already exists; overwrite is blocked.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot 'src/ModelHub.Windows/ModelHub.Windows.csproj'
$publishRoot = Join-Path $fullOutputRoot 'unsigned-publish'
$completed = $false
try {
    foreach ($runtime in @('win-x64', 'win-arm64')) {
        $lane = Get-ModelHubReleaseLane -Runtime $runtime
        $publishDirectory = Join-Path $publishRoot $runtime
        New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
        & dotnet publish $project -c Release -r $runtime --self-contained true --no-restore `
            -p:Version=$Version `
            -p:FileVersion="$Version.$Build" `
            -p:InformationalVersion="$Version+build.$Build" `
            -o $publishDirectory
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $runtime." }

        foreach ($name in @($script:ModelHubMainExe, $script:ModelHubAssembly)) {
            $ownedPath = Join-Path $publishDirectory $name
            if (-not (Test-Path -LiteralPath $ownedPath -PathType Leaf)) {
                throw "The publish directory is missing $name."
            }
            Assert-ModelHubPeMachine -Path $ownedPath -Architecture $lane.Architecture
            Assert-ModelHubUnsigned -Path $ownedPath
        }
    }

    [ordered]@{
        SchemaVersion = 1
        Purpose = 'signpath_input_only'
        Version = $Version
        Build = $Build
        Runtimes = @('win-x64', 'win-arm64')
        OwnedFilesToSign = @($script:ModelHubMainExe, $script:ModelHubAssembly)
        PublicReleaseAllowed = $false
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $publishRoot 'SIGNPATH-INPUT.json') -Encoding utf8NoBOM
    $completed = $true
    Write-Output "Prepared SignPath application binaries: $publishRoot"
}
finally {
    if (-not $completed -and (Test-Path -LiteralPath $fullOutputRoot)) {
        Remove-Item -LiteralPath $fullOutputRoot -Recurse -Force
    }
}
