using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace ModelHub.Windows.Services;

public sealed record MihomoRuntimeOptions(
    string ExecutablePath,
    string ConfigurationPath,
    int ControllerPort,
    TimeSpan StartupTimeout,
    TimeSpan ShutdownTimeout,
    string? ControllerAuthorizationToken = null);

public interface IMihomoRuntimeStatus
{
    bool IsReady { get; }
}

public interface IMihomoRuntimeController : IMihomoRuntimeStatus
{
    Task StartAsync(MihomoRuntimeOptions options, CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
    Task SelectNodeAsync(string selectorGroup, string nodeName, CancellationToken cancellationToken = default);
}

public interface IMihomoNodeSelectionCoordinator : IMihomoRuntimeStatus
{
    Task<IMihomoNodeSelectionLease> AcquireNodeSelectionAsync(
        string selectorGroup,
        string nodeName,
        CancellationToken cancellationToken = default);
}

public interface IMihomoNodeSelectionLease : IDisposable
{
    bool SelectionChanged { get; }
}

public interface IMihomoProcessLauncher
{
    IMihomoProcessHandle Launch(string executablePath, IReadOnlyList<string> arguments);
}

public interface IMihomoProcessHandle : IAsyncDisposable
{
    bool HasExited { get; }
    void RequestStop();
    void Kill();
    Task<int> WaitForExitAsync(CancellationToken cancellationToken);
}

public interface IMihomoControllerProbe
{
    Task<bool> WaitUntilReadyAsync(
        Uri controllerUri,
        TimeSpan timeout,
        string? authorizationToken,
        CancellationToken cancellationToken);
}

public interface IMihomoControllerClient
{
    Task SelectNodeAsync(
        Uri controllerUri,
        string selectorGroup,
        string nodeName,
        string? authorizationToken,
        CancellationToken cancellationToken);
}

/// <summary>
/// Owns one explicitly selected, already-installed mihomo executable. It never searches PATH, downloads,
/// copies, updates, or bundles mihomo. The external controller is forced onto IPv4 loopback.
/// </summary>
public sealed class MihomoRuntimeService : IMihomoRuntimeController, IMihomoNodeSelectionCoordinator, IAsyncDisposable
{
    private static readonly TimeSpan MinimumTimeout = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan MaximumStartupTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan MaximumShutdownTimeout = TimeSpan.FromSeconds(10);
    private readonly IMihomoProcessLauncher _launcher;
    private readonly IMihomoControllerProbe _probe;
    private readonly IMihomoControllerClient _controllerClient;
    private readonly bool _ownsControllerClient;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _selectionSwitchGate = new(1, 1);
    private readonly object _selectionStateGate = new();
    private IMihomoProcessHandle? _ownedProcess;
    private string? _controllerAuthorizationToken;
    private string? _activeSelectorGroup;
    private string? _activeNodeName;
    private int _activeSelectionLeaseCount;
    private int _pendingSelectionSwitchCount;
    private bool _selectionTransitionInProgress;
    private TaskCompletionSource _selectionStateChanged = NewSelectionStateSignal();
    private TimeSpan _shutdownTimeout = TimeSpan.FromSeconds(2);
    private bool _disposed;
    private volatile bool _isReady;

    public MihomoRuntimeService()
        : this(
            new SystemMihomoProcessLauncher(),
            new LoopbackMihomoControllerProbe(),
            new LoopbackMihomoControllerClient(),
            ownsControllerClient: true)
    {
    }

    public MihomoRuntimeService(
        IMihomoProcessLauncher launcher,
        IMihomoControllerProbe probe,
        IMihomoControllerClient? controllerClient = null)
        : this(
            launcher,
            probe,
            controllerClient ?? new LoopbackMihomoControllerClient(),
            ownsControllerClient: true)
    {
    }

    private MihomoRuntimeService(
        IMihomoProcessLauncher launcher,
        IMihomoControllerProbe probe,
        IMihomoControllerClient controllerClient,
        bool ownsControllerClient)
    {
        _launcher = launcher ?? throw new ArgumentNullException(nameof(launcher));
        _probe = probe ?? throw new ArgumentNullException(nameof(probe));
        _controllerClient = controllerClient ?? throw new ArgumentNullException(nameof(controllerClient));
        _ownsControllerClient = ownsControllerClient;
    }

