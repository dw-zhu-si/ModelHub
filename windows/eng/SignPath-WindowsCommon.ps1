Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModelHubApprovedVersion = '1.10.0'
$script:ModelHubApprovedBuild = 67
$script:ModelHubApprovedVelopackVersion = '1.2.0'
$script:ModelHubSignPathSubject = 'CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US'
$script:ModelHubProductName = 'ModelHub'
$script:ModelHubCompanyName = '野路子工作室'
$script:ModelHubMainExe = 'ModelHub.Windows.exe'
$script:ModelHubAssembly = 'ModelHub.Windows.dll'

function Test-ModelHubPathIsFullyQualified {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if ($env:OS -eq 'Windows_NT') {
        return $Path -match '^[A-Za-z]:[\\/]'
    }
    return [System.IO.Path]::IsPathRooted($Path)
}

function Assert-ModelHubApprovedRelease {
    param(
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [int] $Build
    )

    if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -ne $script:ModelHubApprovedVersion) {
        throw "Version must match the approved release $($script:ModelHubApprovedVersion)."
    }
    if ($Build -ne $script:ModelHubApprovedBuild) {
        throw "Build must match the approved release build $($script:ModelHubApprovedBuild)."
    }
}

function Resolve-ModelHubSafeAbsolutePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ParameterName
    )

    if (-not (Test-ModelHubPathIsFullyQualified -Path $Path)) {
        throw "$ParameterName must be an absolute path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $pathRoot) {
        throw "$ParameterName must not be a filesystem root."
    }
    return $fullPath
}

function Assert-ModelHubNoReparseAncestor {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $cursor = $Path
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Release input and output paths must not contain reparse points.'
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-ModelHubWindowsHost {
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) {
        throw 'SignPath Windows release processing must run on a real Windows GitHub-hosted runner.'
    }
}

function Get-ModelHubReleaseLane {
    param([Parameter(Mandatory = $true)] [ValidateSet('win-x64', 'win-arm64')] [string] $Runtime)

    $architecture = if ($Runtime -eq 'win-x64') { 'x64' } else { 'arm64' }
    return [pscustomobject]@{
        Runtime = $Runtime
        Architecture = $architecture
        Channel = "win-$architecture"
        PackId = "com.local.modelhub.windows.$architecture"
    }
}

function Assert-ModelHubPeMachine {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [ValidateSet('x64', 'arm64')] [string] $Architecture
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'A Windows artifact does not contain a valid DOS/PE header.'
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw 'A Windows artifact contains an invalid PE signature.'
    }
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $expectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
    if ($machine -ne $expectedMachine) {
        throw "A Windows artifact has machine type 0x$($machine.ToString('X4')); expected $Architecture."
    }
}

function Assert-ModelHubUnsigned {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne 'NotSigned') {
        throw 'A SignPath input unexpectedly already contains an Authenticode signature.'
    }
}

function Assert-ModelHubSignPathSignature {
    param([Parameter(Mandatory = $true)] [string] $Path)

    & signtool verify /pa /all /v $Path
    if ($LASTEXITCODE -ne 0) { throw 'Authenticode trust verification failed.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'The Authenticode signature is not valid under the Windows trust policy.'
    }
    if (-not ([string]$signature.SignerCertificate.Subject).Equals(
        $script:ModelHubSignPathSubject,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Authenticode publisher is not the approved SignPath Foundation subject.'
    }
    if ([string]$signature.SignerCertificate.Subject -eq [string]$signature.SignerCertificate.Issuer) {
        throw 'A self-signed certificate cannot be used for public packaging.'
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw 'A trusted RFC 3161 timestamp is required for public packaging.'
    }
    return $signature
}

function Assert-ModelHubSignedPublishDirectory {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [ValidateSet('x64', 'arm64')] [string] $Architecture
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw 'The SignPath-signed publish directory is missing.'
    }
    $ownedNames = @($script:ModelHubMainExe, $script:ModelHubAssembly)
    foreach ($name in $ownedNames) {
        $ownedPath = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $ownedPath -PathType Leaf)) {
            throw "The SignPath result is missing $name."
        }
        Assert-ModelHubPeMachine -Path $ownedPath -Architecture $Architecture
        $null = Assert-ModelHubSignPathSignature -Path $ownedPath
    }

    foreach ($candidate in Get-ChildItem -LiteralPath $Path -File -Recurse |
        Where-Object { $_.Extension -in @('.exe', '.dll') -and $ownedNames -notcontains $_.Name }) {
        $signature = Get-AuthenticodeSignature -LiteralPath $candidate.FullName
        if ($null -ne $signature.SignerCertificate -and
            ([string]$signature.SignerCertificate.Subject).Equals(
                $script:ModelHubSignPathSubject,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A third-party binary was signed with the ModelHub SignPath Foundation policy.'
        }
    }
}

