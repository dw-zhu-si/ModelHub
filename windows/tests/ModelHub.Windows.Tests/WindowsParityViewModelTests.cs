using System.Net;
using System.Net.Sockets;
using System.Text;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;
using ModelHub.Windows.ViewModels;

namespace ModelHub.Windows.Tests;

public sealed class WindowsParityViewModelTests
{
    [Theory]
    [InlineData(ProviderProtocol.OpenAICompatible)]
    [InlineData(ProviderProtocol.Anthropic)]
    [InlineData(ProviderProtocol.Gemini)]
    public void ProviderProtocolSelectionIsPersisted(ProviderProtocol protocol)
    {
        using var fixture = new Fixture();
        fixture.ViewModel.ProviderName = "provider";
        fixture.ViewModel.ProviderBaseUrl = "https://provider.example/";
        fixture.ViewModel.ProviderModelId = $"model-{protocol}";
        fixture.ViewModel.ProviderSecret = "developer-api-key";
        fixture.ViewModel.SelectedProviderProtocol = protocol;

        fixture.ViewModel.AddProviderCommand.Execute(null);

        Assert.Equal(protocol, Assert.Single(fixture.State.Snapshot().Providers).Protocol);
        Assert.Equal(string.Empty, fixture.ViewModel.ProviderSecret);
    }