    public bool IsReady => _isReady && _ownedProcess is { HasExited: false };
    public Uri? ControllerUri { get; private set; }

    public async Task StartAsync(MihomoRuntimeOptions options, CancellationToken cancellationToken = default)
    {
        ValidateOptions(options);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_ownedProcess is not null)
            {
                throw new MihomoRuntimeConfigurationException("A mihomo process is already owned by this runtime.");
            }

            var controllerUri = new Uri($"http://127.0.0.1:{options.ControllerPort}/", UriKind.Absolute);
            var arguments = new[]
            {
                "-f",
                Path.GetFullPath(options.ConfigurationPath),
                "-ext-ctl",
                $"127.0.0.1:{options.ControllerPort}",
            };

            IMihomoProcessHandle process;
            try
            {
                process = _launcher.Launch(Path.GetFullPath(options.ExecutablePath), arguments);
            }
            catch (Exception exception) when (exception is InvalidOperationException or IOException or System.ComponentModel.Win32Exception)
            {
                throw new MihomoRuntimeUnavailableException("The user-provided mihomo executable could not be started.");
            }

            _ownedProcess = process;
            _shutdownTimeout = options.ShutdownTimeout;
            _controllerAuthorizationToken = options.ControllerAuthorizationToken;
            ControllerUri = controllerUri;
            try
            {
                var ready = await _probe.WaitUntilReadyAsync(
                    controllerUri,
                    options.StartupTimeout,
                    options.ControllerAuthorizationToken,
                    cancellationToken).ConfigureAwait(false);
                if (!ready || process.HasExited)
                {
                    throw new MihomoRuntimeUnavailableException("The loopback mihomo controller did not become ready.");
                }

                _isReady = true;
                lock (_selectionStateGate)
                {
                    _activeSelectorGroup = null;
                    _activeNodeName = null;
                    PulseSelectionStateLocked();
                }
            }
            catch
            {
                _isReady = false;
                ControllerUri = null;
                _controllerAuthorizationToken = null;
                _ownedProcess = null;
                await StopOwnedProcessAsync(process, options.ShutdownTimeout).ConfigureAwait(false);
                throw;
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public void EnsureReady()
    {
        if (!IsReady || ControllerUri is null)
        {
            throw new MihomoRuntimeUnavailableException("The loopback mihomo runtime is unavailable.");
        }
    }

    public async Task SelectNodeAsync(
        string selectorGroup,
        string nodeName,
        CancellationToken cancellationToken = default)
    {
        using var lease = await AcquireNodeSelectionAsync(
            selectorGroup,
            nodeName,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<IMihomoNodeSelectionLease> AcquireNodeSelectionAsync(
        string selectorGroup,
        string nodeName,
        CancellationToken cancellationToken = default)
    {
        ValidateSelectorValue(selectorGroup, nameof(selectorGroup));
        ValidateSelectorValue(nodeName, nameof(nodeName));
        var pendingSwitchRegistered = false;
        lock (_selectionStateGate)
        {
            ThrowIfSelectionUnavailableLocked();
            if (!_selectionTransitionInProgress
                && _pendingSelectionSwitchCount == 0
                && IsActiveSelectionLocked(selectorGroup, nodeName))
            {
                _activeSelectionLeaseCount++;
                return new SelectionLease(this, selectionChanged: false);
            }

            _pendingSelectionSwitchCount++;
            pendingSwitchRegistered = true;
            PulseSelectionStateLocked();
        }

        var switchGateAcquired = false;
        try
        {
            await _selectionSwitchGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            switchGateAcquired = true;
            while (true)
            {
                Task stateChanged;
                lock (_selectionStateGate)
                {
                    ThrowIfSelectionUnavailableLocked();
                    if (!_selectionTransitionInProgress
                        && IsActiveSelectionLocked(selectorGroup, nodeName))
                    {
                        _activeSelectionLeaseCount++;
                        _pendingSelectionSwitchCount--;
                        pendingSwitchRegistered = false;
                        PulseSelectionStateLocked();
                        return new SelectionLease(this, selectionChanged: false);
                    }

                    if (!_selectionTransitionInProgress && _activeSelectionLeaseCount == 0)
                    {
                        _selectionTransitionInProgress = true;
                        break;
                    }

                    stateChanged = _selectionStateChanged.Task;
                }

                await stateChanged.WaitAsync(cancellationToken).ConfigureAwait(false);
            }

            try
            {
                await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    ObjectDisposedException.ThrowIf(_disposed, this);
                    EnsureReady();
                    await _controllerClient.SelectNodeAsync(
                        ControllerUri!,
                        selectorGroup,
                        nodeName,
                        _controllerAuthorizationToken,
                        cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    _lifecycleGate.Release();
                }

                lock (_selectionStateGate)
                {
                    _activeSelectorGroup = selectorGroup;
                    _activeNodeName = nodeName;
                    _activeSelectionLeaseCount++;
                    _selectionTransitionInProgress = false;
                    _pendingSelectionSwitchCount--;
                    pendingSwitchRegistered = false;
                    PulseSelectionStateLocked();
                }

                return new SelectionLease(this, selectionChanged: true);
            }
            catch
            {
                lock (_selectionStateGate)
                {
                    _activeSelectorGroup = null;
                    _activeNodeName = null;
                    _selectionTransitionInProgress = false;
                    PulseSelectionStateLocked();
                }
                throw;
            }
        }
        finally
        {
            if (pendingSwitchRegistered)
            {
                lock (_selectionStateGate)
                {
                    _pendingSelectionSwitchCount--;
                    PulseSelectionStateLocked();
                }
            }
            if (switchGateAcquired)
            {
                _selectionSwitchGate.Release();
            }
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        var stopPendingRegistered = true;
        lock (_selectionStateGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _pendingSelectionSwitchCount++;
            PulseSelectionStateLocked();
        }
        try
        {
            await _selectionSwitchGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lock (_selectionStateGate)
            {
                _pendingSelectionSwitchCount--;
                PulseSelectionStateLocked();
            }
            throw;
        }

        try
        {
            lock (_selectionStateGate)
            {
                _pendingSelectionSwitchCount--;
                stopPendingRegistered = false;
                _isReady = false;
                PulseSelectionStateLocked();
            }
            await WaitForActiveSelectionLeasesToDrainAsync(CancellationToken.None).ConfigureAwait(false);
            await _lifecycleGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                ControllerUri = null;
                _controllerAuthorizationToken = null;
                var process = _ownedProcess;
                _ownedProcess = null;
                if (process is not null)
                {
                    await StopOwnedProcessAsync(process, _shutdownTimeout).ConfigureAwait(false);
                }
            }
            finally
            {
                _lifecycleGate.Release();
            }
        }
        finally
        {
            lock (_selectionStateGate)
            {
                if (stopPendingRegistered)
                {
                    _pendingSelectionSwitchCount--;
                }
                _activeSelectorGroup = null;
                _activeNodeName = null;
                _selectionTransitionInProgress = false;
                PulseSelectionStateLocked();
            }
            _selectionSwitchGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (_selectionStateGate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _isReady = false;
            PulseSelectionStateLocked();
        }

        await _selectionSwitchGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await WaitForActiveSelectionLeasesToDrainAsync(CancellationToken.None).ConfigureAwait(false);
            await _lifecycleGate.WaitAsync().ConfigureAwait(false);
            try
            {
                ControllerUri = null;
                _controllerAuthorizationToken = null;
                var process = _ownedProcess;
                _ownedProcess = null;
                if (process is not null)
                {
                    await StopOwnedProcessAsync(process, _shutdownTimeout).ConfigureAwait(false);
                }

                if (_ownsControllerClient && _controllerClient is IDisposable disposable)
                {
                    disposable.Dispose();
                }
            }
            finally
            {
                _lifecycleGate.Release();
            }
        }
        finally
        {
            lock (_selectionStateGate)
            {
                _activeSelectorGroup = null;
                _activeNodeName = null;
                _selectionTransitionInProgress = false;
                PulseSelectionStateLocked();
            }
            _selectionSwitchGate.Release();
        }
    }

    private bool IsActiveSelectionLocked(string selectorGroup, string nodeName) =>
        selectorGroup.Equals(_activeSelectorGroup, StringComparison.Ordinal)
        && nodeName.Equals(_activeNodeName, StringComparison.Ordinal);

    private void ThrowIfSelectionUnavailableLocked()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!IsReady)
        {
            throw new MihomoRuntimeUnavailableException("The loopback mihomo runtime is unavailable.");
        }
    }

    private async Task WaitForActiveSelectionLeasesToDrainAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            Task stateChanged;
            lock (_selectionStateGate)
            {
                if (_activeSelectionLeaseCount == 0)
                {
                    return;
                }
                stateChanged = _selectionStateChanged.Task;
            }
            await stateChanged.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private void ReleaseSelectionLease()
    {
        lock (_selectionStateGate)
        {
            if (_activeSelectionLeaseCount <= 0)
            {
                return;
            }
            _activeSelectionLeaseCount--;
            PulseSelectionStateLocked();
        }
    }

    private void PulseSelectionStateLocked()
    {
        var completed = _selectionStateChanged;
        _selectionStateChanged = NewSelectionStateSignal();
        completed.TrySetResult();
    }

    private static TaskCompletionSource NewSelectionStateSignal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static void ValidateOptions(MihomoRuntimeOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrWhiteSpace(options.ExecutablePath) ||
            !Path.IsPathFullyQualified(options.ExecutablePath) ||
            !File.Exists(options.ExecutablePath))
        {
            throw new MihomoRuntimeConfigurationException("Select an existing mihomo executable by its full path.");
        }

        if (string.IsNullOrWhiteSpace(options.ConfigurationPath) ||
            !Path.IsPathFullyQualified(options.ConfigurationPath) ||
            !File.Exists(options.ConfigurationPath))
        {
            throw new MihomoRuntimeConfigurationException("Select an existing mihomo configuration file by its full path.");
        }

        if (options.ControllerPort is < 1024 or > 65535)
        {
            throw new MihomoRuntimeConfigurationException("The loopback controller port is outside the allowed range.");
        }

        if (options.StartupTimeout < MinimumTimeout || options.StartupTimeout > MaximumStartupTimeout ||
            options.ShutdownTimeout < MinimumTimeout || options.ShutdownTimeout > MaximumShutdownTimeout)
        {
            throw new MihomoRuntimeConfigurationException("The mihomo lifecycle timeout is outside the allowed range.");
        }

        if (options.ControllerAuthorizationToken is { } token
            && !MihomoControllerAuthorization.IsValidToken(token))
        {
            throw new MihomoRuntimeConfigurationException("The mihomo controller authorization token is invalid.");
        }
    }

