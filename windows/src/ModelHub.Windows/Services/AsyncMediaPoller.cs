using System.Net;
using System.Net.Http.Headers;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public enum AsyncMediaTaskIdentifierField
{
    TaskId,
    DataTaskId,
    OutputTaskId,
}

public sealed record AsyncMediaProtocolDefinition(
    string CreatePath,
    string PollPathTemplate,
    AsyncMediaTaskIdentifierField TaskIdentifierField);

public sealed record AsyncMediaPollRequest(
    Uri ProviderBaseUri,
    AsyncMediaProtocolDefinition Protocol,
    string BearerCredential,
    ReadOnlyMemory<byte> CreateBody,
    string ArtifactKind);

public sealed record AsyncMediaPollResult(
    string? UpstreamTaskId,
    MediaArtifact Artifact,
    int PollAttempts);

/// <summary>
/// Implements bounded create-and-poll media protocols. A task is successful
/// only after an explicit HTTPS artifact or a locally persisted inline artifact
/// is observed. Generic id/request_id fields are never interpreted as task IDs.
/// </summary>
public sealed class AsyncMediaPoller : IDisposable
{
    private const int HardMaximumBodyBytes = 64 * 1024 * 1024;
    private const int HardMaximumArtifactBytes = 256 * 1024 * 1024;
    private readonly HttpClient _client;
    private readonly SemaphoreSlim _taskSlots;
    private readonly string _artifactDirectory;
    private readonly int _maximumRequestBytes;
    private readonly int _maximumResponseBytes;
    private readonly int _maximumArtifactBytes;
    private readonly int _maximumPollAttempts;
    private readonly TimeSpan _pollInterval;
    private readonly TimeSpan _requestTimeout;
    private readonly TimeSpan _totalTimeout;

