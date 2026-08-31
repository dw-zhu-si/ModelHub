using System.Text;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;
using ModelHub.Windows.ViewModels;

namespace ModelHub.Windows.Tests;

public sealed class WindowsManagementParityViewModelTests
{
    [Fact]
    public async Task SubscriptionImportSearchSelectionAndLatencyAreOfflineTestable()
    {
        using var fixture = new Fixture(subscriptionPayload: "proxies:\n  - name: Taiwan 01\n    type: ss\n    server: node.example\n    port: 443\n  - name: Japan 02\n    type: vmess\n    server: node2.example\n    port: 443\n");
        fixture.ViewModel.SubscriptionName = "owned";
        fixture.ViewModel.SubscriptionUrl = "https://subscription.example/list";
        fixture.ViewModel.MihomoProxyGroup = "GLOBAL";

        await fixture.ViewModel.ImportSubscriptionCommand.ExecuteAsync(null);

        Assert.Equal(2, fixture.State.Snapshot().Nodes.Count);
        Assert.Equal(string.Empty, fixture.ViewModel.SubscriptionUrl);
        fixture.ViewModel.NodeSearch = "Japan";
        Assert.Single(fixture.ViewModel.Nodes);
        var node = fixture.ViewModel.Nodes[0];
        await fixture.ViewModel.SelectNodeCommand.ExecuteAsync(node.Id);
        Assert.Equal(("GLOBAL", "Japan 02"), fixture.Mihomo!.LastSelection);
        await fixture.ViewModel.TestNodeCommand.ExecuteAsync(node.Id);
        Assert.Contains("42 ms", fixture.ViewModel.Status, StringComparison.Ordinal);
        Assert.True(fixture.State.Snapshot().Nodes.Single(candidate => candidate.Name == "Japan 02").IsSelected);
    }

    [Fact]
    public async Task SelectorFailureKeepsThePreviousNodeAndSkipsTheLatencyProbe()
    {
        using var fixture = new Fixture(
            subscriptionPayload: "proxies:\n  - name: Taiwan 01\n    type: ss\n    server: node.example\n    port: 443\n  - name: Japan 02\n    type: vmess\n    server: node2.example\n    port: 443\n",
            failNodeSelection: true);
        fixture.ViewModel.SubscriptionName = "owned";
        fixture.ViewModel.SubscriptionUrl = "https://subscription.example/list";
        fixture.ViewModel.MihomoProxyGroup = "GLOBAL";
        await fixture.ViewModel.ImportSubscriptionCommand.ExecuteAsync(null);
        var japan = fixture.State.Snapshot().Nodes.Single(node => node.Name == "Japan 02");

        await fixture.ViewModel.TestNodeCommand.ExecuteAsync(japan.Id);

        Assert.True(fixture.State.Snapshot().Nodes.Single(node => node.Name == "Taiwan 01").IsSelected);
        Assert.False(fixture.State.Snapshot().Nodes.Single(node => node.Name == "Japan 02").IsSelected);
        Assert.Equal(0, fixture.NodeProbeCount);
        Assert.Contains("原选择保持不变", fixture.ViewModel.Status, StringComparison.Ordinal);
    }

    [Fact]
    public void ExactAssignmentRouteAndEndpointEditingPersistAndFailClosed()
    {
        using var fixture = new Fixture();
        fixture.ViewModel.SelectedAssignmentModel = Assert.Single(fixture.ViewModel.Models);
        fixture.ViewModel.SelectedAssignmentNode = Assert.Single(fixture.ViewModel.Nodes);
        fixture.ViewModel.AssignModelToNodeCommand.Execute(null);
        Assert.Single(fixture.State.Snapshot().ModelNodeAssignments!);
        Assert.Contains("不会回退到直连", fixture.ViewModel.AssignmentStatus, StringComparison.Ordinal);

        fixture.ViewModel.RouteAlias = "fast-chat";
        fixture.ViewModel.SelectedRouteModel = fixture.ViewModel.Models[0];
        fixture.ViewModel.SelectedRouteStrategy = ModelRouteStrategy.WeightedRandom;
        fixture.ViewModel.RouteWeight = 3;
        fixture.ViewModel.AddRouteTargetCommand.Execute(null);
        fixture.ViewModel.SaveRouteCommand.Execute(null);
        Assert.Equal(ModelRouteStrategy.WeightedRandom, Assert.Single(fixture.State.Snapshot().Routes!).Strategy);

        fixture.ViewModel.SelectedEndpointProvider = fixture.ViewModel.Providers[0];
        fixture.ViewModel.SelectedEndpointKind = GatewayEndpointKind.VideoGeneration;
        fixture.ViewModel.EndpointPath = "/v1/videos";
        fixture.ViewModel.EndpointIsAsynchronous = true;
        fixture.ViewModel.EndpointPollPath = "/v1/tasks/{task_id}";
        fixture.ViewModel.SaveEndpointPathCommand.Execute(null);
        var endpoint = Assert.Single(fixture.State.Snapshot().ProviderEndpointPaths!);
        Assert.True(endpoint.IsAsynchronous);
        Assert.Equal(GatewayEndpointKind.VideoGeneration, endpoint.Endpoint);
    }

