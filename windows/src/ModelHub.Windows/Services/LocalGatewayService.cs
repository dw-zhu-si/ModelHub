using System.Net;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>
/// Loopback-only OpenAI-compatible gateway for configured OpenAI-compatible providers.
/// It deliberately refuses non-loopback binding, oversized bodies, redirects, and unknown models.
/// </summary>
public sealed class LocalGatewayService : IAsyncDisposable
{
    private const int MaximumRequestBytes = 4 * 1024 * 1024;
    private const int MaximumMultipartRequestBytes = 32 * 1024 * 1024;
    private const int MaximumUpstreamResponseBytes = 32 * 1024 * 1024;
    private const int MaximumConcurrentRequests = 32;
    private const int MaximumConcurrentMultipartRequests = 2;
    private const int MaximumConcurrentMediaTasks = 4;
    private readonly Func<ModelHubConfiguration> _configuration;
    private readonly ICredentialVault _vault;
    private readonly HttpClient? _injectedClient;
    private readonly ProxyHttpClientPool _proxyClients;
    private readonly bool _ownsProxyClients;
    private readonly IMihomoRuntimeStatus _mihomoRuntime;
    private readonly ModelRouteResolver _routeResolver;
    private readonly Func<Guid, string, RouteTargetState>? _routeState;
    private readonly TimeSpan _asyncMediaPollInterval;
    private readonly UsageLedgerStore _ledger;
    private readonly MediaTaskRegistry _mediaTasks;
    private readonly MediaArtifactStore _mediaArtifacts;
    private readonly int _maximumStreamingResponseBytes;
    private readonly TimeSpan _streamFirstByteTimeout;
    private readonly TimeSpan _streamIdleTimeout;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly CancellationTokenSource _shutdown = new();
    private CancellationTokenSource _requestCancellation = new();
    private readonly SemaphoreSlim _requestSlots = new(MaximumConcurrentRequests, MaximumConcurrentRequests);
    private readonly SemaphoreSlim _multipartSlots = new(MaximumConcurrentMultipartRequests, MaximumConcurrentMultipartRequests);
    private readonly SemaphoreSlim _mediaTaskSlots = new(MaximumConcurrentMediaTasks, MaximumConcurrentMediaTasks);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<int, Task> _activeRequests = new();
    private int _requestSequence;
    private HttpListener? _listener;
    private Task? _serveTask;

    public LocalGatewayService(
        Func<ModelHubConfiguration> configuration,
        ICredentialVault vault,
        HttpMessageHandler? handler = null,
        UsageLedgerStore? ledger = null,
        MediaTaskRegistry? mediaTasks = null,
        MediaArtifactStore? mediaArtifacts = null,
        int maximumStreamingResponseBytes = MaximumUpstreamResponseBytes * 2,
        TimeSpan? streamFirstByteTimeout = null,
        TimeSpan? streamIdleTimeout = null,
        ProxyHttpClientPool? proxyClientPool = null,
        IMihomoRuntimeStatus? mihomoRuntime = null,
        ModelRouteResolver? routeResolver = null,
        Func<Guid, string, RouteTargetState>? routeState = null,
        TimeSpan? asyncMediaPollInterval = null)
    {
        _configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
        _vault = vault ?? throw new ArgumentNullException(nameof(vault));
        _injectedClient = handler is null
            ? null
            : new HttpClient(handler, disposeHandler: false)
            {
                Timeout = TimeSpan.FromSeconds(90),
            };
        _proxyClients = proxyClientPool ?? new ProxyHttpClientPool(
            _injectedClient is null
                ? null
                : new ExistingClientHandlerFactory(_injectedClient));
        _ownsProxyClients = proxyClientPool is null;
        _mihomoRuntime = mihomoRuntime ?? UnavailableMihomoRuntimeStatus.Instance;
        _routeResolver = routeResolver ?? new ModelRouteResolver();
        _routeState = routeState;
        _asyncMediaPollInterval = asyncMediaPollInterval is null
            ? TimeSpan.FromSeconds(2)
            : asyncMediaPollInterval.Value >= TimeSpan.Zero
                && asyncMediaPollInterval.Value <= TimeSpan.FromMinutes(1)
                ? asyncMediaPollInterval.Value
                : throw new ArgumentOutOfRangeException(nameof(asyncMediaPollInterval));
        _ledger = ledger ?? new UsageLedgerStore();
        _mediaTasks = mediaTasks ?? new MediaTaskRegistry();
        _mediaArtifacts = mediaArtifacts ?? new MediaArtifactStore();
        _maximumStreamingResponseBytes = maximumStreamingResponseBytes is >= 1024 and <= MaximumUpstreamResponseBytes * 2
            ? maximumStreamingResponseBytes
            : throw new ArgumentOutOfRangeException(nameof(maximumStreamingResponseBytes));
        _streamFirstByteTimeout = ValidateStreamTimeout(streamFirstByteTimeout ?? TimeSpan.FromSeconds(15), nameof(streamFirstByteTimeout));
        _streamIdleTimeout = ValidateStreamTimeout(streamIdleTimeout ?? TimeSpan.FromSeconds(30), nameof(streamIdleTimeout));
    }

