using ModelHub.Windows.Models;
using ModelHub.Windows.Services;
using ModelHub.Windows.ViewModels;

namespace ModelHub.Windows.Tests;

public sealed class MihomoControllerSettingsTests
{
    [Fact]
    public void ConfigurationStoreRoundTripsOnlyNonSecretMihomoSettings()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var configuration = ModelHubConfiguration.Empty with
            {
                Mihomo = new MihomoSettings(
                    @"C:\Program Files\mihomo\mihomo.exe",
                    @"C:\Users\owner\AppData\Local\ModelHub\mihomo.yaml",
                    19090,
                    "GLOBAL"),
            };
            var store = new ConfigurationStore(directory);

            store.Save(configuration);
            var loaded = store.Load();
            var persistedJson = File.ReadAllText(Path.Combine(directory, "configuration.json"));

            Assert.Equal(configuration.Mihomo, loaded.Mihomo);
            Assert.Contains("mihomo.exe", persistedJson, StringComparison.Ordinal);
            Assert.Contains("GLOBAL", persistedJson, StringComparison.Ordinal);
            Assert.DoesNotContain("controller-secret-value", persistedJson, StringComparison.Ordinal);
            Assert.DoesNotContain("subscription.example", persistedJson, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task GenericConfigurationExportOmitsMachineLocalMihomoSettingsAndSecrets()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var configuration = ModelHubConfiguration.Empty with
            {
                Mihomo = new MihomoSettings(
                    @"C:\SensitiveLocalPath\mihomo.exe",
                    @"C:\SensitiveLocalPath\mihomo.yaml",
                    19090,
                    "PRIVATE-GROUP"),
            };
            var exportPath = Path.Combine(directory, "export.json");

            await new ConfigurationImportExport().ExportAsync(configuration, exportPath);
            var exportedJson = await File.ReadAllTextAsync(exportPath);

            Assert.DoesNotContain("SensitiveLocalPath", exportedJson, StringComparison.Ordinal);
            Assert.DoesNotContain("PRIVATE-GROUP", exportedJson, StringComparison.Ordinal);
            Assert.DoesNotContain("ControllerAuthorizationToken", exportedJson, StringComparison.Ordinal);
            Assert.DoesNotContain("subscription", exportedJson, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("mihomo.exe", @"C:\ModelHub\mihomo.yaml", 19090, "GLOBAL")]
    [InlineData(@"C:\ModelHub\mihomo.exe", "mihomo.yaml", 19090, "GLOBAL")]
    [InlineData(@"C:\ModelHub\mihomo.exe", @"C:\ModelHub\mihomo.yaml", 80, "GLOBAL")]
    [InlineData(@"C:\ModelHub\mihomo.exe", @"C:\ModelHub\mihomo.yaml", 19090, "bad\rgroup")]
    [InlineData(@"C:\ModelHub\..\evil.exe", @"C:\ModelHub\mihomo.yaml", 19090, "GLOBAL")]
    [InlineData(@"\\server\share\mihomo.exe", @"C:\ModelHub\mihomo.yaml", 19090, "GLOBAL")]
    [InlineData(@"\\?\C:\ModelHub\mihomo.exe", @"C:\ModelHub\mihomo.yaml", 19090, "GLOBAL")]
    public void ConfigurationStoreRejectsUnsafeMihomoSettings(
        string executablePath,
        string configurationPath,
        int controllerPort,
        string proxyGroup)
    {
        var configuration = ModelHubConfiguration.Empty with
        {
            Mihomo = new MihomoSettings(
                executablePath,
                configurationPath,
                controllerPort,
                proxyGroup),
        };

        Assert.False(ConfigurationStore.IsSafe(configuration));
    }

    [Fact]
    public void ViewModelSavesControllerSecretOnlyInCredentialVaultAndClearsTheMaskedInput()
    {
        using var fixture = new Fixture();
        fixture.ViewModel.MihomoExecutablePath = @"C:\Program Files\mihomo\mihomo.exe";
        fixture.ViewModel.MihomoConfigurationPath = @"C:\Users\owner\AppData\Local\ModelHub\mihomo.yaml";
        fixture.ViewModel.MihomoControllerPort = 19090;
        fixture.ViewModel.MihomoProxyGroup = "GLOBAL";
        fixture.ViewModel.SubscriptionUrl = "https://subscription.example/private-token";
        fixture.ViewModel.MihomoControllerSecret = "x";

        fixture.ViewModel.SaveMihomoSettingsCommand.Execute(null);
        fixture.ViewModel.SaveMihomoControllerSecretCommand.Execute(null);

        Assert.Equal(
            "x",
            fixture.Vault.Read(MihomoSettings.ControllerSecretCredentialTarget));
        Assert.Equal(string.Empty, fixture.ViewModel.MihomoControllerSecret);
        Assert.Equal("GLOBAL", fixture.State.Snapshot().Mihomo?.ProxyGroup);
        var persistedJson = File.ReadAllText(Path.Combine(fixture.Directory, "configuration.json"));
        Assert.DoesNotContain("\"mihomoControllerSecret\"", persistedJson, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("subscription.example", persistedJson, StringComparison.Ordinal);
        Assert.DoesNotContain("private-token", fixture.ViewModel.Status, StringComparison.Ordinal);
        Assert.DoesNotContain("Controller secret: x", fixture.ViewModel.MihomoStatus, StringComparison.Ordinal);
    }

    [Fact]
    public void WhitespaceControllerSecretIsNotWrittenAndExistingSecretCanBeExplicitlyDeleted()
    {
        using var fixture = new Fixture();
        fixture.ViewModel.MihomoControllerSecret = "   ";

        fixture.ViewModel.SaveMihomoControllerSecretCommand.Execute(null);

        Assert.False(fixture.Vault.Exists(MihomoSettings.ControllerSecretCredentialTarget));
        Assert.Contains("1–1024", fixture.ViewModel.MihomoStatus, StringComparison.Ordinal);

        fixture.Vault.Write(
            MihomoSettings.ControllerSecretCredentialTarget,
            "controller-secret-value");
        fixture.ViewModel.DeleteMihomoControllerSecretCommand.Execute(null);

        Assert.False(fixture.Vault.Exists(MihomoSettings.ControllerSecretCredentialTarget));
        Assert.Equal(string.Empty, fixture.ViewModel.MihomoControllerSecret);
    }

    [Theory]
    [InlineData(" leading")]
    [InlineData("trailing ")]
    [InlineData("line\nbreak")]
    public void ControllerSecretWithBoundaryWhitespaceOrControlCharactersIsRejected(
        string secret)
    {
        using var fixture = new Fixture();
        fixture.ViewModel.MihomoControllerSecret = secret;

        fixture.ViewModel.SaveMihomoControllerSecretCommand.Execute(null);

        Assert.False(fixture.Vault.Exists(MihomoSettings.ControllerSecretCredentialTarget));
    }

    [Fact]
    public void ControllerSecretOverCharacterLimitIsRejected()
    {
        using var fixture = new Fixture();
        fixture.ViewModel.MihomoControllerSecret = new string('x', 1025);

        fixture.ViewModel.SaveMihomoControllerSecretCommand.Execute(null);

        Assert.False(fixture.Vault.Exists(MihomoSettings.ControllerSecretCredentialTarget));
    }

    [Fact]
    public async Task StartMihomoReadsTheControllerSecretWithoutEverRefillingTheUi()
    {
        using var fixture = new Fixture(new MihomoSettings(
            @"C:\Program Files\mihomo\mihomo.exe",
            @"C:\Users\owner\AppData\Local\ModelHub\mihomo.yaml",
            19090,
            "GLOBAL"));
        fixture.Vault.Write(
            MihomoSettings.ControllerSecretCredentialTarget,
            "controller-secret-value");

        await fixture.ViewModel.StartMihomoCommand.ExecuteAsync(null);

        Assert.NotNull(fixture.Runtime.StartOptions);
        Assert.Equal(
            "controller-secret-value",
            fixture.Runtime.StartOptions!.ControllerAuthorizationToken);
        Assert.Equal(string.Empty, fixture.ViewModel.MihomoControllerSecret);
        Assert.DoesNotContain("controller-secret-value", fixture.ViewModel.MihomoStatus, StringComparison.Ordinal);
        Assert.DoesNotContain("controller-secret-value", fixture.ViewModel.Status, StringComparison.Ordinal);
    }

    [Fact]
    public void ConstructorRestoresOnlyNonSecretMihomoSettings()
    {
        using var fixture = new Fixture(new MihomoSettings(
            @"C:\Tools\mihomo.exe",
            @"C:\ModelHub\mihomo.yaml",
            19091,
            "Proxy"));
        fixture.Vault.Write(
            MihomoSettings.ControllerSecretCredentialTarget,
            "controller-secret-value");

        using var restored = fixture.CreateAdditionalViewModel();

        Assert.Equal(@"C:\Tools\mihomo.exe", restored.MihomoExecutablePath);
        Assert.Equal(@"C:\ModelHub\mihomo.yaml", restored.MihomoConfigurationPath);
        Assert.Equal(19091, restored.MihomoControllerPort);
        Assert.Equal("Proxy", restored.MihomoProxyGroup);
        Assert.Equal(string.Empty, restored.MihomoControllerSecret);
        Assert.DoesNotContain("controller-secret-value", restored.Status, StringComparison.Ordinal);
    }

    [Fact]
    public async Task GenericConfigurationImportPreservesMachineLocalMihomoSettingsAndVaultSecret()
    {
        var localSettings = new MihomoSettings(
            @"C:\Tools\mihomo.exe",
            @"C:\ModelHub\mihomo.yaml",
            19091,
            "Proxy");
        using var fixture = new Fixture(localSettings);
        fixture.Vault.Write(
            MihomoSettings.ControllerSecretCredentialTarget,
            "controller-secret-value");
        var importPath = Path.Combine(fixture.Directory, "generic-import.json");
        await new ConfigurationImportExport().ExportAsync(
            ModelHubConfiguration.Empty,
            importPath);
        fixture.ViewModel.ConfigurationFilePath = importPath;

        await fixture.ViewModel.ImportConfigurationCommand.ExecuteAsync(null);

        Assert.Equal(localSettings, fixture.State.Snapshot().Mihomo);
        Assert.Equal(
            "controller-secret-value",
            fixture.Vault.Read(MihomoSettings.ControllerSecretCredentialTarget));
        Assert.Contains("保持不变", fixture.ViewModel.Status, StringComparison.Ordinal);
    }

    private static string CreateTemporaryDirectory()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"modelhub-mihomo-settings-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return directory;
    }

    private sealed class Fixture : IDisposable
    {
        private readonly LocalGatewayService _gateway;
        private readonly ConfigurationStore _store;

        public Fixture(MihomoSettings? mihomo = null)
        {
            Directory = CreateTemporaryDirectory();
            _store = new ConfigurationStore(Directory);
            var initial = ModelHubConfiguration.Empty with { Mihomo = mihomo };
            _store.Save(initial);
            State = new ConfigurationState(initial);
            Vault = new FakeVault();
            Runtime = new CapturingMihomoRuntime();
            _gateway = new LocalGatewayService(State.Snapshot, Vault, mihomoRuntime: Runtime);
            ViewModel = CreateViewModel();
        }

        public string Directory { get; }
        public ConfigurationState State { get; }
        public FakeVault Vault { get; }
        public CapturingMihomoRuntime Runtime { get; }
        public MainWindowViewModel ViewModel { get; }

        public MainWindowViewModel CreateAdditionalViewModel() => CreateViewModel();

        private MainWindowViewModel CreateViewModel() => new(
            State,
            _store,
            Vault,
            _gateway,
            new HealthMonitor(),
            new NodeLatencyTester(),
            mihomoRuntime: Runtime);

        public void Dispose()
        {
            ViewModel.Dispose();
            _gateway.DisposeAsync().AsTask().GetAwaiter().GetResult();
            if (System.IO.Directory.Exists(Directory))
            {
                System.IO.Directory.Delete(Directory, recursive: true);
            }
        }
    }

    private sealed class CapturingMihomoRuntime : IMihomoRuntimeController
    {
        public bool IsReady { get; private set; }
        public MihomoRuntimeOptions? StartOptions { get; private set; }

        public Task StartAsync(
            MihomoRuntimeOptions options,
            CancellationToken cancellationToken = default)
        {
            StartOptions = options;
            IsReady = true;
            return Task.CompletedTask;
        }

        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            IsReady = false;
            return Task.CompletedTask;
        }

        public Task SelectNodeAsync(
            string selectorGroup,
            string nodeName,
            CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private sealed class FakeVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _values = [];

        public void Write(string targetName, string secret) => _values[targetName] = secret;
        public string? Read(string targetName) => _values.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _values.ContainsKey(targetName);
        public void Delete(string targetName) => _values.Remove(targetName);
    }
}
