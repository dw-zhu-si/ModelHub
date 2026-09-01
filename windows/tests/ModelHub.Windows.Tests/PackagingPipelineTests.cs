using System.Diagnostics;
using System.Xml.Linq;

namespace ModelHub.Windows.Tests;

public sealed class PackagingPipelineTests
{
    [Fact]
    public void ProjectAndPackagingLanePinTheSameReleaseAndVelopackVersions()
    {
        var windowsRoot = FindWindowsRoot();
        var project = XDocument.Load(Path.Combine(windowsRoot, "src", "ModelHub.Windows", "ModelHub.Windows.csproj"));
        var script = File.ReadAllText(Path.Combine(windowsRoot, "eng", "Package-Windows.ps1"));
        var propertyGroup = project.Root?.Elements("PropertyGroup").First();
        var velopack = project.Descendants("PackageReference")
            .Single(element => string.Equals((string?)element.Attribute("Include"), "Velopack", StringComparison.Ordinal));

        Assert.Equal("1.10.0", propertyGroup?.Element("Version")?.Value);
        Assert.Equal("1.10.0.67", propertyGroup?.Element("FileVersion")?.Value);
        Assert.Equal("1.10.0+build.67", propertyGroup?.Element("InformationalVersion")?.Value);
        Assert.Equal("false", propertyGroup?.Element("IncludeSourceRevisionInInformationalVersion")?.Value);
        Assert.Equal("ModelHub", propertyGroup?.Element("Product")?.Value);
        Assert.Equal("野路子工作室", propertyGroup?.Element("Company")?.Value);
        Assert.Equal("1.2.0", (string?)velopack.Attribute("Version"));
        Assert.Contains("$ApprovedVersion = '1.10.0'", script, StringComparison.Ordinal);
        Assert.Contains("$ApprovedBuild = 67", script, StringComparison.Ordinal);
        Assert.Contains("$ApprovedVelopackVersion = '1.2.0'", script, StringComparison.Ordinal);
    }

    [Fact]
    public void ArchitecturesHaveIndependentStableIdentityChannelAndOutput()
    {
        var script = File.ReadAllText(Path.Combine(FindWindowsRoot(), "eng", "Package-Windows.ps1"));

        Assert.Contains("com.local.modelhub.windows.$architecture", script, StringComparison.Ordinal);
        Assert.Contains("$channel = \"win-$architecture\"", script, StringComparison.Ordinal);
        Assert.Contains("Join-Path $stagingRoot 'release'", script, StringComparison.Ordinal);
        Assert.Contains("build-$Build/$Runtime", script, StringComparison.Ordinal);
        Assert.Contains("Assert-PeMachine", script, StringComparison.Ordinal);
    }

