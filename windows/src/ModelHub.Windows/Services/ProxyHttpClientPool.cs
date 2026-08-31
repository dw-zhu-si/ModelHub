using System.Net;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public sealed record ProxyHttpClientPoolOptions
{
    public const int MaximumProxyEntries = 17;
    public const int DefaultMaximumEntries = MaximumProxyEntries + 1;
    private static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DefaultConnectionLifetime = TimeSpan.FromMinutes(5);

    public ProxyHttpClientPoolOptions(
        int MaximumEntries = DefaultMaximumEntries,
        TimeSpan? ConnectTimeout = null,
        TimeSpan? RequestTimeout = null,
        TimeSpan? PooledConnectionLifetime = null)
    {
        if (MaximumEntries is < 1 or > DefaultMaximumEntries)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumEntries));
        }

        var connectTimeout = ConnectTimeout ?? DefaultConnectTimeout;
        var requestTimeout = RequestTimeout ?? DefaultRequestTimeout;
        var connectionLifetime = PooledConnectionLifetime ?? DefaultConnectionLifetime;
        if (connectTimeout < TimeSpan.FromMilliseconds(100) || connectTimeout > TimeSpan.FromSeconds(30))
        {
            throw new ArgumentOutOfRangeException(nameof(ConnectTimeout));
        }

        if (requestTimeout < TimeSpan.FromSeconds(1) || requestTimeout > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(nameof(RequestTimeout));
        }

        if (connectionLifetime < TimeSpan.FromSeconds(30) || connectionLifetime > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(nameof(PooledConnectionLifetime));
        }

        this.MaximumEntries = MaximumEntries;
        this.ConnectTimeout = connectTimeout;
        this.RequestTimeout = requestTimeout;
        this.PooledConnectionLifetime = connectionLifetime;
    }

    public int MaximumEntries { get; }
    public TimeSpan ConnectTimeout { get; }
    public TimeSpan RequestTimeout { get; }
    public TimeSpan PooledConnectionLifetime { get; }
}

public enum ProxyClientRouteKind
{
    Direct,
    Proxy,
    Blocked,
}

public interface IProxyHttpHandlerFactory
{
    HttpMessageHandler Create(Uri? proxyEndpoint, ProxyHttpClientPoolOptions options);
}

public sealed class DefaultProxyHttpHandlerFactory : IProxyHttpHandlerFactory
{
    public HttpMessageHandler Create(Uri? proxyEndpoint, ProxyHttpClientPoolOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (proxyEndpoint is not null && !ProxyHttpClientPool.IsSafeExplicitProxy(proxyEndpoint))
        {
            throw new ArgumentException("The proxy endpoint must be an explicit loopback HTTP endpoint.", nameof(proxyEndpoint));
        }

        return new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = options.ConnectTimeout,
            MaxConnectionsPerServer = 32,
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
            PooledConnectionLifetime = options.PooledConnectionLifetime,
            Proxy = proxyEndpoint is null ? null : new WebProxy(proxyEndpoint),
            UseCookies = false,
            UseProxy = proxyEndpoint is not null,
        };
    }
}

/// <summary>
/// A route result plus a reference-counted HttpClient lease. Disposing an acquisition releases the lease;
/// a blocked acquisition has no client. Callers must retain the acquisition until SendAsync completes.
/// </summary>
public sealed class ProxyHttpClientAcquisition : IDisposable
{
    private Action? _release;

    internal ProxyHttpClientAcquisition(
        ProxyClientRouteKind kind,
        HttpClient? client,
        Uri? proxyEndpoint,
        string errorCode,
        Action? release)
    {
        Kind = kind;
        Client = client;
        ProxyEndpoint = proxyEndpoint;
        ErrorCode = errorCode;
        _release = release;
    }

    public ProxyClientRouteKind Kind { get; }
    public HttpClient? Client { get; }
    public Uri? ProxyEndpoint { get; }
    public string ErrorCode { get; }

    internal void AttachRelease(Action release)
    {
        ArgumentNullException.ThrowIfNull(release);
        var current = _release;
        _release = () =>
        {
            try
            {
                current?.Invoke();
            }
            finally
            {
                release();
            }
        };
    }

    public void Dispose() => Interlocked.Exchange(ref _release, null)?.Invoke();
}

