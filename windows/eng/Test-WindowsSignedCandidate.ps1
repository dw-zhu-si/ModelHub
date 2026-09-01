[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('win-x64', 'win-arm64')] [string] $Runtime,
    [Parameter(Mandatory = $true)] [string] $ArtifactRoot,
    [Parameter(Mandatory = $true)] [string] $OutputRoot,
    [string] $ExpectedPublisher = 'CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Version = '1.10.0'
$Build = 67

function Test-SafePathIsFullyQualified {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if ($env:OS -eq 'Windows_NT') {
        return $Path -match '^[A-Za-z]:[\\/]'
    }
    return [System.IO.Path]::IsPathRooted($Path)
}

function Resolve-SafeAbsolutePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ParameterName
    )
    if (-not (Test-SafePathIsFullyQualified -Path $Path)) {
        throw "$ParameterName must be an absolute path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $root) {
        throw "$ParameterName must not be a filesystem root."
    }
    return $fullPath
}

function Find-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitsRoot -PathType Container)) {
        throw 'Windows SDK signtool.exe is unavailable.'
    }
    $architectureOrder = if ($Runtime -eq 'win-arm64') { @('arm64', 'x64') } else { @('x64') }
    foreach ($architecture in $architectureOrder) {
        $candidate = Get-ChildItem -LiteralPath $kitsRoot -Filter 'signtool.exe' -File -Recurse |
            Where-Object { $_.FullName -match "\\$architecture\\signtool\.exe$" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) { return $candidate.FullName }
    }
    throw 'Windows SDK signtool.exe is unavailable for this runner.'
}

function Assert-TrustedSignature {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $SignTool
    )
    & $SignTool verify /pa /all /v $Path | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'signtool trust verification failed.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'The Authenticode signature is not valid under Windows trust policy.'
    }
    if (-not ([string]$signature.SignerCertificate.Subject).Equals($ExpectedPublisher, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Authenticode publisher does not match SignPath Foundation.'
    }
    if ([string]$signature.SignerCertificate.Subject -eq [string]$signature.SignerCertificate.Issuer) {
        throw 'A self-signed certificate is not accepted.'
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw 'The signed candidate has no trusted timestamp.'
    }
    return $signature
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Signed Windows acceptance must run on Windows.'
}
$expectedArchitecture = if ($Runtime -eq 'win-x64') { 'X64' } else { 'Arm64' }
$actualArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if (-not $actualArchitecture.Equals($expectedArchitecture, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The runner architecture $actualArchitecture does not match $Runtime. Emulation is not accepted."
}

$fullArtifactRoot = Resolve-SafeAbsolutePath -Path $ArtifactRoot -ParameterName 'ArtifactRoot'
$fullOutputRoot = Resolve-SafeAbsolutePath -Path $OutputRoot -ParameterName 'OutputRoot'
if (-not (Test-Path -LiteralPath $fullArtifactRoot -PathType Container)) { throw 'ArtifactRoot does not exist.' }
if (Test-Path -LiteralPath $fullOutputRoot) { throw 'OutputRoot already exists; overwrite is blocked.' }
New-Item -ItemType Directory -Path $fullOutputRoot | Out-Null

$runtimeRoot = Join-Path $fullArtifactRoot $Runtime
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw "The $Runtime artifact directory is missing." }
$setups = @(Get-ChildItem -LiteralPath $runtimeRoot -Filter '*-Setup.exe' -File -Recurse)
if ($setups.Count -ne 1) { throw "Expected exactly one $Runtime Setup executable." }
$setup = $setups[0].FullName
$signTool = Find-SignTool
$setupSignature = Assert-TrustedSignature -Path $setup -SignTool $signTool

$defender = Get-MpComputerStatus -ErrorAction Stop
if (-not [bool]$defender.AntivirusEnabled -or -not [bool]$defender.AntispywareEnabled) {
    throw 'Microsoft Defender antivirus is not enabled on the acceptance runner.'
}
$defenderStartedAt = [DateTimeOffset]::UtcNow
Start-MpScan -ScanType CustomScan -ScanPath $setup -ErrorAction Stop

