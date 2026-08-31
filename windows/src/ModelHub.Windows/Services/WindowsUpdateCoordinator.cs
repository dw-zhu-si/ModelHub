using Velopack;

namespace ModelHub.Windows.Services;

public sealed record WindowsUpdateCandidate(string Version, long SizeBytes, object Handle);

public interface IWindowsUpdateEngine
{
    bool IsInstalled { get; }
    Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken);
    Task DownloadAsync(WindowsUpdateCandidate candidate, Action<int>? progress, CancellationToken cancellationToken);
    void ApplyAndRestart(WindowsUpdateCandidate candidate);
}

public sealed class VelopackUpdateEngine : IWindowsUpdateEngine
{
    private readonly UpdateManager _manager;

    public VelopackUpdateEngine(Uri feedUri, IEnumerable<string>? allowedHosts = null)
    {
        ValidateFeedUri(feedUri, allowedHosts ?? ["github.com", "pm.jcm99.com"]);
        _manager = new UpdateManager(feedUri.AbsoluteUri, new UpdateOptions
        {
            AllowVersionDowngrade = false,
            ExplicitChannel = "win",
            MaximumDeltasBeforeFallback = 3,
        });
    }

    public bool IsInstalled => _manager.IsInstalled;

    public async Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken)
    {
        if (!IsInstalled)
        {
            return null;
        }
        var update = await _manager.CheckForUpdatesAsync().WaitAsync(cancellationToken).ConfigureAwait(false);
        return update is null
            ? null
            : new WindowsUpdateCandidate(update.TargetFullRelease.Version.ToString(), update.TargetFullRelease.Size, update);
    }

    public async Task DownloadAsync(WindowsUpdateCandidate candidate, Action<int>? progress, CancellationToken cancellationToken)
    {
        if (candidate.Handle is not UpdateInfo update || !candidate.Version.Equals(update.TargetFullRelease.Version.ToString(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The update candidate does not belong to this Velopack feed.");
        }
        await _manager.DownloadUpdatesAsync(update, progress, cancellationToken).ConfigureAwait(false);
    }

    public void ApplyAndRestart(WindowsUpdateCandidate candidate)
    {
        if (candidate.Handle is not UpdateInfo update || !candidate.Version.Equals(update.TargetFullRelease.Version.ToString(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The update candidate does not belong to this Velopack feed.");
        }
        _manager.ApplyUpdatesAndRestart(update.TargetFullRelease, []);
    }

    public static void ValidateFeedUri(Uri feedUri, IEnumerable<string> allowedHosts)
    {
        ArgumentNullException.ThrowIfNull(feedUri);
        var hosts = allowedHosts.Where(host => !string.IsNullOrWhiteSpace(host)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!feedUri.IsAbsoluteUri || !feedUri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(feedUri.UserInfo) || !string.IsNullOrEmpty(feedUri.Query) || !string.IsNullOrEmpty(feedUri.Fragment) ||
            !hosts.Contains(feedUri.IdnHost) || feedUri.AbsolutePath.Length > 1024)
        {
            throw new InvalidOperationException("The Windows update feed must be an allowlisted credential-free HTTPS URL.");
        }
    }
}

public sealed class WindowsUpdateCoordinator : IDisposable
{
    private readonly IWindowsUpdateEngine _engine;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WindowsUpdateCandidate? _staged;

    public WindowsUpdateCoordinator(IWindowsUpdateEngine engine)
    {
        _engine = engine;
    }

    public bool IsInstalled => _engine.IsInstalled;
    public WindowsUpdateCandidate? Staged => _staged;

    public async Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _staged = null;
            return await _engine.CheckAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StageAsync(WindowsUpdateCandidate candidate, Action<int>? progress = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _engine.DownloadAsync(candidate, value => progress?.Invoke(Math.Clamp(value, 0, 100)), cancellationToken).ConfigureAwait(false);
            _staged = candidate;
        }
        finally
        {
            _gate.Release();
        }
    }

    public void ApplyStagedAndRestart()
    {
        var staged = _staged ?? throw new InvalidOperationException("No verified update has been staged by this application session.");
        _engine.ApplyAndRestart(staged);
    }

    public void Dispose() => _gate.Dispose();
}