    [Fact]
    public void PublicPackagingHasNoUnsignedModeAndProducesNonSecretIntegrityMetadata()
    {
        var script = File.ReadAllText(Path.Combine(FindWindowsRoot(), "eng", "Package-Windows.ps1"));

        Assert.DoesNotContain("RequireTrustedSignature", script, StringComparison.Ordinal);
        Assert.DoesNotContain("New-SelfSignedCertificate", script, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("https://timestamp.digicert.com", script, StringComparison.Ordinal);
        Assert.Contains("Invoke-SignAndVerify", script, StringComparison.Ordinal);
        Assert.Contains("$publishedExecutables", script, StringComparison.Ordinal);
        Assert.Contains("Get-AuthenticodeSignature", script, StringComparison.Ordinal);
        Assert.Contains("TimeStamperCertificate", script, StringComparison.Ordinal);
        Assert.Contains("Import-PfxCertificate", script, StringComparison.Ordinal);
        Assert.DoesNotContain("$afterCertificates", script, StringComparison.Ordinal);
        Assert.Contains("$importedCertificates |", script, StringComparison.Ordinal);
        Assert.DoesNotContain("/p $env:MODELHUB_WINDOWS_SIGN_CERT_PASSWORD", script, StringComparison.Ordinal);
        Assert.Contains("release-manifest.json", script, StringComparison.Ordinal);
        Assert.Contains("SHA256SUMS", script, StringComparison.Ordinal);
        Assert.Contains("Remove-Item -LiteralPath $privateWorkDirectory", script, StringComparison.Ordinal);
        Assert.DoesNotContain("MODELHUB_WINDOWS_SIGN_CERT_PASSWORD = '", script, StringComparison.Ordinal);
        Assert.DoesNotContain("MODELHUB_WINDOWS_SIGN_CERT_PASSWORD = \"", script, StringComparison.Ordinal);
    }

    [Fact]
    public void GitHubTrustedPackagingUsesSignPathOriginVerificationWithoutPrivateKeyMaterial()
    {
        var windowsRoot = FindWindowsRoot();
        var workflow = File.ReadAllText(Path.Combine(
            Directory.GetParent(windowsRoot)!.FullName,
            ".github",
            "workflows",
            "windows-release.yml"));

        Assert.Contains("signpath/github-action-submit-signing-request@c92b958760219087e01f8d67a1669ed57afe2627", workflow, StringComparison.Ordinal);
        Assert.Contains("SIGNPATH_API_TOKEN", workflow, StringComparison.Ordinal);
        Assert.Contains("SIGNPATH_ORGANIZATION_ID", workflow, StringComparison.Ordinal);
        Assert.Contains("SIGNPATH_PROJECT_SLUG", workflow, StringComparison.Ordinal);
        Assert.Contains("SIGNPATH_PUBLISH_ARTIFACT_CONFIGURATION_SLUG", workflow, StringComparison.Ordinal);
        Assert.Contains("SIGNPATH_SETUP_ARTIFACT_CONFIGURATION_SLUG", workflow, StringComparison.Ordinal);
        Assert.Contains("Prepare-SignPathWindows.ps1", workflow, StringComparison.Ordinal);
        Assert.Contains("Package-SignPathWindows.ps1", workflow, StringComparison.Ordinal);
        Assert.Contains("Finalize-SignPathWindows.ps1", workflow, StringComparison.Ordinal);
        Assert.DoesNotContain("WINDOWS_AUTHENTICODE_PFX_BASE64", workflow, StringComparison.Ordinal);
        Assert.DoesNotContain("WINDOWS_AUTHENTICODE_PASSWORD", workflow, StringComparison.Ordinal);
        Assert.DoesNotContain("Import-PfxCertificate", workflow, StringComparison.Ordinal);
        Assert.DoesNotContain("New-SelfSignedCertificate", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("windows-11-arm", workflow, StringComparison.Ordinal);
        Assert.Contains("Test-WindowsNativePublish.ps1", workflow, StringComparison.Ordinal);
        Assert.Contains("Test-WindowsSignedCandidate.ps1", workflow, StringComparison.Ordinal);
        Assert.Contains("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093", workflow, StringComparison.Ordinal);
    }

    [Fact]
    public void NativeWindowsAcceptanceRequiresTrustedSignaturesDefenderAndUninstall()
    {
        var windowsRoot = FindWindowsRoot();
        var nativeProbe = File.ReadAllText(Path.Combine(windowsRoot, "eng", "Test-WindowsNativePublish.ps1"));
        var signedAcceptance = File.ReadAllText(Path.Combine(windowsRoot, "eng", "Test-WindowsSignedCandidate.ps1"));
        var program = File.ReadAllText(Path.Combine(windowsRoot, "src", "ModelHub.Windows", "Program.cs"));

        Assert.Contains("--acceptance-probe-output", program, StringComparison.Ordinal);
        Assert.Contains("Emulation is not accepted", nativeProbe, StringComparison.Ordinal);
        Assert.Contains("Get-AuthenticodeSignature", signedAcceptance, StringComparison.Ordinal);
        Assert.Contains("TimeStamperCertificate", signedAcceptance, StringComparison.Ordinal);
        Assert.Contains("Get-MpComputerStatus", signedAcceptance, StringComparison.Ordinal);
        Assert.Contains("Start-MpScan", signedAcceptance, StringComparison.Ordinal);
        Assert.Contains("'uninstall'", signedAcceptance, StringComparison.Ordinal);
        Assert.Contains("requires_separate_interactive_evidence", signedAcceptance, StringComparison.Ordinal);
    }

    [Fact]
    public void SignPathPolicyAndArtifactConfigurationsConstrainWhatMayBeSigned()
    {
        var windowsRoot = FindWindowsRoot();
        var repositoryRoot = Directory.GetParent(windowsRoot)!.FullName;
        var policy = File.ReadAllText(Path.Combine(repositoryRoot, "docs", "CODE_SIGNING_POLICY.md"));
        var publishConfiguration = File.ReadAllText(Path.Combine(
            repositoryRoot,
            ".signpath",
            "artifact-configurations",
            "modelhub-published-binaries.xml"));
        var setupConfiguration = File.ReadAllText(Path.Combine(
            repositoryRoot,
            ".signpath",
            "artifact-configurations",
            "modelhub-velopack-setups.xml"));

        Assert.Contains("Free code signing provided by SignPath.io, certificate by SignPath Foundation.", policy, StringComparison.Ordinal);
        Assert.Contains("人工审核中", policy, StringComparison.Ordinal);
        Assert.Contains("dw-zhu-si", policy, StringComparison.Ordinal);
        Assert.Contains("ModelHub.Windows.exe", publishConfiguration, StringComparison.Ordinal);
        Assert.Contains("ModelHub.Windows.dll", publishConfiguration, StringComparison.Ordinal);
        Assert.DoesNotContain("*.dll", publishConfiguration, StringComparison.Ordinal);
        Assert.Contains("win-x64/*-Setup.exe", setupConfiguration, StringComparison.Ordinal);
        Assert.Contains("win-arm64/*-Setup.exe", setupConfiguration, StringComparison.Ordinal);
        Assert.Contains("authenticode-sign", publishConfiguration, StringComparison.Ordinal);
        Assert.Contains("authenticode-sign", setupConfiguration, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DryRunFailsClosedBeforeToolOrArtifactWorkWhenCertificateIsMissing()
    {
        var missingCertificate = Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.pfx");
        var result = await InvokeDryRunAsync(
            runtime: "win-x64",
            version: "1.10.0",
            build: "67",
            outputRoot: Path.Combine(Path.GetTempPath(), $"modelhub-packaging-{Guid.NewGuid():N}"),
            certificatePath: missingCertificate);

        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("trusted Authenticode certificate file is required", result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(result.OutputRoot));
    }

    [Theory]
    [InlineData("win-x64", "1.9.9", "67", "Version must match the approved release")]
    [InlineData("win-arm64", "1.10.0", "66", "Build must match the approved release")]
    public async Task DryRunRejectsUnapprovedVersionOrBuild(
        string runtime,
        string version,
        string build,
        string expectedError)
    {
        var result = await InvokeDryRunAsync(
            runtime,
            version,
            build,
            Path.Combine(Path.GetTempPath(), $"modelhub-packaging-{Guid.NewGuid():N}"),
            Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.pfx"));

        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains(expectedError, result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(result.OutputRoot));
    }

    [Fact]
    public async Task DryRunRejectsRelativeOutputPathBeforeCreatingAnything()
    {
        var relative = $"relative-modelhub-output-{Guid.NewGuid():N}";
        var result = await InvokeDryRunAsync(
            "win-x64",
            "1.10.0",
            "67",
            relative,
            Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.pfx"));

        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("OutputRoot must be an absolute path", result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(Path.Combine(Directory.GetCurrentDirectory(), relative)));
    }

    [Fact]
    public async Task DryRunRejectsUnsupportedRuntimeBeforeCreatingAnything()
    {
        var outputRoot = Path.Combine(Path.GetTempPath(), $"modelhub-packaging-{Guid.NewGuid():N}");
        var result = await InvokeDryRunAsync(
            "win-x86",
            "1.10.0",
            "67",
            outputRoot,
            Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.pfx"));

        Assert.NotEqual(0, result.ExitCode);
        Assert.False(Directory.Exists(outputRoot));
    }

    [Fact]
    public async Task DryRunRejectsRelativeCertificatePathBeforeCreatingAnything()
    {
        var outputRoot = Path.Combine(Path.GetTempPath(), $"modelhub-packaging-{Guid.NewGuid():N}");
        var result = await InvokeDryRunAsync(
            "win-arm64",
            "1.10.0",
            "67",
            outputRoot,
            $"relative-certificate-{Guid.NewGuid():N}.pfx");

        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("trusted Authenticode certificate file is required", result.Output, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(outputRoot));
    }

    [Fact]
    public async Task DryRunBlocksDowngradeInTheSameRuntimeChannelWithoutChangingExistingArtifacts()
    {
        var temporaryRoot = OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath();
        var outputRoot = Path.Combine(temporaryRoot, $"modelhub-downgrade-{Guid.NewGuid():N}");
        var existingRelease = Path.Combine(outputRoot, "stable", "1.11.0", "build-68", "win-x64");
        var existingManifest = Path.Combine(existingRelease, "release-manifest.json");
        var certificate = Path.Combine(temporaryRoot, $"modelhub-placeholder-{Guid.NewGuid():N}.pfx");
        const string manifest = "{\"Version\":\"1.11.0\",\"Runtime\":\"win-x64\",\"Channel\":\"win-x64\"}";
        try
        {
            Directory.CreateDirectory(existingRelease);
            await File.WriteAllTextAsync(existingManifest, manifest);
            await File.WriteAllBytesAsync(certificate, [0x00]);

            var result = await InvokeDryRunAsync("win-x64", "1.10.0", "67", outputRoot, certificate);

            Assert.NotEqual(0, result.ExitCode);
            Assert.Contains("newer win-x64 release already exists", result.Output, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("packaging is blocked", result.Output, StringComparison.OrdinalIgnoreCase);
            Assert.Equal(manifest, await File.ReadAllTextAsync(existingManifest));
            Assert.False(Directory.Exists(Path.Combine(outputRoot, "stable", "1.10.0")));
        }
        finally
        {
            File.Delete(certificate);
            if (Directory.Exists(outputRoot))
            {
                Directory.Delete(outputRoot, recursive: true);
            }
        }
    }

    [Theory]
    [InlineData("win-x64", "x64", "win-x64", "com.local.modelhub.windows.x64")]
    [InlineData("win-arm64", "arm64", "win-arm64", "com.local.modelhub.windows.arm64")]
    public async Task OfflineDryRunPlansEachArchitectureWithoutCreatingArtifacts(
        string runtime,
        string architecture,
        string channel,
        string packId)
    {
        var temporaryRoot = OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath();
        var certificate = Path.Combine(temporaryRoot, $"modelhub-placeholder-{Guid.NewGuid():N}.pfx");
        var outputRoot = Path.Combine(temporaryRoot, $"modelhub-dryrun-{Guid.NewGuid():N}");
        try
        {
            await File.WriteAllBytesAsync(certificate, [0x00]);
            var result = await InvokeDryRunAsync(runtime, "1.10.0", "67", outputRoot, certificate);

            Assert.True(
                result.ExitCode == 0,
                $"Packaging dry-run failed with exit code {result.ExitCode}:{Environment.NewLine}{result.Output}");
            Assert.Contains("\"ProducesArtifacts\":false", result.Output, StringComparison.Ordinal);
            Assert.Contains($"\"Architecture\":\"{architecture}\"", result.Output, StringComparison.Ordinal);
            Assert.Contains($"\"Channel\":\"{channel}\"", result.Output, StringComparison.Ordinal);
            Assert.Contains($"\"PackId\":\"{packId}\"", result.Output, StringComparison.Ordinal);
            Assert.DoesNotContain(certificate, result.Output, StringComparison.Ordinal);
            Assert.False(Directory.Exists(outputRoot));
        }
        finally
        {
            File.Delete(certificate);
        }
    }

    private static async Task<PowerShellResult> InvokeDryRunAsync(
        string runtime,
        string version,
        string build,
        string outputRoot,
        string certificatePath)
    {
        var executable = OperatingSystem.IsWindows() ? "powershell.exe" : "pwsh";
        var script = Path.Combine(FindWindowsRoot(), "eng", "Package-Windows.ps1");
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(script);
        startInfo.ArgumentList.Add("-Runtime");
        startInfo.ArgumentList.Add(runtime);
        startInfo.ArgumentList.Add("-Version");
        startInfo.ArgumentList.Add(version);
        startInfo.ArgumentList.Add("-Build");
        startInfo.ArgumentList.Add(build);
        startInfo.ArgumentList.Add("-OutputRoot");
        startInfo.ArgumentList.Add(outputRoot);
        startInfo.ArgumentList.Add("-SigningCertificatePath");
        startInfo.ArgumentList.Add(certificatePath);
        startInfo.ArgumentList.Add("-ExpectedPublisher");
        startInfo.ArgumentList.Add("CN=ModelHub Packaging Test");
        startInfo.ArgumentList.Add("-DryRun");
        startInfo.Environment["MODELHUB_WINDOWS_SIGN_CERT_PASSWORD"] = "offline-test-placeholder";

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("PowerShell could not be started.");
        var standardOutput = process.StandardOutput.ReadToEndAsync();
        var standardError = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("The packaging dry-run did not terminate within ten seconds.");
        }

        var output = string.Concat(await standardOutput, Environment.NewLine, await standardError);
        return new PowerShellResult(process.ExitCode, output, outputRoot);
    }

    private static string FindWindowsRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (File.Exists(Path.Combine(current.FullName, "eng", "Package-Windows.ps1")) &&
                Directory.Exists(Path.Combine(current.FullName, "src", "ModelHub.Windows")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException("The Windows project root could not be located.");
    }

    private sealed record PowerShellResult(int ExitCode, string Output, string OutputRoot);
}
