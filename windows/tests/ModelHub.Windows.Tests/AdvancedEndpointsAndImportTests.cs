using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class AdvancedEndpointsAndImportTests
{
    private static readonly Uri ProviderBaseUri = new("https://provider.example.com/");
    private const string TestCredential = "test-provider-credential-value";

    [Fact]
    public async Task AdvancedJsonEndpointForwardsOnlyFixedProtocolPathAndBoundsResponse()
    {
        string? observedPath = null;
        string? observedAuthorization = null;
        var handler = new DelegateHandler(async (request, cancellationToken) =>
        {
            observedPath = request.RequestUri?.AbsolutePath;
            observedAuthorization = request.Headers.Authorization?.ToString();
            Assert.Equal("application/json", request.Content?.Headers.ContentType?.MediaType);
            Assert.Contains(
                "input",
                await request.Content!.ReadAsStringAsync(cancellationToken),
                StringComparison.Ordinal);
            return JsonResponse(HttpStatusCode.Accepted, "{\"data\":[0.1,0.2]}");
        });
        using var forwarder = new AdvancedEndpointForwarder(
            handler,
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024,
            maximumConcurrentRequests: 2,
            requestTimeout: TimeSpan.FromSeconds(1));
        using var content = new StringContent("{\"input\":\"hello\"}", Encoding.UTF8, "application/json");

        var response = await forwarder.ForwardAsync(new AdvancedForwardRequest(
            ProviderBaseUri,
            AdvancedEndpointKind.Embeddings,
            TestCredential,
            content));

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Equal("/v1/embeddings", observedPath);
        Assert.Equal($"Bearer {TestCredential}", observedAuthorization);
        Assert.Equal("{\"data\":[0.1,0.2]}", Encoding.UTF8.GetString(response.Body));
    }

    [Fact]
    public async Task AdvancedEndpointRejectsWrongContentTypeAndOversizedResponse()
    {
        string? observedPath = null;
        using var forwarder = new AdvancedEndpointForwarder(
            new DelegateHandler((request, _) =>
            {
                observedPath = request.RequestUri?.AbsolutePath;
                return Task.FromResult(JsonResponse(
                    HttpStatusCode.OK,
                    new string('x', 65)));
            }),
            maximumRequestBytes: 64,
            maximumResponseBytes: 64,
            maximumConcurrentRequests: 1,
            requestTimeout: TimeSpan.FromSeconds(1));
        using var wrongContent = new StringContent("not multipart", Encoding.UTF8, "text/plain");
        await Assert.ThrowsAsync<InvalidDataException>(() => forwarder.ForwardAsync(
            new AdvancedForwardRequest(
                ProviderBaseUri,
                AdvancedEndpointKind.AudioTranscription,
                TestCredential,
                wrongContent)));

        using var json = new StringContent("{}", Encoding.UTF8, "application/json");
        await Assert.ThrowsAsync<InvalidDataException>(() => forwarder.ForwardAsync(
            new AdvancedForwardRequest(
                ProviderBaseUri,
                AdvancedEndpointKind.Rerank,
                TestCredential,
                json)));
        Assert.Equal("/v1/rerank", observedPath);
    }

    [Fact]
    public async Task MultipartTranscriptionBuildsBoundedSafeUploadWithoutHeaderInjection()
    {
        string? observedMultipart = null;
        var handler = new DelegateHandler(async (request, cancellationToken) =>
        {
            Assert.Equal("/v1/audio/transcriptions", request.RequestUri?.AbsolutePath);
            Assert.Equal("multipart/form-data", request.Content?.Headers.ContentType?.MediaType);
            observedMultipart = await request.Content!.ReadAsStringAsync(cancellationToken);
            return JsonResponse(HttpStatusCode.OK, "{\"text\":\"ok\"}");
        });
        using var advanced = new AdvancedEndpointForwarder(handler);
        var multipart = new MultipartMediaForwarder(
            advanced,
            maximumFileBytes: 1_024,
            maximumTotalBytes: 2_048,
            maximumFiles: 2);
        var request = new MultipartMediaRequest(
            AdvancedEndpointKind.AudioTranscription,
            new Dictionary<string, string> { ["model"] = "whisper-test" },
            [new MultipartUpload("file", "voice.wav", "audio/wav", new byte[] { 1, 2, 3, 4 })]);

        var response = await multipart.ForwardAsync(ProviderBaseUri, TestCredential, request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("name=file", observedMultipart, StringComparison.Ordinal);
        Assert.Contains("filename=voice.wav", observedMultipart, StringComparison.Ordinal);

        var injected = request with
        {
            Files = [new MultipartUpload(
                "file",
                "voice.wav\r\nX-Injected: true",
                "audio/wav",
                new byte[] { 1 })],
        };
        await Assert.ThrowsAsync<InvalidDataException>(() => multipart.ForwardAsync(
            ProviderBaseUri,
            TestCredential,
            injected));
    }

    [Fact]
    public async Task MultipartImageEditUsesFixedPathAndAcceptsBoundedImageAndMask()
    {
        var handler = new DelegateHandler(async (request, cancellationToken) =>
        {
            Assert.Equal("/v1/images/edits", request.RequestUri?.AbsolutePath);
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Assert.Contains("name=image", body, StringComparison.Ordinal);
            Assert.Contains("name=mask", body, StringComparison.Ordinal);
            return JsonResponse(
                HttpStatusCode.OK,
                "{\"data\":[{\"url\":\"https://cdn.example.com/edit.png\"}]}");
        });
        using var advanced = new AdvancedEndpointForwarder(handler);
        var multipart = new MultipartMediaForwarder(
            advanced,
            maximumFileBytes: 1_024,
            maximumTotalBytes: 2_048,
            maximumFiles: 2);

        var response = await multipart.ForwardAsync(
            ProviderBaseUri,
            TestCredential,
            new MultipartMediaRequest(
                AdvancedEndpointKind.ImageEdit,
                new Dictionary<string, string> { ["model"] = "image-edit-test" },
                [
                    new MultipartUpload("image", "input.png", "image/png", new byte[] { 1, 2 }),
                    new MultipartUpload("mask", "mask.png", "image/png", new byte[] { 3, 4 }),
                ]));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task AsyncMediaUsesOnlyExplicitTaskIdAndPollsToRealHttpsArtifact()
    {
        var handler = new SequenceHandler(
            JsonResponse(HttpStatusCode.OK, "{\"data\":{\"task_id\":\"video-task-1\"},\"request_id\":\"req-1\"}"),
            JsonResponse(HttpStatusCode.OK, "{\"status\":\"processing\"}"),
            JsonResponse(HttpStatusCode.OK, "{\"status\":\"completed\",\"data\":[{\"url\":\"https://cdn.example.com/result.mp4\"}]}")
        );
        using var poller = new AsyncMediaPoller(
            handler,
            maximumPollAttempts: 3,
            pollInterval: TimeSpan.FromMilliseconds(1),
            requestTimeout: TimeSpan.FromSeconds(1),
            totalTimeout: TimeSpan.FromSeconds(2));
        var protocol = new AsyncMediaProtocolDefinition(
            "/v1/videos",
            "/v1/videos/{task_id}",
            AsyncMediaTaskIdentifierField.DataTaskId);

        var result = await poller.CreateAndPollAsync(new AsyncMediaPollRequest(
            ProviderBaseUri,
            protocol,
            TestCredential,
            Encoding.UTF8.GetBytes("{\"model\":\"video-test\"}"),
            "video"));

        Assert.Equal("video-task-1", result.UpstreamTaskId);
        Assert.Equal(2, result.PollAttempts);
        Assert.Equal("https://cdn.example.com/result.mp4", result.Artifact.RemoteUrl?.AbsoluteUri);
        Assert.Equal(
            ["/v1/videos", "/v1/videos/video-task-1", "/v1/videos/video-task-1"],
            handler.Paths);
    }

    [Fact]
    public async Task AsyncMediaRejectsOrdinaryIdRequestIdAndCompletedResponseWithoutArtifact()
    {
        using var ordinaryPoller = new AsyncMediaPoller(new SequenceHandler(
            JsonResponse(
                HttpStatusCode.OK,
                "{\"data\":{\"id\":\"ordinary-id\",\"request_id\":\"request-id\"},\"request_id\":\"outer-request-id\"}")));
        var protocol = new AsyncMediaProtocolDefinition(
            "/v1/images/generations",
            "/v1/images/tasks/{task_id}",
            AsyncMediaTaskIdentifierField.TaskId);
        var request = new AsyncMediaPollRequest(
            ProviderBaseUri,
            protocol,
            TestCredential,
            Encoding.UTF8.GetBytes("{}"),
            "image");

        await Assert.ThrowsAsync<InvalidDataException>(() => ordinaryPoller.CreateAndPollAsync(request));

        using var artifactlessPoller = new AsyncMediaPoller(
            new SequenceHandler(
                JsonResponse(HttpStatusCode.OK, "{\"task_id\":\"task-2\"}"),
                JsonResponse(
                    HttpStatusCode.OK,
                    "{\"status\":\"completed\",\"request_id\":\"req-2\",\"data\":[{\"url\":\"http://cdn.example.com/unsafe.png\"}]}")),
            maximumPollAttempts: 1,
            pollInterval: TimeSpan.FromMilliseconds(1));
        await Assert.ThrowsAsync<InvalidDataException>(() => artifactlessPoller.CreateAndPollAsync(request));
    }

    [Fact]
    public async Task AsyncMediaAcceptsSynchronousArtifactEvenWhenRequestIdExists()
    {
        using var poller = new AsyncMediaPoller(new SequenceHandler(JsonResponse(
            HttpStatusCode.OK,
            "{\"request_id\":\"req-sync\",\"data\":[{\"url\":\"https://cdn.example.com/image.png\"}]}")));
        var request = new AsyncMediaPollRequest(
            ProviderBaseUri,
            new AsyncMediaProtocolDefinition(
                "/v1/images/generations",
                "/v1/images/tasks/{task_id}",
                AsyncMediaTaskIdentifierField.TaskId),
            TestCredential,
            Encoding.UTF8.GetBytes("{}"),
            "image");

        var result = await poller.CreateAndPollAsync(request);

        Assert.Null(result.UpstreamTaskId);
        Assert.Equal(0, result.PollAttempts);
        Assert.Equal("https://cdn.example.com/image.png", result.Artifact.RemoteUrl?.AbsoluteUri);
    }

    [Fact]
    public async Task AsyncMediaStoresInlineArtifactWithPrivatePermissions()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            using var poller = new AsyncMediaPoller(
                new SequenceHandler(JsonResponse(
                    HttpStatusCode.OK,
                    "{\"data\":[{\"b64_json\":\"AQIDBA==\"}]}")),
                artifactDirectory: directory,
                maximumArtifactBytes: 64);
            var result = await poller.CreateAndPollAsync(new AsyncMediaPollRequest(
                ProviderBaseUri,
                new AsyncMediaProtocolDefinition(
                    "/v1/images/generations",
                    "/v1/images/tasks/{task_id}",
                    AsyncMediaTaskIdentifierField.TaskId),
                TestCredential,
                Encoding.UTF8.GetBytes("{}"),
                "image"));

            var path = Assert.IsType<string>(result.Artifact.LocalPath);
            Assert.Equal(new byte[] { 1, 2, 3, 4 }, await File.ReadAllBytesAsync(path));
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(
                    UnixFileMode.UserRead | UnixFileMode.UserWrite,
                    File.GetUnixFileMode(path));
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AsyncMediaBoundsPollAttemptsAndConcurrency()
    {
        using var queuedPoller = new AsyncMediaPoller(
            new SequenceHandler(
                JsonResponse(HttpStatusCode.OK, "{\"task_id\":\"never-finishes\"}"),
                JsonResponse(HttpStatusCode.OK, "{\"status\":\"queued\"}"),
                JsonResponse(HttpStatusCode.OK, "{\"status\":\"processing\"}")),
            maximumPollAttempts: 2,
            pollInterval: TimeSpan.FromMilliseconds(1));
        var request = new AsyncMediaPollRequest(
            ProviderBaseUri,
            new AsyncMediaProtocolDefinition(
                "/v1/music/generations",
                "/v1/music/tasks/{task_id}",
                AsyncMediaTaskIdentifierField.TaskId),
            TestCredential,
            Encoding.UTF8.GetBytes("{}"),
            "music");
        await Assert.ThrowsAsync<TimeoutException>(() => queuedPoller.CreateAndPollAsync(request));

        var concurrencyHandler = new ConcurrencyHandler();
        using var boundedPoller = new AsyncMediaPoller(
            concurrencyHandler,
            maximumConcurrentTasks: 2,
            requestTimeout: TimeSpan.FromSeconds(1),
            totalTimeout: TimeSpan.FromSeconds(2));
        await Task.WhenAll(Enumerable.Range(0, 6).Select(_ =>
            boundedPoller.CreateAndPollAsync(request)));
        Assert.InRange(concurrencyHandler.MaximumObserved, 1, 2);
    }

    [Fact]
    public async Task ConfigurationMetadataRoundTripsAtomicallyWithoutSecrets()
    {
        var directory = CreateTemporaryDirectory();
        var path = Path.Combine(directory, "modelhub-export.json");
        try
        {
            var configuration = CreateGatewayMetadataConfiguration();
            var exchange = new ConfigurationImportExport(maximumBytes: 1_048_576);

            await exchange.ExportAsync(configuration, path);
            var json = await File.ReadAllTextAsync(path);
            var imported = await exchange.ImportAsync(path);

            Assert.DoesNotContain("apiKey", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("clientSecret", json, StringComparison.OrdinalIgnoreCase);
            Assert.Equal(configuration.Gateway.Port, imported.Gateway.Port);
            Assert.Equal(configuration.Providers.Single().BaseUri, imported.Providers.Single().BaseUri);
            Assert.Equal(configuration.Nodes.Single().ProxyUri, imported.Nodes.Single().ProxyUri);
            Assert.Equal(configuration.Nodes.Single().SelectorGroup, imported.Nodes.Single().SelectorGroup);
            Assert.Equal(
                configuration.CredentialPools!.Single().Entries.Single().CredentialTarget,
                imported.CredentialPools!.Single().Entries.Single().CredentialTarget);
            var route = Assert.Single(imported.Routes!);
            Assert.Equal("writer", route.Alias);
            Assert.Equal(ModelRouteStrategy.PriorityFailover, route.Strategy);
            Assert.Equal(configuration.Providers.Single().Id, Assert.Single(route.Targets).ProviderId);
            Assert.Equal("model-a", Assert.Single(route.Targets).ModelId);
            var endpoints = imported.ProviderEndpointPaths!;
            Assert.Equal(2, endpoints.Count);
            var videoEndpoint = Assert.Single(
                endpoints,
                endpoint => endpoint.Endpoint == GatewayEndpointKind.VideoGeneration);
            Assert.True(videoEndpoint.IsAsynchronous);
            Assert.Equal("/v1/videos/{task_id}", videoEndpoint.PollPathTemplate);
            Assert.Equal(GatewayTaskIdentifierField.DataTaskId, videoEndpoint.TaskIdentifierField);
            var assignment = Assert.Single(imported.ModelNodeAssignments!);
            Assert.Equal(configuration.Providers.Single().Id, assignment.ProviderId);
            Assert.Equal("model-a", assignment.ModelId);
            Assert.Equal(configuration.Nodes.Single().Id, assignment.NodeId);
            Assert.Empty(Directory.EnumerateFiles(directory, ".*.tmp"));
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(
                    UnixFileMode.UserRead | UnixFileMode.UserWrite,
                    File.GetUnixFileMode(path));
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ConfigurationImportAcceptsLegacyDocumentWithoutGatewayRoutingMetadata()
    {
        var directory = CreateTemporaryDirectory();
        var path = Path.Combine(directory, "legacy.json");
        try
        {
            var exchange = new ConfigurationImportExport(maximumBytes: 1_048_576);
            await exchange.ExportAsync(CreateGatewayMetadataConfiguration(), path);
            var root = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
            root.Remove("routes");
            root.Remove("providerEndpointPaths");
            root.Remove("modelNodeAssignments");
            await File.WriteAllTextAsync(path, root.ToJsonString());

            var imported = await exchange.ImportAsync(path);

            Assert.Empty(imported.Routes ?? []);
            Assert.Empty(imported.ProviderEndpointPaths ?? []);
            Assert.Empty(imported.ModelNodeAssignments ?? []);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ConfigurationImportRejectsUnsafeDuplicateAndBrokenGatewayMetadata()
    {
        var directory = CreateTemporaryDirectory();
        var path = Path.Combine(directory, "source.json");
        try
        {
            var exchange = new ConfigurationImportExport(maximumBytes: 1_048_576);
            await exchange.ExportAsync(CreateGatewayMetadataConfiguration(), path);
            var sourceJson = await File.ReadAllTextAsync(path);

            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "unsafe-path", root =>
            {
                root["providerEndpointPaths"]!.AsArray()[0]!["path"] =
                    "https://evil.example/v1/responses";
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "duplicate-route", root =>
            {
                var routes = root["routes"]!.AsArray();
                routes.Add(routes[0]!.DeepClone());
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "alias-model-collision", root =>
            {
                root["routes"]!.AsArray()[0]!["alias"] = "model-a";
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "duplicate-endpoint", root =>
            {
                var endpoints = root["providerEndpointPaths"]!.AsArray();
                endpoints.Add(endpoints[0]!.DeepClone());
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "duplicate-assignment", root =>
            {
                var assignments = root["modelNodeAssignments"]!.AsArray();
                assignments.Add(assignments[0]!.DeepClone());
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "missing-route-provider", root =>
            {
                root["routes"]!.AsArray()[0]!["targets"]!.AsArray()[0]!["providerId"] =
                    Guid.NewGuid();
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "missing-endpoint-provider", root =>
            {
                root["providerEndpointPaths"]!.AsArray()[0]!["providerId"] = Guid.NewGuid();
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "missing-assignment-node", root =>
            {
                root["modelNodeAssignments"]!.AsArray()[0]!["nodeId"] = Guid.NewGuid();
            });
            await AssertRejectedMutationAsync(exchange, directory, sourceJson, "too-many-routes", root =>
            {
                var routes = root["routes"]!.AsArray();
                var seed = routes[0]!;
                routes.Clear();
                for (var index = 0; index < 257; index++)
                {
                    var route = seed.DeepClone();
                    route!["alias"] = $"writer-{index}";
                    routes.Add(route);
                }
            });
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ConfigurationImportRejectsSecretFieldsUnsafeUrlsOversizeAndSymlinks()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var exchange = new ConfigurationImportExport(maximumBytes: 1_024);
            var safePath = Path.Combine(directory, "safe.json");
            await exchange.ExportAsync(CreateConfiguration(), safePath);
            var safeJson = await File.ReadAllTextAsync(safePath);

            var secretPath = Path.Combine(directory, "secret.json");
            await File.WriteAllTextAsync(secretPath, safeJson.Replace(
                "{",
                "{\"apiKey\":\"must-not-import\",",
                StringComparison.Ordinal));
            await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(secretPath));

            var unsafePath = Path.Combine(directory, "unsafe.json");
            await File.WriteAllTextAsync(unsafePath, safeJson.Replace(
                "https://provider.example.com/",
                "https://provider.example.com/?api_key=hidden",
                StringComparison.Ordinal));
            await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(unsafePath));

            var remoteProxyPath = Path.Combine(directory, "remote-proxy.json");
            await File.WriteAllTextAsync(remoteProxyPath, safeJson.Replace(
                "http://127.0.0.1:7890/",
                "http://proxy.example.com:7890/",
                StringComparison.Ordinal));
            await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(remoteProxyPath));

            var oversizedPath = Path.Combine(directory, "oversized.json");
            await File.WriteAllTextAsync(oversizedPath, new string('x', 1_025));
            await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(oversizedPath));

            var importLink = Path.Combine(directory, "import-link.json");
            File.CreateSymbolicLink(importLink, safePath);
            await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(importLink));

            var exportLink = Path.Combine(directory, "export-link.json");
            File.CreateSymbolicLink(exportLink, safePath);
            await Assert.ThrowsAsync<InvalidDataException>(() =>
                exchange.ExportAsync(CreateConfiguration(), exportLink));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static ModelHubConfiguration CreateConfiguration()
    {
        var provider = new ProviderConfiguration(
            Guid.NewGuid(),
            "provider",
            ProviderBaseUri,
            true,
            [new ModelDefinition("model-a", "Model A", "text")]);
        var entry = new CredentialPoolEntry(
            Guid.NewGuid(),
            "developer credential",
            $"ModelHub.Windows/Pool/{provider.Id:N}/primary",
            0,
            false);
        return new ModelHubConfiguration(
            1,
            new GatewaySettings(11435, GatewaySettings.DefaultCredentialTarget),
            [provider],
            [new NodeConfiguration(Guid.NewGuid(), "local node", new Uri("http://127.0.0.1:7890/"), true, "GLOBAL")],
            [new CredentialPoolConfiguration(provider.Id, true, entry.Id, [entry])]);
    }

    private static ModelHubConfiguration CreateGatewayMetadataConfiguration()
    {
        var configuration = CreateConfiguration();
        var provider = configuration.Providers.Single();
        var node = configuration.Nodes.Single();
        return configuration with
        {
            Routes =
            [
                new ModelRouteDefinition(
                    "writer",
                    true,
                    ModelRouteStrategy.PriorityFailover,
                    [new ModelRouteTarget(provider.Id, "model-a")]),
            ],
            ProviderEndpointPaths =
            [
                new ProviderEndpointPath(
                    provider.Id,
                    GatewayEndpointKind.Responses,
                    "/v1/responses"),
                new ProviderEndpointPath(
                    provider.Id,
                    GatewayEndpointKind.VideoGeneration,
                    "/v1/videos",
                    IsAsynchronous: true,
                    PollPathTemplate: "/v1/videos/{task_id}",
                    TaskIdentifierField: GatewayTaskIdentifierField.DataTaskId),
            ],
            ModelNodeAssignments = [new ModelNodeAssignment(provider.Id, "model-a", node.Id)],
        };
    }

    private static async Task AssertRejectedMutationAsync(
        ConfigurationImportExport exchange,
        string directory,
        string sourceJson,
        string name,
        Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(sourceJson)!.AsObject();
        mutate(root);
        var path = Path.Combine(directory, $"{name}.json");
        await File.WriteAllTextAsync(path, root.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => exchange.ImportAsync(path));
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) => new(status)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "modelhub-advanced-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed class DelegateHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => response(request, cancellationToken);
    }

    private sealed class SequenceHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses = new(responses);
        public List<string> Paths { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Paths.Add(request.RequestUri?.AbsolutePath ?? string.Empty);
            return Task.FromResult(_responses.Count > 0
                ? _responses.Dequeue()
                : throw new InvalidOperationException("No fake response remains."));
        }
    }

    private sealed class ConcurrencyHandler : HttpMessageHandler
    {
        private int _active;
        private int _maximumObserved;
        public int MaximumObserved => Volatile.Read(ref _maximumObserved);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var active = Interlocked.Increment(ref _active);
            UpdateMaximum(active);
            try
            {
                await Task.Delay(30, cancellationToken);
                return JsonResponse(
                    HttpStatusCode.OK,
                    "{\"data\":[{\"url\":\"https://cdn.example.com/result.bin\"}]}");
            }
            finally
            {
                Interlocked.Decrement(ref _active);
            }
        }

        private void UpdateMaximum(int candidate)
        {
            var current = Volatile.Read(ref _maximumObserved);
            while (candidate > current)
            {
                var observed = Interlocked.CompareExchange(
                    ref _maximumObserved,
                    candidate,
                    current);
                if (observed == current) { return; }
                current = observed;
            }
        }
    }
}