function Assert-ModelHubArchiveContainsSignedApp {
    param(
        [Parameter(Mandatory = $true)] [string] $ArchivePath,
        [Parameter(Mandatory = $true)] [ValidateSet('x64', 'arm64')] [string] $Architecture,
        [Parameter(Mandatory = $true)] [string] $ScratchRoot
    )

    $extractRoot = Join-Path $ScratchRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractRoot)
        foreach ($name in @($script:ModelHubMainExe, $script:ModelHubAssembly)) {
            $matches = @(Get-ChildItem -LiteralPath $extractRoot -File -Recurse -Filter $name)
            if ($matches.Count -ne 1) {
                throw "The archive must contain exactly one $name."
            }
            Assert-ModelHubPeMachine -Path $matches[0].FullName -Architecture $Architecture
            $null = Assert-ModelHubSignPathSignature -Path $matches[0].FullName
        }
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
    }
}

function Assert-ModelHubVelopackToolVersion {
    $null = Get-Command vpk -ErrorAction Stop
    $toolListText = (& dotnet tool list --global --format json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'The global .NET tool inventory could not be read.' }
    try { $toolList = $toolListText | ConvertFrom-Json }
    catch { throw 'The global .NET tool inventory is malformed.' }
    $vpk = @($toolList.data) | Where-Object { [string]$_.packageId -eq 'vpk' } | Select-Object -First 1
    if ($null -eq $vpk -or [string]$vpk.version -ne $script:ModelHubApprovedVelopackVersion) {
        throw "The global vpk tool must be pinned to version $($script:ModelHubApprovedVelopackVersion)."
    }
}

function Write-ModelHubReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)] [string] $ReleaseDirectory,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [int] $Build,
        [Parameter(Mandatory = $true)] [pscustomobject] $Lane
    )

    $files = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File -Recurse |
        Where-Object { $_.Name -notin @('SHA256SUMS', 'release-manifest.json') } |
        Sort-Object FullName)
    if ($files.Count -eq 0) { throw 'Velopack produced no release artifacts.' }
    $artifacts = @()
    $checksumLines = @()
    foreach ($file in $files) {
        $relativePath = [System.IO.Path]::GetRelativePath($ReleaseDirectory, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $checksumLines += "$hash  $relativePath"
        $authenticode = if ($file.Extension -ieq '.exe') { 'valid_signpath_timestamped' } else { 'embedded_app_binaries_verified' }
        $artifacts += [ordered]@{
            Path = $relativePath
            Bytes = $file.Length
            Sha256 = $hash
            Authenticode = $authenticode
        }
    }
    $checksumPath = Join-Path $ReleaseDirectory 'SHA256SUMS'
    [System.IO.File]::WriteAllLines($checksumPath, $checksumLines, [System.Text.UTF8Encoding]::new($false))
    $manifest = [ordered]@{
        SchemaVersion = 2
        Product = 'ModelHub.Windows'
        Version = $Version
        Build = $Build
        Runtime = $Lane.Runtime
        Architecture = $Lane.Architecture
        PackId = $Lane.PackId
        Channel = $Lane.Channel
        VelopackVersion = $script:ModelHubApprovedVelopackVersion
        SigningProvider = 'SignPath Foundation'
        SignerSubject = $script:ModelHubSignPathSubject
        OriginVerificationRequired = $true
        RealWindowsDeviceGatePassed = $false
        PublicReleaseAllowed = $false
        CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Artifacts = $artifacts
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $ReleaseDirectory 'release-manifest.json'),
        ($manifest | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
}