/// <summary>
/// Bounded LRU pool for direct and explicit-loopback-proxy HttpClient handlers. Entries with active leases
/// are retired but never disposed or reused during eviction, preventing cancellation of in-flight requests.
/// </summary>
public sealed class ProxyHttpClientPool : IDisposable
{
    private readonly object _gate = new();
    private readonly IProxyHttpHandlerFactory _handlerFactory;
    private readonly ProxyHttpClientPoolOptions _options;
    private readonly Dictionary<RouteKey, PoolEntry> _entries = [];
    private readonly LinkedList<RouteKey> _lru = [];
    private int _liveEntryCount;
    private bool _disposed;

    public ProxyHttpClientPool(
        IProxyHttpHandlerFactory? handlerFactory = null,
        ProxyHttpClientPoolOptions? options = null)
    {
        _handlerFactory = handlerFactory ?? new DefaultProxyHttpHandlerFactory();
        _options = options ?? new ProxyHttpClientPoolOptions();
    }

    public int EntryCount
    {
        get
        {
            lock (_gate)
            {
                return _entries.Count;
            }
        }
    }

    public ProxyHttpClientAcquisition AcquireForModel(
        Guid providerId,
        string modelId,
        IReadOnlyCollection<ModelNodeAssignment> assignments,
        IReadOnlyCollection<NodeConfiguration> nodes,
        IMihomoRuntimeStatus runtime)
    {
        ArgumentNullException.ThrowIfNull(assignments);
        ArgumentNullException.ThrowIfNull(nodes);
        ArgumentNullException.ThrowIfNull(runtime);
        if (providerId == Guid.Empty ||
            string.IsNullOrWhiteSpace(modelId) ||
            modelId.Length > 256 ||
            !modelId.Equals(modelId.Trim(), StringComparison.Ordinal) ||
            modelId.Any(char.IsControl))
        {
            return Blocked("invalid_model_identity");
        }

        var matchingAssignments = assignments
            .Where(candidate => candidate.ProviderId == providerId &&
                candidate.ModelId.Equals(modelId, StringComparison.Ordinal))
            .Take(2)
            .ToArray();
        if (matchingAssignments.Length == 0)
        {
            return AcquireDirect();
        }

        if (matchingAssignments.Length > 1)
        {
            return Blocked("duplicate_node_assignment");
        }

        ModelNodeRouteDecision decision;
        try
        {
            var resolver = new ModelNodeAssignmentService(assignments);
            decision = resolver.Resolve(providerId, modelId, nodes, runtime);
        }
        catch (ArgumentException)
        {
            return Blocked("invalid_node_assignment");
        }
        catch (InvalidOperationException)
        {
            return Blocked("invalid_node_assignment");
        }

        if (decision.Kind != ModelNodeRouteKind.Proxy || decision.ProxyUri is null)
        {
            return Blocked(decision.ErrorCode);
        }

        if (decision.SelectorGroup is not null)
        {
            return Blocked("mihomo_selection_required");
        }

        return AcquireExplicitProxy(decision.ProxyUri);
    }

