using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace ModelHub.Windows.Services;

public sealed record MultipartUpload(
    string FieldName,
    string FileName,
    string ContentType,
    ReadOnlyMemory<byte> Content);

public sealed record MultipartMediaRequest(
    AdvancedEndpointKind Endpoint,
    IReadOnlyDictionary<string, string> Fields,
    IReadOnlyList<MultipartUpload> Files);

/// <summary>
/// Constructs multipart payloads for the two upload endpoints supported by the
/// local gateway. Header-bearing values are deliberately ASCII allowlisted so
/// untrusted filenames cannot inject additional multipart headers.
/// </summary>
public sealed class MultipartMediaForwarder
{
    private const int MaximumFields = 64;
    private const int MaximumFieldValueBytes = 16 * 1024;
    private readonly AdvancedEndpointForwarder _forwarder;
    private readonly int _maximumFileBytes;
    private readonly int _maximumTotalBytes;
    private readonly int _maximumFiles;

    public MultipartMediaForwarder(
        AdvancedEndpointForwarder forwarder,
        int maximumFileBytes = 25 * 1024 * 1024,
        int maximumTotalBytes = AdvancedEndpointForwarder.DefaultMaximumRequestBytes,
        int maximumFiles = 16)
    {
        _forwarder = forwarder ?? throw new ArgumentNullException(nameof(forwarder));
        _maximumFileBytes = ValidateLimit(maximumFileBytes, nameof(maximumFileBytes));
        _maximumTotalBytes = ValidateLimit(maximumTotalBytes, nameof(maximumTotalBytes));
        if (_maximumFileBytes > _maximumTotalBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumFileBytes));
        }
        _maximumFiles = maximumFiles is >= 1 and <= 32
            ? maximumFiles
            : throw new ArgumentOutOfRangeException(nameof(maximumFiles));
    }

    public async Task<AdvancedForwardResponse> ForwardAsync(
        Uri providerBaseUri,
        string bearerCredential,
        MultipartMediaRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateRequest(request);

        using var multipart = new MultipartFormDataContent(
            $"modelhub-{Guid.NewGuid():N}");
        var ownedBuffers = new List<byte[]>(request.Files.Count);
        try
        {
            foreach (var field in request.Fields.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                var fieldContent = new StringContent(field.Value, Encoding.UTF8);
                multipart.Add(fieldContent, field.Key);
            }

            foreach (var upload in request.Files)
            {
                var buffer = upload.Content.ToArray();
                ownedBuffers.Add(buffer);
                var fileContent = new ByteArrayContent(buffer);
                fileContent.Headers.ContentType = MediaTypeHeaderValue.Parse(upload.ContentType);
                multipart.Add(fileContent, upload.FieldName, upload.FileName);
            }

            return await _forwarder.ForwardAsync(
                new AdvancedForwardRequest(
                    providerBaseUri,
                    request.Endpoint,
                    bearerCredential,
                    multipart),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            foreach (var buffer in ownedBuffers)
            {
                CryptographicOperations.ZeroMemory(buffer);
            }
        }
    }

    private void ValidateRequest(MultipartMediaRequest request)
    {
        if (request.Endpoint is not (
            AdvancedEndpointKind.ImageEdit or AdvancedEndpointKind.AudioTranscription))
        {
            throw new InvalidDataException("Multipart forwarding is not supported for this endpoint.");
        }
        ArgumentNullException.ThrowIfNull(request.Fields);
        ArgumentNullException.ThrowIfNull(request.Files);
        if (request.Fields.Count > MaximumFields || request.Files.Count is 0 || request.Files.Count > _maximumFiles)
        {
            throw new InvalidDataException("The multipart part count exceeds the configured limit.");
        }

        long totalBytes = 0;
        foreach (var field in request.Fields)
        {
            if (!IsSafeToken(field.Key, 64)
                || field.Value is null
                || Encoding.UTF8.GetByteCount(field.Value) > MaximumFieldValueBytes)
            {
                throw new InvalidDataException("A multipart form field is invalid.");
            }
            totalBytes = checked(totalBytes + Encoding.UTF8.GetByteCount(field.Value));
        }

        var primaryUploads = 0;
        foreach (var upload in request.Files)
        {
            if (!IsSafeToken(upload.FieldName, 64)
                || !IsSafeFileName(upload.FileName)
                || !IsAllowedContentType(request.Endpoint, upload.ContentType)
                || upload.Content.Length is 0
                || upload.Content.Length > _maximumFileBytes)
            {
                throw new InvalidDataException("A multipart file is invalid or too large.");
            }
            totalBytes = checked(totalBytes + upload.Content.Length);
            if (request.Endpoint == AdvancedEndpointKind.AudioTranscription
                && string.Equals(upload.FieldName, "file", StringComparison.Ordinal))
            {
                primaryUploads++;
            }
            if (request.Endpoint == AdvancedEndpointKind.ImageEdit
                && string.Equals(upload.FieldName, "image", StringComparison.Ordinal))
            {
                primaryUploads++;
            }
        }

        if (primaryUploads == 0
            || (request.Endpoint == AdvancedEndpointKind.AudioTranscription
                && (primaryUploads != 1 || request.Files.Count != 1)))
        {
            throw new InvalidDataException("The required primary upload is missing or ambiguous.");
        }
        if (totalBytes > _maximumTotalBytes)
        {
            throw new InvalidDataException("The multipart payload exceeds the configured limit.");
        }
    }

    private static bool IsAllowedContentType(
        AdvancedEndpointKind endpoint,
        string contentType)
    {
        if (string.IsNullOrEmpty(contentType)
            || contentType.Length > 128
            || contentType.Any(character => character <= ' ' || character >= 127))
        {
            return false;
        }
        return endpoint switch
        {
            AdvancedEndpointKind.ImageEdit => contentType is
                "image/png" or "image/jpeg" or "image/webp",
            AdvancedEndpointKind.AudioTranscription => contentType is
                "audio/wav" or "audio/x-wav" or "audio/mpeg" or "audio/mp4"
                or "audio/webm" or "audio/ogg" or "application/ogg",
            _ => false,
        };
    }

    private static bool IsSafeFileName(string fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName)
            || fileName.Length > 255
            || fileName is "." or ".."
            || fileName.Contains("..", StringComparison.Ordinal)
            || fileName.Any(character => !IsSafeFileNameCharacter(character)))
        {
            return false;
        }
        return true;
    }

    private static bool IsSafeFileNameCharacter(char character) =>
        character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '.' or '_' or '-';

    private static bool IsSafeToken(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length <= maximumLength
        && value.All(character => character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '_' or '-' or '.');

    private static int ValidateLimit(int value, string parameterName) =>
        value is >= 1 and <= 64 * 1024 * 1024
            ? value
            : throw new ArgumentOutOfRangeException(parameterName);
}
