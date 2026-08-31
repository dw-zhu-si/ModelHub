using System.Net;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class ProxyHttpClientPoolTests
{
    [Fact]
    public void UnassignedModelGetsAnExplicitDirectClient()
    {
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));

        using var acquisition = pool.AcquireForModel(
            Guid.NewGuid(),
            "unassigned",
            assignments: [],
            nodes: [],
            new RuntimeStatus(isReady: false));

        Assert.Equal(ProxyClientRouteKind.Direct, acquisition.Kind);
        Assert.NotNull(acquisition.Client);
        Assert.Null(Assert.Single(factory.Created).ProxyEndpoint);
    }

    [Fact]
    public void InvalidUnassignedIdentityIsBlockedInsteadOfDirect()
    {
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));

        using var acquisition = pool.AcquireForModel(
            Guid.Empty,
            " ",
            assignments: [],
            nodes: [],
            new RuntimeStatus(isReady: true));

        Assert.Equal(ProxyClientRouteKind.Blocked, acquisition.Kind);
        Assert.Equal("invalid_model_identity", acquisition.ErrorCode);
        Assert.Empty(factory.Created);
    }

    [Fact]
    public void AssignedModelUsesOnlyItsExactLocalProxy()
    {
        var providerId = Guid.NewGuid();
        var nodeId = Guid.NewGuid();
        var endpoint = new Uri("http://127.0.0.1:7890/");
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));

        using var acquisition = pool.AcquireForModel(
            providerId,
            "gemini-2.5-pro",
            [new ModelNodeAssignment(providerId, "gemini-2.5-pro", nodeId)],
            [new NodeConfiguration(nodeId, "Taiwan 01", endpoint, true)],
            new RuntimeStatus(isReady: true));

        Assert.Equal(ProxyClientRouteKind.Proxy, acquisition.Kind);
        Assert.Equal(endpoint, acquisition.ProxyEndpoint);
        Assert.Equal(endpoint, Assert.Single(factory.Created).ProxyEndpoint);
    }

    [Fact]
    public async Task SelectorAssignmentsSelectPerRequestHoldTheLeaseAndEvictOldProxyConnections()
    {
        var providerId = Guid.NewGuid();
        var firstNodeId = Guid.NewGuid();
        var secondNodeId = Guid.NewGuid();
        var endpoint = new Uri("http://127.0.0.1:7890/");
        var factory = new TrackingHandlerFactory();
        using var coordinator = new SerialSelectionCoordinator();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));
        var nodes = new[]
        {
            new NodeConfiguration(firstNodeId, "Taiwan 01", endpoint, true, "GLOBAL"),
            new NodeConfiguration(secondNodeId, "Taiwan 02", endpoint, false, "GLOBAL"),
        };

        var first = await pool.AcquireForModelAsync(
            providerId,
            "model-a",
            [new ModelNodeAssignment(providerId, "model-a", firstNodeId)],
            nodes,
            coordinator,
            CancellationToken.None);
        var firstClient = first.Client;
        var secondTask = pool.AcquireForModelAsync(
            providerId,
            "model-b",
            [new ModelNodeAssignment(providerId, "model-b", secondNodeId)],
            nodes,
            coordinator,
            CancellationToken.None);

        await coordinator.SecondWaitStarted.Task.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.False(secondTask.IsCompleted);
        Assert.Equal(1, coordinator.ActiveLeaseCount);

        first.Dispose();
        using var second = await secondTask.WaitAsync(TimeSpan.FromSeconds(1));

        Assert.Equal(["Taiwan 01", "Taiwan 02"], coordinator.SelectedNodes);
        Assert.NotSame(firstClient, second.Client);
        Assert.Equal(2, factory.Created.Count);
        Assert.True(factory.Created[0].IsDisposed);
        Assert.False(factory.Created[1].IsDisposed);
        Assert.Equal(1, coordinator.ActiveLeaseCount);

        second.Dispose();
        Assert.Equal(0, coordinator.ActiveLeaseCount);
    }

    [Fact]
    public async Task SelectorAssignmentWithoutSelectionCoordinatorIsBlockedAndNeverConnects()
    {
        var providerId = Guid.NewGuid();
        var nodeId = Guid.NewGuid();
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));

        using var acquisition = await pool.AcquireForModelAsync(
            providerId,
            "assigned-model",
            [new ModelNodeAssignment(providerId, "assigned-model", nodeId)],
            [new NodeConfiguration(nodeId, "Taiwan 01", new Uri("http://127.0.0.1:7890/"), true, "GLOBAL")],
            new RuntimeStatus(isReady: true),
            CancellationToken.None);

        Assert.Equal(ProxyClientRouteKind.Blocked, acquisition.Kind);
        Assert.Equal("mihomo_selection_unavailable", acquisition.ErrorCode);
        Assert.Empty(factory.Created);
    }

    [Theory]
    [InlineData(false, true, "mihomo_runtime_unavailable")]
    [InlineData(true, false, "assigned_node_missing")]
    public void AssignedModelFailureIsBlockedAndNeverCreatesADirectClient(
        bool runtimeReady,
        bool nodePresent,
        string expectedError)
    {
        var providerId = Guid.NewGuid();
        var nodeId = Guid.NewGuid();
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));
        var nodes = nodePresent
            ? new[] { new NodeConfiguration(nodeId, "selected", new Uri("http://127.0.0.1:7890/"), true) }
            : [];

        using var acquisition = pool.AcquireForModel(
            providerId,
            "assigned-model",
            [new ModelNodeAssignment(providerId, "assigned-model", nodeId)],
            nodes,
            new RuntimeStatus(runtimeReady));

        Assert.Equal(ProxyClientRouteKind.Blocked, acquisition.Kind);
        Assert.Equal(expectedError, acquisition.ErrorCode);
        Assert.Null(acquisition.Client);
        Assert.Empty(factory.Created);
    }

    [Fact]
    public void SameRouteReusesTheSameClientAndUpdatesLruOrder()
    {
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 2));
        var firstEndpoint = new Uri("http://127.0.0.1:7890/");
        var secondEndpoint = new Uri("http://127.0.0.1:7891/");

        using var first = pool.AcquireExplicitProxy(firstEndpoint);
        var firstClient = first.Client;
        first.Dispose();
        using var direct = pool.AcquireDirect();
        direct.Dispose();
        using var firstAgain = pool.AcquireExplicitProxy(firstEndpoint);
        Assert.Same(firstClient, firstAgain.Client);
        firstAgain.Dispose();
        using var second = pool.AcquireExplicitProxy(secondEndpoint);

        Assert.Equal(2, pool.EntryCount);
        Assert.Equal(3, factory.Created.Count);
        Assert.True(factory.Created.Single(entry => entry.ProxyEndpoint is null).IsDisposed);
        Assert.False(factory.Created.Single(entry => entry.ProxyEndpoint == firstEndpoint).IsDisposed);
    }

    [Fact]
    public void ConfigurationEvictionDoesNotDisposeAnInFlightLease()
    {
        var endpoint = new Uri("http://127.0.0.1:7890/");
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 1));
        var inFlight = pool.AcquireExplicitProxy(endpoint);
        var handler = Assert.Single(factory.Created);

        pool.RetainProxyEndpoints([]);

        Assert.Equal(0, pool.EntryCount);
        Assert.False(handler.IsDisposed);
        using var saturated = pool.AcquireDirect();
        Assert.Equal(ProxyClientRouteKind.Blocked, saturated.Kind);
        Assert.Equal("proxy_pool_saturated", saturated.ErrorCode);

        inFlight.Dispose();
        Assert.True(handler.IsDisposed);
        using var direct = pool.AcquireDirect();
        Assert.Equal(ProxyClientRouteKind.Direct, direct.Kind);
    }

    [Fact]
    public async Task ConfigurationEvictionAllowsAnAlreadyStartedRequestToFinish()
    {
        var endpoint = new Uri("http://127.0.0.1:7890/");
        var factory = new BlockingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 1));
        var lease = pool.AcquireExplicitProxy(endpoint);
        var client = Assert.IsType<HttpClient>(lease.Client);
        var responseTask = client.GetAsync("https://offline.example.test/health", CancellationToken.None);
        await factory.Handler.RequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(1));

        pool.RetainProxyEndpoints([]);

        Assert.False(factory.Handler.IsDisposed);
        factory.Handler.Complete();
        using var response = await responseTask;
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.False(factory.Handler.IsDisposed);

        lease.Dispose();
        Assert.True(factory.Handler.IsDisposed);
    }

    [Fact]
    public void ExplicitProxyRejectsRemoteAndCredentialBearingEndpoints()
    {
        var factory = new TrackingHandlerFactory();
        using var pool = new ProxyHttpClientPool(factory, new ProxyHttpClientPoolOptions(MaximumEntries: 3));

        using var remote = pool.AcquireExplicitProxy(new Uri("http://proxy.example.test:7890/"));
        using var credentials = pool.AcquireExplicitProxy(new Uri("http://user:secret@127.0.0.1:7890/"));

        Assert.Equal(ProxyClientRouteKind.Blocked, remote.Kind);
        Assert.Equal("unsafe_proxy_endpoint", remote.ErrorCode);
        Assert.Equal(ProxyClientRouteKind.Blocked, credentials.Kind);
        Assert.Empty(factory.Created);
    }

    [Fact]
    public void DefaultHandlerDisablesRedirectsAndUsesBoundedConnectionSettings()
    {
        var options = new ProxyHttpClientPoolOptions(
            MaximumEntries: ProxyHttpClientPoolOptions.DefaultMaximumEntries,
            ConnectTimeout: TimeSpan.FromSeconds(2),
            RequestTimeout: TimeSpan.FromSeconds(9),
            PooledConnectionLifetime: TimeSpan.FromMinutes(2));
        var factory = new DefaultProxyHttpHandlerFactory();
        using var handler = Assert.IsType<SocketsHttpHandler>(
            factory.Create(new Uri("http://127.0.0.1:7890/"), options));

        Assert.False(handler.AllowAutoRedirect);
        Assert.True(handler.UseProxy);
        Assert.Equal(TimeSpan.FromSeconds(2), handler.ConnectTimeout);
        Assert.Equal(TimeSpan.FromMinutes(2), handler.PooledConnectionLifetime);
        var webProxy = Assert.IsType<WebProxy>(handler.Proxy);
        Assert.Equal(new Uri("http://127.0.0.1:7890/"), webProxy.Address);
    }

    [Fact]
    public void PoolCapacityCoversSixteenManagedNodesOneManualEndpointAndDirect()
    {
        Assert.Equal(18, ProxyHttpClientPoolOptions.DefaultMaximumEntries);
        Assert.Equal(17, ProxyHttpClientPoolOptions.MaximumProxyEntries);
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new ProxyHttpClientPoolOptions(MaximumEntries: 19));
    }

    private sealed class RuntimeStatus(bool isReady) : IMihomoRuntimeStatus
    {
        public bool IsReady { get; } = isReady;
    }

    private sealed class SerialSelectionCoordinator : IMihomoRuntimeStatus, IMihomoNodeSelectionCoordinator, IDisposable
    {
        private readonly SemaphoreSlim _gate = new(1, 1);
        private int _activeLeaseCount;
        private int _waitCount;
        private string? _currentNode;

        public bool IsReady => true;
        public int ActiveLeaseCount => Volatile.Read(ref _activeLeaseCount);
        public List<string> SelectedNodes { get; } = [];
        public TaskCompletionSource SecondWaitStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<IMihomoNodeSelectionLease> AcquireNodeSelectionAsync(
            string selectorGroup,
            string nodeName,
            CancellationToken cancellationToken = default)
        {
            if (Interlocked.Increment(ref _waitCount) == 2)
            {
                SecondWaitStarted.TrySetResult();
            }
            await _gate.WaitAsync(cancellationToken);
            var changed = !_currentNode?.Equals(nodeName, StringComparison.Ordinal) ?? true;
            _currentNode = nodeName;
            SelectedNodes.Add(nodeName);
            Interlocked.Increment(ref _activeLeaseCount);
            return new CallbackLease(changed, () =>
            {
                Interlocked.Decrement(ref _activeLeaseCount);
                _gate.Release();
            });
        }

        public void Dispose() => _gate.Dispose();
    }

    private sealed class CallbackLease(bool selectionChanged, Action release) : IMihomoNodeSelectionLease
    {
        private Action? _release = release;

        public bool SelectionChanged { get; } = selectionChanged;

        public void Dispose() => Interlocked.Exchange(ref _release, null)?.Invoke();
    }

    private sealed class TrackingHandlerFactory : IProxyHttpHandlerFactory
    {
        public List<TrackingHandler> Created { get; } = [];

        public HttpMessageHandler Create(Uri? proxyEndpoint, ProxyHttpClientPoolOptions options)
        {
            var handler = new TrackingHandler(proxyEndpoint);
            Created.Add(handler);
            return handler;
        }
    }

    private sealed class TrackingHandler(Uri? proxyEndpoint) : HttpMessageHandler
    {
        public Uri? ProxyEndpoint { get; } = proxyEndpoint;
        public bool IsDisposed { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));

        protected override void Dispose(bool disposing)
        {
            IsDisposed = true;
            base.Dispose(disposing);
        }
    }

    private sealed class BlockingHandlerFactory : IProxyHttpHandlerFactory
    {
        public BlockingHandler Handler { get; } = new();

        public HttpMessageHandler Create(Uri? proxyEndpoint, ProxyHttpClientPoolOptions options) => Handler;
    }

    private sealed class BlockingHandler : HttpMessageHandler
    {
        private readonly TaskCompletionSource<HttpResponseMessage> _response =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource RequestStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool IsDisposed { get; private set; }

        public void Complete() => _response.TrySetResult(new HttpResponseMessage(HttpStatusCode.OK));

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestStarted.TrySetResult();
            return await _response.Task.WaitAsync(cancellationToken);
        }

        protected override void Dispose(bool disposing)
        {
            IsDisposed = true;
            base.Dispose(disposing);
        }
    }
}
