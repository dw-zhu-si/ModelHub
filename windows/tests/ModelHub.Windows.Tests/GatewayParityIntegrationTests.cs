using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class GatewayParityIntegrationTests
{
    private const string GatewayToken = "gateway-integration-test-token";
    private const string ProviderSecret = "provider-integration-test-secret";

    [Fact]
    public void ConfigurationPersistsRoutesEndpointPathsAndAssignmentsWhileOldSchemaRemainsValid()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var provider = Provider("model-a");
            var node = new NodeConfiguration(
                Guid.NewGuid(),
                "selected node",
                new Uri("http://127.0.0.1:7890/"),
                true);
            var configuration = Configuration(
                ReservePort(),
                [provider],
                [node],
                [new ModelRouteDefinition(
                    "smart-model",
                    true,
                    ModelRouteStrategy.PriorityFailover,
                    [new ModelRouteTarget(provider.Id, "model-a")])],
                [new ProviderEndpointPath(
                    provider.Id,
                    GatewayEndpointKind.VideoGeneration,
                    "/v1/videos/create",
                    IsAsynchronous: true,
                    PollPathTemplate: "/v1/videos/tasks/{task_id}",
                    TaskIdentifierField: GatewayTaskIdentifierField.DataTaskId)],
                [new ModelNodeAssignment(provider.Id, "model-a", node.Id)]);
            var store = new ConfigurationStore(directory);

            store.Save(configuration);
            var loaded = store.Load();

            Assert.True(ConfigurationStore.IsSafe(loaded));
            Assert.Equal("smart-model", Assert.Single(loaded.Routes!).Alias);
            Assert.Equal(
                "/v1/videos/create",
                Assert.Single(loaded.ProviderEndpointPaths!).Path);
            Assert.Equal(node.Id, Assert.Single(loaded.ModelNodeAssignments!).NodeId);

            var conflict = configuration with
            {
                Routes = [new ModelRouteDefinition(
                    "model-a",
                    true,
                    ModelRouteStrategy.PriorityFailover,
                    [new ModelRouteTarget(provider.Id, "model-a")])],
            };
            Assert.False(ConfigurationStore.IsSafe(conflict));

            var duplicatedEndpoint = configuration with
            {
                ProviderEndpointPaths =
                [
                    configuration.ProviderEndpointPaths!.Single(),
                    configuration.ProviderEndpointPaths!.Single(),
                ],
            };
            Assert.False(ConfigurationStore.IsSafe(duplicatedEndpoint));

            var unsafePoll = configuration with
            {
                ProviderEndpointPaths = [configuration.ProviderEndpointPaths!.Single() with
                {
                    PollPathTemplate = "https://attacker.example/{task_id}",
                }],
            };
            Assert.False(ConfigurationStore.IsSafe(unsafePoll));

            var duplicatedAssignment = configuration with
            {
                ModelNodeAssignments =
                [
                    configuration.ModelNodeAssignments!.Single(),
                    configuration.ModelNodeAssignments!.Single(),
                ],
            };
            Assert.False(ConfigurationStore.IsSafe(duplicatedAssignment));

            var oldDirectory = CreateTemporaryDirectory();
            try
            {
                File.WriteAllText(
                    Path.Combine(oldDirectory, "configuration.json"),
                    "{\"schemaVersion\":1,\"gateway\":{\"port\":11435,\"tokenCredentialTarget\":\"ModelHub.Windows/GatewayToken\"},\"providers\":[],\"nodes\":[],\"credentialPools\":[]}");
                var oldConfiguration = new ConfigurationStore(oldDirectory).Load();
                Assert.True(ConfigurationStore.IsSafe(oldConfiguration));
                Assert.Empty(oldConfiguration.Routes ?? []);
                Assert.Empty(oldConfiguration.ProviderEndpointPaths ?? []);
                Assert.Empty(oldConfiguration.ModelNodeAssignments ?? []);
            }
            finally
            {
                Directory.Delete(oldDirectory, recursive: true);
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AliasRouteFailsOverAndRewritesModelBeforeUpstreamSend()
    {
        var port = ReservePort();
        var first = Provider("model-first", "first");
        var second = Provider("model-second", "second");
        var configuration = Configuration(
            port,
            [first, second],
            [],
            [new ModelRouteDefinition(
                "smart-model",
                true,
                ModelRouteStrategy.PriorityFailover,
                [
                    new ModelRouteTarget(first.Id, "model-first", Priority: 0),
                    new ModelRouteTarget(second.Id, "model-second", Priority: 1),
                ])]);
        var vault = Vault(configuration);
        string? observedModel = null;
        string? observedHost = null;
        var handler = new RecordingHandler(async (request, cancellationToken) =>
        {
            observedHost = request.RequestUri?.Host;
            using var body = JsonDocument.Parse(
                await request.Content!.ReadAsByteArrayAsync(cancellationToken));
            observedModel = body.RootElement.GetProperty("model").GetString();
            return JsonResponse(HttpStatusCode.OK, "{\"choices\":[]}");
        });
        await using var gateway = new LocalGatewayService(
            () => configuration,
            vault,
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()),
            routeState: (providerId, _) => providerId == first.Id
                ? RouteTargetState.Unavailable
                : RouteTargetState.Available);
        await gateway.StartAsync();

        using var client = AuthorizedClient(port);
        using var response = await client.PostAsync(
            "/v1/chat/completions",
            JsonContent("{\"model\":\"smart-model\",\"messages\":[]}"));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("model-second", observedModel);
        Assert.Equal("second.example.com", observedHost);
    }

    [Fact]
    public async Task AssignedModelWithUnavailableProxyReturns503AndNeverDirectConnects()
    {
        var port = ReservePort();
        var provider = Provider("model-a");
        var node = new NodeConfiguration(
            Guid.NewGuid(),
            "selected node",
            new Uri("http://127.0.0.1:7890/"),
            true);
        var configuration = Configuration(
            port,
            [provider],
            [node],
            assignments: [new ModelNodeAssignment(provider.Id, "model-a", node.Id)]);
        var handler = new RecordingHandler((_, _) =>
            Task.FromResult(JsonResponse(HttpStatusCode.OK, "{\"data\":[]}")));
        await using var gateway = new LocalGatewayService(
            () => configuration,
            Vault(configuration),
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()),
            mihomoRuntime: new RuntimeStatus(isReady: false));
        await gateway.StartAsync();

        using var client = AuthorizedClient(port);
        using var response = await client.PostAsync(
            "/v1/embeddings",
            JsonContent("{\"model\":\"model-a\",\"input\":\"hello\"}"));
        var responseBody = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Contains("proxy_route_blocked", responseBody, StringComparison.Ordinal);
        Assert.Empty(handler.Paths);
    }

    [Fact]
    public async Task PerRequestSelectorCanRouteAnAssignedNodeThatIsNotTheGlobalUiSelectionAndHoldsItsLease()
    {
        var port = ReservePort();
        var provider = Provider("model-a") with
        {
            Models =
            [
                new ModelDefinition("model-a", "model-a", "text"),
                new ModelDefinition("model-b", "model-b", "text"),
            ],
        };
        var selectedNode = new NodeConfiguration(
            Guid.NewGuid(),
            "Taiwan 01",
            new Uri("http://127.0.0.1:7890/"),
            true,
            "GLOBAL");
        var assignedNode = new NodeConfiguration(
            Guid.NewGuid(),
            "Taiwan 02",
            new Uri("http://127.0.0.1:7890/"),
            false,
            "GLOBAL");
        var configuration = Configuration(
            port,
            [provider],
            [selectedNode, assignedNode],
            assignments:
            [
                new ModelNodeAssignment(provider.Id, "model-a", selectedNode.Id),
                new ModelNodeAssignment(provider.Id, "model-b", assignedNode.Id),
            ]);
        var runtime = new LeaseObservingRuntime();
        var handler = new BlockingGatewayHandler();
        await using var gateway = new LocalGatewayService(
            () => configuration,
            Vault(configuration),
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()),
            mihomoRuntime: runtime);
        await gateway.StartAsync();
        using var client = AuthorizedClient(port);

        var responseTask = client.PostAsync(
            "/v1/embeddings",
            JsonContent("{\"model\":\"model-b\",\"input\":\"hello\"}"));
        await handler.RequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(1));

        Assert.Equal(1, runtime.ActiveLeaseCount);
        Assert.Equal("GLOBAL", runtime.SelectorGroup);
        Assert.Equal("Taiwan 02", runtime.NodeName);

        handler.Complete();
        using var response = await responseTask.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await runtime.LeaseReleased.Task.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(0, runtime.ActiveLeaseCount);
    }

    [Fact]
    public async Task TransparentAndAdvancedJsonEndpointsUseExplicitMappings()
    {
        var port = ReservePort();
        var provider = Provider("model-a");
        var configuration = Configuration(port, [provider]);
        var handler = new RecordingHandler((request, _) => Task.FromResult(
            request.RequestUri?.AbsolutePath switch
            {
                "/v1/embeddings" => JsonResponse(HttpStatusCode.OK, "{\"data\":[{\"embedding\":[0.1]}]}"),
                "/v1/rerank" => JsonResponse(HttpStatusCode.OK, "{\"results\":[]}"),
                "/v1/responses" => JsonResponse(HttpStatusCode.OK, "{\"id\":\"response-1\"}"),
                "/v1/messages" => JsonResponse(HttpStatusCode.OK, "{\"id\":\"native-1\"}"),
                _ => JsonResponse(HttpStatusCode.NotFound, "{}"),
            }));
        await using var gateway = new LocalGatewayService(
            () => configuration,
            Vault(configuration),
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(port);

        foreach (var endpoint in new[]
        {
            "/v1/embeddings",
            "/v1/rerank",
            "/v1/responses",
            "/v1/messages",
        })
        {
            using var response = await client.PostAsync(
                endpoint,
                JsonContent("{\"model\":\"model-a\",\"input\":\"hello\"}"));
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        }

        Assert.Equal(
            ["/v1/embeddings", "/v1/rerank", "/v1/responses", "/v1/messages"],
            handler.Paths);
    }

    [Fact]
    public async Task AsyncVideoUsesConfiguredTaskIdProtocolAndReturnsOnlyRealArtifact()
    {
        var port = ReservePort();
        var provider = Provider("video-model");
        var configuration = Configuration(
            port,
            [provider],
            endpoints: [new ProviderEndpointPath(
                provider.Id,
                GatewayEndpointKind.VideoGeneration,
                "/v1/videos/create",
                IsAsynchronous: true,
                PollPathTemplate: "/v1/videos/tasks/{task_id}",
                TaskIdentifierField: GatewayTaskIdentifierField.DataTaskId)]);
        var handler = new RecordingHandler((request, _) => Task.FromResult(
            request.RequestUri?.AbsolutePath switch
            {
                "/v1/videos/create" => JsonResponse(
                    HttpStatusCode.OK,
                    "{\"data\":{\"task_id\":\"video-task-1\",\"id\":\"ordinary-id\"},\"request_id\":\"request-1\"}"),
                "/v1/videos/tasks/video-task-1" => JsonResponse(
                    HttpStatusCode.OK,
                    "{\"status\":\"completed\",\"data\":[{\"url\":\"https://cdn.example.com/video.mp4\"}]}"),
                _ => JsonResponse(HttpStatusCode.NotFound, "{}"),
            }));
        await using var gateway = new LocalGatewayService(
            () => configuration,
            Vault(configuration),
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()),
            asyncMediaPollInterval: TimeSpan.Zero);
        await gateway.StartAsync();

        using var client = AuthorizedClient(port);
        using var response = await client.PostAsync(
            "/v1/videos",
            JsonContent("{\"model\":\"video-model\",\"prompt\":\"test\"}"));
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("succeeded", body, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("https://cdn.example.com/video.mp4", body, StringComparison.Ordinal);
        Assert.Equal(
            ["/v1/videos/create", "/v1/videos/tasks/video-task-1"],
            handler.Paths);
    }

    [Fact]
    public async Task MultipartEditAndTranscriptionSelectProviderFromSafeModelFieldAndRewriteAlias()
    {
        var port = ReservePort();
        var provider = Provider("real-media-model");
        var configuration = Configuration(
            port,
            [provider],
            routes: [new ModelRouteDefinition(
                "media-alias",
                true,
                ModelRouteStrategy.PriorityFailover,
                [new ModelRouteTarget(provider.Id, "real-media-model")])]);
        var upstreamBodies = new List<string>();
        var handler = new RecordingHandler(async (request, cancellationToken) =>
        {
            upstreamBodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return request.RequestUri?.AbsolutePath == "/v1/images/edits"
                ? JsonResponse(
                    HttpStatusCode.OK,
                    "{\"data\":[{\"url\":\"https://cdn.example.com/edit.png\"}]}")
                : JsonResponse(HttpStatusCode.OK, "{\"text\":\"transcribed\"}");
        });
        await using var gateway = new LocalGatewayService(
            () => configuration,
            Vault(configuration),
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(port);

        using var editContent = new MultipartFormDataContent();
        editContent.Add(new StringContent("media-alias"), "model");
        editContent.Add(new ByteArrayContent([1, 2, 3]), "image", "input.png");
        editContent.Last().Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
        using var edit = await client.PostAsync("/v1/images/edits", editContent);

        using var transcriptionContent = new MultipartFormDataContent();
        transcriptionContent.Add(new StringContent("media-alias"), "model");
        transcriptionContent.Add(new ByteArrayContent([4, 5, 6]), "file", "voice.wav");
        transcriptionContent.Last().Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue("audio/wav");
        using var transcription = await client.PostAsync(
            "/v1/audio/transcriptions",
            transcriptionContent);

        Assert.Equal(HttpStatusCode.OK, edit.StatusCode);
        Assert.Contains("succeeded", await edit.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(HttpStatusCode.OK, transcription.StatusCode);
        Assert.Contains("transcribed", await transcription.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(["/v1/images/edits", "/v1/audio/transcriptions"], handler.Paths);
        Assert.All(upstreamBodies, body =>
        {
            Assert.Contains("real-media-model", body, StringComparison.Ordinal);
            Assert.DoesNotContain("media-alias", body, StringComparison.Ordinal);
        });
    }

    private static ProviderConfiguration Provider(string modelId, string hostPrefix = "provider") => new(
        Guid.NewGuid(),
        hostPrefix,
        new Uri($"https://{hostPrefix}.example.com/"),
        true,
        [new ModelDefinition(modelId, modelId, "text")]);

    private static ModelHubConfiguration Configuration(
        int port,
        IReadOnlyList<ProviderConfiguration> providers,
        IReadOnlyList<NodeConfiguration>? nodes = null,
        IReadOnlyList<ModelRouteDefinition>? routes = null,
        IReadOnlyList<ProviderEndpointPath>? endpoints = null,
        IReadOnlyList<ModelNodeAssignment>? assignments = null) => new(
            1,
            new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget),
            providers,
            nodes ?? [],
            [],
            routes,
            endpoints,
            assignments);

    private static FakeCredentialVault Vault(ModelHubConfiguration configuration)
    {
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, GatewayToken);
        foreach (var provider in configuration.Providers)
        {
            vault.Write(provider.CredentialTarget, ProviderSecret);
        }
        return vault;
    }

    private static HttpClient AuthorizedClient(int port)
    {
        var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/") };
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", GatewayToken);
        return client;
    }

    private static StringContent JsonContent(string json) =>
        new(json, Encoding.UTF8, "application/json");

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) => new(status)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            "modelhub-gateway-parity-tests",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed class RuntimeStatus(bool isReady) : IMihomoRuntimeStatus
    {
        public bool IsReady { get; } = isReady;
    }

    private sealed class LeaseObservingRuntime : IMihomoRuntimeStatus, IMihomoNodeSelectionCoordinator
    {
        private int _activeLeaseCount;

        public bool IsReady => true;
        public int ActiveLeaseCount => Volatile.Read(ref _activeLeaseCount);
        public string? SelectorGroup { get; private set; }
        public string? NodeName { get; private set; }
        public TaskCompletionSource LeaseReleased { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<IMihomoNodeSelectionLease> AcquireNodeSelectionAsync(
            string selectorGroup,
            string nodeName,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SelectorGroup = selectorGroup;
            NodeName = nodeName;
            Interlocked.Increment(ref _activeLeaseCount);
            return Task.FromResult<IMihomoNodeSelectionLease>(new ObservedSelectionLease(
                () =>
                {
                    if (Interlocked.Decrement(ref _activeLeaseCount) == 0)
                    {
                        LeaseReleased.TrySetResult();
                    }
                }));
        }
    }

    private sealed class ObservedSelectionLease(Action release) : IMihomoNodeSelectionLease
    {
        private Action? _release = release;

        public bool SelectionChanged => true;

        public void Dispose() => Interlocked.Exchange(ref _release, null)?.Invoke();
    }

    private sealed class BlockingGatewayHandler : HttpMessageHandler
    {
        private readonly TaskCompletionSource<HttpResponseMessage> _response =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource RequestStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Complete() => _response.TrySetResult(
            JsonResponse(HttpStatusCode.OK, "{\"data\":[]}"));

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestStarted.TrySetResult();
            return await _response.Task.WaitAsync(cancellationToken);
        }
    }

    private sealed class FakeCredentialVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _entries = new(StringComparer.Ordinal);

        public void Write(string targetName, string secret) => _entries[targetName] = secret;
        public string? Read(string targetName) => _entries.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _entries.ContainsKey(targetName);
        public void Delete(string targetName) => _entries.Remove(targetName);
    }

    private sealed class RecordingHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        public List<string> Paths { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Paths.Add(request.RequestUri?.AbsolutePath ?? string.Empty);
            return response(request, cancellationToken);
        }
    }
}
