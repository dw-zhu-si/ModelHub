using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Tracks local media work and refuses 2xx responses without a usable remote or local artifact.</summary>
public sealed class MediaTaskRegistry
{
    private readonly ConcurrentDictionary<Guid, MediaTaskSnapshot> _tasks = new();
    private readonly object _capacityGate = new();
    private readonly int _capacity;
    private readonly TimeSpan _terminalTtl;
    private readonly Func<DateTimeOffset> _now;

    public MediaTaskRegistry(int capacity = 512, TimeSpan? terminalTtl = null, Func<DateTimeOffset>? now = null)
    {
        _capacity = capacity is >= 2 and <= 4096 ? capacity : throw new ArgumentOutOfRangeException(nameof(capacity));
        _terminalTtl = terminalTtl is null ? TimeSpan.FromHours(24) : terminalTtl.Value >= TimeSpan.FromSeconds(1) && terminalTtl.Value <= TimeSpan.FromDays(7) ? terminalTtl.Value : throw new ArgumentOutOfRangeException(nameof(terminalTtl));
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public MediaTaskSnapshot Create(string endpoint, string model)
    {
        lock (_capacityGate)
        {
            EvictExpiredAndOverflow(needSlot: true);
            if (_tasks.Count >= _capacity) { throw new InvalidOperationException("Media task capacity is occupied by active work."); }
            var timestamp = _now();
            var snapshot = new MediaTaskSnapshot(Guid.NewGuid(), endpoint, model, MediaTaskState.Pending, timestamp, timestamp, null, null);
            return _tasks.TryAdd(snapshot.Id, snapshot) ? snapshot : throw new InvalidOperationException("Task identifier collision.");
        }
    }

    public MediaTaskSnapshot MarkRunning(Guid id) => Update(id, task => task with { State = MediaTaskState.Running, UpdatedAt = _now() });

    public MediaTaskSnapshot MarkSucceeded(Guid id, MediaArtifact artifact)
    {
        if (!artifact.IsUsable) { throw new InvalidOperationException("A media task cannot succeed without a usable artifact."); }
        return Update(id, task => task with { State = MediaTaskState.Succeeded, Artifact = artifact, ErrorCode = null, UpdatedAt = _now() });
    }

    public MediaTaskSnapshot MarkFailed(Guid id, string errorCode) => Update(id, task => task with { State = MediaTaskState.Failed, ErrorCode = errorCode, UpdatedAt = _now() });

    public MediaTaskSnapshot? Get(Guid id)
    {
        lock (_capacityGate) { EvictExpiredAndOverflow(needSlot: false); }
        return _tasks.GetValueOrDefault(id);
    }

    private void EvictExpiredAndOverflow(bool needSlot)
    {
        var cutoff = _now() - _terminalTtl;
        foreach (var task in _tasks.Values.Where(IsTerminal).Where(task => task.UpdatedAt < cutoff)) { _tasks.TryRemove(task.Id, out _); }
        while (needSlot && _tasks.Count >= _capacity)
        {
            var oldest = _tasks.Values.Where(IsTerminal).OrderBy(task => task.UpdatedAt).FirstOrDefault();
            if (oldest is null || !_tasks.TryRemove(oldest.Id, out _)) { break; }
        }
    }

    private static bool IsTerminal(MediaTaskSnapshot task) => task.State is MediaTaskState.Succeeded or MediaTaskState.Failed or MediaTaskState.Cancelled;

    private MediaTaskSnapshot Update(Guid id, Func<MediaTaskSnapshot, MediaTaskSnapshot> update)
    {
        while (_tasks.TryGetValue(id, out var old))
        {
            var next = update(old);
            if (_tasks.TryUpdate(id, next, old)) { return next; }
        }
        throw new KeyNotFoundException("The media task does not exist.");
    }
}

public sealed class MediaArtifactStore
{
    private const int MaximumArtifactBytes = 64 * 1024 * 1024;
    private readonly string _directory;

    public MediaArtifactStore(string? directory = null) =>
        _directory = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ModelHub", "media-results");

    public async Task<MediaArtifact> CaptureAsync(HttpContent content, CancellationToken cancellationToken)
    {
        var contentType = content.Headers.ContentType?.MediaType ?? "application/octet-stream";
        if (!contentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase) && !contentType.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) && !contentType.StartsWith("video/", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Media success response did not contain a supported artifact content type.");
        }
        if (content.Headers.ContentLength is <= 0 or > MaximumArtifactBytes)
        {
            throw new InvalidOperationException("Media artifact has an invalid or excessive size.");
        }
        Directory.CreateDirectory(_directory);
        var suffix = contentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase) ? ".image" : contentType.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) ? ".audio" : ".video";
        var path = Path.Combine(_directory, $"{Guid.NewGuid():N}{suffix}");
        long total = 0;
        var buffer = new byte[81920];
        try
        {
            await using var source = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using var destination = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.WriteThrough);
            while (true)
            {
                var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0) { break; }
                total = checked(total + read);
                if (total > MaximumArtifactBytes) { throw new InvalidOperationException("Media artifact exceeds the local limit."); }
                await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            }
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            if (total == 0) { throw new InvalidOperationException("Media artifact was empty."); }
            return new MediaArtifact(contentType, null, path, total);
        }
        catch
        {
            if (File.Exists(path)) { File.Delete(path); }
            throw;
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    public static MediaArtifact ParseRemoteJsonArtifact(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        var candidates = new[] { "data", "output", "artifacts" };
        foreach (var property in candidates)
        {
            if (!document.RootElement.TryGetProperty(property, out var entries) || entries.ValueKind != JsonValueKind.Array) { continue; }
            foreach (var entry in entries.EnumerateArray())
            {
                if (entry.TryGetProperty("url", out var value) && value.ValueKind == JsonValueKind.String && Uri.TryCreate(value.GetString(), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps)
                {
                    return new MediaArtifact("remote-url", uri, null, 1);
                }
            }
        }
        throw new InvalidOperationException("Media success response did not contain a usable HTTPS artifact URL.");
    }
}
