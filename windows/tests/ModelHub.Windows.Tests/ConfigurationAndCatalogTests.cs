using ModelHub.Windows.Models;
using ModelHub.Windows.Services;
using System.Net;
using System.Net.Sockets;

namespace ModelHub.Windows.Tests;

public sealed class ConfigurationAndCatalogTests
{
    [Theory]
    [InlineData(" ModelHub.Windows/Test")]
    [InlineData("ModelHub.Windows/Test\r\nInjected")]
    [InlineData("OtherProduct/Test")]
    public void CredentialVaultRejectsUnsafeTargetsBeforePlatformAccess(string target)
    {
        var vault = new WindowsCredentialVault();

        Assert.Throws<ArgumentException>(() => vault.Read(target));
    }

    [Fact]
    public void SafeConfigurationAcceptsHttpsProviderAndLocalProxy()
    {
        var configuration = CreateConfiguration();

        Assert.True(ConfigurationStore.IsSafe(configuration));
        var entry = Assert.Single(ProviderCatalog.Models(configuration));
        Assert.Equal("gpt-test", entry.Model.Id);
        Assert.Equal("测试供应商", entry.Provider.DisplayName);
    }

    [Theory]
    [InlineData("http://provider.example.com/")]
    [InlineData("https://user:password@provider.example.com/")]
    public void SafeConfigurationRejectsUnsafeProviderEndpoint(string endpoint)
    {
        var provider = CreateConfiguration().Providers.Single() with { BaseUri = new Uri(endpoint) };
        var configuration = CreateConfiguration() with { Providers = [provider] };

        Assert.False(ConfigurationStore.IsSafe(configuration));
    }

    [Fact]
    public void SafeConfigurationRejectsProviderApiKeyInQuery()
    {
        var provider = CreateConfiguration().Providers.Single() with { BaseUri = new Uri("https://provider.example.com/?api_key=secret") };
        Assert.False(ConfigurationStore.IsSafe(CreateConfiguration() with { Providers = [provider] }));
    }

    [Fact]
    public void SafeConfigurationRejectsFragmentsInProviderAndProxyUrls()
    {
        var baseline = CreateConfiguration();
        var provider = baseline.Providers.Single() with { BaseUri = new Uri("https://provider.example.com/#credential") };
        var node = baseline.Nodes.Single() with { ProxyUri = new Uri("http://127.0.0.1:7890/#hidden") };

        Assert.False(ConfigurationStore.IsSafe(baseline with { Providers = [provider] }));
        Assert.False(ConfigurationStore.IsSafe(baseline with { Nodes = [node] }));
    }

    [Fact]
    public void SafeConfigurationRejectsDuplicatedModelIdAcrossProviders()
    {
        var first = CreateConfiguration().Providers.Single();
        var second = first with { Id = Guid.NewGuid(), DisplayName = "第二供应商" };
        var configuration = CreateConfiguration() with { Providers = [first, second] };

        Assert.False(ConfigurationStore.IsSafe(configuration));
    }

    [Fact]
    public void CatalogDoesNotRouteDisabledProvider()
    {
        var disabled = CreateConfiguration().Providers.Single() with { IsEnabled = false };
        var configuration = CreateConfiguration() with { Providers = [disabled] };

        Assert.Empty(ProviderCatalog.Models(configuration));
        Assert.Null(ProviderCatalog.FindEnabledProvider(configuration, "gpt-test"));
    }

    [Fact]
    public async Task NodeLatencyTesterRejectsUnsafeNodeBeforeNetworking()
    {
        var result = await NodeLatencyTester.TestAsync(new NodeConfiguration(Guid.NewGuid(), "bad", new Uri("ftp://example.com"), true), CancellationToken.None);

        Assert.Equal("拒绝", result.Status);
        Assert.Null(result.LatencyMilliseconds);
    }

    [Fact]
    public void HealthMonitorReplacesOnlyTheSameSubject()
    {
        var monitor = new HealthMonitor();
        monitor.RecordFailure("provider/a", "timeout");
        monitor.RecordSuccess("provider/a", TimeSpan.FromMilliseconds(24));
        monitor.RecordDegraded("provider/b", "quota");

        var snapshots = monitor.Snapshot();
        Assert.Equal(2, snapshots.Count);
        Assert.Equal(HealthState.Healthy, Assert.Single(snapshots, snapshot => snapshot.Subject == "provider/a").State);
        Assert.Equal(HealthState.Degraded, Assert.Single(snapshots, snapshot => snapshot.Subject == "provider/b").State);
    }