$installRoot = Join-Path $env:LOCALAPPDATA "modelhub-acceptance-$Runtime-$([Guid]::NewGuid().ToString('N'))"
$installLog = Join-Path $fullOutputRoot 'install.log'
$uninstallLog = Join-Path $fullOutputRoot 'uninstall.log'
$nativeReceipt = Join-Path $fullOutputRoot 'native-runtime.json'
$uiProcess = $null
try {
    $install = Start-Process -FilePath $setup `
        -ArgumentList @('--silent', '--installto', "`"$installRoot`"", '--log', "`"$installLog`"") `
        -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "Velopack installation failed with exit code $($install.ExitCode)." }

    $currentRoot = Join-Path $installRoot 'current'
    $installedExecutable = Join-Path $currentRoot 'ModelHub.Windows.exe'
    $updateExecutable = Join-Path $installRoot 'Update.exe'
    if (-not (Test-Path -LiteralPath $installedExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $updateExecutable -PathType Leaf)) {
        throw 'The installed Velopack layout is incomplete.'
    }
    $installedSignature = Assert-TrustedSignature -Path $installedExecutable -SignTool $signTool

    & (Join-Path $PSScriptRoot 'Test-WindowsNativePublish.ps1') `
        -Runtime $Runtime -PublishRoot $currentRoot -ReceiptPath $nativeReceipt
    if ($LASTEXITCODE -ne 0) { throw 'The installed native runtime probe failed.' }

    $uiProcess = Start-Process -FilePath $installedExecutable -PassThru
    Start-Sleep -Seconds 8
    if ($uiProcess.HasExited) {
        throw "The installed ModelHub UI exited during startup with code $($uiProcess.ExitCode)."
    }
    Stop-Process -Id $uiProcess.Id -Force
    $uiProcess.WaitForExit()
    $uiProcess = $null

    Start-MpScan -ScanType CustomScan -ScanPath $installRoot -ErrorAction Stop
    $detections = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object {
        $_.InitialDetectionTime -ge $defenderStartedAt.UtcDateTime -and
        (@($_.Resources) -join "`n") -match [regex]::Escape($installRoot)
    })
    if ($detections.Count -gt 0) { throw 'Microsoft Defender reported a threat in the installed candidate.' }

    $uninstall = Start-Process -FilePath $updateExecutable `
        -ArgumentList @('--silent', '--log', "`"$uninstallLog`"", 'uninstall') `
        -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) { throw "Velopack uninstall failed with exit code $($uninstall.ExitCode)." }
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $installRoot); $attempt++) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $installRoot) { throw 'Velopack uninstall left the task-owned installation directory behind.' }

    $result = [ordered]@{
        SchemaVersion = 1
        Product = 'ModelHub.Windows'
        Version = $Version
        Build = $Build
        Runtime = $Runtime
        NativeOSArchitecture = $actualArchitecture
        SetupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
        Publisher = [string]$setupSignature.SignerCertificate.Subject
        Timestamped = $null -ne $setupSignature.TimeStamperCertificate
        InstalledPublisher = [string]$installedSignature.SignerCertificate.Subject
        DefenderEnabled = [bool]$defender.AntivirusEnabled
        DefenderDetections = 0
        Install = 'passed'
        NativeRuntimeProbe = 'passed'
        UIStartup = 'passed'
        Uninstall = 'passed'
        SmartScreenInteractive = 'requires_separate_interactive_evidence'
        UACInteractive = 'requires_separate_interactive_evidence'
        CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $fullOutputRoot 'acceptance-result.json'),
        ($result | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "Signed native $Runtime acceptance passed; interactive SmartScreen/UAC evidence remains separate."
}
finally {
    if ($null -ne $uiProcess -and -not $uiProcess.HasExited) {
        Stop-Process -Id $uiProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $installRoot) {
        $cleanupUpdater = Join-Path $installRoot 'Update.exe'
        if (Test-Path -LiteralPath $cleanupUpdater -PathType Leaf) {
            Start-Process -FilePath $cleanupUpdater -ArgumentList @('--silent', 'uninstall') -Wait -ErrorAction SilentlyContinue | Out-Null
        }
        if (Test-Path -LiteralPath $installRoot) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force
        }
    }
}