    public async Task<ProxyHttpClientAcquisition> AcquireForModelAsync(
        Guid providerId,
        string modelId,
        IReadOnlyCollection<ModelNodeAssignment> assignments,
        IReadOnlyCollection<NodeConfiguration> nodes,
        IMihomoRuntimeStatus runtime,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(assignments);
        ArgumentNullException.ThrowIfNull(nodes);
        ArgumentNullException.ThrowIfNull(runtime);
        if (providerId == Guid.Empty ||
            string.IsNullOrWhiteSpace(modelId) ||
            modelId.Length > 256 ||
            !modelId.Equals(modelId.Trim(), StringComparison.Ordinal) ||
            modelId.Any(char.IsControl))
        {
            return Blocked("invalid_model_identity");
        }

        var matchingAssignments = assignments
            .Where(candidate => candidate.ProviderId == providerId &&
                candidate.ModelId.Equals(modelId, StringComparison.Ordinal))
            .Take(2)
            .ToArray();
        if (matchingAssignments.Length == 0)
        {
            return AcquireDirect();
        }

        if (matchingAssignments.Length > 1)
        {
            return Blocked("duplicate_node_assignment");
        }

        ModelNodeRouteDecision decision;
        try
        {
            var resolver = new ModelNodeAssignmentService(assignments);
            decision = resolver.Resolve(providerId, modelId, nodes, runtime);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            return Blocked("invalid_node_assignment");
        }

        if (decision.Kind != ModelNodeRouteKind.Proxy || decision.ProxyUri is null)
        {
            return Blocked(decision.ErrorCode);
        }

        if (decision.SelectorGroup is null)
        {
            return AcquireExplicitProxy(decision.ProxyUri);
        }

        if (runtime is not IMihomoNodeSelectionCoordinator coordinator
            || decision.NodeName is null)
        {
            return Blocked("mihomo_selection_unavailable");
        }

        IMihomoNodeSelectionLease selectionLease;
        try
        {
            selectionLease = await coordinator.AcquireNodeSelectionAsync(
                decision.SelectorGroup,
                decision.NodeName,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is MihomoRuntimeConfigurationException or MihomoRuntimeUnavailableException)
        {
            return Blocked("mihomo_selection_failed");
        }

        var leaseTransferred = false;
        try
        {
            if (selectionLease.SelectionChanged)
            {
                EvictProxyEndpoint(decision.ProxyUri);
            }
            var acquisition = AcquireExplicitProxy(decision.ProxyUri);
            if (acquisition.Kind == ProxyClientRouteKind.Blocked)
            {
                return acquisition;
            }
            acquisition.AttachRelease(selectionLease.Dispose);
            leaseTransferred = true;
            return acquisition;
        }
        finally
        {
            if (!leaseTransferred)
            {
                selectionLease.Dispose();
            }
        }
    }

    public ProxyHttpClientAcquisition AcquireDirect() => Acquire(RouteKey.Direct, proxyEndpoint: null);

    public ProxyHttpClientAcquisition AcquireExplicitProxy(Uri proxyEndpoint)
    {
        ArgumentNullException.ThrowIfNull(proxyEndpoint);
        return !IsSafeExplicitProxy(proxyEndpoint)
            ? Blocked("unsafe_proxy_endpoint")
            : Acquire(RouteKey.ForProxy(proxyEndpoint), proxyEndpoint);
    }

    /// <summary>
    /// Retires proxy handlers that are no longer present after a configuration update. The direct entry is
    /// unaffected. In-use retired entries are disposed only after their final acquisition is released.
    /// </summary>
    public void RetainProxyEndpoints(IEnumerable<Uri> activeProxyEndpoints)
    {
        ArgumentNullException.ThrowIfNull(activeProxyEndpoints);
        var retained = new HashSet<RouteKey>();
        foreach (var endpoint in activeProxyEndpoints)
        {
            if (!IsSafeExplicitProxy(endpoint))
            {
                throw new ArgumentException("The active proxy set contains an unsafe endpoint.", nameof(activeProxyEndpoints));
            }

            retained.Add(RouteKey.ForProxy(endpoint));
        }

        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var stale = _entries.Keys
                .Where(key => !key.IsDirect && !retained.Contains(key))
                .ToArray();
            foreach (var key in stale)
            {
                RetireEntry(_entries[key]);
            }
        }
    }

    /// <summary>
    /// Retires the handler for one loopback proxy after a confirmed selector switch. Active requests keep
    /// their handler until their lease completes; future requests cannot reuse a tunnel from the old node.
    /// </summary>
    public void EvictProxyEndpoint(Uri proxyEndpoint)
    {
        ArgumentNullException.ThrowIfNull(proxyEndpoint);
        if (!IsSafeExplicitProxy(proxyEndpoint))
        {
            throw new ArgumentException("The proxy endpoint must be an explicit loopback HTTP endpoint.", nameof(proxyEndpoint));
        }

        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var key = RouteKey.ForProxy(proxyEndpoint);
            if (_entries.TryGetValue(key, out var entry))
            {
                RetireEntry(entry);
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            foreach (var entry in _entries.Values.ToArray())
            {
                RetireEntry(entry);
            }
        }
    }