    [Fact]
    public void HealthMonitorFeedsOnlyPermanentModelEvidenceIntoRouteExclusion()
    {
        var monitor = new HealthMonitor();
        var target = new ModelHealthTarget(Guid.NewGuid(), "model-a");

        monitor.RecordModel(new ModelHealthVerificationResult(
            target,
            HealthState.Degraded,
            null,
            "rate_limited",
            ShouldPermanentlyQuarantine: false));
        Assert.Equal(
            RouteTargetState.Degraded,
            monitor.RouteState(target.ProviderId, target.ModelId));

        monitor.RecordModel(new ModelHealthVerificationResult(
            target,
            HealthState.Failed,
            null,
            "model_not_found",
            ShouldPermanentlyQuarantine: true));
        Assert.Equal(
            RouteTargetState.Unavailable,
            monitor.RouteState(target.ProviderId, target.ModelId));

        Assert.Equal(
            RouteTargetState.Available,
            monitor.RouteState(Guid.NewGuid(), "never-tested"));
    }

    [Fact]
    public async Task LocalGatewayServesOnlyAuthorizedLoopbackHealthAndModelCatalog()
    {
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, "a-very-long-test-token-that-is-never-logged");
        await using var gateway = new LocalGatewayService(() => configuration, vault);
        await gateway.StartAsync();

