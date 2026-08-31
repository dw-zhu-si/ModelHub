using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>One-shot PKCE flow for a user-owned Google developer application. It does not automate consumer subscriptions or rotate quota.</summary>
public sealed class WindowsDeveloperOAuth : IDisposable
{
    private const int MaximumCallbackLength = 4096;
    private const int MaximumCallbackHeaderBytes = 8 * 1024;
    private const int MaximumTokenResponseBytes = 64 * 1024;
    private const int MaximumResponseHeaderBytes = 16 * 1024;
    private static readonly Uri GoogleAuthorizationEndpoint = new("https://accounts.google.com/o/oauth2/v2/auth");
    private static readonly Uri GoogleTokenEndpoint = new("https://oauth2.googleapis.com/token");
    private static readonly HashSet<string> GoogleScopes = new(StringComparer.Ordinal)
    {
        "https://www.googleapis.com/auth/generative-language",
        "https://www.googleapis.com/auth/generative-language.retriever",
        "https://www.googleapis.com/auth/cloud-platform",
    };

    private readonly DeveloperOAuthRegistration _registration;
    private readonly ICredentialVault _vault;
    private readonly HttpClient _client;
    private readonly string _state;
    private readonly string _nonce;
    private readonly string _verifier;
    private readonly TimeSpan _callbackTotalTimeout;
    private readonly TimeSpan _callbackConnectionTimeout;
    private readonly CancellationTokenSource _disposeCancellation = new();
    private int _redeemed;
    private int _listenerStarted;