    [Fact]
    public async Task BatchHealthAndConfigurationExchangeCompleteWithoutSecrets()
    {
        using var fixture = new Fixture(withHealth: true);
        await fixture.ViewModel.StartBatchHealthVerificationCommand.ExecuteAsync(null);
        Assert.Equal(100, fixture.ViewModel.HealthProgress);
        Assert.Contains("完成", fixture.ViewModel.HealthVerificationStatus, StringComparison.Ordinal);

        var path = Path.Combine(fixture.Directory, "export.json");
        fixture.ViewModel.ConfigurationFilePath = path;
        await fixture.ViewModel.ExportConfigurationCommand.ExecuteAsync(null);
        var exported = await File.ReadAllTextAsync(path);
        Assert.DoesNotContain("secret", exported, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("subscription.example", exported, StringComparison.OrdinalIgnoreCase);
        await fixture.ViewModel.ImportConfigurationCommand.ExecuteAsync(null);
        Assert.Contains("已导入", fixture.ViewModel.Status, StringComparison.Ordinal);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly FakeVault _vault = new();
        private readonly LocalGatewayService _gateway;
        public string Directory { get; } = Path.Combine(Path.GetTempPath(), $"modelhub-management-{Guid.NewGuid():N}");
        public ConfigurationState State { get; }
        public MainWindowViewModel ViewModel { get; }
        public FakeMihomoRuntimeController? Mihomo { get; }
        public int NodeProbeCount { get; private set; }

        public Fixture(string? subscriptionPayload = null, bool withHealth = false, bool failNodeSelection = false)
        {
            var providerId = Guid.NewGuid();
            var initial = ModelHubConfiguration.Empty with
            {
                Providers = [new ProviderConfiguration(providerId, "Provider", new Uri("https://provider.example/"), true, [new ModelDefinition("model-1", "Model 1", "text")])],
                Nodes = [new NodeConfiguration(Guid.NewGuid(), "Local node", new Uri("http://127.0.0.1:7890"), true)]
            };
            State = new ConfigurationState(initial);
            var store = new ConfigurationStore(Directory);
            store.Save(initial);
            _gateway = new LocalGatewayService(State.Snapshot, _vault);
            Mihomo = subscriptionPayload is null ? null : new FakeMihomoRuntimeController(failNodeSelection);
            ViewModel = new MainWindowViewModel(State, store, _vault, _gateway, new HealthMonitor(), new NodeLatencyTester(),
                subscriptionClient: subscriptionPayload is null ? null : new FakeSubscriptionClient(subscriptionPayload),
                mihomoRuntime: (IMihomoRuntimeStatus?)Mihomo ?? new UnavailableMihomoStatus(),
                batchHealthVerifier: withHealth ? new BatchHealthVerifier(new HealthyProbe(), 2) : null,
                configurationExchange: new ConfigurationImportExport(),
                nodeLatencyProbe: (node, _) =>
                {
                    NodeProbeCount++;
                    return Task.FromResult(new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, 42, "available", "offline fake"));
                });
        }

        public void Dispose()
        {
            ViewModel.Dispose();
            _gateway.DisposeAsync().AsTask().GetAwaiter().GetResult();
            if (System.IO.Directory.Exists(Directory)) { System.IO.Directory.Delete(Directory, true); }
        }
    }

    private sealed class FakeSubscriptionClient(string payload) : IProxySubscriptionClient
    {
        public Task<byte[]> FetchAsync(Uri source, CancellationToken cancellationToken) =>
            Task.FromResult(Encoding.UTF8.GetBytes(payload));
    }

    private sealed class HealthyProbe : IModelHealthProbe
    {
        public Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken) =>
            Task.FromResult(new ModelHealthObservation(ModelHealthOutcome.Healthy, TimeSpan.FromMilliseconds(8), "offline-test"));
    }

    public sealed class FakeMihomoRuntimeController(bool failSelection) : IMihomoRuntimeController
    {
        public bool IsReady { get; private set; } = true;
        public (string Group, string Node)? LastSelection { get; private set; }

        public Task StartAsync(MihomoRuntimeOptions options, CancellationToken cancellationToken = default)
        {
            IsReady = true;
            return Task.CompletedTask;
        }

        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            IsReady = false;
            return Task.CompletedTask;
        }

        public Task SelectNodeAsync(string selectorGroup, string nodeName, CancellationToken cancellationToken = default)
        {
            if (failSelection)
            {
                throw new MihomoRuntimeUnavailableException("offline fake rejection");
            }

            LastSelection = (selectorGroup, nodeName);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _secrets = [];
        public void Write(string targetName, string secret) => _secrets[targetName] = secret;
        public string? Read(string targetName) => _secrets.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _secrets.ContainsKey(targetName);
        public void Delete(string targetName) => _secrets.Remove(targetName);
    }
}