    public bool IsRunning => _listener?.IsListening == true;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsRunning)
            {
                return;
            }
            if (_requestCancellation.IsCancellationRequested)
            {
                _requestCancellation.Dispose();
                _requestCancellation = new CancellationTokenSource();
            }
            var configuration = _configuration();
            if (!ConfigurationStore.IsSafe(configuration))
            {
                throw new InvalidOperationException("The loopback gateway configuration is unsafe or invalid.");
            }
            var gateway = configuration.Gateway;
            if (string.IsNullOrWhiteSpace(_vault.Read(gateway.TokenCredentialTarget)))
            {
                throw new InvalidOperationException("Create a local gateway token in Windows Credential Manager before starting the API.");
            }

            var listener = new HttpListener();
            listener.Prefixes.Add($"http://127.0.0.1:{gateway.Port}/");
            listener.Start();
            _listener = listener;
            _serveTask = Task.Run(() => ServeAsync(listener, _requestCancellation.Token), CancellationToken.None);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task StopAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _requestCancellation.Cancel();
            _listener?.Close();
            _listener = null;
        }
        finally
        {
            _lifecycleGate.Release();
        }

        if (_serveTask is not null)
        {
            await IgnoreShutdownFailureAsync(_serveTask).ConfigureAwait(false);
            _serveTask = null;
        }
        var activeRequests = _activeRequests.Values.ToArray();
        if (activeRequests.Length > 0)
        {
            try { await Task.WhenAll(activeRequests).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
    }

    private async Task ServeAsync(HttpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && listener.IsListening)
        {
            HttpListenerContext context;
            try
            {
                context = await listener.GetContextAsync().WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is HttpListenerException or ObjectDisposedException or OperationCanceledException)
            {
                break;
            }
            await _requestSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            var requestId = Interlocked.Increment(ref _requestSequence);
            var task = HandleBoundedAsync(context, requestId, cancellationToken);
            _activeRequests[requestId] = task;
        }
    }

    private async Task HandleBoundedAsync(HttpListenerContext context, int requestId, CancellationToken cancellationToken)
    {
        try { await HandleSafelyAsync(context, cancellationToken).ConfigureAwait(false); }
        finally
        {
            _activeRequests.TryRemove(requestId, out _);
            _requestSlots.Release();
        }
    }

    private async Task HandleSafelyAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        try
        {
            await HandleAsync(context, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Gateway shutdown owns the connection lifecycle; do not write to a response that listener.Close already disposed.
        }
        catch (OperationCanceledException)
        {
            await WriteJsonAsync(context.Response, HttpStatusCode.RequestTimeout, new { error = new { code = "request_cancelled", message = "Request cancelled." } }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception)
        {
            await WriteJsonAsync(context.Response, HttpStatusCode.InternalServerError, new { error = new { code = "internal_error", message = "Local gateway failed safely." } }, CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                context.Response.Close();
            }
            catch (ObjectDisposedException) when (cancellationToken.IsCancellationRequested)
            {
                // Listener shutdown may dispose an in-flight response first.
            }
            catch (HttpListenerException) when (cancellationToken.IsCancellationRequested)
            {
                // Listener shutdown owns the connection and may already have closed it.
            }
        }
    }

    private async Task HandleAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        if (!IPAddress.IsLoopback(context.Request.RemoteEndPoint?.Address ?? IPAddress.None))
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.Forbidden, "loopback_only", "This gateway only accepts loopback clients.", cancellationToken).ConfigureAwait(false);
            return;
        }
        if (!IsAuthorized(context.Request))
        {
            context.Response.AddHeader("WWW-Authenticate", "Bearer");
            await WriteErrorAsync(context.Response, HttpStatusCode.Unauthorized, "unauthorized", "A valid local gateway token is required.", cancellationToken).ConfigureAwait(false);
            return;
        }

        var path = context.Request.Url?.AbsolutePath;
        if (HttpMethod.Get.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal) && path == "/health")
        {
            await WriteJsonAsync(context.Response, HttpStatusCode.OK, new { status = "ok", scope = "loopback", version = "1.10.0", build = 67 }, cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Get.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal) && path == "/v1/models")
        {
            var configuration = _configuration();
            var models = ProviderCatalog.Models(configuration)
                .Select(entry => new { id = entry.Model.Id, @object = "model", owned_by = entry.Provider.DisplayName })
                .Concat((configuration.Routes ?? [])
                    .Where(route => route.IsEnabled)
                    .Select(route => new { id = route.Alias, @object = "model", owned_by = "modelhub-route" }))
                .ToArray();
            await WriteJsonAsync(context.Response, HttpStatusCode.OK, new { @object = "list", data = models }, cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Post.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal) && path == "/v1/chat/completions")
        {
            await ForwardChatCompletionAsync(context, cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Post.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal)
            && path is "/v1/responses" or "/v1/messages")
        {
            await ForwardTransparentJsonAsync(
                context,
                path,
                path == "/v1/responses"
                    ? GatewayEndpointKind.Responses
                    : GatewayEndpointKind.Native,
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Post.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal)
            && path is "/v1/embeddings" or "/v1/rerank")
        {
            await ForwardAdvancedJsonAsync(
                context,
                path,
                path == "/v1/embeddings"
                    ? GatewayEndpointKind.Embeddings
                    : GatewayEndpointKind.Rerank,
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Post.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal)
            && path is "/v1/images/generations" or "/v1/videos"
                or "/v1/music/generations" or "/v1/audio/speech")
        {
            var kind = path switch
            {
                "/v1/images/generations" => GatewayEndpointKind.ImageGeneration,
                "/v1/videos" => GatewayEndpointKind.VideoGeneration,
                "/v1/music/generations" => GatewayEndpointKind.MusicGeneration,
                _ => GatewayEndpointKind.AudioSpeech,
            };
            await ForwardJsonMediaTaskAsync(context, path, kind, cancellationToken)
                .ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Post.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal)
            && path is "/v1/images/edits" or "/v1/audio/transcriptions")
        {
            await ForwardMultipartEndpointAsync(
                context,
                path,
                path == "/v1/images/edits"
                    ? GatewayEndpointKind.ImageEdit
                    : GatewayEndpointKind.AudioTranscription,
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Get.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal) && path?.StartsWith("/v1/media/tasks/", StringComparison.Ordinal) == true)
        {
            await GetMediaTaskAsync(context, path, cancellationToken).ConfigureAwait(false);
            return;
        }
        if (HttpMethod.Get.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal) && path == "/v1/usage/ledger")
        {
            await GetUsageLedgerAsync(context, cancellationToken).ConfigureAwait(false);
            return;
        }

        await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "not_found", "The endpoint is not exposed by this local gateway.", cancellationToken).ConfigureAwait(false);
    }

    private bool IsAuthorized(HttpListenerRequest request)
    {
        var token = _vault.Read(_configuration().Gateway.TokenCredentialTarget);
        if (string.IsNullOrWhiteSpace(token))
        {
            return false;
        }
        var provided = request.Headers["Authorization"];
        const string prefix = "Bearer ";
        if (provided is null || !provided.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        var expectedBytes = Encoding.UTF8.GetBytes(token);
        var providedBytes = Encoding.UTF8.GetBytes(provided[prefix.Length..]);
        try
        {
            return CryptographicOperations.FixedTimeEquals(expectedBytes, providedBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(expectedBytes);
            CryptographicOperations.ZeroMemory(providedBytes);
        }
    }

    private async Task ForwardChatCompletionAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        var parsed = await ReadJsonGatewayRequestAsync(context, cancellationToken)
            .ConfigureAwait(false);
        if (parsed is null) { return; }
        try
        {
            await ForwardChatRequestAsync(context, parsed, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(parsed.Body);
        }
    }

    private async Task ForwardChatRequestAsync(
        HttpListenerContext context,
        ParsedJsonGatewayRequest parsed,
        CancellationToken cancellationToken)
    {
        var configuration = _configuration();
        var resolution = ResolveGatewayModel(configuration, parsed.ModelId);
        if (resolution is null)
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "model_not_found", "The requested model is not enabled in the local catalog.", cancellationToken).ConfigureAwait(false);
            return;
        }
        var apiKey = GetProviderSecret(configuration, resolution.Provider);
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.ServiceUnavailable, "provider_key_missing", "The selected provider has no credential in Windows Credential Manager.", cancellationToken).ConfigureAwait(false);
            return;
        }

        var requestBody = RewriteJsonModel(parsed.Body, resolution.Model.Id);
        try
        {
            using var acquisition = await AcquireClientAsync(
                configuration,
                resolution,
                cancellationToken).ConfigureAwait(false);
            if (await RejectBlockedProxyAsync(
                context,
                acquisition,
                "/v1/chat/completions",
                parsed.ModelId,
                resolution.Provider.DisplayName,
                requestBody.Length,
                cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            HttpRequestMessage request;
            try
            {
                request = ProviderProtocolAdapter.CreateChatRequest(
                    resolution.Provider,
                    requestBody,
                    apiKey,
                    parsed.WantsStream);
            }
            catch (Exception exception) when (exception is JsonException or NotSupportedException)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.BadRequest, "unsupported_chat_payload", "The chat payload cannot be represented by the selected provider protocol.", cancellationToken).ConfigureAwait(false);
                return;
            }
            using (request)
            {
                if (FindEndpoint(
                    configuration,
                    resolution.Provider.Id,
                    GatewayEndpointKind.ChatCompletions) is { } configured)
                {
                    request.RequestUri = BuildEndpointUri(
                        resolution.Provider,
                        configured.Path,
                        resolution.Model.Id);
                }
                using var upstreamResponse = await acquisition.Client!.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken).ConfigureAwait(false);
                await RelayChatResponseAsync(
                    context,
                    upstreamResponse,
                    resolution,
                    parsed,
                    requestBody.Length,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBody);
        }
    }

    private async Task RelayChatResponseAsync(
        HttpListenerContext context,
        HttpResponseMessage upstreamResponse,
        ModelRouteResolution resolution,
        ParsedJsonGatewayRequest parsed,
        int requestBytes,
        CancellationToken cancellationToken)
    {
        var responseContentType = upstreamResponse.Content.Headers.ContentType?.ToString() ?? "application/json";
        if (parsed.WantsStream
            && upstreamResponse.IsSuccessStatusCode
            && !ProviderProtocolAdapter.IsExpectedStreamingContentType(
                resolution.Provider.Protocol,
                responseContentType))
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.BadGateway, "invalid_sse_response", "Upstream accepted streaming but did not return text/event-stream.", cancellationToken).ConfigureAwait(false);
            return;
        }
        if (parsed.WantsStream && !upstreamResponse.IsSuccessStatusCode)
        {
            var errorBytes = await ReadBoundedAsync(await upstreamResponse.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), MaximumRequestBytes, cancellationToken).ConfigureAwait(false);
            context.Response.StatusCode = (int)upstreamResponse.StatusCode;
            context.Response.ContentType = responseContentType;
            context.Response.Headers["Cache-Control"] = "no-store";
            context.Response.ContentLength64 = errorBytes.Length;
            try { await context.Response.OutputStream.WriteAsync(errorBytes, cancellationToken).ConfigureAwait(false); }
            finally { CryptographicOperations.ZeroMemory(errorBytes); }
            await AppendLedgerAsync("/v1/chat/completions", parsed.ModelId, resolution.Provider.DisplayName, (int)upstreamResponse.StatusCode, requestBytes, upstreamResponse.Content.Headers.ContentLength ?? 0, null, cancellationToken).ConfigureAwait(false);
            return;
        }
        if (parsed.WantsStream)
        {
            context.Response.StatusCode = (int)upstreamResponse.StatusCode;
            context.Response.ContentType = responseContentType;
            context.Response.Headers["Cache-Control"] = "no-store";
            var responseStarted = false;
            try
            {
                responseStarted = true;
                var source = await upstreamResponse.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                if (resolution.Provider.Protocol == ProviderProtocol.OpenAICompatible)
                {
                    await CopyStreamingBoundedAsync(source, context.Response.OutputStream, _maximumStreamingResponseBytes, _streamFirstByteTimeout, _streamIdleTimeout, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await CopyProtocolStreamingBoundedAsync(source, context.Response.OutputStream, resolution.Provider.Protocol, _maximumStreamingResponseBytes, _streamFirstByteTimeout, _streamIdleTimeout, cancellationToken).ConfigureAwait(false);
                }
            }
            catch (Exception exception) when (responseStarted && exception is IOException or HttpRequestException or InvalidOperationException or TimeoutException or JsonException)
            {
                await AppendLedgerAsync("/v1/chat/completions#stream_aborted", parsed.ModelId, resolution.Provider.DisplayName, 502, requestBytes, 0, null, CancellationToken.None).ConfigureAwait(false);
                context.Response.Abort();
                return;
            }
        }
        else
        {
            var upstreamBytes = await ReadBoundedAsync(await upstreamResponse.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), MaximumUpstreamResponseBytes, cancellationToken).ConfigureAwait(false);
            byte[] responseBytes;
            try
            {
                responseBytes = upstreamResponse.IsSuccessStatusCode
                    ? ProviderProtocolAdapter.NormalizeNonStreamingResponse(resolution.Provider.Protocol, upstreamBytes)
                    : upstreamBytes;
            }
            catch (JsonException)
            {
                CryptographicOperations.ZeroMemory(upstreamBytes);
                await WriteErrorAsync(context.Response, HttpStatusCode.BadGateway, "invalid_upstream_response", "Upstream returned a response that did not match its configured protocol.", cancellationToken).ConfigureAwait(false);
                return;
            }
            context.Response.StatusCode = (int)upstreamResponse.StatusCode;
            context.Response.ContentType = upstreamResponse.IsSuccessStatusCode ? "application/json; charset=utf-8" : responseContentType;
            context.Response.Headers["Cache-Control"] = "no-store";
            await context.Response.OutputStream.WriteAsync(responseBytes, cancellationToken).ConfigureAwait(false);
            CryptographicOperations.ZeroMemory(responseBytes);
            if (!ReferenceEquals(upstreamBytes, responseBytes)) { CryptographicOperations.ZeroMemory(upstreamBytes); }
        }
        await AppendLedgerAsync("/v1/chat/completions", parsed.ModelId, resolution.Provider.DisplayName, (int)upstreamResponse.StatusCode, requestBytes, upstreamResponse.Content.Headers.ContentLength ?? 0, null, cancellationToken).ConfigureAwait(false);
    }

    private async Task ForwardTransparentJsonAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        var parsed = await ReadJsonGatewayRequestAsync(context, cancellationToken)
            .ConfigureAwait(false);
        if (parsed is null) { return; }
        try
        {
            var configuration = _configuration();
            var resolution = ResolveGatewayModel(configuration, parsed.ModelId);
            if (resolution is null)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "model_not_found", "The requested model is not enabled in the local catalog.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var credential = GetProviderSecret(configuration, resolution.Provider);
            if (string.IsNullOrWhiteSpace(credential))
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.ServiceUnavailable, "provider_key_missing", "The selected provider has no credential in Windows Credential Manager.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var requestBody = RewriteJsonModel(parsed.Body, resolution.Model.Id);
            try
            {
                using var acquisition = await AcquireClientAsync(
                    configuration,
                    resolution,
                    cancellationToken).ConfigureAwait(false);
                if (await RejectBlockedProxyAsync(context, acquisition, endpoint, parsed.ModelId, resolution.Provider.DisplayName, requestBody.Length, cancellationToken).ConfigureAwait(false)) { return; }
                using var request = CreateJsonRequest(
                    resolution.Provider,
                    ResolveEndpointPath(configuration, resolution.Provider, endpointKind),
                    resolution.Model.Id,
                    credential,
                    requestBody);
                using var response = await acquisition.Client!.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken).ConfigureAwait(false);
                await RelayTransparentResponseAsync(
                    context,
                    response,
                    endpoint,
                    parsed.ModelId,
                    resolution.Provider.DisplayName,
                    requestBody.Length,
                    parsed.WantsStream,
                    cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(requestBody);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(parsed.Body);
        }
    }

    private async Task ForwardAdvancedJsonAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        var parsed = await ReadJsonGatewayRequestAsync(context, cancellationToken)
            .ConfigureAwait(false);
        if (parsed is null) { return; }
        try
        {
            var configuration = _configuration();
            var resolution = ResolveGatewayModel(configuration, parsed.ModelId);
            if (resolution is null)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "model_not_found", "The requested model is not enabled in the local catalog.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var credential = GetProviderSecret(configuration, resolution.Provider);
            if (string.IsNullOrWhiteSpace(credential))
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.ServiceUnavailable, "provider_key_missing", "The selected provider has no credential in Windows Credential Manager.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var requestBody = RewriteJsonModel(parsed.Body, resolution.Model.Id);
            try
            {
                using var acquisition = await AcquireClientAsync(
                    configuration,
                    resolution,
                    cancellationToken).ConfigureAwait(false);
                if (await RejectBlockedProxyAsync(context, acquisition, endpoint, parsed.ModelId, resolution.Provider.DisplayName, requestBody.Length, cancellationToken).ConfigureAwait(false)) { return; }
                var configured = FindEndpoint(configuration, resolution.Provider.Id, endpointKind);
                AdvancedForwardResponse advancedResponse;
                if (configured is null
                    && resolution.Provider.Protocol == ProviderProtocol.OpenAICompatible)
                {
                    using var bridge = new ExistingClientHandler(acquisition.Client!);
                    using var forwarder = new AdvancedEndpointForwarder(
                        bridge,
                        maximumRequestBytes: MaximumRequestBytes,
                        maximumResponseBytes: MaximumUpstreamResponseBytes,
                        maximumConcurrentRequests: 1);
                    using var content = new ByteArrayContent(requestBody);
                    content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
                    advancedResponse = await forwarder.ForwardAsync(
                        new AdvancedForwardRequest(
                            resolution.Provider.BaseUri,
                            endpointKind == GatewayEndpointKind.Embeddings
                                ? AdvancedEndpointKind.Embeddings
                                : AdvancedEndpointKind.Rerank,
                            credential,
                            content),
                        cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    using var request = CreateJsonRequest(
                        resolution.Provider,
                        ResolveEndpointPath(configuration, resolution.Provider, endpointKind),
                        resolution.Model.Id,
                        credential,
                        requestBody);
                    using var response = await acquisition.Client!.SendAsync(
                        request,
                        HttpCompletionOption.ResponseHeadersRead,
                        cancellationToken).ConfigureAwait(false);
                    var body = await ReadBoundedAsync(
                        await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
                        MaximumUpstreamResponseBytes,
                        cancellationToken).ConfigureAwait(false);
                    advancedResponse = new AdvancedForwardResponse(
                        response.StatusCode,
                        SafeContentType(response.Content.Headers.ContentType),
                        body);
                }
                try
                {
                    await WriteBufferedResponseAsync(
                        context.Response,
                        advancedResponse.StatusCode,
                        advancedResponse.ContentType,
                        advancedResponse.Body,
                        cancellationToken).ConfigureAwait(false);
                    await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)advancedResponse.StatusCode, requestBody.Length, advancedResponse.Body.Length, null, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(advancedResponse.Body);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(requestBody);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(parsed.Body);
        }
    }

    private async Task ForwardJsonMediaTaskAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        if (!await _mediaTaskSlots.WaitAsync(TimeSpan.Zero, cancellationToken)
                .ConfigureAwait(false))
        {
            await WriteErrorAsync(
                context.Response,
                HttpStatusCode.TooManyRequests,
                "media_capacity_exhausted",
                "The bounded local media queue is full; retry later.",
                cancellationToken).ConfigureAwait(false);
            return;
        }
        try
        {
            await ForwardJsonMediaTaskCoreAsync(
                context,
                endpoint,
                endpointKind,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _mediaTaskSlots.Release();
        }
    }

    private async Task ForwardJsonMediaTaskCoreAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        var parsed = await ReadJsonGatewayRequestAsync(context, cancellationToken)
            .ConfigureAwait(false);
        if (parsed is null) { return; }
        try
        {
            var configuration = _configuration();
            var resolution = ResolveGatewayModel(configuration, parsed.ModelId);
            if (resolution is null)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "model_not_found", "The requested media model is not enabled in the local catalog.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var credential = GetProviderSecret(configuration, resolution.Provider);
            if (string.IsNullOrWhiteSpace(credential))
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.ServiceUnavailable, "provider_key_missing", "The selected provider has no credential in Windows Credential Manager.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var requestBody = RewriteJsonModel(parsed.Body, resolution.Model.Id);
            try
            {
                using var acquisition = await AcquireClientAsync(
                    configuration,
                    resolution,
                    cancellationToken).ConfigureAwait(false);
                if (await RejectBlockedProxyAsync(context, acquisition, endpoint, parsed.ModelId, resolution.Provider.DisplayName, requestBody.Length, cancellationToken).ConfigureAwait(false)) { return; }
                var task = _mediaTasks.Create(endpoint, parsed.ModelId);
                _mediaTasks.MarkRunning(task.Id);
                context.Response.Headers["X-ModelHub-Media-Task-ID"] = task.Id.ToString("N");
                var endpointDefinition = FindEndpoint(
                    configuration,
                    resolution.Provider.Id,
                    endpointKind);
                try
                {
                    MediaArtifact artifact;
                    HttpStatusCode upstreamStatus;
                    if (endpointDefinition is { IsAsynchronous: true })
                    {
                        using var bridge = new ExistingClientHandler(acquisition.Client!);
                        using var poller = new AsyncMediaPoller(
                            bridge,
                            maximumRequestBytes: MaximumRequestBytes,
                            maximumResponseBytes: MaximumRequestBytes,
                            maximumArtifactBytes: 64 * 1024 * 1024,
                            maximumPollAttempts: 20,
                            pollInterval: _asyncMediaPollInterval,
                            requestTimeout: TimeSpan.FromSeconds(30),
                            totalTimeout: TimeSpan.FromMinutes(5),
                            maximumConcurrentTasks: 1);
                        var asyncResult = await poller.CreateAndPollAsync(
                            new AsyncMediaPollRequest(
                                resolution.Provider.BaseUri,
                                new AsyncMediaProtocolDefinition(
                                    endpointDefinition.Path,
                                    endpointDefinition.PollPathTemplate!,
                                    MapTaskIdentifierField(
                                        endpointDefinition.TaskIdentifierField)),
                                credential,
                                requestBody,
                                ArtifactKind(endpointKind)),
                            cancellationToken).ConfigureAwait(false);
                        artifact = asyncResult.Artifact;
                        upstreamStatus = HttpStatusCode.OK;
                    }
                    else
                    {
                        using var request = CreateJsonRequest(
                            resolution.Provider,
                            ResolveEndpointPath(configuration, resolution.Provider, endpointKind),
                            resolution.Model.Id,
                            credential,
                            requestBody);
                        using var response = await acquisition.Client!.SendAsync(
                            request,
                            HttpCompletionOption.ResponseHeadersRead,
                            cancellationToken).ConfigureAwait(false);
                        upstreamStatus = response.StatusCode;
                        if (!response.IsSuccessStatusCode)
                        {
                            _mediaTasks.MarkFailed(task.Id, $"upstream_{(int)response.StatusCode}");
                            var error = await ReadBoundedAsync(
                                await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
                                MaximumRequestBytes,
                                cancellationToken).ConfigureAwait(false);
                            try
                            {
                                await WriteBufferedResponseAsync(context.Response, response.StatusCode, SafeContentType(response.Content.Headers.ContentType), error, cancellationToken).ConfigureAwait(false);
                                await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)response.StatusCode, requestBody.Length, error.Length, task.Id, cancellationToken).ConfigureAwait(false);
                            }
                            finally
                            {
                                CryptographicOperations.ZeroMemory(error);
                            }
                            return;
                        }
                        artifact = await ExtractSynchronousArtifactAsync(response, cancellationToken)
                            .ConfigureAwait(false);
                    }
                    var completed = _mediaTasks.MarkSucceeded(task.Id, artifact);
                    await WriteJsonAsync(context.Response, HttpStatusCode.OK, ToMediaTaskResponse(completed), cancellationToken).ConfigureAwait(false);
                    await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)upstreamStatus, requestBody.Length, artifact.ByteCount, task.Id, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception exception) when (exception is JsonException or InvalidOperationException or HttpRequestException or IOException or TimeoutException)
                {
                    _mediaTasks.MarkFailed(task.Id, "artifact_validation_failed");
                    await WriteErrorAsync(context.Response, HttpStatusCode.BadGateway, "media_artifact_missing", "Upstream media response did not contain a usable artifact.", cancellationToken).ConfigureAwait(false);
                    await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)HttpStatusCode.BadGateway, requestBody.Length, 0, task.Id, cancellationToken).ConfigureAwait(false);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(requestBody);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(parsed.Body);
        }
    }

    private async Task ForwardMultipartEndpointAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        if (!await _multipartSlots.WaitAsync(TimeSpan.Zero, cancellationToken)
                .ConfigureAwait(false))
        {
            await WriteErrorAsync(
                context.Response,
                HttpStatusCode.TooManyRequests,
                "multipart_capacity_exhausted",
                "The bounded local multipart queue is full; retry later.",
                cancellationToken).ConfigureAwait(false);
            return;
        }
        try
        {
            await ForwardMultipartEndpointCoreAsync(
                context,
                endpoint,
                endpointKind,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _multipartSlots.Release();
        }
    }

    private async Task ForwardMultipartEndpointCoreAsync(
        HttpListenerContext context,
        string endpoint,
        GatewayEndpointKind endpointKind,
        CancellationToken cancellationToken)
    {
        if (context.Request.ContentLength64 is < 0 or > MaximumMultipartRequestBytes)
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.RequestEntityTooLarge, "request_too_large", "Multipart body exceeds the 32 MiB gateway limit.", cancellationToken).ConfigureAwait(false);
            return;
        }
        var raw = await ReadBoundedAsync(
            context.Request.InputStream,
            MaximumMultipartRequestBytes,
            cancellationToken).ConfigureAwait(false);
        ParsedMultipartGatewayRequest? parsed = null;
        try
        {
            try
            {
                parsed = ParseMultipartRequest(
                    context.Request.ContentType,
                    raw,
                    endpointKind);
            }
            catch (Exception exception) when (exception is FormatException or InvalidDataException or DecoderFallbackException)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.BadRequest, "invalid_multipart", "Multipart media payload is invalid.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var configuration = _configuration();
            var resolution = ResolveGatewayModel(configuration, parsed.ModelId);
            if (resolution is null)
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "model_not_found", "The requested media model is not enabled in the local catalog.", cancellationToken).ConfigureAwait(false);
                return;
            }
            var credential = GetProviderSecret(configuration, resolution.Provider);
            if (string.IsNullOrWhiteSpace(credential))
            {
                await WriteErrorAsync(context.Response, HttpStatusCode.ServiceUnavailable, "provider_key_missing", "The selected provider has no credential in Windows Credential Manager.", cancellationToken).ConfigureAwait(false);
                return;
            }
            parsed.Fields["model"] = resolution.Model.Id;
            using var acquisition = await AcquireClientAsync(
                configuration,
                resolution,
                cancellationToken).ConfigureAwait(false);
            if (await RejectBlockedProxyAsync(context, acquisition, endpoint, parsed.ModelId, resolution.Provider.DisplayName, raw.Length, cancellationToken).ConfigureAwait(false)) { return; }
            var isMediaTask = endpointKind == GatewayEndpointKind.ImageEdit;
            MediaTaskSnapshot? task = null;
            if (isMediaTask)
            {
                task = _mediaTasks.Create(endpoint, parsed.ModelId);
                _mediaTasks.MarkRunning(task.Id);
                context.Response.Headers["X-ModelHub-Media-Task-ID"] = task.Id.ToString("N");
            }
            try
            {
                var advancedKind = endpointKind == GatewayEndpointKind.ImageEdit
                    ? AdvancedEndpointKind.ImageEdit
                    : AdvancedEndpointKind.AudioTranscription;
                AdvancedForwardResponse response;
                var configured = FindEndpoint(
                    configuration,
                    resolution.Provider.Id,
                    endpointKind);
                if (configured is null
                    && resolution.Provider.Protocol == ProviderProtocol.OpenAICompatible)
                {
                    using var bridge = new ExistingClientHandler(acquisition.Client!);
                    using var advanced = new AdvancedEndpointForwarder(
                        bridge,
                        maximumRequestBytes: MaximumMultipartRequestBytes,
                        maximumResponseBytes: MaximumUpstreamResponseBytes,
                        maximumConcurrentRequests: 1);
                    var multipart = new MultipartMediaForwarder(
                        advanced,
                        maximumFileBytes: 25 * 1024 * 1024,
                        maximumTotalBytes: MaximumMultipartRequestBytes,
                        maximumFiles: 16);
                    response = await multipart.ForwardAsync(
                        resolution.Provider.BaseUri,
                        credential,
                        new MultipartMediaRequest(
                            advancedKind,
                            parsed.Fields,
                            parsed.Files),
                        cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    using var multipartContent = BuildMultipartContent(parsed);
                    using var request = new HttpRequestMessage(
                        HttpMethod.Post,
                        BuildEndpointUri(
                            resolution.Provider,
                            ResolveEndpointPath(
                                configuration,
                                resolution.Provider,
                                endpointKind),
                            resolution.Model.Id))
                    {
                        Content = multipartContent,
                    };
                    ApplyProviderAuthentication(request, resolution.Provider, credential);
                    using var upstream = await acquisition.Client!.SendAsync(
                        request,
                        HttpCompletionOption.ResponseHeadersRead,
                        cancellationToken).ConfigureAwait(false);
                    var bytes = await ReadBoundedAsync(
                        await upstream.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
                        MaximumUpstreamResponseBytes,
                        cancellationToken).ConfigureAwait(false);
                    response = new AdvancedForwardResponse(
                        upstream.StatusCode,
                        SafeContentType(upstream.Content.Headers.ContentType),
                        bytes);
                }

                try
                {
                    if (!isMediaTask)
                    {
                        await WriteBufferedResponseAsync(context.Response, response.StatusCode, response.ContentType, response.Body, cancellationToken).ConfigureAwait(false);
                        await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)response.StatusCode, raw.Length, response.Body.Length, null, cancellationToken).ConfigureAwait(false);
                    }
                    else if ((int)response.StatusCode is < 200 or > 299)
                    {
                        _mediaTasks.MarkFailed(task!.Id, $"upstream_{(int)response.StatusCode}");
                        await WriteBufferedResponseAsync(context.Response, response.StatusCode, response.ContentType, response.Body, cancellationToken).ConfigureAwait(false);
                        await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)response.StatusCode, raw.Length, response.Body.Length, task.Id, cancellationToken).ConfigureAwait(false);
                    }
                    else
                    {
                        var artifact = MediaArtifactStore.ParseRemoteJsonArtifact(response.Body);
                        var completed = _mediaTasks.MarkSucceeded(task!.Id, artifact);
                        await WriteJsonAsync(context.Response, HttpStatusCode.OK, ToMediaTaskResponse(completed), cancellationToken).ConfigureAwait(false);
                        await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)response.StatusCode, raw.Length, artifact.ByteCount, task.Id, cancellationToken).ConfigureAwait(false);
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(response.Body);
                }
            }
            catch (Exception exception) when (isMediaTask
                && exception is (JsonException or InvalidOperationException
                    or HttpRequestException or IOException or TimeoutException))
            {
                _mediaTasks.MarkFailed(task!.Id, "artifact_validation_failed");
                await WriteErrorAsync(context.Response, HttpStatusCode.BadGateway, "media_artifact_missing", "Upstream media response did not contain a usable artifact.", cancellationToken).ConfigureAwait(false);
                await AppendLedgerAsync(endpoint, parsed.ModelId, resolution.Provider.DisplayName, (int)HttpStatusCode.BadGateway, raw.Length, 0, task.Id, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            parsed?.Dispose();
            CryptographicOperations.ZeroMemory(raw);
        }
    }

    private static async Task<ParsedJsonGatewayRequest?> ReadJsonGatewayRequestAsync(
        HttpListenerContext context,
        CancellationToken cancellationToken)
    {
        if (context.Request.ContentLength64 is < 0 or > MaximumRequestBytes)
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.RequestEntityTooLarge, "request_too_large", "Request body exceeds the 4 MiB gateway limit.", cancellationToken).ConfigureAwait(false);
            return null;
        }
        if (!string.Equals(
            context.Request.ContentType?.Split(';', 2)[0].Trim(),
            "application/json",
            StringComparison.OrdinalIgnoreCase))
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.UnsupportedMediaType, "invalid_content_type", "This endpoint requires application/json.", cancellationToken).ConfigureAwait(false);
            return null;
        }
        var body = await ReadBoundedAsync(
            context.Request.InputStream,
            MaximumRequestBytes,
            cancellationToken).ConfigureAwait(false);
        try
        {
            using var document = JsonDocument.Parse(body, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new JsonException("The request root must be an object.");
            }
            var modelProperties = document.RootElement.EnumerateObject()
                .Where(property => property.NameEquals("model"))
                .Take(2)
                .ToArray();
            if (modelProperties.Length != 1
                || modelProperties[0].Value.ValueKind != JsonValueKind.String
                || !IsSafeModelIdentity(modelProperties[0].Value.GetString()))
            {
                throw new JsonException("Exactly one safe model string is required.");
            }
            var wantsStream = document.RootElement.TryGetProperty("stream", out var stream)
                && stream.ValueKind == JsonValueKind.True;
            return new ParsedJsonGatewayRequest(
                body,
                modelProperties[0].Value.GetString()!,
                wantsStream);
        }
        catch (JsonException)
        {
            CryptographicOperations.ZeroMemory(body);
            await WriteErrorAsync(context.Response, HttpStatusCode.BadRequest, "invalid_json", "Request body must be valid JSON with one safe model field.", cancellationToken).ConfigureAwait(false);
            return null;
        }
    }

    private ModelRouteResolution? ResolveGatewayModel(
        ModelHubConfiguration configuration,
        string requestedModel) =>
        ConfigurationStore.IsSafe(configuration)
            ? _routeResolver.Resolve(
                configuration,
                configuration.Routes ?? [],
                requestedModel,
                _routeState)
            : null;

    private static byte[] RewriteJsonModel(byte[] body, string upstreamModel)
    {
        using var document = JsonDocument.Parse(body, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 64,
        });
        using var output = new MemoryStream(Math.Min(body.Length + 256, MaximumRequestBytes));
        using (var writer = new Utf8JsonWriter(output, new JsonWriterOptions
        {
            Indented = false,
            SkipValidation = false,
        }))
        {
            writer.WriteStartObject();
            foreach (var property in document.RootElement.EnumerateObject())
            {
                writer.WritePropertyName(property.Name);
                if (property.NameEquals("model"))
                {
                    writer.WriteStringValue(upstreamModel);
                }
                else
                {
                    property.Value.WriteTo(writer);
                }
            }
            writer.WriteEndObject();
        }
        if (output.Length > MaximumRequestBytes)
        {
            throw new InvalidDataException("The normalized JSON request is too large.");
        }
        return output.ToArray();
    }

    private Task<ProxyHttpClientAcquisition> AcquireClientAsync(
        ModelHubConfiguration configuration,
        ModelRouteResolution resolution,
        CancellationToken cancellationToken) =>
        _proxyClients.AcquireForModelAsync(
            resolution.Provider.Id,
            resolution.Model.Id,
            configuration.ModelNodeAssignments ?? [],
            configuration.Nodes,
            _mihomoRuntime,
            cancellationToken);

    private async Task<bool> RejectBlockedProxyAsync(
        HttpListenerContext context,
        ProxyHttpClientAcquisition acquisition,
        string endpoint,
        string requestedModel,
        string provider,
        int requestBytes,
        CancellationToken cancellationToken)
    {
        if (acquisition.Kind != ProxyClientRouteKind.Blocked
            && acquisition.Client is not null)
        {
            return false;
        }
        await WriteErrorAsync(
            context.Response,
            HttpStatusCode.ServiceUnavailable,
            "proxy_route_blocked",
            "The assigned proxy route is unavailable; direct fallback is disabled.",
            cancellationToken).ConfigureAwait(false);
        await AppendLedgerAsync(
            endpoint,
            requestedModel,
            provider,
            (int)HttpStatusCode.ServiceUnavailable,
            requestBytes,
            0,
            null,
            cancellationToken).ConfigureAwait(false);
        return true;
    }

    private static ProviderEndpointPath? FindEndpoint(
        ModelHubConfiguration configuration,
        Guid providerId,
        GatewayEndpointKind endpoint) =>
        (configuration.ProviderEndpointPaths ?? []).SingleOrDefault(candidate =>
            candidate.ProviderId == providerId && candidate.Endpoint == endpoint);

    private static string ResolveEndpointPath(
        ModelHubConfiguration configuration,
        ProviderConfiguration provider,
        GatewayEndpointKind endpoint) =>
        FindEndpoint(configuration, provider.Id, endpoint)?.Path
            ?? DefaultEndpointPath(endpoint);

    private static string DefaultEndpointPath(GatewayEndpointKind endpoint) => endpoint switch
    {
        GatewayEndpointKind.ChatCompletions => "/v1/chat/completions",
        GatewayEndpointKind.Responses => "/v1/responses",
        GatewayEndpointKind.Native => "/v1/messages",
        GatewayEndpointKind.ImageGeneration => "/v1/images/generations",
        GatewayEndpointKind.ImageEdit => "/v1/images/edits",
        GatewayEndpointKind.VideoGeneration => "/v1/videos",
        GatewayEndpointKind.MusicGeneration => "/v1/music/generations",
        GatewayEndpointKind.AudioSpeech => "/v1/audio/speech",
        GatewayEndpointKind.AudioTranscription => "/v1/audio/transcriptions",
        GatewayEndpointKind.Embeddings => "/v1/embeddings",
        GatewayEndpointKind.Rerank => "/v1/rerank",
        _ => throw new ArgumentOutOfRangeException(nameof(endpoint)),
    };

    private static Uri BuildEndpointUri(
        ProviderConfiguration provider,
        string path,
        string modelId)
    {
        var resolvedPath = path.Replace(
            "{model}",
            Uri.EscapeDataString(modelId),
            StringComparison.Ordinal);
        if (!ConfigurationStore.IsSafeEndpointPath(resolvedPath))
        {
            throw new InvalidOperationException("The configured provider endpoint path is unsafe.");
        }
        return new Uri(provider.BaseUri, resolvedPath);
    }

    private static HttpRequestMessage CreateJsonRequest(
        ProviderConfiguration provider,
        string path,
        string modelId,
        string credential,
        byte[] body)
    {
        var request = new HttpRequestMessage(
            HttpMethod.Post,
            BuildEndpointUri(provider, path, modelId))
        {
            Content = new ByteArrayContent(body),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        ApplyProviderAuthentication(request, provider, credential);
        return request;
    }

    private static void ApplyProviderAuthentication(
        HttpRequestMessage request,
        ProviderConfiguration provider,
        string credential)
    {
        switch (provider.Protocol)
        {
            case ProviderProtocol.OpenAICompatible:
                request.Headers.Authorization = new AuthenticationHeaderValue(
                    "Bearer",
                    credential);
                break;
            case ProviderProtocol.Anthropic:
                request.Headers.TryAddWithoutValidation("x-api-key", credential);
                request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
                break;
            case ProviderProtocol.Gemini:
                request.Headers.TryAddWithoutValidation("x-goog-api-key", credential);
                break;
            default:
                throw new InvalidOperationException("The provider protocol is unsupported.");
        }
    }

    private async Task RelayTransparentResponseAsync(
        HttpListenerContext context,
        HttpResponseMessage response,
        string endpoint,
        string requestedModel,
        string provider,
        int requestBytes,
        bool wantsStream,
        CancellationToken cancellationToken)
    {
        var contentType = SafeContentType(response.Content.Headers.ContentType);
        if (wantsStream
            && response.IsSuccessStatusCode
            && !contentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase))
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.BadGateway, "invalid_sse_response", "Upstream accepted streaming but did not return text/event-stream.", cancellationToken).ConfigureAwait(false);
            return;
        }
        if (wantsStream && response.IsSuccessStatusCode)
        {
            context.Response.StatusCode = (int)response.StatusCode;
            context.Response.ContentType = contentType;
            context.Response.Headers["Cache-Control"] = "no-store";
            var responseStarted = false;
            try
            {
                responseStarted = true;
                var source = await response.Content.ReadAsStreamAsync(cancellationToken)
                    .ConfigureAwait(false);
                await CopyStreamingBoundedAsync(
                    source,
                    context.Response.OutputStream,
                    _maximumStreamingResponseBytes,
                    _streamFirstByteTimeout,
                    _streamIdleTimeout,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (responseStarted
                && exception is IOException or HttpRequestException
                    or InvalidOperationException or TimeoutException)
            {
                await AppendLedgerAsync(
                    endpoint + "#stream_aborted",
                    requestedModel,
                    provider,
                    502,
                    requestBytes,
                    0,
                    null,
                    CancellationToken.None).ConfigureAwait(false);
                context.Response.Abort();
                return;
            }
            await AppendLedgerAsync(endpoint, requestedModel, provider, (int)response.StatusCode, requestBytes, response.Content.Headers.ContentLength ?? 0, null, cancellationToken).ConfigureAwait(false);
            return;
        }

        var maximum = response.IsSuccessStatusCode
            ? MaximumUpstreamResponseBytes
            : MaximumRequestBytes;
        var body = await ReadBoundedAsync(
            await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
            maximum,
            cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteBufferedResponseAsync(
                context.Response,
                response.StatusCode,
                contentType,
                body,
                cancellationToken).ConfigureAwait(false);
            await AppendLedgerAsync(endpoint, requestedModel, provider, (int)response.StatusCode, requestBytes, body.Length, null, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(body);
        }
    }

    private async Task<MediaArtifact> ExtractSynchronousArtifactAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if ((response.Content.Headers.ContentType?.MediaType ?? string.Empty)
            .Contains("json", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = await ReadBoundedAsync(
                await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
                MaximumRequestBytes,
                cancellationToken).ConfigureAwait(false);
            try
            {
                return MediaArtifactStore.ParseRemoteJsonArtifact(bytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        return await _mediaArtifacts.CaptureAsync(response.Content, cancellationToken)
            .ConfigureAwait(false);
    }

    private static AsyncMediaTaskIdentifierField MapTaskIdentifierField(
        GatewayTaskIdentifierField field) => field switch
    {
        GatewayTaskIdentifierField.TaskId => AsyncMediaTaskIdentifierField.TaskId,
        GatewayTaskIdentifierField.DataTaskId => AsyncMediaTaskIdentifierField.DataTaskId,
        GatewayTaskIdentifierField.OutputTaskId => AsyncMediaTaskIdentifierField.OutputTaskId,
        _ => throw new ArgumentOutOfRangeException(nameof(field)),
    };

    private static string ArtifactKind(GatewayEndpointKind endpoint) => endpoint switch
    {
        GatewayEndpointKind.ImageGeneration or GatewayEndpointKind.ImageEdit => "image",
        GatewayEndpointKind.VideoGeneration => "video",
        GatewayEndpointKind.MusicGeneration => "music",
        GatewayEndpointKind.AudioSpeech => "audio",
        _ => "media",
    };

    private static string SafeContentType(MediaTypeHeaderValue? contentType)
    {
        var value = contentType?.ToString();
        return !string.IsNullOrEmpty(value)
            && value.Length <= 512
            && value.All(character => character >= ' ' && character != 127)
                ? value
                : "application/octet-stream";
    }

    private static async Task WriteBufferedResponseAsync(
        HttpListenerResponse response,
        HttpStatusCode status,
        string contentType,
        byte[] body,
        CancellationToken cancellationToken)
    {
        response.StatusCode = (int)status;
        response.ContentType = contentType;
        response.Headers["Cache-Control"] = "no-store";
        response.ContentLength64 = body.Length;
        await response.OutputStream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static ParsedMultipartGatewayRequest ParseMultipartRequest(
        string? rawContentType,
        byte[] body,
        GatewayEndpointKind endpointKind)
    {
        if (!MediaTypeHeaderValue.TryParse(rawContentType, out var contentType)
            || !string.Equals(
                contentType.MediaType,
                "multipart/form-data",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("A multipart/form-data content type is required.");
        }
        var boundary = contentType.Parameters.SingleOrDefault(parameter =>
            parameter.Name.Equals("boundary", StringComparison.OrdinalIgnoreCase))?.Value;
        boundary = boundary?.Trim('"');
        if (!IsSafeBoundary(boundary))
        {
            throw new InvalidDataException("The multipart boundary is invalid.");
        }

        var delimiter = Encoding.ASCII.GetBytes("--" + boundary);
        var nextDelimiter = Encoding.ASCII.GetBytes("\r\n--" + boundary);
        var headerTerminator = "\r\n\r\n"u8;
        if (!body.AsSpan().StartsWith(delimiter)
            || body.Length < delimiter.Length + 2
            || body[delimiter.Length] != (byte)'\r'
            || body[delimiter.Length + 1] != (byte)'\n')
        {
            throw new InvalidDataException("The multipart body has no opening boundary.");
        }

        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var files = new List<MultipartUpload>();
        var cursor = delimiter.Length + 2;
        var parts = 0;
        try
        {
            while (true)
            {
                parts++;
                if (parts > 80)
                {
                    throw new InvalidDataException("The multipart part limit was exceeded.");
                }
                var headerOffset = body.AsSpan(cursor).IndexOf(headerTerminator);
                if (headerOffset < 0 || headerOffset > 16 * 1024)
                {
                    throw new InvalidDataException("Multipart headers are missing or too large.");
                }
                var headerBytes = body.AsSpan(cursor, headerOffset);
                var headers = StrictAscii(headerBytes);
                cursor += headerOffset + headerTerminator.Length;
                var boundaryOffset = body.AsSpan(cursor).IndexOf(nextDelimiter);
                if (boundaryOffset < 0)
                {
                    throw new InvalidDataException("A multipart part is not terminated.");
                }
                var contentBytes = body.AsSpan(cursor, boundaryOffset);
                cursor += boundaryOffset + nextDelimiter.Length;

                ParseMultipartPart(headers, contentBytes, fields, files, endpointKind);

                if (cursor + 2 > body.Length)
                {
                    throw new InvalidDataException("The multipart closing boundary is incomplete.");
                }
                if (body[cursor] == (byte)'-' && body[cursor + 1] == (byte)'-')
                {
                    cursor += 2;
                    if (cursor + 2 == body.Length
                        && body[cursor] == (byte)'\r'
                        && body[cursor + 1] == (byte)'\n')
                    {
                        cursor += 2;
                    }
                    if (cursor != body.Length)
                    {
                        throw new InvalidDataException("Unexpected bytes follow the multipart closing boundary.");
                    }
                    break;
                }
                if (body[cursor] != (byte)'\r' || body[cursor + 1] != (byte)'\n')
                {
                    throw new InvalidDataException("The multipart boundary separator is invalid.");
                }
                cursor += 2;
            }

            if (!fields.TryGetValue("model", out var modelId)
                || !IsSafeModelIdentity(modelId))
            {
                throw new InvalidDataException("Exactly one safe model field is required.");
            }
            ValidateMultipartShape(endpointKind, files);
            return new ParsedMultipartGatewayRequest(fields, files, modelId);
        }
        catch
        {
            foreach (var file in files)
            {
                ZeroUpload(file);
            }
            throw;
        }
    }

    private static void ParseMultipartPart(
        string rawHeaders,
        ReadOnlySpan<byte> content,
        Dictionary<string, string> fields,
        List<MultipartUpload> files,
        GatewayEndpointKind endpointKind)
    {
        var headerLines = rawHeaders.Split("\r\n", StringSplitOptions.None);
        if (headerLines.Length is 0 or > 16
            || headerLines.Any(line => string.IsNullOrEmpty(line)
                || char.IsWhiteSpace(line[0])))
        {
            throw new InvalidDataException("Multipart headers are malformed.");
        }
        var dispositionValues = headerLines
            .Where(line => line.StartsWith("Content-Disposition:", StringComparison.OrdinalIgnoreCase))
            .Select(line => line[(line.IndexOf(':') + 1)..].Trim())
            .ToArray();
        if (dispositionValues.Length != 1
            || !ContentDispositionHeaderValue.TryParse(
                dispositionValues[0],
                out var disposition)
            || !string.Equals(disposition.DispositionType, "form-data", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("A form-data content disposition is required.");
        }
        var fieldName = Unquote(disposition.Name);
        if (!IsSafeMultipartToken(fieldName, 64))
        {
            throw new InvalidDataException("A multipart field name is unsafe.");
        }
        var contentTypes = headerLines
            .Where(line => line.StartsWith("Content-Type:", StringComparison.OrdinalIgnoreCase))
            .Select(line => line[(line.IndexOf(':') + 1)..].Trim())
            .ToArray();
        if (contentTypes.Length > 1)
        {
            throw new InvalidDataException("A multipart part has duplicate content types.");
        }
        var fileName = Unquote(disposition.FileNameStar ?? disposition.FileName);
        if (string.IsNullOrEmpty(fileName))
        {
            if (content.Length > 16 * 1024 || !fields.TryAdd(
                fieldName!,
                StrictUtf8(content)))
            {
                throw new InvalidDataException("A multipart text field is duplicated or too large.");
            }
            return;
        }
        if (files.Count >= 16
            || content.Length is 0 or > 25 * 1024 * 1024
            || contentTypes.Length != 1
            || !IsSafeMultipartFileName(fileName)
            || !IsAllowedMultipartMediaType(endpointKind, contentTypes[0]))
        {
            throw new InvalidDataException("A multipart file is unsafe or too large.");
        }
        files.Add(new MultipartUpload(
            fieldName!,
            fileName,
            contentTypes[0],
            content.ToArray()));
    }

    private static void ValidateMultipartShape(
        GatewayEndpointKind endpoint,
        List<MultipartUpload> files)
    {
        var valid = endpoint switch
        {
            GatewayEndpointKind.ImageEdit => files.Any(file =>
                file.FieldName.Equals("image", StringComparison.Ordinal)),
            GatewayEndpointKind.AudioTranscription => files.Count == 1
                && files[0].FieldName.Equals("file", StringComparison.Ordinal),
            _ => false,
        };
        if (!valid)
        {
            throw new InvalidDataException("The required multipart media file is missing.");
        }
    }

    private static MultipartFormDataContent BuildMultipartContent(
        ParsedMultipartGatewayRequest parsed)
    {
        var content = new MultipartFormDataContent($"modelhub-{Guid.NewGuid():N}");
        foreach (var field in parsed.Fields.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            content.Add(new StringContent(field.Value, Encoding.UTF8), field.Key);
        }
        foreach (var file in parsed.Files)
        {
            var fileContent = new ByteArrayContent(GetUploadArray(file.Content));
            fileContent.Headers.ContentType = MediaTypeHeaderValue.Parse(file.ContentType);
            content.Add(fileContent, file.FieldName, file.FileName);
        }
        return content;
    }

    private static bool IsAllowedMultipartMediaType(
        GatewayEndpointKind endpoint,
        string contentType) => endpoint switch
    {
        GatewayEndpointKind.ImageEdit => contentType is
            "image/png" or "image/jpeg" or "image/webp",
        GatewayEndpointKind.AudioTranscription => contentType is
            "audio/wav" or "audio/x-wav" or "audio/mpeg" or "audio/mp4"
            or "audio/webm" or "audio/ogg" or "application/ogg",
        _ => false,
    };

    private static bool IsSafeBoundary(string? value) =>
        !string.IsNullOrEmpty(value)
        && value.Length <= 70
        && value.All(character => char.IsAsciiLetterOrDigit(character)
            || character is '\'' or '(' or ')' or '+' or '_' or ',' or '-'
                or '.' or '/' or ':' or '=' or '?');

    private static bool IsSafeMultipartToken(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length <= maximumLength
        && value.All(character => char.IsAsciiLetterOrDigit(character)
            || character is '_' or '-' or '.');

    private static bool IsSafeMultipartFileName(string value) =>
        value.Length <= 255
        && value is not ("." or "..")
        && !value.Contains("..", StringComparison.Ordinal)
        && value.All(character => char.IsAsciiLetterOrDigit(character)
            || character is '_' or '-' or '.');

    private static bool IsSafeModelIdentity(string? value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length <= 256
        && value.Equals(value.Trim(), StringComparison.Ordinal)
        && !value.Any(char.IsControl);

    private static string StrictAscii(ReadOnlySpan<byte> value) =>
        Encoding.GetEncoding(
            Encoding.ASCII.CodePage,
            EncoderFallback.ExceptionFallback,
            DecoderFallback.ExceptionFallback).GetString(value);

    private static string StrictUtf8(ReadOnlySpan<byte> value) =>
        new UTF8Encoding(false, true).GetString(value);

    private static string? Unquote(string? value) =>
        value is { Length: >= 2 } && value[0] == '"' && value[^1] == '"'
            ? value[1..^1]
            : value;

    private static byte[] GetUploadArray(ReadOnlyMemory<byte> content)
    {
        if (MemoryMarshal.TryGetArray(content, out var segment)
            && segment.Array is not null
            && segment.Offset == 0
            && segment.Count == segment.Array.Length)
        {
            return segment.Array;
        }
        return content.ToArray();
    }

    private static void ZeroUpload(MultipartUpload upload)
    {
        if (MemoryMarshal.TryGetArray(upload.Content, out var segment)
            && segment.Array is not null)
        {
            CryptographicOperations.ZeroMemory(
                segment.Array.AsSpan(segment.Offset, segment.Count));
        }
    }

    private async Task GetMediaTaskAsync(HttpListenerContext context, string path, CancellationToken cancellationToken)
    {
        var raw = path["/v1/media/tasks/".Length..];
        if (!Guid.TryParse(raw, out var id) || _mediaTasks.Get(id) is not { } task)
        {
            await WriteErrorAsync(context.Response, HttpStatusCode.NotFound, "media_task_not_found", "The requested media task does not exist in this local session.", cancellationToken).ConfigureAwait(false);
            return;
        }
        await WriteJsonAsync(context.Response, HttpStatusCode.OK, ToMediaTaskResponse(task), cancellationToken).ConfigureAwait(false);
    }

    private async Task GetUsageLedgerAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        var query = context.Request.QueryString;
        var requestedLimit = int.TryParse(query["limit"], out var value) ? value : 50;
        var page = await _ledger.ReadPageAsync(query["cursor"], requestedLimit, cancellationToken).ConfigureAwait(false);
        await WriteJsonAsync(context.Response, HttpStatusCode.OK, new { data = page.Entries, next_cursor = page.NextCursor }, cancellationToken).ConfigureAwait(false);
    }

    private string? GetProviderSecret(
        ModelHubConfiguration configuration,
        ProviderConfiguration provider)
    {
        var pool = (configuration.CredentialPools ?? []).SingleOrDefault(
            candidate => candidate.ProviderId == provider.Id);
        var selected = CredentialPoolSelector.Select(pool);
        return selected is null ? _vault.Read(provider.CredentialTarget) : _vault.Read(selected.CredentialTarget);
    }

    private async Task AppendLedgerAsync(string endpoint, string? model, string? provider, int statusCode, int requestBytes, long responseBytes, Guid? taskId, CancellationToken cancellationToken)
    {
        try
        {
            await _ledger.AppendAsync(new UsageLedgerEntry(Guid.NewGuid(), DateTimeOffset.UtcNow, endpoint, model, provider, statusCode, requestBytes, responseBytes, taskId), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OperationCanceledException) { }
    }

    private static object ToMediaTaskResponse(MediaTaskSnapshot task) => new
    {
        id = task.Id,
        status = task.State.ToString().ToLowerInvariant(),
        endpoint = task.Endpoint,
        model = task.Model,
        artifact = task.Artifact is null ? null : new { kind = task.Artifact.Kind, url = task.Artifact.RemoteUrl?.AbsoluteUri, local_path = task.Artifact.LocalPath, bytes = task.Artifact.ByteCount },
        error = task.ErrorCode,
    };

    private static async Task<byte[]> ReadBoundedAsync(Stream source, int maximumBytes, CancellationToken cancellationToken)
    {
        await using var buffer = new MemoryStream();
        await CopyBoundedAsync(source, buffer, maximumBytes, cancellationToken).ConfigureAwait(false);
        return buffer.ToArray();
    }

    private static async Task CopyBoundedAsync(Stream source, Stream destination, int maximumBytes, CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        var total = 0;
        try
        {
            while (true)
            {
                var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    return;
                }
                total = checked(total + read);
                if (total > maximumBytes)
                {
                    throw new InvalidOperationException("Payload exceeds the configured safety limit.");
                }
                await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
        }
    }

    private static async Task CopyStreamingBoundedAsync(Stream source, Stream destination, int maximumBytes, TimeSpan firstByteTimeout, TimeSpan idleTimeout, CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        var total = 0;
        var firstRead = true;
        try
        {
            while (true)
            {
                var timeout = firstRead ? firstByteTimeout : idleTimeout;
                var read = await source.ReadAsync(buffer, cancellationToken).AsTask().WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
                if (read == 0) { return; }
                firstRead = false;
                total = checked(total + read);
                if (total > maximumBytes) { throw new InvalidOperationException("Streaming payload exceeds the configured safety limit."); }
                await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    private static async Task CopyProtocolStreamingBoundedAsync(Stream source, Stream destination, ProviderProtocol protocol, int maximumBytes, TimeSpan firstByteTimeout, TimeSpan idleTimeout, CancellationToken cancellationToken)
    {
        const int maximumEventBytes = 256 * 1024;
        var buffer = new byte[8192];
        await using var pending = new MemoryStream();
        var inputTotal = 0;
        var outputTotal = 0;
        var firstRead = true;
        try
        {
            while (true)
            {
                var timeout = firstRead ? firstByteTimeout : idleTimeout;
                var read = await source.ReadAsync(buffer, cancellationToken).AsTask().WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
                if (read == 0) { break; }
                firstRead = false;
                inputTotal = checked(inputTotal + read);
                if (inputTotal > maximumBytes || pending.Length + read > maximumEventBytes) { throw new InvalidOperationException("Streaming protocol payload exceeds the configured safety limit."); }
                await pending.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                outputTotal = await FlushCompleteProtocolEventsAsync(pending, destination, protocol, outputTotal, maximumBytes, cancellationToken).ConfigureAwait(false);
            }
            if (pending.Length > 0)
            {
                var normalized = ProviderProtocolAdapter.NormalizeStreamingEvent(protocol, pending.ToArray());
                outputTotal = checked(outputTotal + normalized.Length);
                if (outputTotal > maximumBytes) { throw new InvalidOperationException("Normalized streaming payload exceeds the configured safety limit."); }
                await destination.WriteAsync(normalized, cancellationToken).ConfigureAwait(false);
            }
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    private static async Task<int> FlushCompleteProtocolEventsAsync(MemoryStream pending, Stream destination, ProviderProtocol protocol, int outputTotal, int maximumBytes, CancellationToken cancellationToken)
    {
        var bytes = pending.ToArray();
        var consumed = 0;
        try
        {
            while (TryFindSseBoundary(bytes, consumed, out var boundaryEnd))
            {
                var normalized = ProviderProtocolAdapter.NormalizeStreamingEvent(protocol, bytes.AsSpan(consumed, boundaryEnd - consumed));
                outputTotal = checked(outputTotal + normalized.Length);
                if (outputTotal > maximumBytes) { throw new InvalidOperationException("Normalized streaming payload exceeds the configured safety limit."); }
                await destination.WriteAsync(normalized, cancellationToken).ConfigureAwait(false);
                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
                consumed = boundaryEnd;
            }
            pending.SetLength(0);
            if (consumed < bytes.Length) { await pending.WriteAsync(bytes.AsMemory(consumed), cancellationToken).ConfigureAwait(false); }
            return outputTotal;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static bool TryFindSseBoundary(byte[] bytes, int start, out int boundaryEnd)
    {
        for (var index = start; index < bytes.Length - 1; index++)
        {
            if (bytes[index] == (byte)'\n' && bytes[index + 1] == (byte)'\n') { boundaryEnd = index + 2; return true; }
            if (index < bytes.Length - 3 && bytes[index] == (byte)'\r' && bytes[index + 1] == (byte)'\n' && bytes[index + 2] == (byte)'\r' && bytes[index + 3] == (byte)'\n') { boundaryEnd = index + 4; return true; }
        }
        boundaryEnd = 0;
        return false;
    }

    private static TimeSpan ValidateStreamTimeout(TimeSpan value, string parameterName) =>
        value >= TimeSpan.FromMilliseconds(50) && value <= TimeSpan.FromMinutes(5) ? value : throw new ArgumentOutOfRangeException(parameterName);

    private static async Task WriteErrorAsync(HttpListenerResponse response, HttpStatusCode status, string code, string message, CancellationToken cancellationToken) =>
        await WriteJsonAsync(response, status, new { error = new { code, message } }, cancellationToken).ConfigureAwait(false);

    private static async Task WriteJsonAsync(HttpListenerResponse response, HttpStatusCode status, object body, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(body);
        response.StatusCode = (int)status;
        response.ContentType = "application/json; charset=utf-8";
        response.Headers["Cache-Control"] = "no-store";
        response.ContentLength64 = bytes.Length;
        try
        {
            await response.OutputStream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static async Task IgnoreShutdownFailureAsync(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (Exception exception) when (exception is HttpListenerException or ObjectDisposedException or OperationCanceledException) { }
    }

    private sealed record ParsedJsonGatewayRequest(
        byte[] Body,
        string ModelId,
        bool WantsStream);

    private sealed class ParsedMultipartGatewayRequest(
        Dictionary<string, string> fields,
        List<MultipartUpload> files,
        string modelId) : IDisposable
    {
        public Dictionary<string, string> Fields { get; } = fields;
        public List<MultipartUpload> Files { get; } = files;
        public string ModelId { get; } = modelId;

        public void Dispose()
        {
            foreach (var file in Files)
            {
                ZeroUpload(file);
            }
        }
    }

    /// <summary>
    /// Test-injected handlers cannot create a real proxy transport. The pool
    /// still decides Direct/Proxy/Blocked; this factory only bridges a selected
    /// non-blocked client to the injected deterministic handler.
    /// </summary>
    private sealed class ExistingClientHandlerFactory(HttpClient client)
        : IProxyHttpHandlerFactory
    {
        public HttpMessageHandler Create(
            Uri? proxyEndpoint,
            ProxyHttpClientPoolOptions options) => new ExistingClientHandler(client);
    }

    private sealed class ExistingClientHandler(HttpClient client) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            using var clone = new HttpRequestMessage(request.Method, request.RequestUri)
            {
                Version = request.Version,
                VersionPolicy = request.VersionPolicy,
            };
            foreach (var header in request.Headers)
            {
                clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }

            byte[]? body = null;
            try
            {
                if (request.Content is not null)
                {
                    if (request.Content.Headers.ContentLength
                        is > MaximumMultipartRequestBytes)
                    {
                        throw new InvalidDataException(
                            "The bridged request exceeds the gateway limit.");
                    }
                    body = await request.Content.ReadAsByteArrayAsync(cancellationToken)
                        .ConfigureAwait(false);
                    if (body.Length > MaximumMultipartRequestBytes)
                    {
                        throw new InvalidDataException(
                            "The bridged request exceeds the gateway limit.");
                    }
                    clone.Content = new ByteArrayContent(body);
                    foreach (var header in request.Content.Headers)
                    {
                        clone.Content.Headers.TryAddWithoutValidation(
                            header.Key,
                            header.Value);
                    }
                }
                return await client.SendAsync(
                    clone,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                if (body is not null)
                {
                    CryptographicOperations.ZeroMemory(body);
                }
            }
        }
    }

    private sealed class UnavailableMihomoRuntimeStatus : IMihomoRuntimeStatus
    {
        public static UnavailableMihomoRuntimeStatus Instance { get; } = new();
        public bool IsReady => false;
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        _requestCancellation.Cancel();
        await StopAsync().ConfigureAwait(false);
        if (_ownsProxyClients)
        {
            _proxyClients.Dispose();
        }
        _injectedClient?.Dispose();
        _ledger.Dispose();
        _shutdown.Dispose();
        _requestCancellation.Dispose();
        _lifecycleGate.Dispose();
        _requestSlots.Dispose();
        _multipartSlots.Dispose();
        _mediaTaskSlots.Dispose();
    }
}