    private static void ValidateSelectorValue(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value)
            || !value.Equals(value.Trim(), StringComparison.Ordinal)
            || value.Length > 128
            || value.Any(char.IsControl))
        {
            throw new MihomoRuntimeConfigurationException($"{parameterName} is invalid.");
        }
    }

    private static async Task StopOwnedProcessAsync(IMihomoProcessHandle process, TimeSpan shutdownTimeout)
    {
        try
        {
            if (!process.HasExited)
            {
                process.RequestStop();
                using var gracefulTimeout = new CancellationTokenSource(shutdownTimeout);
                try
                {
                    await process.WaitForExitAsync(gracefulTimeout.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (gracefulTimeout.IsCancellationRequested)
                {
                    process.Kill();
                    using var killTimeout = new CancellationTokenSource(MaximumShutdownTimeout);
                    try
                    {
                        await process.WaitForExitAsync(killTimeout.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (killTimeout.IsCancellationRequested)
                    {
                        // The owned process ignored termination. Release the handle and keep the runtime failed closed.
                    }
                }
            }
        }
        finally
        {
            await process.DisposeAsync().ConfigureAwait(false);
        }
    }

    private sealed class SelectionLease(
        MihomoRuntimeService owner,
        bool selectionChanged) : IMihomoNodeSelectionLease
    {
        private MihomoRuntimeService? _owner = owner;

        public bool SelectionChanged { get; } = selectionChanged;

        public void Dispose() => Interlocked.Exchange(ref _owner, null)?.ReleaseSelectionLease();
    }
}

public sealed class LoopbackMihomoControllerClient : IMihomoControllerClient, IDisposable
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(5);
    private const int MaximumControllerResponseBytes = 64 * 1024;
    private readonly HttpClient _client;

    public LoopbackMihomoControllerClient()
    {
        _client = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(2),
            MaxConnectionsPerServer = 2,
            UseProxy = false,
        })
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public LoopbackMihomoControllerClient(HttpMessageHandler handler)
    {
        _client = new HttpClient(handler ?? throw new ArgumentNullException(nameof(handler)))
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public async Task SelectNodeAsync(
        Uri controllerUri,
        string selectorGroup,
        string nodeName,
        string? authorizationToken,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(controllerUri);
        if (!IsSafeSelectorValue(selectorGroup) || !IsSafeSelectorValue(nodeName))
        {
            throw new MihomoRuntimeConfigurationException("The mihomo selector group or node name is invalid.");
        }
        if (!controllerUri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || !IPAddress.TryParse(controllerUri.Host, out var address)
            || !address.Equals(IPAddress.Loopback)
            || controllerUri.Port is < 1024 or > 65535
            || controllerUri.UserInfo.Length != 0
            || !controllerUri.AbsolutePath.Equals("/", StringComparison.Ordinal)
            || controllerUri.Query.Length != 0
            || controllerUri.Fragment.Length != 0)
        {
            throw new MihomoRuntimeConfigurationException("The mihomo controller must be an uncredentialed loopback HTTP endpoint.");
        }

        var endpoint = new Uri(controllerUri, $"proxies/{Uri.EscapeDataString(selectorGroup)}");
        var payload = JsonSerializer.SerializeToUtf8Bytes(new { name = nodeName });
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(RequestTimeout);
            using (var request = new HttpRequestMessage(HttpMethod.Put, endpoint)
            {
                Content = new ByteArrayContent(payload),
            })
            {
                ApplyAuthorization(request, authorizationToken);
                request.Content.Headers.ContentType = new("application/json") { CharSet = Encoding.UTF8.WebName };
                using var response = await _client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    deadline.Token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    throw new MihomoRuntimeUnavailableException("The mihomo controller rejected the requested node selection.");
                }
            }

            using var confirmationRequest = new HttpRequestMessage(HttpMethod.Get, endpoint);
            ApplyAuthorization(confirmationRequest, authorizationToken);
            using var confirmation = await _client.SendAsync(
                confirmationRequest,
                HttpCompletionOption.ResponseHeadersRead,
                deadline.Token).ConfigureAwait(false);
            if (!confirmation.IsSuccessStatusCode)
            {
                throw new MihomoRuntimeUnavailableException("The mihomo controller could not confirm the requested node selection.");
            }

            var confirmedNode = await ReadConfirmedNodeAsync(confirmation, deadline.Token).ConfigureAwait(false);
            if (!nodeName.Equals(confirmedNode, StringComparison.Ordinal))
            {
                throw new MihomoRuntimeUnavailableException("The mihomo controller did not activate the requested node.");
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new MihomoRuntimeUnavailableException("The mihomo controller node selection timed out.");
        }
        catch (HttpRequestException exception)
        {
            throw new MihomoRuntimeUnavailableException("The mihomo controller could not apply the requested node selection.", exception);
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException)
        {
            throw new MihomoRuntimeUnavailableException("The mihomo controller returned an invalid node selection confirmation.", exception);
        }
        finally
        {
            Array.Clear(payload);
        }
    }

    private static bool IsSafeSelectorValue(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Equals(value.Trim(), StringComparison.Ordinal)
        && value.Length <= 128
        && !value.Any(char.IsControl);

    private static void ApplyAuthorization(HttpRequestMessage request, string? authorizationToken)
    {
        MihomoControllerAuthorization.Apply(request, authorizationToken);
    }

    private static async Task<string?> ReadConfirmedNodeAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is > MaximumControllerResponseBytes)
        {
            throw new InvalidDataException("The mihomo controller response exceeded the allowed size.");
        }

        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[4096];
        try
        {
            while (true)
            {
                var read = await source.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }
                if (buffer.Length + read > MaximumControllerResponseBytes)
                {
                    throw new InvalidDataException("The mihomo controller response exceeded the allowed size.");
                }
                await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            }

            buffer.Position = 0;
            using var document = await JsonDocument.ParseAsync(
                buffer,
                new JsonDocumentOptions { MaxDepth = 8 },
                cancellationToken).ConfigureAwait(false);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("now", out var now)
                && now.ValueKind == JsonValueKind.String
                    ? now.GetString()
                    : null;
        }
        finally
        {
            Array.Clear(chunk);
            if (buffer.TryGetBuffer(out var segment) && segment.Array is not null)
            {
                Array.Clear(segment.Array, segment.Offset, segment.Count);
            }
        }
    }

    public void Dispose() => _client.Dispose();
}