    public AsyncMediaPoller(
        HttpMessageHandler? handler = null,
        string? artifactDirectory = null,
        int maximumRequestBytes = 4 * 1024 * 1024,
        int maximumResponseBytes = 4 * 1024 * 1024,
        int maximumArtifactBytes = 64 * 1024 * 1024,
        int maximumPollAttempts = 20,
        TimeSpan? pollInterval = null,
        TimeSpan? requestTimeout = null,
        TimeSpan? totalTimeout = null,
        int maximumConcurrentTasks = 4)
    {
        _maximumRequestBytes = ValidateByteLimit(
            maximumRequestBytes,
            HardMaximumBodyBytes,
            nameof(maximumRequestBytes));
        _maximumResponseBytes = ValidateByteLimit(
            maximumResponseBytes,
            HardMaximumBodyBytes,
            nameof(maximumResponseBytes));
        _maximumArtifactBytes = ValidateByteLimit(
            maximumArtifactBytes,
            HardMaximumArtifactBytes,
            nameof(maximumArtifactBytes));
        _maximumPollAttempts = maximumPollAttempts is >= 1 and <= 100
            ? maximumPollAttempts
            : throw new ArgumentOutOfRangeException(nameof(maximumPollAttempts));
        _pollInterval = ValidateDuration(
            pollInterval ?? TimeSpan.FromSeconds(2),
            TimeSpan.Zero,
            TimeSpan.FromMinutes(1),
            nameof(pollInterval));
        _requestTimeout = ValidateDuration(
            requestTimeout ?? TimeSpan.FromSeconds(30),
            TimeSpan.FromMilliseconds(10),
            TimeSpan.FromMinutes(5),
            nameof(requestTimeout));
        _totalTimeout = ValidateDuration(
            totalTimeout ?? TimeSpan.FromMinutes(5),
            TimeSpan.FromMilliseconds(50),
            TimeSpan.FromMinutes(30),
            nameof(totalTimeout));
        if (maximumConcurrentTasks is < 1 or > 16)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumConcurrentTasks));
        }

        _artifactDirectory = Path.GetFullPath(artifactDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ModelHub",
            "media-artifacts"));
        _taskSlots = new SemaphoreSlim(maximumConcurrentTasks, maximumConcurrentTasks);
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

    public async Task<AsyncMediaPollResult> CreateAndPollAsync(
        AsyncMediaPollRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);
        using var total = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        total.CancelAfter(_totalTimeout);
        try
        {
            await _taskSlots.WaitAsync(total.Token).ConfigureAwait(false);
            try
            {
                return await CreateAndPollCoreAsync(request, total.Token)
                    .ConfigureAwait(false);
            }
            finally
            {
                _taskSlots.Release();
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("The asynchronous media operation timed out.");
        }
    }

    public void Dispose()
    {
        _client.Dispose();
        _taskSlots.Dispose();
    }

    private async Task<AsyncMediaPollResult> CreateAndPollCoreAsync(
        AsyncMediaPollRequest request,
        CancellationToken cancellationToken)
    {
        using var creation = await SendJsonAsync(
            HttpMethod.Post,
            new Uri(request.ProviderBaseUri, request.Protocol.CreatePath),
            request.BearerCredential,
            request.CreateBody,
            cancellationToken).ConfigureAwait(false);
        ThrowIfFailedStatus(creation.RootElement);
        var synchronousArtifact = await ExtractArtifactAsync(
            creation.RootElement,
            request.ArtifactKind,
            cancellationToken).ConfigureAwait(false);
        if (synchronousArtifact is not null)
        {
            return new AsyncMediaPollResult(null, synchronousArtifact, 0);
        }

        var taskId = ReadTaskId(
            creation.RootElement,
            request.Protocol.TaskIdentifierField);
        if (!IsSafeTaskId(taskId))
        {
            throw new InvalidDataException(
                "The media creation response did not contain the configured task_id field.");
        }

        for (var attempt = 1; attempt <= _maximumPollAttempts; attempt++)
        {
            if (_pollInterval > TimeSpan.Zero)
            {
                await Task.Delay(_pollInterval, cancellationToken).ConfigureAwait(false);
            }
            var pollPath = request.Protocol.PollPathTemplate.Replace(
                "{task_id}",
                Uri.EscapeDataString(taskId!),
                StringComparison.Ordinal);
            using var poll = await SendJsonAsync(
                HttpMethod.Get,
                new Uri(request.ProviderBaseUri, pollPath),
                request.BearerCredential,
                ReadOnlyMemory<byte>.Empty,
                cancellationToken).ConfigureAwait(false);

            var status = ReadStatus(poll.RootElement);
            if (IsFailedStatus(status))
            {
                throw new InvalidDataException("The upstream media task failed.");
            }
            var artifact = await ExtractArtifactAsync(
                poll.RootElement,
                request.ArtifactKind,
                cancellationToken).ConfigureAwait(false);
            if (artifact is not null)
            {
                return new AsyncMediaPollResult(taskId, artifact, attempt);
            }
            if (IsCompletedStatus(status))
            {
                throw new InvalidDataException(
                    "The upstream media task completed without a usable artifact.");
            }
            if (!IsPendingStatus(status))
            {
                throw new InvalidDataException(
                    "The upstream media task returned an unrecognized state without an artifact.");
            }
        }
        throw new TimeoutException("The upstream media task exceeded the poll attempt limit.");
    }

    private async Task<JsonDocument> SendJsonAsync(
        HttpMethod method,
        Uri endpoint,
        string credential,
        ReadOnlyMemory<byte> body,
        CancellationToken cancellationToken)
    {
        using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        requestTimeout.CancelAfter(_requestTimeout);
        using var message = new HttpRequestMessage(method, endpoint);
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
        message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        byte[]? bodyCopy = null;
        try
        {
            if (method != HttpMethod.Get)
            {
                bodyCopy = body.ToArray();
                message.Content = new ByteArrayContent(bodyCopy);
                message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
            using var response = await _client.SendAsync(
                message,
                HttpCompletionOption.ResponseHeadersRead,
                requestTimeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidDataException(
                    $"The upstream media endpoint returned HTTP {(int)response.StatusCode}.");
            }
            var bytes = await ReadBoundedAsync(
                response.Content,
                _maximumResponseBytes,
                requestTimeout.Token).ConfigureAwait(false);
            try
            {
                using var jsonStream = new MemoryStream(bytes, writable: false);
                return await JsonDocument.ParseAsync(jsonStream, new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32,
                }, requestTimeout.Token).ConfigureAwait(false);
            }
            catch (JsonException exception)
            {
                throw new InvalidDataException(
                    "The upstream media response is not valid bounded JSON.",
                    exception);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("The upstream media request timed out.");
        }
        finally
        {
            if (bodyCopy is not null)
            {
                CryptographicOperations.ZeroMemory(bodyCopy);
            }
        }
    }

    private async Task<MediaArtifact?> ExtractArtifactAsync(
        JsonElement root,
        string artifactKind,
        CancellationToken cancellationToken)
    {
        foreach (var candidate in EnumerateArtifactCandidates(root))
        {
            if (TryReadString(candidate, "url", out var remote)
                && TryCreateSafeArtifactUri(remote, out var remoteUri))
            {
                return new MediaArtifact(artifactKind, remoteUri, null, 1);
            }
            if (TryReadString(candidate, "b64_json", out var encoded))
            {
                return await PersistInlineArtifactAsync(
                    encoded,
                    artifactKind,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        return null;
    }

    private static IEnumerable<JsonElement> EnumerateArtifactCandidates(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            yield break;
        }
        yield return root;
        foreach (var propertyName in new[] { "data", "output", "result", "artifacts" })
        {
            if (!root.TryGetProperty(propertyName, out var value)) { continue; }
            if (value.ValueKind == JsonValueKind.Object)
            {
                yield return value;
            }
            else if (value.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in value.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.Object)
                    {
                        yield return item;
                    }
                }
            }
        }
    }

    private async Task<MediaArtifact> PersistInlineArtifactAsync(
        string encoded,
        string artifactKind,
        CancellationToken cancellationToken)
    {
        var maximumEncodedLength = checked(((_maximumArtifactBytes + 2L) / 3L) * 4L);
        if (string.IsNullOrEmpty(encoded) || encoded.Length > maximumEncodedLength)
        {
            throw new InvalidDataException("The inline media artifact is too large.");
        }
        byte[] decoded;
        try
        {
            decoded = Convert.FromBase64String(encoded);
        }
        catch (FormatException exception)
        {
            throw new InvalidDataException("The inline media artifact is not valid base64.", exception);
        }
        if (decoded.Length is 0 || decoded.Length > _maximumArtifactBytes)
        {
            CryptographicOperations.ZeroMemory(decoded);
            throw new InvalidDataException("The inline media artifact is empty or too large.");
        }

        EnsurePrivateArtifactDirectory();
        var path = Path.Combine(
            _artifactDirectory,
            $"{Guid.NewGuid():N}{ExtensionFor(artifactKind)}");
        try
        {
            await using (var stream = OpenPrivateArtifactFile(path))
            {
                await stream.WriteAsync(decoded, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            ApplyPrivateFilePermissions(path);
            return new MediaArtifact(artifactKind, null, path, decoded.Length);
        }
        catch
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(decoded);
        }
    }

    private void EnsurePrivateArtifactDirectory()
    {
        if (File.Exists(_artifactDirectory)
            || (Directory.Exists(_artifactDirectory)
                && IsLinkOrReparsePoint(_artifactDirectory)))
        {
            throw new InvalidDataException("The artifact directory is unsafe.");
        }
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(_artifactDirectory);
            ApplyCurrentUserDirectoryAcl(_artifactDirectory);
        }
        else
        {
            Directory.CreateDirectory(
                _artifactDirectory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            File.SetUnixFileMode(
                _artifactDirectory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    private static FileStream OpenPrivateArtifactFile(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            return new FileStream(
                path,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough);
        }
        return new FileStream(path, new FileStreamOptions
        {
            Mode = FileMode.CreateNew,
            Access = FileAccess.Write,
            Share = FileShare.None,
            BufferSize = 64 * 1024,
            Options = FileOptions.Asynchronous | FileOptions.WriteThrough,
            UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite,
        });
    }

    private static void ApplyPrivateFilePermissions(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            ApplyCurrentUserFileAcl(path);
        }
        else
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserFileAcl(string path)
    {
        var user = WindowsIdentity.GetCurrent().User
            ?? throw new InvalidOperationException("The current Windows user is unavailable.");
        var security = new FileSecurity();
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserDirectoryAcl(string path)
    {
        var user = WindowsIdentity.GetCurrent().User
            ?? throw new InvalidOperationException("The current Windows user is unavailable.");
        var security = new DirectorySecurity();
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    private static string? ReadTaskId(
        JsonElement root,
        AsyncMediaTaskIdentifierField field)
    {
        if (root.ValueKind != JsonValueKind.Object) { return null; }
        return field switch
        {
            AsyncMediaTaskIdentifierField.TaskId =>
                ReadOptionalString(root, "task_id"),
            AsyncMediaTaskIdentifierField.DataTaskId =>
                ReadNestedOptionalString(root, "data", "task_id"),
            AsyncMediaTaskIdentifierField.OutputTaskId =>
                ReadNestedOptionalString(root, "output", "task_id"),
            _ => null,
        };
    }

    private static string? ReadStatus(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) { return null; }
        return ReadOptionalString(root, "status")
            ?? ReadNestedOptionalString(root, "data", "status")
            ?? ReadNestedOptionalString(root, "output", "status");
    }

    private static void ThrowIfFailedStatus(JsonElement root)
    {
        if (IsFailedStatus(ReadStatus(root)))
        {
            throw new InvalidDataException("The upstream media creation failed.");
        }
    }

    private static string? ReadOptionalString(JsonElement element, string propertyName) =>
        TryReadString(element, propertyName, out var value) ? value : null;

    private static string? ReadNestedOptionalString(
        JsonElement root,
        string containerName,
        string propertyName) =>
        root.TryGetProperty(containerName, out var container)
        && container.ValueKind == JsonValueKind.Object
            ? ReadOptionalString(container, propertyName)
            : null;

    private static bool TryReadString(
        JsonElement element,
        string propertyName,
        out string value)
    {
        value = string.Empty;
        return element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String
            && (value = property.GetString() ?? string.Empty).Length > 0;
    }

    private static bool IsPendingStatus(string? value) => value?.ToLowerInvariant() is
        "pending" or "queued" or "processing" or "running" or "in_progress";

    private static bool IsCompletedStatus(string? value) => value?.ToLowerInvariant() is
        "completed" or "succeeded" or "success";

    private static bool IsFailedStatus(string? value) => value?.ToLowerInvariant() is
        "failed" or "error" or "cancelled" or "canceled";

    private static bool IsSafeTaskId(string? taskId) =>
        !string.IsNullOrEmpty(taskId)
        && taskId.Length <= 256
        && taskId.All(character => character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '_' or '-' or '.' or ':');

    private static bool TryCreateSafeArtifactUri(string value, out Uri? uri)
    {
        if (value.Length <= 4096
            && Uri.TryCreate(value, UriKind.Absolute, out var candidate)
            && candidate.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrWhiteSpace(candidate.Host)
            && string.IsNullOrEmpty(candidate.UserInfo)
            && string.IsNullOrEmpty(candidate.Fragment))
        {
            uri = candidate;
            return true;
        }
        uri = null;
        return false;
    }

    private void ValidateRequest(AsyncMediaPollRequest request)
    {
        if (!ConfigurationStore.IsSecureProviderEndpoint(request.ProviderBaseUri)
            || request.Protocol is null
            || !IsSafeProtocolPath(request.Protocol.CreatePath, requiresPlaceholder: false)
            || !IsSafeProtocolPath(request.Protocol.PollPathTemplate, requiresPlaceholder: true)
            || !IsSafeCredential(request.BearerCredential)
            || request.CreateBody.Length is 0
            || request.CreateBody.Length > _maximumRequestBytes
            || !IsSafeArtifactKind(request.ArtifactKind))
        {
            throw new InvalidDataException("The asynchronous media request is unsafe or too large.");
        }
    }

    private static bool IsSafeProtocolPath(string path, bool requiresPlaceholder)
    {
        if (string.IsNullOrEmpty(path)
            || path.Length > 1024
            || !path.StartsWith("/v1/", StringComparison.Ordinal)
            || path.StartsWith("//", StringComparison.Ordinal)
            || path.Contains('\\')
            || path.Contains('?')
            || path.Contains('#'))
        {
            return false;
        }
        string decoded;
        try
        {
            decoded = Uri.UnescapeDataString(path);
        }
        catch (UriFormatException)
        {
            return false;
        }
        if (decoded.Contains("/../", StringComparison.Ordinal)
            || decoded.EndsWith("/..", StringComparison.Ordinal)
            || decoded.Contains("/./", StringComparison.Ordinal)
            || decoded.EndsWith("/.", StringComparison.Ordinal)
            || decoded.Contains('\\')
            || decoded.Contains('?')
            || decoded.Contains('#'))
        {
            return false;
        }
        var placeholderCount = path.Split("{task_id}", StringSplitOptions.None).Length - 1;
        return requiresPlaceholder
            ? placeholderCount == 1
            : placeholderCount == 0 && !path.Contains('{') && !path.Contains('}');
    }

    private static bool IsSafeCredential(string value) =>
        !string.IsNullOrEmpty(value)
        && value.Length <= 16_384
        && value.All(character => character > ' ' && character < 127);

    private static bool IsSafeArtifactKind(string value) =>
        !string.IsNullOrEmpty(value)
        && value.Length <= 32
        && value.All(character => character is >= 'a' and <= 'z'
            or >= '0' and <= '9'
            or '-');

    private static string ExtensionFor(string artifactKind) => artifactKind switch
    {
        "image" => ".image",
        "video" => ".video",
        "audio" or "music" => ".audio",
        _ => ".bin",
    };

    private static bool IsLinkOrReparsePoint(string path)
    {
        var info = new DirectoryInfo(path);
        return info.LinkTarget is not null
            || (info.Attributes & FileAttributes.ReparsePoint) != 0;
    }

    private static int ValidateByteLimit(int value, int maximum, string parameterName) =>
        value is >= 1 && value <= maximum
            ? value
            : throw new ArgumentOutOfRangeException(parameterName);

    private static TimeSpan ValidateDuration(
        TimeSpan value,
        TimeSpan minimum,
        TimeSpan maximum,
        string parameterName) =>
        value >= minimum && value <= maximum
            ? value
            : throw new ArgumentOutOfRangeException(parameterName);

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength > maximumBytes)
        {
            throw new InvalidDataException("The upstream media response is too large.");
        }
        await using var source = await content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var output = new MemoryStream(Math.Min(maximumBytes, 81_920));
        var buffer = new byte[Math.Min(maximumBytes + 1, 81_920)];
        try
        {
            var total = 0;
            while (true)
            {
                var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0) { break; }
                total = checked(total + read);
                if (total > maximumBytes)
                {
                    throw new InvalidDataException("The upstream media response is too large.");
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
