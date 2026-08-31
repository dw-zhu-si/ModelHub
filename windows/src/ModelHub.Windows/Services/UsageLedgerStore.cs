using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Bounded, append-only local usage ledger. It stores metadata only, never requests, responses, keys, or prompts.</summary>
public sealed class UsageLedgerStore : IDisposable
{
    private const long MaximumLedgerBytes = 64L * 1024 * 1024;
    private const int MaximumPageSize = 200;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _directory;
    private readonly string _path;

    public UsageLedgerStore(string? directory = null)
    {
        _directory = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ModelHub");
        _path = Path.Combine(_directory, "usage-ledger.ndjson");
    }

    public async Task AppendAsync(UsageLedgerEntry entry, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(_directory);
            RejectLink(_directory);
            if (File.Exists(_path))
            {
                RejectLink(_path);
                if (new FileInfo(_path).Length >= MaximumLedgerBytes)
                {
                    return; // Preserve bounded disk usage; observability must not destabilize the gateway.
                }
            }
            var line = JsonSerializer.SerializeToUtf8Bytes(entry, JsonOptions);
            try
            {
                await using var stream = new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough | FileOptions.Asynchronous);
                await stream.WriteAsync(line, cancellationToken).ConfigureAwait(false);
                await stream.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                if (OperatingSystem.IsWindows()) { ApplyCurrentUserAcl(_path); }
            }
            finally { Array.Clear(line); }
        }
        finally { _gate.Release(); }
    }

    public async Task<UsageLedgerPage> ReadPageAsync(string? cursor, int requestedLimit, CancellationToken cancellationToken = default)
    {
        var offset = ParseCursor(cursor);
        var limit = Math.Clamp(requestedLimit, 1, MaximumPageSize);
        if (!File.Exists(_path)) { return new UsageLedgerPage([], null); }
        RejectLink(_path);
        if (new FileInfo(_path).Length > MaximumLedgerBytes) { return new UsageLedgerPage([], null); }

        var entries = new List<UsageLedgerEntry>(limit);
        var seen = 0;
        await using var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var reader = new StreamReader(stream);
        var hasMore = false;
        while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
        {
            if (seen++ < offset) { continue; }
            if (entries.Count == limit) { hasMore = true; break; }
            if (line.Length > 16384) { continue; }
            try
            {
                var entry = JsonSerializer.Deserialize<UsageLedgerEntry>(line, JsonOptions);
                if (entry is not null) { entries.Add(entry); }
            }
            catch (JsonException) { /* A partial or corrupt row is ignored rather than breaking API observability. */ }
        }
        var next = hasMore ? EncodeCursor(offset + entries.Count) : null;
        return new UsageLedgerPage(entries, next);
    }

    private static int ParseCursor(string? cursor)
    {
        if (string.IsNullOrWhiteSpace(cursor)) { return 0; }
        try
        {
            var raw = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(cursor));
            return int.TryParse(raw, out var offset) && offset >= 0 ? offset : 0;
        }
        catch (FormatException) { return 0; }
    }

    private static string EncodeCursor(int offset) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(offset.ToString(System.Globalization.CultureInfo.InvariantCulture)));

    private static void RejectLink(string path)
    {
        var info = new FileInfo(path);
        if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) { throw new IOException("Ledger path must not be a symbolic link or reparse point."); }
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserAcl(string path)
    {
        var security = new FileSecurity();
        var user = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("The current Windows user is unavailable.");
        security.SetOwner(user);
        security.SetAccessRuleProtection(true, false);
        security.SetAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    public void Dispose() => _gate.Dispose();
}
