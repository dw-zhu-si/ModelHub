using System.Net;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class ProxySubscriptionAndHealthTests
{
    [Theory]
    [InlineData("http://subscription.example.test/clash.yaml")]
    [InlineData("https://user:secret@subscription.example.test/clash.yaml")]
    [InlineData("https://subscription.example.test/clash.yaml#secret")]
    public void SubscriptionSourcePolicyRejectsUnsafeUrls(string value)
    {
        Assert.Throws<ProxySubscriptionSecurityException>(() =>
            ProxySubscriptionPolicy.ValidateSourceUri(new Uri(value)));
    }

    [Fact]
    public void SubscriptionRedirectMustRemainOnTheExactHttpsOrigin()
    {
        var source = new Uri("https://subscription.example.test:8443/clash.yaml");

        ProxySubscriptionPolicy.ValidateSourceUri(new Uri("https://subscription.example.test/clash.yaml?token=ephemeral"));
        Assert.True(ProxySubscriptionPolicy.IsSameOriginRedirect(
            source,
            new Uri("https://subscription.example.test:8443/rotated.yaml")));
        Assert.False(ProxySubscriptionPolicy.IsSameOriginRedirect(
            source,
            new Uri("https://cdn.example.test:8443/rotated.yaml")));
        Assert.False(ProxySubscriptionPolicy.IsSameOriginRedirect(
            source,
            new Uri("https://subscription.example.test/rotated.yaml")));
        Assert.False(ProxySubscriptionPolicy.IsSameOriginRedirect(
            source,
            new Uri("http://subscription.example.test:8443/rotated.yaml")));
    }

    [Fact]
    public void ParsesBoundedJsonWithoutPersistingTheSubscriptionUrl()
    {
        const string sourceUrl = "https://subscription.example.test/private-token";
        var payload = Encoding.UTF8.GetBytes("""
            {
              "proxies": [
                { "name": "Taiwan 01", "type": "ss", "server": "tw.example.test", "port": 443, "cipher": "aes-256-gcm", "password": "node-secret", "tls": true },
                { "name": "Japan 01", "type": "trojan", "server": "203.0.113.8", "port": 8443, "password": "another-secret" }
              ]
            }
            """);

        var snapshot = ProxySubscriptionParser.Parse(payload, "My subscription", DateTimeOffset.UnixEpoch);

        Assert.Equal(2, snapshot.Nodes.Count);
        Assert.Equal(ProxyNodeProtocol.Shadowsocks, snapshot.Nodes[0].Protocol);
        Assert.Equal(ProxyNodeProtocol.Trojan, snapshot.Nodes[1].Protocol);
        var serialized = JsonSerializer.Serialize(snapshot);
        Assert.DoesNotContain(sourceUrl, serialized, StringComparison.Ordinal);
        Assert.DoesNotContain("node-secret", serialized, StringComparison.Ordinal);
        Assert.DoesNotContain(
            typeof(Uri),
            typeof(ProxySubscriptionSnapshot).GetProperties().Select(property => property.PropertyType));
        Assert.DoesNotContain(
            typeof(ProxySubscriptionSnapshot).GetProperties(),
            property => property.Name.Contains("source", StringComparison.OrdinalIgnoreCase) ||
                property.Name.Contains("url", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain("node-secret", snapshot.Nodes[0].ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void ParsesClashYamlNodeMetadataAndIgnoresUnrelatedGroups()
    {
        var payload = Encoding.UTF8.GetBytes("""
            proxies:
              - name: "Hong Kong 01"
                type: vmess
                server: hk.example.test
                port: 443
                uuid: "00000000-0000-0000-0000-000000000001"
                tls: true
                network: ws
                ws-opts:
                  path: /socket
              - name: Singapore 01
                type: socks5
                server: 198.51.100.10
                port: 1080
            proxy-groups:
              - name: Auto
                type: select
                proxies:
                  - Hong Kong 01
            """);

        var snapshot = ProxySubscriptionParser.Parse(payload, "Clash", DateTimeOffset.UnixEpoch);

        Assert.Collection(
            snapshot.Nodes,
            node =>
            {
                Assert.Equal("Hong Kong 01", node.Name);
                Assert.Equal(ProxyNodeProtocol.Vmess, node.Protocol);
                Assert.True(node.UsesTls);
            },
            node =>
            {
                Assert.Equal("Singapore 01", node.Name);
                Assert.Equal(ProxyNodeProtocol.Socks5, node.Protocol);
                Assert.False(node.UsesTls);
            });
    }

    [Fact]
    public void ParserRejectsPayloadsAndNodeSetsBeyondTheHardLimits()
    {
        var oversized = new byte[ProxySubscriptionPolicy.MaximumPayloadBytes + 1];
        Assert.Throws<ProxySubscriptionLimitException>(() =>
            ProxySubscriptionParser.Parse(oversized, "oversized", DateTimeOffset.UnixEpoch));

        var builder = new StringBuilder("{\"proxies\":[");
        for (var index = 0; index <= ProxySubscriptionPolicy.MaximumNodeCount; index++)
        {
            if (index > 0)
            {
                builder.Append(',');
            }

            builder.Append("{\"name\":\"n")
                .Append(index)
                .Append("\",\"type\":\"socks5\",\"server\":\"127.0.0.1\",\"port\":1080}");
        }

        builder.Append("]}");
        Assert.Throws<ProxySubscriptionLimitException>(() =>
            ProxySubscriptionParser.Parse(Encoding.UTF8.GetBytes(builder.ToString()), "too-many", DateTimeOffset.UnixEpoch));
    }

    [Fact]
    public void ParserRejectsMalformedNodesWithoutEchoingSecrets()
    {
        var payload = Encoding.UTF8.GetBytes("""
            proxies:
              - name: unsafe
                type: trojan
                server: https://user:top-secret@example.test/path
                port: 443
                password: top-secret
            """);

        var exception = Assert.Throws<ProxySubscriptionFormatException>(() =>
            ProxySubscriptionParser.Parse(payload, "unsafe", DateTimeOffset.UnixEpoch));

        Assert.DoesNotContain("top-secret", exception.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("user:", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ParserRejectsDuplicateNodeNamesBecauseMihomoSelectionIsNameBased()
    {
        var payload = Encoding.UTF8.GetBytes("""
            {"proxies":[
              {"name":"duplicate","type":"http","server":"one.example.test","port":8080},
              {"name":"duplicate","type":"http","server":"two.example.test","port":8080}
            ]}
            """);

        Assert.Throws<ProxySubscriptionFormatException>(() =>
            ProxySubscriptionParser.Parse(payload, "duplicates", DateTimeOffset.UnixEpoch));
    }

    [Fact]
    public async Task MihomoRuntimeRequiresAnExplicitExistingExecutableBeforeLaunch()
    {
        var launcher = new FakeMihomoLauncher();
        var service = new MihomoRuntimeService(launcher, new FakeMihomoProbe(ready: true));
        var options = new MihomoRuntimeOptions(
            Path.Combine(Path.GetTempPath(), $"missing-mihomo-{Guid.NewGuid():N}.exe"),
            Path.Combine(Path.GetTempPath(), $"missing-config-{Guid.NewGuid():N}.yaml"),
            11467,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAsync<MihomoRuntimeConfigurationException>(() =>
            service.StartAsync(options, CancellationToken.None));
        Assert.Equal(0, launcher.LaunchCount);
    }

    [Fact]
    public async Task MihomoRuntimeUsesLoopbackControllerAndKillsOnlyItsOwnedHungProcess()
    {
        using var files = TemporaryMihomoFiles.Create();
        var process = new FakeMihomoProcess(exitOnStopRequest: false);
        var launcher = new FakeMihomoLauncher(process);
        var probe = new FakeMihomoProbe(ready: true);
        await using var service = new MihomoRuntimeService(launcher, probe);
        var options = new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11467,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(25));

        await service.StartAsync(options, CancellationToken.None);
        Assert.True(service.IsReady);
        Assert.Equal(new Uri("http://127.0.0.1:11467/"), service.ControllerUri);
        Assert.Contains("127.0.0.1:11467", launcher.LastArguments);

        await service.StopAsync(CancellationToken.None);

        Assert.False(service.IsReady);
        Assert.Equal(1, process.StopRequestCount);
        Assert.Equal(1, process.KillCount);
    }

    [Fact]
    public async Task MihomoStartupFailureClosesTheOwnedProcessAndFailsClosed()
    {
        using var files = TemporaryMihomoFiles.Create();
        var process = new FakeMihomoProcess(exitOnStopRequest: true);
        var launcher = new FakeMihomoLauncher(process);
        await using var service = new MihomoRuntimeService(launcher, new FakeMihomoProbe(ready: false));
        var options = new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11468,
            TimeSpan.FromMilliseconds(50),
            TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAsync<MihomoRuntimeUnavailableException>(() =>
            service.StartAsync(options, CancellationToken.None));

        Assert.False(service.IsReady);
        Assert.Equal(1, process.StopRequestCount);
    }

    [Fact]
    public async Task MihomoRuntimeSelectsTheExactGroupAndNodeAfterReadiness()
    {
        using var files = TemporaryMihomoFiles.Create();
        var selector = new FakeMihomoControllerClient();
        await using var service = new MihomoRuntimeService(
            new FakeMihomoLauncher(),
            new FakeMihomoProbe(ready: true),
            selector);
        await service.StartAsync(new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11469,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(50)));

        await service.SelectNodeAsync("🚀 节点选择", "台湾 01");

        Assert.Equal(new Uri("http://127.0.0.1:11469/"), selector.ControllerUri);
        Assert.Equal("🚀 节点选择", selector.SelectorGroup);
        Assert.Equal("台湾 01", selector.NodeName);
    }

    [Fact]
    public async Task MihomoSelectionLeaseSerializesRequestsUntilTheActiveRequestReleasesIt()
    {
        using var files = TemporaryMihomoFiles.Create();
        var selector = new FakeMihomoControllerClient();
        await using var service = new MihomoRuntimeService(
            new FakeMihomoLauncher(),
            new FakeMihomoProbe(ready: true),
            selector);
        await service.StartAsync(new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11469,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(50)));

        var first = await service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 01");
        var secondTask = service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 02");

        await Task.Delay(30);
        Assert.False(secondTask.IsCompleted);
        Assert.Equal(["Taiwan 01"], selector.SelectedNodes);

        first.Dispose();
        using var second = await secondTask.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(["Taiwan 01", "Taiwan 02"], selector.SelectedNodes);
    }

    [Fact]
    public async Task SameNodeLeasesRunConcurrentlyButQueuedSwitchPreventsNewSameNodeStarvation()
    {
        using var files = TemporaryMihomoFiles.Create();
        var selector = new FakeMihomoControllerClient();
        await using var service = new MihomoRuntimeService(
            new FakeMihomoLauncher(),
            new FakeMihomoProbe(ready: true),
            selector);
        await service.StartAsync(new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11469,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(50)));

        var first = await service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 01");
        var sameNode = await service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 01");
        Assert.True(first.SelectionChanged);
        Assert.False(sameNode.SelectionChanged);
        Assert.Equal(["Taiwan 01"], selector.SelectedNodes);

        var switchTask = service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 02");
        var lateSameNodeTask = service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 01");
        Assert.False(switchTask.IsCompleted);
        Assert.False(lateSameNodeTask.IsCompleted);

        first.Dispose();
        sameNode.Dispose();
        using var switched = await switchTask.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.True(switched.SelectionChanged);
        Assert.False(lateSameNodeTask.IsCompleted);

        switched.Dispose();
        using var switchedBack = await lateSameNodeTask.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.True(switchedBack.SelectionChanged);
        Assert.Equal(["Taiwan 01", "Taiwan 02", "Taiwan 01"], selector.SelectedNodes);
    }

    [Fact]
    public async Task MihomoRuntimeCanRestartAndDoesNotDisposeItsControllerClientUntilRuntimeDispose()
    {
        using var files = TemporaryMihomoFiles.Create();
        var selector = new FakeMihomoControllerClient();
        var launcher = new RestartableMihomoLauncher();
        var service = new MihomoRuntimeService(launcher, new FakeMihomoProbe(ready: true), selector);
        var options = new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11469,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(50),
            ControllerAuthorizationToken: "controller-test-token");

        await service.StartAsync(options);
        await service.SelectNodeAsync("GLOBAL", "Taiwan 01");
        await service.StopAsync();
        Assert.False(selector.IsDisposed);

        await service.StartAsync(options);
        await service.SelectNodeAsync("GLOBAL", "Taiwan 02");
        await service.StopAsync();

        Assert.Equal(2, launcher.LaunchCount);
        Assert.Equal(["Taiwan 01", "Taiwan 02"], selector.SelectedNodes);
        Assert.DoesNotContain("controller-test-token", launcher.AllArguments, StringComparison.Ordinal);
        Assert.False(selector.IsDisposed);

        await service.DisposeAsync();
        Assert.True(selector.IsDisposed);
    }

    [Fact]
    public async Task CancelledStopBeforeOwnershipLeavesTheRunningRuntimeReadyAndSelectable()
    {
        using var files = TemporaryMihomoFiles.Create();
        var selector = new FakeMihomoControllerClient();
        await using var service = new MihomoRuntimeService(
            new FakeMihomoLauncher(),
            new FakeMihomoProbe(ready: true),
            selector);
        await service.StartAsync(new MihomoRuntimeOptions(
            files.ExecutablePath,
            files.ConfigurationPath,
            11469,
            TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(50)));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.StopAsync(cancelled.Token));
        Assert.True(service.IsReady);

        using var lease = await service.AcquireNodeSelectionAsync("GLOBAL", "Taiwan 01");
        Assert.Equal(["Taiwan 01"], selector.SelectedNodes);
    }

    [Fact]
    public async Task ControllerClientUsesLoopbackPutWithBoundedJsonAndRejectsRemoteEndpoints()
    {
        var handler = new RecordingControllerHandler();
        using var client = new LoopbackMihomoControllerClient(handler);

        await client.SelectNodeAsync(
            new Uri("http://127.0.0.1:9090/"),
            "🚀 节点选择",
            "台湾 01",
            authorizationToken: null,
            CancellationToken.None);

        Assert.Equal(HttpMethod.Put, handler.Methods[0]);
        Assert.Equal("/proxies/%F0%9F%9A%80%20%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9", handler.RequestUri!.AbsolutePath);
        using (var body = JsonDocument.Parse(handler.Body!))
        {
            Assert.Equal("台湾 01", body.RootElement.GetProperty("name").GetString());
        }
        await Assert.ThrowsAsync<MihomoRuntimeConfigurationException>(() => client.SelectNodeAsync(
            new Uri("http://controller.example.test:9090/"),
            "GLOBAL",
            "Taiwan 01",
            authorizationToken: null,
            CancellationToken.None));
        Assert.Equal(2, handler.RequestCount);
    }

    [Fact]
    public async Task ControllerClientUsesBearerForPutAndGetAndRequiresExactNowConfirmation()
    {
        var accepted = new RecordingControllerHandler(selectedNode: "Taiwan 01");
        using var client = new LoopbackMihomoControllerClient(accepted);

        await client.SelectNodeAsync(
            new Uri("http://127.0.0.1:9090/"),
            "GLOBAL",
            "Taiwan 01",
            "controller secret+/=",
            CancellationToken.None);

        Assert.Equal([HttpMethod.Put, HttpMethod.Get], accepted.Methods);
        Assert.All(accepted.AuthorizationHeaders, value =>
            Assert.Equal("Bearer controller secret+/=", value));

        var mismatched = new RecordingControllerHandler(selectedNode: "Taiwan 02");
        using var mismatchedClient = new LoopbackMihomoControllerClient(mismatched);
        await Assert.ThrowsAsync<MihomoRuntimeUnavailableException>(() =>
            mismatchedClient.SelectNodeAsync(
                new Uri("http://127.0.0.1:9090/"),
                "GLOBAL",
                "Taiwan 01",
                "controller secret+/=",
                CancellationToken.None));
    }

    [Fact]
    public async Task ControllerReadinessProbeRejectsNonLoopbackWithoutSendingARequest()
    {
        var probe = new LoopbackMihomoControllerProbe();

        var ready = await probe.WaitUntilReadyAsync(
            new Uri("http://controller.example.test:9090/"),
            TimeSpan.FromMilliseconds(50),
            authorizationToken: null,
            CancellationToken.None);

        Assert.False(ready);
    }

    [Fact]
    public void ModelNodeAssignmentUsesExactProviderAndModelIdentityAndNeverFallsBackDirect()
    {
        var providerId = Guid.NewGuid();
        var nodeId = Guid.NewGuid();
        var assignments = new ModelNodeAssignmentService(
            [new ModelNodeAssignment(providerId, "gemini-2.5-pro", nodeId)]);
        var nodes = new[]
        {
            new NodeConfiguration(nodeId, "Selected", new Uri("http://127.0.0.1:7890/"), true),
        };
        var runtime = new FakeMihomoRuntimeStatus(isReady: true);

        var selected = assignments.Resolve(providerId, "gemini-2.5-pro", nodes, runtime);
        var wrongProvider = assignments.Resolve(Guid.NewGuid(), "gemini-2.5-pro", nodes, runtime);
        var wrongCase = assignments.Resolve(providerId, "Gemini-2.5-Pro", nodes, runtime);
        var missingNode = assignments.Resolve(providerId, "gemini-2.5-pro", [], runtime);
        var failedRuntime = assignments.Resolve(providerId, "gemini-2.5-pro", nodes, new FakeMihomoRuntimeStatus(isReady: false));

        Assert.Equal(ModelNodeRouteKind.Proxy, selected.Kind);
        Assert.Equal(nodes[0].ProxyUri, selected.ProxyUri);
        Assert.All([wrongProvider, wrongCase, missingNode, failedRuntime], decision =>
        {
            Assert.Equal(ModelNodeRouteKind.Blocked, decision.Kind);
            Assert.Null(decision.ProxyUri);
        });
    }

    [Fact]
    public void AssignmentRejectsNonLoopbackProxyEndpoints()
    {
        var providerId = Guid.NewGuid();
        var nodeId = Guid.NewGuid();
        var assignments = new ModelNodeAssignmentService(
            [new ModelNodeAssignment(providerId, "model", nodeId)]);
        var nodes = new[]
        {
            new NodeConfiguration(nodeId, "unsafe", new Uri("http://proxy.example.test:7890/"), true),
        };

        var decision = assignments.Resolve(providerId, "model", nodes, new FakeMihomoRuntimeStatus(isReady: true));

        Assert.Equal(ModelNodeRouteKind.Blocked, decision.Kind);
        Assert.Equal("unsafe_proxy_endpoint", decision.ErrorCode);
        Assert.Null(decision.ProxyUri);
    }

    [Fact]
    public async Task BatchVerifierBoundsConcurrencyAndDoesNotPermanentlyQuarantineTransientFailures()
    {
        var transientTarget = new ModelHealthTarget(Guid.NewGuid(), "transient");
        var permanentTarget = new ModelHealthTarget(Guid.NewGuid(), "removed");
        var targets = Enumerable.Range(0, 12)
            .Select(index => new ModelHealthTarget(Guid.NewGuid(), $"model-{index}"))
            .Append(transientTarget)
            .Append(permanentTarget)
            .ToArray();
        var probe = new TrackingHealthProbe(transientTarget, permanentTarget);
        var verifier = new BatchHealthVerifier(probe, maximumConcurrency: 3);

        var results = await verifier.VerifyAsync(targets, CancellationToken.None);

        Assert.Equal(targets, results.Select(result => result.Target));
        Assert.InRange(probe.MaximumObservedConcurrency, 1, 3);
        var transient = Assert.Single(results, result => result.Target == transientTarget);
        var permanent = Assert.Single(results, result => result.Target == permanentTarget);
        Assert.Equal(HealthState.Degraded, transient.State);
        Assert.False(transient.ShouldPermanentlyQuarantine);
        Assert.Equal(HealthState.Failed, permanent.State);
        Assert.True(permanent.ShouldPermanentlyQuarantine);
    }

    [Fact]
    public async Task BatchVerifierTreatsUnexpectedProbeExceptionsAsRetryableWithoutLeakingDetails()
    {
        var target = new ModelHealthTarget(Guid.NewGuid(), "throws");
        var verifier = new BatchHealthVerifier(new ThrowingHealthProbe("credential-top-secret"), maximumConcurrency: 2);

        var result = Assert.Single(await verifier.VerifyAsync([target], CancellationToken.None));

        Assert.Equal(HealthState.Degraded, result.State);
        Assert.False(result.ShouldPermanentlyQuarantine);
        Assert.Equal("probe_unavailable", result.DetailCode);
        Assert.DoesNotContain("credential-top-secret", result.DetailCode, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BatchVerifierDoesNotQuarantineAuthenticationFailures()
    {
        var target = new ModelHealthTarget(Guid.NewGuid(), "needs-reauthorization");
        var verifier = new BatchHealthVerifier(new AuthenticationFailureProbe(), maximumConcurrency: 1);

        var result = Assert.Single(await verifier.VerifyAsync([target], CancellationToken.None));

        Assert.Equal(HealthState.Degraded, result.State);
        Assert.False(result.ShouldPermanentlyQuarantine);
        Assert.Equal("credential_reauthorization_required", result.DetailCode);
    }

    private sealed class FakeMihomoLauncher(FakeMihomoProcess? process = null) : IMihomoProcessLauncher
    {
        private readonly FakeMihomoProcess _process = process ?? new FakeMihomoProcess(exitOnStopRequest: true);

        public int LaunchCount { get; private set; }
        public string LastArguments { get; private set; } = string.Empty;

        public IMihomoProcessHandle Launch(string executablePath, IReadOnlyList<string> arguments)
        {
            LaunchCount++;
            LastArguments = string.Join(' ', arguments);
            return _process;
        }
    }

    private sealed class RestartableMihomoLauncher : IMihomoProcessLauncher
    {
        public int LaunchCount { get; private set; }
        public string AllArguments { get; private set; } = string.Empty;

        public IMihomoProcessHandle Launch(string executablePath, IReadOnlyList<string> arguments)
        {
            LaunchCount++;
            AllArguments += string.Join(' ', arguments);
            return new FakeMihomoProcess(exitOnStopRequest: true);
        }
    }

    private sealed class FakeMihomoProcess(bool exitOnStopRequest) : IMihomoProcessHandle
    {
        private readonly TaskCompletionSource<int> _exit = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool HasExited => _exit.Task.IsCompleted;
        public int StopRequestCount { get; private set; }
        public int KillCount { get; private set; }

        public void RequestStop()
        {
            StopRequestCount++;
            if (exitOnStopRequest)
            {
                _exit.TrySetResult(0);
            }
        }

        public void Kill()
        {
            KillCount++;
            _exit.TrySetResult(-1);
        }

        public async Task<int> WaitForExitAsync(CancellationToken cancellationToken) =>
            await _exit.Task.WaitAsync(cancellationToken);

        public ValueTask DisposeAsync()
        {
            _exit.TrySetResult(0);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeMihomoProbe(bool ready) : IMihomoControllerProbe
    {
        public Task<bool> WaitUntilReadyAsync(
            Uri controllerUri,
            TimeSpan timeout,
            string? authorizationToken,
            CancellationToken cancellationToken) =>
            Task.FromResult(ready);
    }

    private sealed class FakeMihomoControllerClient : IMihomoControllerClient, IDisposable
    {
        public Uri? ControllerUri { get; private set; }
        public string? SelectorGroup { get; private set; }
        public string? NodeName { get; private set; }
        public List<string> SelectedNodes { get; } = [];
        public bool IsDisposed { get; private set; }

        public Task SelectNodeAsync(
            Uri controllerUri,
            string selectorGroup,
            string nodeName,
            string? authorizationToken,
            CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            ControllerUri = controllerUri;
            SelectorGroup = selectorGroup;
            NodeName = nodeName;
            SelectedNodes.Add(nodeName);
            return Task.CompletedTask;
        }

        public void Dispose() => IsDisposed = true;
    }

    private sealed class RecordingControllerHandler(string? selectedNode = null) : HttpMessageHandler
    {
        public int RequestCount { get; private set; }
        public HttpMethod? Method { get; private set; }
        public List<HttpMethod> Methods { get; } = [];
        public List<string?> AuthorizationHeaders { get; } = [];
        public Uri? RequestUri { get; private set; }
        public string? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestCount++;
            Method = request.Method;
            Methods.Add(request.Method);
            AuthorizationHeaders.Add(
                request.Headers.TryGetValues("Authorization", out var values)
                    ? values.Single()
                    : null);
            RequestUri = request.RequestUri;
            if (request.Content is not null)
            {
                Body = await request.Content.ReadAsStringAsync(cancellationToken);
            }
            return request.Method == HttpMethod.Get
                ? new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(
                        JsonSerializer.Serialize(new { now = selectedNode ?? "台湾 01" }),
                        Encoding.UTF8,
                        "application/json"),
                }
                : new HttpResponseMessage(HttpStatusCode.NoContent);
        }
    }

    private sealed class FakeMihomoRuntimeStatus(bool isReady) : IMihomoRuntimeStatus
    {
        public bool IsReady { get; } = isReady;
    }

    private sealed class TrackingHealthProbe(ModelHealthTarget transient, ModelHealthTarget permanent) : IModelHealthProbe
    {
        private int _active;
        private int _maximum;

        public int MaximumObservedConcurrency => Volatile.Read(ref _maximum);

        public async Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken)
        {
            var active = Interlocked.Increment(ref _active);
            UpdateMaximum(active);
            try
            {
                await Task.Delay(10, cancellationToken);
                if (target == transient)
                {
                    return new ModelHealthObservation(ModelHealthOutcome.TransientFailure, null, "transport_timeout");
                }

                if (target == permanent)
                {
                    return new ModelHealthObservation(ModelHealthOutcome.PermanentModelFailure, null, "model_not_found");
                }

                return new ModelHealthObservation(ModelHealthOutcome.Healthy, TimeSpan.FromMilliseconds(8), "verified");
            }
            finally
            {
                Interlocked.Decrement(ref _active);
            }
        }

        private void UpdateMaximum(int value)
        {
            var current = Volatile.Read(ref _maximum);
            while (value > current)
            {
                var observed = Interlocked.CompareExchange(ref _maximum, value, current);
                if (observed == current)
                {
                    return;
                }

                current = observed;
            }
        }
    }

    private sealed class ThrowingHealthProbe(string message) : IModelHealthProbe
    {
        public Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken) =>
            throw new InvalidOperationException(message);
    }

    private sealed class AuthenticationFailureProbe : IModelHealthProbe
    {
        public Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken) =>
            Task.FromResult(new ModelHealthObservation(
                ModelHealthOutcome.AuthenticationFailure,
                null,
                "credential_reauthorization_required"));
    }

    private sealed class TemporaryMihomoFiles : IDisposable
    {
        private TemporaryMihomoFiles(string directory)
        {
            Directory = directory;
            ExecutablePath = Path.Combine(directory, "mihomo.exe");
            ConfigurationPath = Path.Combine(directory, "config.yaml");
            File.WriteAllText(ExecutablePath, "test executable placeholder");
            File.WriteAllText(ConfigurationPath, "mixed-port: 7890");
        }

        private string Directory { get; }
        public string ExecutablePath { get; }
        public string ConfigurationPath { get; }

        public static TemporaryMihomoFiles Create()
        {
            var directory = Path.Combine(Path.GetTempPath(), $"modelhub-mihomo-{Guid.NewGuid():N}");
            System.IO.Directory.CreateDirectory(directory);
            return new TemporaryMihomoFiles(directory);
        }

        public void Dispose()
        {
            try
            {
                System.IO.Directory.Delete(Directory, recursive: true);
            }
            catch (IOException)
            {
                // Best effort cleanup for test-only files.
            }
        }
    }
}
