using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace ModelHub.Windows.Services;

public enum AdvancedEndpointKind
{
    ImageEdit,
    AudioTranscription,
    Embeddings,
    Rerank,
}

public sealed record AdvancedForwardRequest(
    Uri ProviderBaseUri,
    AdvancedEndpointKind Endpoint,
    string BearerCredential,
    HttpContent Content);

public sealed record AdvancedForwardResponse(
    HttpStatusCode StatusCode,
    string ContentType,
    byte[] Body);

/// <summary>
/// Forwards a small allowlist of advanced OpenAI-compatible endpoints. Both
/// sides are buffered behind hard limits so callers can safely bridge an
/// HttpListener request without exposing redirects, cookies, or upstream
/// response headers that are unrelated to the protocol payload.
/// </summary>
public sealed class AdvancedEndpointForwarder : IDisposable
{
    public const int DefaultMaximumRequestBytes = 32 * 1024 * 1024;
    public const int DefaultMaximumResponseBytes = 32 * 1024 * 1024;

    private readonly HttpClient _client;
    private readonly SemaphoreSlim _requestSlots;
    private readonly int _maximumRequestBytes;
    private readonly int _maximumResponseBytes;
    private readonly TimeSpan _requestTimeout;

    public AdvancedEndpointForwarder(
        HttpMessageHandler? handler = null,
        int maximumRequestBytes = DefaultMaximumRequestBytes,
        int maximumResponseBytes = DefaultMaximumResponseBytes,
        int maximumConcurrentRequests = 8,
        TimeSpan? requestTimeout = null)
    {
        _maximumRequestBytes = ValidateByteLimit(
            maximumRequestBytes,
            nameof(maximumRequestBytes));
        _maximumResponseBytes = ValidateByteLimit(
            maximumResponseBytes,
            nameof(maximumResponseBytes));
        if (maximumConcurrentRequests is < 1 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumConcurrentRequests));
        }
        _requestTimeout = requestTimeout is null
            ? TimeSpan.FromSeconds(90)
            : requestTimeout.Value >= TimeSpan.FromMilliseconds(50)
                && requestTimeout.Value <= TimeSpan.FromMinutes(5)
                ? requestTimeout.Value
                : throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        _requestSlots = new SemaphoreSlim(
            maximumConcurrentRequests,
            maximumConcurrentRequests);
        _client = handler is null
            ? new HttpClient(new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                ConnectTimeout = TimeSpan.FromSeconds(10),
                UseCookies = false,
            })
            : new HttpClient(handler, disposeHandler: false);
        _client.Timeout = Timeout.InfiniteTimeSpan;
    }

    public async Task<AdvancedForwardResponse> ForwardAsync(
        AdvancedForwardRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        await _requestSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            timeout.CancelAfter(_requestTimeout);
            try
            {
                return await ForwardCoreAsync(request, timeout.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException("The upstream advanced endpoint timed out.");
            }
        }
        finally
        {
            _requestSlots.Release();
        }
    }

    public void Dispose()
    {
        _client.Dispose();
        _requestSlots.Dispose();
    }

    internal static string EndpointPath(AdvancedEndpointKind endpoint) => endpoint switch
    {
        AdvancedEndpointKind.ImageEdit => "v1/images/edits",
        AdvancedEndpointKind.AudioTranscription => "v1/audio/transcriptions",
        AdvancedEndpointKind.Embeddings => "v1/embeddings",
        AdvancedEndpointKind.Rerank => "v1/rerank",
        _ => throw new ArgumentOutOfRangeException(nameof(endpoint)),
    };

    private async Task<AdvancedForwardResponse> ForwardCoreAsync(
        AdvancedForwardRequest request,
        CancellationToken cancellationToken)
    {
        var requestBytes = await ReadBoundedAsync(
            request.Content,
            _maximumRequestBytes,
            cancellationToken).ConfigureAwait(false);
        try
        {
            var endpoint = new Uri(
                request.ProviderBaseUri,
                EndpointPath(request.Endpoint));
            using var message = new HttpRequestMessage(HttpMethod.Post, endpoint);
            using var content = new ByteArrayContent(requestBytes);
            content.Headers.ContentType = MediaTypeHeaderValue.Parse(
                request.Content.Headers.ContentType!.ToString());
            message.Content = content;
            message.Headers.Authorization = new AuthenticationHeaderValue(
                "Bearer",
                request.BearerCredential);
            message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            using var response = await _client.SendAsync(
                message,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            var responseBytes = await ReadBoundedAsync(
                response.Content,
                _maximumResponseBytes,
                cancellationToken).ConfigureAwait(false);
            return new AdvancedForwardResponse(
                response.StatusCode,
                SafeResponseContentType(response.Content.Headers.ContentType),
                responseBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
        }
    }

    private static void ValidateRequest(AdvancedForwardRequest request)
    {
        if (!ConfigurationStore.IsSecureProviderEndpoint(request.ProviderBaseUri))
        {
            throw new InvalidDataException("The provider endpoint is unsafe.");
        }
        if (string.IsNullOrEmpty(request.BearerCredential)
            || request.BearerCredential.Length > 16_384
            || request.BearerCredential.Any(character => character <= ' ' || character >= 127))
        {
            throw new InvalidDataException("The provider credential is invalid.");
        }
        ArgumentNullException.ThrowIfNull(request.Content);
        var contentTypeHeader = request.Content.Headers.ContentType?.ToString();
        var mediaType = request.Content.Headers.ContentType?.MediaType;
        var requiresMultipart = request.Endpoint is
            AdvancedEndpointKind.ImageEdit or AdvancedEndpointKind.AudioTranscription;
        if (string.IsNullOrEmpty(contentTypeHeader)
            || contentTypeHeader.Length > 1_024
            || contentTypeHeader.Any(character => character < ' ' || character == 127)
            || (requiresMultipart
            ? !string.Equals(mediaType, "multipart/form-data", StringComparison.OrdinalIgnoreCase)
            : !string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidDataException("The content type does not match the endpoint protocol.");
        }
    }

    private static string SafeResponseContentType(MediaTypeHeaderValue? contentType)
    {
        var value = contentType?.ToString();
        return !string.IsNullOrEmpty(value)
            && value.Length <= 512
            && value.All(character => character >= ' ' && character != 127)
                ? value
                : "application/octet-stream";
    }

    private static int ValidateByteLimit(int value, string parameterName) =>
        value is >= 1 and <= 64 * 1024 * 1024
            ? value
            : throw new ArgumentOutOfRangeException(parameterName);

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is < 0 or > int.MaxValue
            || content.Headers.ContentLength > maximumBytes)
        {
            throw new InvalidDataException("The HTTP payload exceeds the configured limit.");
        }
        await using var source = await content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var output = new MemoryStream(
            content.Headers.ContentLength is > 0
                ? (int)content.Headers.ContentLength.Value
                : Math.Min(maximumBytes, 81_920));
        var buffer = new byte[Math.Min(81_920, maximumBytes + 1)];
        try
        {
            var total = 0;
            while (true)
            {
                var read = await source.ReadAsync(buffer, cancellationToken)
                    .ConfigureAwait(false);
                if (read == 0) { break; }
                total = checked(total + read);
                if (total > maximumBytes)
                {
                    throw new InvalidDataException(
                        "The HTTP payload exceeds the configured limit.");
                }
                await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken)
                    .ConfigureAwait(false);
            }
            return output.ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
        }
    }
}