    internal static bool IsSafeExplicitProxy(Uri endpoint)
    {
        if (!endpoint.IsAbsoluteUri ||
            endpoint.Scheme is not ("http" or "https") ||
            !string.IsNullOrEmpty(endpoint.UserInfo) ||
            !string.IsNullOrEmpty(endpoint.Query) ||
            !string.IsNullOrEmpty(endpoint.Fragment) ||
            (endpoint.AbsolutePath.Length > 0 && endpoint.AbsolutePath != "/"))
        {
            return false;
        }

        var host = endpoint.Host.Length > 2 && endpoint.Host[0] == '[' && endpoint.Host[^1] == ']'
            ? endpoint.Host[1..^1]
            : endpoint.Host;
        return IPAddress.TryParse(host, out var address) &&
            IPAddress.IsLoopback(address) &&
            endpoint.Port is >= 1 and <= 65535;
    }

    private ProxyHttpClientAcquisition Acquire(RouteKey key, Uri? proxyEndpoint)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_entries.TryGetValue(key, out var existing))
            {
                existing.LeaseCount++;
                Touch(existing);
                return Lease(existing);
            }

            if (_liveEntryCount >= _options.MaximumEntries && !EvictLeastRecentlyUsedIdleEntry())
            {
                return Blocked("proxy_pool_saturated");
            }

            var handler = _handlerFactory.Create(proxyEndpoint, _options) ??
                throw new InvalidOperationException("The HTTP handler factory returned no handler.");
            HttpClient client;
            try
            {
                client = new HttpClient(handler, disposeHandler: true)
                {
                    Timeout = _options.RequestTimeout,
                };
            }
            catch
            {
                handler.Dispose();
                throw;
            }

            var node = _lru.AddFirst(key);
            var created = new PoolEntry(key, proxyEndpoint, client, node)
            {
                LeaseCount = 1,
            };
            _entries.Add(key, created);
            _liveEntryCount++;
            return Lease(created);
        }
    }

    private ProxyHttpClientAcquisition Lease(PoolEntry entry)
    {
        var kind = entry.Key.IsDirect ? ProxyClientRouteKind.Direct : ProxyClientRouteKind.Proxy;
        return new ProxyHttpClientAcquisition(
            kind,
            entry.Client,
            entry.ProxyEndpoint,
            string.Empty,
            () => Release(entry));
    }

    private void Release(PoolEntry entry)
    {
        lock (_gate)
        {
            if (entry.LeaseCount <= 0)
            {
                return;
            }

            entry.LeaseCount--;
            if (entry.Retired && entry.LeaseCount == 0)
            {
                DisposeEntry(entry);
            }
        }
    }

    private bool EvictLeastRecentlyUsedIdleEntry()
    {
        var node = _lru.Last;
        while (node is not null)
        {
            var previous = node.Previous;
            var entry = _entries[node.Value];
            if (entry.LeaseCount == 0)
            {
                RetireEntry(entry);
                return true;
            }

            node = previous;
        }

        return false;
    }

    private void Touch(PoolEntry entry)
    {
        _lru.Remove(entry.LruNode);
        _lru.AddFirst(entry.LruNode);
    }

    private void RetireEntry(PoolEntry entry)
    {
        if (entry.Retired)
        {
            return;
        }

        entry.Retired = true;
        _entries.Remove(entry.Key);
        _lru.Remove(entry.LruNode);
        if (entry.LeaseCount == 0)
        {
            DisposeEntry(entry);
        }
    }

    private void DisposeEntry(PoolEntry entry)
    {
        if (entry.IsDisposed)
        {
            return;
        }

        entry.IsDisposed = true;
        entry.Client.Dispose();
        _liveEntryCount--;
    }

    private static ProxyHttpClientAcquisition Blocked(string errorCode) =>
        new(ProxyClientRouteKind.Blocked, null, null, errorCode, release: null);

    private readonly record struct RouteKey(bool IsDirect, string Value)
    {
        public static RouteKey Direct { get; } = new(IsDirect: true, Value: string.Empty);

        public static RouteKey ForProxy(Uri endpoint) =>
            new(IsDirect: false, Value: endpoint.AbsoluteUri);
    }

    private sealed class PoolEntry(
        RouteKey key,
        Uri? proxyEndpoint,
        HttpClient client,
        LinkedListNode<RouteKey> lruNode)
    {
        public RouteKey Key { get; } = key;
        public Uri? ProxyEndpoint { get; } = proxyEndpoint;
        public HttpClient Client { get; } = client;
        public LinkedListNode<RouteKey> LruNode { get; } = lruNode;
        public int LeaseCount { get; set; }
        public bool Retired { get; set; }
        public bool IsDisposed { get; set; }
    }
}