    [Fact]
    public async Task DeveloperOAuthIsExplicitOneShotAndNeverDisplaysToken()
    {
        using var fixture = new Fixture(withOAuth: true);
        var port = ReservePort();
        fixture.ViewModel.OAuthClientId = "owned-desktop-client.apps.googleusercontent.com";
        fixture.ViewModel.OAuthCloudProject = "owned-cloud-project";
        fixture.ViewModel.OAuthRedirectUri = $"http://127.0.0.1:{port}/oauth/callback";

        await fixture.ViewModel.PrepareDeveloperOAuthCommand.ExecuteAsync(null);

        Assert.StartsWith("https://accounts.google.com/", fixture.Browser.OpenedUri!.AbsoluteUri, StringComparison.Ordinal);
        Assert.Equal(1, fixture.TokenHandler!.ExchangeCount);
        Assert.Equal(string.Empty, fixture.ViewModel.OAuthAuthorizationUrl);
        Assert.DoesNotContain("developer-access-token", fixture.ViewModel.Status, StringComparison.Ordinal);
        Assert.DoesNotContain("developer-access-token", fixture.ViewModel.GetType().GetProperties().Select(property => property.GetValue(fixture.ViewModel)?.ToString() ?? string.Empty));
        Assert.Contains("分离保存", fixture.ViewModel.Status, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DeveloperOAuthRejectsNonDesktopClientAndHasNoConsumerAutomationCommands()
    {
        using var fixture = new Fixture(withOAuth: true);
        fixture.ViewModel.OAuthClientId = "consumer-account";
        fixture.ViewModel.OAuthCloudProject = "owned-cloud-project";
        fixture.ViewModel.OAuthRedirectUri = "http://127.0.0.1:18443/oauth/callback";

        await fixture.ViewModel.PrepareDeveloperOAuthCommand.ExecuteAsync(null);

        Assert.Equal(string.Empty, fixture.ViewModel.OAuthAuthorizationUrl);
        Assert.Contains("Desktop client ID", fixture.ViewModel.Status, StringComparison.Ordinal);
        Assert.DoesNotContain(fixture.ViewModel.GetType().GetProperties(), property =>
            property.Name.Contains("ConsumerAccount", StringComparison.OrdinalIgnoreCase) ||
            property.Name.Contains("QuotaRotation", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstalledUpdateRequiresExplicitCheckDownloadAndRestart()
    {
        var engine = new FakeUpdateEngine(isInstalled: true);
        using var fixture = new Fixture(updateEngine: engine);

        Assert.True(fixture.ViewModel.CanCheckUpdates);
        Assert.Equal(0, engine.CheckCount);
        await fixture.ViewModel.CheckForUpdateCommand.ExecuteAsync(null);
        Assert.Equal(1, engine.CheckCount);
        Assert.Equal(0, engine.DownloadCount);
        Assert.True(fixture.ViewModel.CanDownloadUpdate);

        await fixture.ViewModel.DownloadUpdateCommand.ExecuteAsync(null);
        Assert.Equal(1, engine.DownloadCount);
        Assert.Equal(0, engine.ApplyCount);
        Assert.True(fixture.ViewModel.CanRestartToUpdate);

        fixture.ViewModel.RestartToUpdateCommand.Execute(null);
        Assert.Equal(1, engine.ApplyCount);
    }

    [Fact]
    public async Task PortableBuildDisablesUpdateWithoutCallingFeed()
    {
        var engine = new FakeUpdateEngine(isInstalled: false);
        using var fixture = new Fixture(updateEngine: engine);

        Assert.False(fixture.ViewModel.CanCheckUpdates);
        Assert.Contains("便携", fixture.ViewModel.UpdateStatus, StringComparison.Ordinal);
        await fixture.ViewModel.CheckForUpdateCommand.ExecuteAsync(null);
        Assert.Equal(0, engine.CheckCount);
    }

    private static Dictionary<string, string> ParseQuery(string query) => query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
        .Select(part => part.Split('=', 2)).ToDictionary(parts => Uri.UnescapeDataString(parts[0]), parts => Uri.UnescapeDataString(parts[1]), StringComparer.Ordinal);

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), $"modelhub-windows-vm-{Guid.NewGuid():N}");
        private readonly FakeVault _vault = new();
        private readonly LocalGatewayService _gateway;
        private readonly WindowsUpdateCoordinator _updates;
        public ConfigurationState State { get; }
        public TokenHandler? TokenHandler { get; }
        public FakeBrowser Browser { get; }
        public MainWindowViewModel ViewModel { get; }

        public Fixture(bool withOAuth = false, IWindowsUpdateEngine? updateEngine = null)
        {
            State = new ConfigurationState(ModelHubConfiguration.Empty);
            var store = new ConfigurationStore(_directory);
            _gateway = new LocalGatewayService(State.Snapshot, _vault);
            _updates = new WindowsUpdateCoordinator(updateEngine ?? new FakeUpdateEngine(false));
            if (withOAuth) { TokenHandler = new TokenHandler(); }
            Browser = new FakeBrowser();
            ViewModel = new MainWindowViewModel(State, store, _vault, _gateway, new HealthMonitor(), new NodeLatencyTester(), _updates, Browser,
                withOAuth ? registration => new WindowsDeveloperOAuth(registration, _vault, TokenHandler!, TimeSpan.FromSeconds(1)) : null);
        }

        public void Dispose()
        {
            ViewModel.Dispose();
            _gateway.DisposeAsync().AsTask().GetAwaiter().GetResult();
            _updates.Dispose();
            if (Directory.Exists(_directory)) { Directory.Delete(_directory, true); }
        }
    }

    private sealed class FakeVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _values = [];
        public void Write(string targetName, string secret) => _values[targetName] = secret;
        public string? Read(string targetName) => _values.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _values.ContainsKey(targetName);
        public void Delete(string targetName) => _values.Remove(targetName);
    }

    private sealed class TokenHandler : HttpMessageHandler
    {
        public int ExchangeCount { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            ExchangeCount += 1;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"access_token\":\"developer-access-token\",\"refresh_token\":\"developer-refresh-token\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/generative-language\"}", Encoding.UTF8, "application/json"),
            });
        }
    }

    private sealed class FakeBrowser : ISystemBrowserLauncher
    {
        public Uri? OpenedUri { get; private set; }
        public void Open(Uri uri)
        {
            OpenedUri = uri;
            var query = ParseQuery(uri.Query);
            var redirect = new Uri(query["redirect_uri"]);
            var callback = new UriBuilder(redirect) { Query = $"code=owned-code&state={Uri.EscapeDataString(query["state"])}" }.Uri;
            _ = Task.Run(async () =>
            {
                using var client = new HttpClient();
                using var response = await client.GetAsync(callback);
                response.EnsureSuccessStatusCode();
            });
        }
    }

    private sealed class FakeUpdateEngine(bool isInstalled) : IWindowsUpdateEngine
    {
        private readonly WindowsUpdateCandidate _candidate = new("1.10.1", 1024, new object());
        public bool IsInstalled { get; } = isInstalled;
        public int CheckCount { get; private set; }
        public int DownloadCount { get; private set; }
        public int ApplyCount { get; private set; }
        public Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken) { CheckCount += 1; return Task.FromResult<WindowsUpdateCandidate?>(_candidate); }
        public Task DownloadAsync(WindowsUpdateCandidate candidate, Action<int>? progress, CancellationToken cancellationToken) { DownloadCount += 1; progress?.Invoke(100); return Task.CompletedTask; }
        public void ApplyAndRestart(WindowsUpdateCandidate candidate) => ApplyCount += 1;
    }

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }
}
