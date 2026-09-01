[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('win-x64', 'win-arm64')] [string] $Runtime,
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $Build,
    [Parameter(Mandatory = $true)] [string] $OutputRoot,
    [Parameter(Mandatory = $true)] [string] $SigningCertificatePath,
    [Parameter(Mandatory = $true)] [string] $ExpectedPublisher,
    [string] $TimestampUrl = 'https://timestamp.digicert.com',
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ApprovedVersion = '1.10.0'
$ApprovedBuild = 67
$ApprovedVelopackVersion = '1.2.0'
$MainExe = 'ModelHub.Windows.exe'

function Resolve-SafeAbsolutePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ParameterName
    )

    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) {
        throw "$ParameterName must be an absolute path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    # Windows PowerShell 5.1 expands a char[] passed to String.TrimEnd and can
    # also resolve static String.Equals overloads differently from PowerShell
    # Core. GetFullPath/GetPathRoot already normalize a filesystem root, so a
    # scalar case-insensitive operator avoids both method-binding hazards.
    if ($fullPath -ieq $pathRoot) {
        throw "$ParameterName must not be a filesystem root."
    }
    return $fullPath
}

function Assert-NoReparseAncestor {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $cursor = $Path
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'OutputRoot and its existing ancestors must not be reparse points.'
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-ProjectReleaseMetadata {
    param([Parameter(Mandatory = $true)] [string] $ProjectPath)

    [xml] $projectXml = Get-Content -LiteralPath $ProjectPath -Raw
    $propertyGroups = @($projectXml.Project.PropertyGroup)
    $versionValue = [string]($propertyGroups | ForEach-Object { $_.Version } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $fileVersionValue = [string]($propertyGroups | ForEach-Object { $_.FileVersion } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $informationalVersionValue = [string]($propertyGroups | ForEach-Object { $_.InformationalVersion } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $runtimeIdentifiers = [string]($propertyGroups | ForEach-Object { $_.RuntimeIdentifiers } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $velopackReference = @($projectXml.Project.ItemGroup.PackageReference) |
        Where-Object { [string]$_.Include -eq 'Velopack' } |
        Select-Object -First 1
    if ($null -eq $velopackReference) {
        throw 'The project must contain exactly one pinned Velopack package reference.'
    }
    return [pscustomobject]@{
        Version = $versionValue
        FileVersion = $fileVersionValue
        InformationalVersion = $informationalVersionValue
        RuntimeIdentifiers = $runtimeIdentifiers
        VelopackVersion = [string]$velopackReference.Version
    }
}

function Assert-NoDowngrade {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $TargetRuntime,
        [Parameter(Mandatory = $true)] [string] $TargetChannel,
        [Parameter(Mandatory = $true)] [version] $TargetVersion
    )

    $stableRoot = Join-Path $Root 'stable'
    if (-not (Test-Path -LiteralPath $stableRoot -PathType Container)) { return }
    foreach ($manifestFile in Get-ChildItem -LiteralPath $stableRoot -Filter 'release-manifest.json' -File -Recurse) {
        if ($manifestFile.Length -gt 1048576) {
            throw 'An existing release manifest exceeds the 1 MiB safety limit.'
        }
        try {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
        }
        catch {
            throw "An existing release manifest is malformed or unsafe: $($manifestFile.Name)"
        }
        if ([string]$manifest.Runtime -eq $TargetRuntime -and [string]$manifest.Channel -eq $TargetChannel) {
            try { $manifestVersion = [version]([string]$manifest.Version) }
            catch { throw "An existing release manifest is malformed or unsafe: $($manifestFile.Name)" }
            if ($manifestVersion -gt $TargetVersion) {
                throw "A newer $TargetRuntime release already exists in this stable channel; downgrade packaging is blocked."
            }
        }
    }
}

function Assert-VelopackToolVersion {
    param([Parameter(Mandatory = $true)] [string] $ExpectedVersion)

    $null = Get-Command dotnet -ErrorAction Stop
    $null = Get-Command vpk -ErrorAction Stop
    $toolListText = (& dotnet tool list --global --format json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'The global .NET tool inventory could not be read.' }
    try { $toolList = $toolListText | ConvertFrom-Json }
    catch { throw 'The global .NET tool inventory is malformed.' }
    $vpk = @($toolList.data) | Where-Object { [string]$_.packageId -eq 'vpk' } | Select-Object -First 1
    if ($null -eq $vpk -or [string]$vpk.version -ne $ExpectedVersion) {
        throw "The global vpk tool must be pinned to version $ExpectedVersion."
    }
}

function Assert-PeMachine {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TargetArchitecture
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
    $expectedMachine = if ($TargetArchitecture -eq 'x64') { 0x8664 } else { 0xAA64 }
    if ($machine -ne $expectedMachine) {
        throw "A Windows artifact has machine type 0x$($machine.ToString('X4')); expected $TargetArchitecture."
    }
}

function Invoke-SignAndVerify {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $CertificateThumbprint,
        [Parameter(Mandatory = $true)] [string] $Publisher,
        [Parameter(Mandatory = $true)] [uri] $TimestampAuthority
    )

    & signtool sign /fd SHA256 /td SHA256 /tr $TimestampAuthority.AbsoluteUri /sha1 $CertificateThumbprint $Path
    if ($LASTEXITCODE -ne 0) { throw 'Authenticode signing failed.' }
    & signtool verify /pa /all /v $Path
    if ($LASTEXITCODE -ne 0) { throw 'Authenticode trust verification failed.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'The Authenticode signature is not valid under the Windows trust policy.'
    }
    if (-not ([string]$signature.SignerCertificate.Subject).Equals($Publisher, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Authenticode publisher does not match ExpectedPublisher.'
    }
    if ([string]$signature.SignerCertificate.Subject -eq [string]$signature.SignerCertificate.Issuer) {
        throw 'A self-signed certificate cannot be used for public packaging.'
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw 'A trusted RFC 3161 timestamp is required for public packaging.'
    }
}

function Write-IntegrityMetadata {
    param(
        [Parameter(Mandatory = $true)] [string] $StagingRoot,
        [Parameter(Mandatory = $true)] [string] $ReleaseDirectory,
        [Parameter(Mandatory = $true)] [string] $ReleaseVersion,
        [Parameter(Mandatory = $true)] [int] $ReleaseBuild,
        [Parameter(Mandatory = $true)] [string] $ReleaseRuntime,
        [Parameter(Mandatory = $true)] [string] $ReleaseArchitecture,
        [Parameter(Mandatory = $true)] [string] $ReleasePackId,
        [Parameter(Mandatory = $true)] [string] $ReleaseChannel,
        [Parameter(Mandatory = $true)] [string] $VelopackVersion,
        [Parameter(Mandatory = $true)] [string] $Publisher,
        [Parameter(Mandatory = $true)] [uri] $TimestampAuthority
    )

    $files = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File -Recurse | Sort-Object FullName)
    if ($files.Count -eq 0) { throw 'Velopack produced no release artifacts.' }
    $artifacts = @()
    $checksumLines = @()
    foreach ($file in $files) {
        $relativePath = [System.IO.Path]::GetRelativePath($StagingRoot, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $checksumLines += "$hash  $relativePath"
        $artifacts += [ordered]@{
            Path = $relativePath
            Bytes = $file.Length
            Sha256 = $hash
            Authenticode = if ($file.Extension -ieq '.exe') { 'valid_timestamped' } else { 'not_applicable' }
        }
    }
    $checksumPath = Join-Path $StagingRoot 'SHA256SUMS'
    [System.IO.File]::WriteAllLines($checksumPath, $checksumLines, [System.Text.UTF8Encoding]::new($false))
    $checksumHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $checksumPath).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        SchemaVersion = 1
        Product = 'ModelHub.Windows'
        Version = $ReleaseVersion
        Build = $ReleaseBuild
        Runtime = $ReleaseRuntime
        Architecture = $ReleaseArchitecture
        PackId = $ReleasePackId
        Channel = $ReleaseChannel
        VelopackVersion = $VelopackVersion
        Publisher = $Publisher
        TimestampAuthority = $TimestampAuthority.GetLeftPart([System.UriPartial]::Authority)
        CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ChecksumFile = [ordered]@{ Path = 'SHA256SUMS'; Sha256 = $checksumHash }
        Artifacts = $artifacts
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $StagingRoot 'release-manifest.json'),
        ($manifest | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
}

if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -ne $ApprovedVersion) {
    throw "Version must match the approved release $ApprovedVersion."
}
if ($Build -ne $ApprovedBuild) { throw "Build must match the approved release build $ApprovedBuild." }
$fullOutputRoot = Resolve-SafeAbsolutePath -Path $OutputRoot -ParameterName 'OutputRoot'
if (Test-Path -LiteralPath $fullOutputRoot -PathType Leaf) { throw 'OutputRoot must be a directory path.' }

try { $timestampUri = [uri]$TimestampUrl }
catch { throw 'TimestampUrl must be a valid HTTPS URL.' }
if (-not $timestampUri.IsAbsoluteUri -or $timestampUri.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($timestampUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($timestampUri.Query) -or
    -not [string]::IsNullOrEmpty($timestampUri.Fragment)) {
    throw 'TimestampUrl must be a credential-free HTTPS URL without query or fragment data.'
}
if ([string]::IsNullOrWhiteSpace($ExpectedPublisher) -or $ExpectedPublisher.Length -gt 512 -or $ExpectedPublisher -match '[\r\n]') {
    throw 'ExpectedPublisher is invalid.'
}
if ([string]::IsNullOrWhiteSpace($SigningCertificatePath) -or
    -not [System.IO.Path]::IsPathFullyQualified($SigningCertificatePath) -or
    [System.IO.Path]::GetExtension($SigningCertificatePath) -ine '.pfx' -or
    -not (Test-Path -LiteralPath $SigningCertificatePath -PathType Leaf)) {
    throw 'A trusted Authenticode certificate file is required; self-signed fallback is prohibited.'
}
$fullCertificatePath = [System.IO.Path]::GetFullPath($SigningCertificatePath)
if ([string]::IsNullOrWhiteSpace($env:MODELHUB_WINDOWS_SIGN_CERT_PASSWORD)) {
    throw 'MODELHUB_WINDOWS_SIGN_CERT_PASSWORD must be supplied by the release secret store.'
}
Assert-NoReparseAncestor -Path $fullOutputRoot

$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot 'src/ModelHub.Windows/ModelHub.Windows.csproj'
$metadata = Get-ProjectReleaseMetadata -ProjectPath $project
if ($metadata.Version -ne $ApprovedVersion -or
    $metadata.FileVersion -ne "$ApprovedVersion.$ApprovedBuild" -or
    $metadata.InformationalVersion -ne "$ApprovedVersion+build.$ApprovedBuild") {
    throw 'The project version metadata does not match the approved 1.10.0 build 67 release.'
}
if ($metadata.VelopackVersion -ne $ApprovedVelopackVersion) {
    throw "The project Velopack package must be pinned to $ApprovedVelopackVersion."
}
if (@($metadata.RuntimeIdentifiers -split ';') -notcontains $Runtime) {
    throw 'The requested runtime is not declared by the project.'
}

$architecture = if ($Runtime -eq 'win-x64') { 'x64' } else { 'arm64' }
$packId = "com.local.modelhub.windows.$architecture"
$channel = "win-$architecture"
$artifactRoot = Join-Path $fullOutputRoot "stable/$Version/build-$Build/$Runtime"
if (Test-Path -LiteralPath $artifactRoot) {
    throw 'The exact release artifact directory already exists; overwrite and mixed-build packaging are blocked.'
}
Assert-NoDowngrade -Root $fullOutputRoot -TargetRuntime $Runtime -TargetChannel $channel -TargetVersion ([version]$Version)

if ($DryRun) {
    [ordered]@{
        DryRun = $true
        ProducesArtifacts = $false
        Version = $Version
        Build = $Build
        Runtime = $Runtime
        Architecture = $architecture
        PackId = $packId
        Channel = $channel
        VelopackVersion = $metadata.VelopackVersion
        CertificateProvided = $true
        CertificatePathRecorded = $false
        PasswordRecorded = $false
        TimestampAuthority = $timestampUri.GetLeftPart([System.UriPartial]::Authority)
    } | ConvertTo-Json -Compress | Write-Output
    return
}

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
if (-not $isWindowsHost) {
    throw 'Trusted public Windows packaging must run on Windows with signtool; use -DryRun for offline validation.'
}
$null = Get-Command signtool -ErrorAction Stop
$null = Get-Command Import-PfxCertificate -ErrorAction Stop
Assert-VelopackToolVersion -ExpectedVersion $ApprovedVelopackVersion

$stagingRoot = Join-Path $fullOutputRoot ".modelhub-staging-$Runtime-$([Guid]::NewGuid().ToString('N'))"
$publishDirectory = Join-Path $stagingRoot 'work/publish'
$releaseDirectory = Join-Path $stagingRoot 'release'
$createdOutputRoot = -not (Test-Path -LiteralPath $fullOutputRoot)
$completed = $false
$newCertificateThumbprints = @()
$secureCertificatePassword = $null
try {
    $certificateStore = 'Cert:\CurrentUser\My'
    $beforeThumbprints = @(
        Get-ChildItem -LiteralPath $certificateStore |
            ForEach-Object { [string]$_.Thumbprint }
    )
    $certificatePasswordText = [string]$env:MODELHUB_WINDOWS_SIGN_CERT_PASSWORD
    $secureCertificatePassword = ConvertTo-SecureString $certificatePasswordText -AsPlainText -Force
    $certificatePasswordText = $null
    $env:MODELHUB_WINDOWS_SIGN_CERT_PASSWORD = $null
    $importedCertificates = @(
        Import-PfxCertificate -FilePath $fullCertificatePath `
            -CertStoreLocation $certificateStore `
            -Password $secureCertificatePassword `
            -Exportable:$false
    )
    $newCertificateThumbprints = @(
        $importedCertificates |
            Where-Object { $beforeThumbprints -notcontains [string]$_.Thumbprint } |
            ForEach-Object { [string]$_.Thumbprint }
    )
    $signingCertificate = $importedCertificates |
        Where-Object {
            $_.HasPrivateKey -and
            ([string]$_.Subject).Equals($ExpectedPublisher, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First 1
    if ($null -eq $signingCertificate) {
        throw 'The PFX does not contain a private-key certificate matching ExpectedPublisher.'
    }
    if ([string]$signingCertificate.Subject -eq [string]$signingCertificate.Issuer) {
        throw 'A self-signed certificate cannot be used for public packaging.'
    }
    if ($signingCertificate.NotBefore -gt [DateTime]::UtcNow -or $signingCertificate.NotAfter -le [DateTime]::UtcNow) {
        throw 'The Authenticode signing certificate is outside its validity period.'
    }
    $enhancedKeyUsage = $signingCertificate.Extensions |
        Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        Select-Object -First 1
    if ($null -eq $enhancedKeyUsage -or
        $null -eq ($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' } | Select-Object -First 1)) {
        throw 'The trusted certificate must contain the Code Signing enhanced key usage.'
    }
    $signingThumbprint = [string]$signingCertificate.Thumbprint

    New-Item -ItemType Directory -Path $publishDirectory, $releaseDirectory -Force | Out-Null
    & dotnet publish $project -c Release -r $Runtime --self-contained true --no-restore `
        -p:Version=$Version `
        -p:FileVersion="$Version.$Build" `
        -p:InformationalVersion="$Version+build.$Build" `
        -o $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

    $mainExecutable = Join-Path $publishDirectory $MainExe
    if (-not (Test-Path -LiteralPath $mainExecutable -PathType Leaf)) {
        throw 'The expected ModelHub.Windows.exe was not published.'
    }
    $publishedExecutables = @(Get-ChildItem -LiteralPath $publishDirectory -Filter '*.exe' -File -Recurse)
    if ($publishedExecutables.Count -eq 0) { throw 'The publish directory contains no Windows executable.' }
    foreach ($publishedExecutable in $publishedExecutables) {
        Assert-PeMachine -Path $publishedExecutable.FullName -TargetArchitecture $architecture
        Invoke-SignAndVerify -Path $publishedExecutable.FullName -CertificateThumbprint $signingThumbprint -Publisher $ExpectedPublisher -TimestampAuthority $timestampUri
    }

    & vpk pack --channel $channel --runtime $Runtime --packId $packId --packVersion $Version `
        --packDir $publishDirectory --mainExe $MainExe --outputDir $releaseDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Velopack packaging failed.' }

    $packages = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.nupkg' -File)
    if ($packages.Count -eq 0 -or @($packages | Where-Object { -not $_.Name.StartsWith("$packId-", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw 'Velopack package identity or architecture is inconsistent with the requested release lane.'
    }
    $setups = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*-Setup.exe' -File)
    if ($setups.Count -ne 1) { throw 'Velopack must produce exactly one Setup executable per architecture.' }
    Assert-PeMachine -Path $setups[0].FullName -TargetArchitecture $architecture

    $publicExecutables = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.exe' -File -Recurse)
    if ($publicExecutables.Count -eq 0) { throw 'Velopack produced no public executable to sign.' }
    foreach ($publicExecutable in $publicExecutables) {
        Invoke-SignAndVerify -Path $publicExecutable.FullName -CertificateThumbprint $signingThumbprint -Publisher $ExpectedPublisher -TimestampAuthority $timestampUri
    }

    Write-IntegrityMetadata -StagingRoot $stagingRoot -ReleaseDirectory $releaseDirectory `
        -ReleaseVersion $Version -ReleaseBuild $Build -ReleaseRuntime $Runtime `
        -ReleaseArchitecture $architecture -ReleasePackId $packId -ReleaseChannel $channel `
        -VelopackVersion $metadata.VelopackVersion -Publisher $ExpectedPublisher -TimestampAuthority $timestampUri

    $privateWorkDirectory = Join-Path $stagingRoot 'work'
    Remove-Item -LiteralPath $privateWorkDirectory -Recurse -Force
    $artifactParent = Split-Path -Parent $artifactRoot
    New-Item -ItemType Directory -Path $artifactParent -Force | Out-Null
    Move-Item -LiteralPath $stagingRoot -Destination $artifactRoot
    $completed = $true
    Write-Output "Created trusted Windows release family: $artifactRoot"
}
finally {
    if (-not $completed -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    if (-not $completed -and $createdOutputRoot -and (Test-Path -LiteralPath $fullOutputRoot)) {
        $remaining = @(Get-ChildItem -LiteralPath $fullOutputRoot -Force)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $fullOutputRoot -Force }
    }
    foreach ($thumbprint in $newCertificateThumbprints) {
        $certificateItem = Join-Path 'Cert:\CurrentUser\My' $thumbprint
        if (Test-Path -LiteralPath $certificateItem) {
            Remove-Item -LiteralPath $certificateItem -Force
        }
    }
    if ($null -ne $secureCertificatePassword) {
        $secureCertificatePassword.Dispose()
    }
}