    public WindowsDeveloperOAuth(DeveloperOAuthRegistration registration, ICredentialVault vault, HttpMessageHandler? handler = null, TimeSpan? timeout = null, TimeSpan? callbackTotalTimeout = null, TimeSpan? callbackConnectionTimeout = null)
    {
        Validate(registration);
        _registration = registration;
        _vault = vault;
        _client = handler is null ? new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(10) }) : new HttpClient(handler, false);
        _client.Timeout = timeout is { } requested && requested >= TimeSpan.FromMilliseconds(100) && requested <= TimeSpan.FromSeconds(60) ? requested : TimeSpan.FromSeconds(30);
        _callbackTotalTimeout = ValidateCallbackTimeout(callbackTotalTimeout ?? TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(1), TimeSpan.FromMinutes(5), nameof(callbackTotalTimeout));
        _callbackConnectionTimeout = ValidateCallbackTimeout(callbackConnectionTimeout ?? TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(100), TimeSpan.FromSeconds(5), nameof(callbackConnectionTimeout));
        _state = RandomBase64Url(32);
        _nonce = RandomBase64Url(32);
        _verifier = RandomBase64Url(64);
        AuthorizationUri = BuildAuthorizationUri();
    }

    public Uri AuthorizationUri { get; }
    public string CredentialTarget => _registration.CredentialTarget;
    public string RefreshCredentialTarget => $"{_registration.CredentialTarget}/Refresh";
    public string ExpiryMetadataTarget => $"{_registration.CredentialTarget}/ExpiresAt";
    public string ReauthorizationMetadataTarget => $"{_registration.CredentialTarget}/ReauthorizationRequired";

    public async Task ListenAndRedeemCallbackAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _listenerStarted, 1) != 0) { throw new InvalidOperationException("This OAuth loopback listener has already been started."); }
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{_registration.RedirectUri.Port}/");
        listener.Start();
        using var totalCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _disposeCancellation.Token);
        totalCancellation.CancelAfter(_callbackTotalTimeout);
        while (Volatile.Read(ref _redeemed) == 0)
        {
            HttpListenerContext context;
            try { context = await listener.GetContextAsync().WaitAsync(totalCancellation.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw new TimeoutException("The one-time OAuth loopback callback expired."); }
            using var connectionCancellation = CancellationTokenSource.CreateLinkedTokenSource(totalCancellation.Token);
            connectionCancellation.CancelAfter(_callbackConnectionTimeout);
            try
            {
                if (!HttpMethod.Get.Method.Equals(context.Request.HttpMethod, StringComparison.Ordinal)) { throw new InvalidOperationException("OAuth loopback callback must use GET."); }
                var headers = context.Request.Headers.AllKeys.Where(key => key is not null).ToDictionary(key => key!, key => context.Request.Headers[key!] ?? string.Empty, StringComparer.OrdinalIgnoreCase);
                if (headers.Count > 64 || HeaderByteCount(headers) > MaximumCallbackHeaderBytes) { throw new InvalidOperationException("OAuth callback request headers exceeded the 8 KiB safety limit."); }
                await RedeemCallbackAsync(context.Request.Url ?? throw new InvalidOperationException("OAuth callback URL is unavailable."), headers, connectionCancellation.Token).ConfigureAwait(false);
                await WriteLoopbackResponseAsync(context.Response, HttpStatusCode.OK, "ModelHub developer OAuth completed. You may close this page.", connectionCancellation.Token).ConfigureAwait(false);
                return;
            }
            catch when (Volatile.Read(ref _redeemed) == 0)
            {
                try { await WriteLoopbackResponseAsync(context.Response, HttpStatusCode.BadRequest, "ModelHub ignored an invalid OAuth callback and is still waiting for the authorized response.", CancellationToken.None).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or ObjectDisposedException or HttpListenerException) { }
            }
            catch
            {
                try { await WriteLoopbackResponseAsync(context.Response, HttpStatusCode.BadRequest, "ModelHub rejected this OAuth callback. Return to the app and try again.", CancellationToken.None).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or ObjectDisposedException or HttpListenerException) { }
                throw;
            }
            finally { context.Response.Close(); }
        }
        listener.Stop();
    }

    public async Task RedeemCallbackAsync(Uri callback, IReadOnlyDictionary<string, string>? requestHeaders = null, CancellationToken cancellationToken = default)
    {
        ValidateCallback(callback);
        if (requestHeaders is { Count: > 64 } || requestHeaders is not null && HeaderByteCount(requestHeaders) > MaximumCallbackHeaderBytes) { throw new InvalidOperationException("OAuth callback request headers exceeded the 8 KiB safety limit."); }
        var query = ParseQuery(callback.Query);
        if (query.TryGetValue("error", out _)) { throw new InvalidOperationException("The authorization server denied the developer authorization request."); }
        if (!query.TryGetValue("state", out var state) || !FixedTimeEquals(state, _state)) { throw new InvalidOperationException("OAuth state validation failed."); }
        if (!query.TryGetValue("code", out var code) || string.IsNullOrWhiteSpace(code) || code.Length > 2048) { throw new InvalidOperationException("The OAuth authorization code is invalid."); }
        if (Interlocked.CompareExchange(ref _redeemed, 1, 0) != 0) { throw new InvalidOperationException("This OAuth callback has already been consumed."); }

        using var request = new HttpRequestMessage(HttpMethod.Post, GoogleTokenEndpoint)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = _registration.ClientId,
                ["code"] = code,
                ["code_verifier"] = _verifier,
                ["grant_type"] = "authorization_code",
                ["redirect_uri"] = _registration.RedirectUri.AbsoluteUri,
            }),
        };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        var headerBytes = response.Headers.Concat(response.Content.Headers).Sum(header => Encoding.UTF8.GetByteCount(header.Key) + header.Value.Sum(Encoding.UTF8.GetByteCount));
        if (headerBytes > MaximumResponseHeaderBytes) { throw new HttpRequestException("OAuth token response headers exceeded the safety limit."); }
        var bytes = await ReadBoundedAsync(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), MaximumTokenResponseBytes, cancellationToken).ConfigureAwait(false);
        try
        {
            if (!response.IsSuccessStatusCode) { throw new HttpRequestException("The official OAuth token endpoint rejected the authorization code."); }
            using var document = JsonDocument.Parse(bytes);
            var accessToken = document.RootElement.TryGetProperty("access_token", out var token) && token.ValueKind == JsonValueKind.String ? token.GetString() : null;
            if (string.IsNullOrWhiteSpace(accessToken) || Encoding.UTF8.GetByteCount(accessToken) > 5120) { throw new InvalidOperationException("The OAuth token response did not contain a usable access token."); }
            ValidateGrantedScopes(document.RootElement);
            var expiresIn = document.RootElement.TryGetProperty("expires_in", out var expiry) && expiry.TryGetInt32(out var seconds) && seconds is >= 1 and <= 86400
                ? seconds
                : throw new InvalidOperationException("The OAuth token response did not contain a bounded expiry.");
            var refreshToken = document.RootElement.TryGetProperty("refresh_token", out var refresh) && refresh.ValueKind == JsonValueKind.String ? refresh.GetString() : null;
            if (refreshToken is not null && Encoding.UTF8.GetByteCount(refreshToken) > 5120) { throw new InvalidOperationException("The OAuth refresh token exceeded the Credential Manager limit."); }
            var writtenTargets = new List<string>();
            try
            {
                _vault.Write(_registration.CredentialTarget, accessToken);
                writtenTargets.Add(_registration.CredentialTarget);
                _vault.Write(ExpiryMetadataTarget, DateTimeOffset.UtcNow.AddSeconds(expiresIn).ToString("O", System.Globalization.CultureInfo.InvariantCulture));
                writtenTargets.Add(ExpiryMetadataTarget);
                if (!string.IsNullOrWhiteSpace(refreshToken))
                {
                    _vault.Write(RefreshCredentialTarget, refreshToken);
                    writtenTargets.Add(RefreshCredentialTarget);
                    _vault.Delete(ReauthorizationMetadataTarget);
                }
                else
                {
                    _vault.Write(ReauthorizationMetadataTarget, "true");
                    writtenTargets.Add(ReauthorizationMetadataTarget);
                    _vault.Delete(RefreshCredentialTarget);
                }
            }
            catch
            {
                foreach (var target in writtenTargets) { try { _vault.Delete(target); } catch { } }
                throw;
            }
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public static object CreateConsumerSubscriptionAutomation() => throw new NotSupportedException("Consumer subscription OAuth automation is prohibited.");
    public static object EnableQuotaRotation() => throw new NotSupportedException("OAuth quota rotation is prohibited.");

    private Uri BuildAuthorizationUri()
    {
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(_verifier)));
        var parameters = new Dictionary<string, string>
        {
            ["client_id"] = _registration.ClientId,
            ["redirect_uri"] = _registration.RedirectUri.AbsoluteUri,
            ["response_type"] = "code",
            ["scope"] = string.Join(' ', _registration.Scopes),
            ["state"] = _state,
            ["nonce"] = _nonce,
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256",
            ["access_type"] = "offline",
            ["prompt"] = "consent",
        };
        var builder = new UriBuilder(GoogleAuthorizationEndpoint) { Query = string.Join('&', parameters.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}")) };
        return builder.Uri;
    }

    private void ValidateCallback(Uri callback)
    {
        if (!callback.IsAbsoluteUri || callback.AbsoluteUri.Length > MaximumCallbackLength || callback.Scheme != Uri.UriSchemeHttp || callback.Host != "127.0.0.1" || callback.Port != _registration.RedirectUri.Port || callback.AbsolutePath != _registration.RedirectUri.AbsolutePath || !string.IsNullOrEmpty(callback.Fragment))
        {
            throw new InvalidOperationException("OAuth callback did not match the registered 127.0.0.1 loopback redirect.");
        }
    }

    private static void Validate(DeveloperOAuthRegistration registration)
    {
        if (registration.Provider != DeveloperOAuthProvider.GoogleGemini || string.IsNullOrWhiteSpace(registration.ClientId) || registration.ClientId.Length > 512 || registration.CredentialId == Guid.Empty) { throw new ArgumentException("Developer OAuth registration is invalid.", nameof(registration)); }
        var redirect = registration.RedirectUri;
        if (!redirect.IsAbsoluteUri || redirect.Scheme != Uri.UriSchemeHttp || redirect.Host != "127.0.0.1" || redirect.IsDefaultPort || redirect.Port is < 1024 or > 65535 || redirect.AbsolutePath != "/oauth/callback" || !string.IsNullOrEmpty(redirect.Query) || !string.IsNullOrEmpty(redirect.Fragment) || !string.IsNullOrEmpty(redirect.UserInfo)) { throw new ArgumentException("OAuth redirect must be an exact http://127.0.0.1 loopback URI ending in /oauth/callback with an explicit non-privileged port.", nameof(registration)); }
        if (registration.Scopes.Count is < 1 or > 8 || registration.Scopes.Any(scope => !GoogleScopes.Contains(scope))) { throw new ArgumentException("OAuth scopes must come from the Google developer API allowlist.", nameof(registration)); }
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var pieces = part.Split('=', 2);
            if (pieces.Length != 2 || !result.TryAdd(Uri.UnescapeDataString(pieces[0]), Uri.UnescapeDataString(pieces[1]))) { throw new InvalidOperationException("OAuth callback query is malformed."); }
        }
        return result;
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        try { return leftBytes.Length == rightBytes.Length && CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes); }
        finally { CryptographicOperations.ZeroMemory(leftBytes); CryptographicOperations.ZeroMemory(rightBytes); }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream source, int maximumBytes, CancellationToken cancellationToken)
    {
        await using var destination = new MemoryStream();
        var buffer = new byte[8192];
        try
        {
            while (true)
            {
                var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0) { return destination.ToArray(); }
                if (destination.Length + read > maximumBytes) { throw new HttpRequestException("OAuth token response exceeded the safety limit."); }
                await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            }
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    private static string RandomBase64Url(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));
    private static string Base64Url(ReadOnlySpan<byte> bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static int HeaderByteCount(IEnumerable<KeyValuePair<string, string>> headers) => headers.Sum(header => checked(Encoding.UTF8.GetByteCount(header.Key) + Encoding.UTF8.GetByteCount(header.Value)));
    private void ValidateGrantedScopes(JsonElement root)
    {
        if (!root.TryGetProperty("scope", out var scopeElement) || scopeElement.ValueKind != JsonValueKind.String) { throw new InvalidOperationException("The OAuth token response omitted the granted scope set."); }
        var granted = (scopeElement.GetString() ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        var requested = _registration.Scopes.ToHashSet(StringComparer.Ordinal);
        if (!granted.SetEquals(requested)) { throw new InvalidOperationException("The OAuth token response scope set did not exactly cover the requested allowlist."); }
    }

    private static async Task WriteLoopbackResponseAsync(HttpListenerResponse response, HttpStatusCode status, string message, CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(message);
        response.StatusCode = (int)status;
        response.ContentType = "text/plain; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.Headers["Cache-Control"] = "no-store";
        try { await response.OutputStream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static TimeSpan ValidateCallbackTimeout(TimeSpan value, TimeSpan minimum, TimeSpan maximum, string parameterName) => value >= minimum && value <= maximum ? value : throw new ArgumentOutOfRangeException(parameterName);
    public void Dispose() { _disposeCancellation.Cancel(); _disposeCancellation.Dispose(); _client.Dispose(); }
}