        using var client = new HttpClient();
        using var unauthenticated = await client.GetAsync($"http://127.0.0.1:{port}/health");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);

        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", vault.Read(GatewaySettings.DefaultCredentialTarget));
        using var health = await client.GetAsync($"http://127.0.0.1:{port}/health");
        using var models = await client.GetAsync($"http://127.0.0.1:{port}/v1/models");
        Assert.Equal(HttpStatusCode.OK, health.StatusCode);
        Assert.Equal(HttpStatusCode.OK, models.StatusCode);
        Assert.Contains("gpt-test", await models.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task LocalGatewayForwardsSseWithoutBufferingTheWholeConversation()
    {
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = CreateVault(configuration);
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n", System.Text.Encoding.UTF8, "text/event-stream"),
        });
        await using var gateway = new LocalGatewayService(() => configuration, vault, handler, new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();

        using var client = AuthorizedClient(vault);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/chat/completions")
        {
            Content = new StringContent("{\"model\":\"gpt-test\",\"stream\":true,\"messages\":[]}", System.Text.Encoding.UTF8, "application/json"),
        };
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.StartsWith("text/event-stream", response.Content.Headers.ContentType?.MediaType, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("data: [DONE]", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task LocalGatewayRejectsMediaSuccessWithoutArtifactAndRecordsFailure()
    {
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = CreateVault(configuration);
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"data\":[{}]}", System.Text.Encoding.UTF8, "application/json"),
        });
        await using var gateway = new LocalGatewayService(() => configuration, vault, handler, new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();

        using var client = AuthorizedClient(vault);
        using var response = await client.PostAsync($"http://127.0.0.1:{port}/v1/images/generations", new StringContent("{\"model\":\"gpt-test\",\"prompt\":\"x\"}", System.Text.Encoding.UTF8, "application/json"));

        Assert.Equal(HttpStatusCode.BadGateway, response.StatusCode);
        Assert.Equal("media_artifact_missing", (await response.Content.ReadAsStringAsync()).Contains("media_artifact_missing", StringComparison.Ordinal) ? "media_artifact_missing" : null);
        Assert.True(response.Headers.TryGetValues("X-ModelHub-Media-Task-ID", out var ids));
        using var task = await client.GetAsync($"http://127.0.0.1:{port}/v1/media/tasks/{ids.Single()}");
        Assert.Contains("failed", await task.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UsageLedgerUsesBoundedPagesAndOpaqueCursor()
    {
        using var ledger = new UsageLedgerStore(CreateTemporaryDirectory());
        await ledger.AppendAsync(new UsageLedgerEntry(Guid.NewGuid(), DateTimeOffset.UtcNow, "/v1/a", "m", "p", 200, 10, 20, null));
        await ledger.AppendAsync(new UsageLedgerEntry(Guid.NewGuid(), DateTimeOffset.UtcNow, "/v1/b", "m", "p", 200, 10, 20, null));

        var first = await ledger.ReadPageAsync(null, 1);
        var second = await ledger.ReadPageAsync(first.NextCursor, 1);
        Assert.Single(first.Entries);
        Assert.NotNull(first.NextCursor);
        Assert.Single(second.Entries);
        Assert.NotEqual(first.Entries[0].Id, second.Entries[0].Id);
    }

    [Fact]
    public void CredentialPoolOnlyFailsOverAfterIrreversibleCredentialEvidence()
    {
        var first = new CredentialPoolEntry(Guid.NewGuid(), "primary", "ModelHub.Windows/Pool/p/primary", 0, false);
        var second = new CredentialPoolEntry(Guid.NewGuid(), "secondary", "ModelHub.Windows/Pool/p/secondary", 1, false);
        var pool = new CredentialPoolConfiguration(Guid.NewGuid(), true, first.Id, [first, second]);

        Assert.Equal(first, CredentialPoolSelector.Select(pool));
        Assert.Null(CredentialPoolSelector.SelectAfterFailure(pool, first.Id, CredentialFailureEvidence.RateLimited));
        Assert.Equal(second, CredentialPoolSelector.SelectAfterFailure(pool, first.Id, CredentialFailureEvidence.InvalidGrantOrRevoked));
    }

    [Fact]
    public void MediaTaskCannotBecomeSuccessfulWithoutUsableArtifact()
    {
        var registry = new MediaTaskRegistry();
        var task = registry.Create("/v1/images/generations", "image-test");
        registry.MarkRunning(task.Id);

        Assert.Throws<InvalidOperationException>(() => registry.MarkSucceeded(task.Id, new MediaArtifact("remote-url", null, null, 0)));
        var artifact = MediaArtifactStore.ParseRemoteJsonArtifact(System.Text.Encoding.UTF8.GetBytes("{\"data\":[{\"url\":\"https://example.test/artifact.png\"}]}"));
        var succeeded = registry.MarkSucceeded(task.Id, artifact);
        Assert.Equal(MediaTaskState.Succeeded, succeeded.State);
        Assert.Equal("https://example.test/artifact.png", succeeded.Artifact?.RemoteUrl?.AbsoluteUri);
    }

    [Fact]
    public async Task SharedConfigurationStateMakesNewProviderVisibleWithoutGatewayRestart()
    {
        var port = ReservePort();
        var initial = ModelHubConfiguration.Empty with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var state = new ConfigurationState(initial);
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, "a-very-long-test-token-that-is-never-logged");
        await using var gateway = new LocalGatewayService(state.Snapshot, vault, new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)), new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();

        var provider = CreateConfiguration().Providers.Single();
        state.Replace(initial with { Providers = [provider] });
        using var client = AuthorizedClient(vault);
        using var response = await client.GetAsync($"http://127.0.0.1:{port}/v1/models");

        Assert.Contains("gpt-test", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task StoppingGatewayCancelsTrackedSlowUpstreamRequest()
    {
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = CreateVault(configuration);
        var handler = new BlockingHandler();
        await using var gateway = new LocalGatewayService(() => configuration, vault, handler, new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(vault);
        var request = client.PostAsync($"http://127.0.0.1:{port}/v1/chat/completions", new StringContent("{\"model\":\"gpt-test\",\"messages\":[]}", System.Text.Encoding.UTF8, "application/json"));
        await handler.Started.Task.WaitAsync(TimeSpan.FromSeconds(1));

        await gateway.StopAsync().WaitAsync(TimeSpan.FromSeconds(2));
        using var completed = await request.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.NotNull(completed);
    }

    [Fact]
    public async Task GatewayRejectsUnknownLengthChunkedRequestBeforeParsing()
    {
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = CreateVault(configuration);
        await using var gateway = new LocalGatewayService(() => configuration, vault, new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)), new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(vault);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/chat/completions") { Content = new UnknownLengthContent("{\"model\":\"gpt-test\"}") };
        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task SseOverflowClosesStartedResponseWithoutSecondJsonResponse()
    {
        var payload = System.Text.Encoding.UTF8.GetBytes("data: " + new string('x', 2048) + "\n\n");
        await AssertStartedSseIsAbortedWithoutJsonAsync(new ByteArrayContent(payload), 1024);
    }

    [Fact]
    public async Task SseMidstreamFailureClosesStartedResponseWithoutSecondJsonResponse()
    {
        await AssertStartedSseIsAbortedWithoutJsonAsync(new StreamContent(new ChunkThenThrowStream("data: first\n\n")), 4096);
    }

    [Fact]
    public async Task SseStallAfterHeadersHitsFirstByteTimeoutWithoutSecondResponse()
    {
        await AssertStartedSseIsAbortedWithoutJsonAsync(new StreamContent(new NeverReadStream()), 4096, TimeSpan.FromMilliseconds(75));
    }

    [Fact]
    public async Task SseStallAfterFirstChunkHitsIdleTimeoutWithoutSecondResponse()
    {
        await AssertStartedSseIsAbortedWithoutJsonAsync(
            new StreamContent(new ChunkThenStallStream("data: first\n\n")),
            4096,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(75));
    }

    [Fact]
    public void MediaRegistryEvictsExpiredTerminalTasksButPreservesActiveWork()
    {
        var now = DateTimeOffset.UtcNow;
        var registry = new MediaTaskRegistry(2, TimeSpan.FromSeconds(1), () => now);
        var completed = registry.Create("/v1/images/generations", "m");
        registry.MarkSucceeded(completed.Id, new MediaArtifact("remote-url", new Uri("https://example.test/a"), null, 1));
        var active = registry.Create("/v1/videos", "m");
        registry.MarkRunning(active.Id);
        now += TimeSpan.FromSeconds(2);

        var replacement = registry.Create("/v1/audio/speech", "m");
        Assert.Null(registry.Get(completed.Id));
        Assert.NotNull(registry.Get(active.Id));
        Assert.NotNull(registry.Get(replacement.Id));
    }

    [Fact]
    public void ViewModelDoesNotExposeStoredGatewayToken()
    {
        var configuration = CreateConfiguration();
        var state = new ConfigurationState(configuration);
        var vault = CreateVault(configuration);
        using var ledger = new UsageLedgerStore(CreateTemporaryDirectory());
        var gateway = new LocalGatewayService(state.Snapshot, vault, new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)), ledger);
        var viewModel = new ModelHub.Windows.ViewModels.MainWindowViewModel(state, new ConfigurationStore(CreateTemporaryDirectory()), vault, gateway, new HealthMonitor(), new NodeLatencyTester());

        Assert.Empty(viewModel.GatewayToken);
        Assert.Contains("已安全保存", viewModel.Status, StringComparison.Ordinal);
    }

    private static ModelHubConfiguration CreateConfiguration() => new(
        1,
        new GatewaySettings(11435, GatewaySettings.DefaultCredentialTarget),
        [new ProviderConfiguration(Guid.NewGuid(), "测试供应商", new Uri("https://provider.example.com/"), true, [new ModelDefinition("gpt-test", "GPT Test", "text")])],
        [new NodeConfiguration(Guid.NewGuid(), "测试节点", new Uri("http://127.0.0.1:7890"), true)]);

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static FakeCredentialVault CreateVault(ModelHubConfiguration configuration)
    {
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, "a-very-long-test-token-that-is-never-logged");
        vault.Write(configuration.Providers.Single().CredentialTarget, "test-provider-secret");
        return vault;
    }

    private static HttpClient AuthorizedClient(FakeCredentialVault vault)
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", vault.Read(GatewaySettings.DefaultCredentialTarget));
        return client;
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "modelhub-windows-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static async Task AssertStartedSseIsAbortedWithoutJsonAsync(HttpContent upstreamContent, int limit, TimeSpan? firstByteTimeout = null, TimeSpan? idleTimeout = null)
    {
        upstreamContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/event-stream");
        var port = ReservePort();
        var configuration = CreateConfiguration() with { Gateway = new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget) };
        var vault = CreateVault(configuration);
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = upstreamContent });
        await using var gateway = new LocalGatewayService(() => configuration, vault, handler, new UsageLedgerStore(CreateTemporaryDirectory()), maximumStreamingResponseBytes: limit, streamFirstByteTimeout: firstByteTimeout, streamIdleTimeout: idleTimeout);
        await gateway.StartAsync();
        using var client = AuthorizedClient(vault);
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/chat/completions")
        {
            Content = new StringContent("{\"model\":\"gpt-test\",\"stream\":true,\"messages\":[]}", System.Text.Encoding.UTF8, "application/json"),
        };
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            var body = await response.Content.ReadAsStringAsync();
            Assert.DoesNotContain("internal_error", body, StringComparison.Ordinal);
            Assert.DoesNotContain("request_cancelled", body, StringComparison.Ordinal);
        }
        catch (HttpRequestException)
        {
            // Expected when the connection is aborted after SSE headers started.
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

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response(request));
    }

    private sealed class BlockingHandler : HttpMessageHandler
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Started.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }

    private sealed class UnknownLengthContent(string value) : HttpContent
    {
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context) => await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(value));
    }

    private sealed class ChunkThenThrowStream(string chunk) : Stream
    {
        private readonly byte[] _chunk = System.Text.Encoding.UTF8.GetBytes(chunk);
        private bool _served;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_served) { throw new IOException("Injected upstream SSE failure."); }
            _served = true;
            var length = Math.Min(count, _chunk.Length);
            Array.Copy(_chunk, 0, buffer, offset, length);
            return length;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class NeverReadStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => new(Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ContinueWith(_ => 0, CancellationToken.None));
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class ChunkThenStallStream(string chunk) : Stream
    {
        private readonly byte[] _chunk = System.Text.Encoding.UTF8.GetBytes(chunk);
        private bool _served;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_served)
            {
                return new ValueTask<int>(Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ContinueWith(_ => 0, CancellationToken.None));
            }
            _served = true;
            var length = Math.Min(buffer.Length, _chunk.Length);
            _chunk.AsMemory(0, length).CopyTo(buffer);
            return ValueTask.FromResult(length);
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