public sealed class SystemMihomoProcessLauncher : IMihomoProcessLauncher
{
    public IMihomoProcessHandle Launch(string executablePath, IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executablePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(executablePath) ?? throw new InvalidOperationException("The executable directory is unavailable."),
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        var process = Process.Start(startInfo) ?? throw new InvalidOperationException("mihomo did not return a process handle.");
        return new SystemMihomoProcessHandle(process);
    }
}

public sealed class SystemMihomoProcessHandle(Process process) : IMihomoProcessHandle
{
    private readonly Process _process = process ?? throw new ArgumentNullException(nameof(process));

    public bool HasExited => _process.HasExited;

    public void RequestStop()
    {
        if (!_process.HasExited)
        {
            _process.CloseMainWindow();
        }
    }

    public void Kill()
    {
        if (!_process.HasExited)
        {
            _process.Kill(entireProcessTree: true);
        }
    }

    public async Task<int> WaitForExitAsync(CancellationToken cancellationToken)
    {
        await _process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return _process.ExitCode;
    }

    public ValueTask DisposeAsync()
    {
        _process.Dispose();
        return ValueTask.CompletedTask;
    }
}

public sealed class LoopbackMihomoControllerProbe : IMihomoControllerProbe
{
    public async Task<bool> WaitUntilReadyAsync(
        Uri controllerUri,
        TimeSpan timeout,
        string? authorizationToken,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(controllerUri);
        if (!controllerUri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
            !IPAddress.TryParse(controllerUri.Host, out var address) ||
            !IPAddress.IsLoopback(address))
        {
            return false;
        }

        using var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromMilliseconds(Math.Min(timeout.TotalMilliseconds, 500)),
            UseProxy = false,
        };
        using var client = new HttpClient(handler)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        var endpoint = new Uri(controllerUri, "version");
        while (!deadline.IsCancellationRequested)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
                MihomoControllerAuthorization.Apply(request, authorizationToken);
                using var response = await client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    deadline.Token).ConfigureAwait(false);
                if (response.IsSuccessStatusCode)
                {
                    return true;
                }
            }
            catch (HttpRequestException)
            {
                // The loopback listener is not ready yet.
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                return false;
            }

            try
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                return false;
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        return false;
    }
}

internal static class MihomoControllerAuthorization
{
    public static bool IsValidToken(string token) =>
        !string.IsNullOrWhiteSpace(token)
        && token.Equals(token.Trim(), StringComparison.Ordinal)
        && token.Length <= 4096
        && !token.Any(char.IsControl);

    public static void Apply(HttpRequestMessage request, string? authorizationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (authorizationToken is null)
        {
            return;
        }
        if (!IsValidToken(authorizationToken)
            || !request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {authorizationToken}"))
        {
            throw new MihomoRuntimeConfigurationException("The mihomo controller authorization token is invalid.");
        }
    }
}

public sealed class MihomoRuntimeConfigurationException : InvalidOperationException
{
    public MihomoRuntimeConfigurationException()
    {
    }

    public MihomoRuntimeConfigurationException(string message)
        : base(message)
    {
    }

    public MihomoRuntimeConfigurationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class MihomoRuntimeUnavailableException : InvalidOperationException
{
    public MihomoRuntimeUnavailableException()
    {
    }

    public MihomoRuntimeUnavailableException(string message)
        : base(message)
    {
    }

    public MihomoRuntimeUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
