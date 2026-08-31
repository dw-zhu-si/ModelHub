using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>
/// Imports and exports an explicit non-secret configuration schema. Credential
/// targets are identifiers for Credential Manager entries; credential values,
/// OAuth tokens, passwords, and API keys are not members of the schema.
/// </summary>
public sealed class ConfigurationImportExport
{
    private const int FormatVersion = 1;
    private const int HardMaximumBytes = 8 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 32,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = false,
    };
    private readonly int _maximumBytes;

    public ConfigurationImportExport(int maximumBytes = 2 * 1024 * 1024)
    {
        _maximumBytes = maximumBytes is >= 1 and <= HardMaximumBytes
            ? maximumBytes
            : throw new ArgumentOutOfRangeException(nameof(maximumBytes));
    }

    public async Task ExportAsync(
        ModelHubConfiguration configuration,
        string path,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var fullPath = ValidateExportPath(path);
        if (!IsSafeExportConfiguration(configuration))
        {
            throw new InvalidDataException(
                "The configuration contains unsafe or non-exportable metadata.");
        }

        var document = ToDocument(configuration);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
        if (bytes.Length is 0 || bytes.Length > _maximumBytes)
        {
            throw new InvalidDataException("The exported configuration is too large.");
        }

        var directory = Path.GetDirectoryName(fullPath)!;
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = OpenPrivateTemporaryFile(temporaryPath))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            ApplyPrivateFilePermissions(temporaryPath);
            EnsureNotLinkOrReparsePoint(fullPath, allowMissing: true);
            File.Move(temporaryPath, fullPath, overwrite: true);
            ApplyPrivateFilePermissions(fullPath);
        }
        finally
        {
            Array.Clear(bytes);
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    public async Task<ModelHubConfiguration> ImportAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        var fullPath = ValidateImportPath(path);
        var file = new FileInfo(fullPath);
        if (file.Length is <= 0 || file.Length > _maximumBytes)
        {
            throw new InvalidDataException("The imported configuration is empty or too large.");
        }

        byte[] bytes;
        await using (var stream = new FileStream(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            bytes = await ReadBoundedAsync(stream, _maximumBytes, cancellationToken)
                .ConfigureAwait(false);
        }
        try
        {
            ImportDocument? document;
            try
            {
                document = JsonSerializer.Deserialize<ImportDocument>(bytes, JsonOptions);
            }
            catch (JsonException exception)
            {
                throw new InvalidDataException(
                    "The imported configuration does not match the non-secret schema.",
                    exception);
            }
            var configuration = FromDocument(document);
            if (!IsSafeExportConfiguration(configuration))
            {
                throw new InvalidDataException(
                    "The imported configuration contains unsafe metadata.");
            }
            EnsureNotLinkOrReparsePoint(fullPath, allowMissing: false);
            return configuration;
        }
        finally
        {
            Array.Clear(bytes);
        }
    }

    private static ExportDocument ToDocument(ModelHubConfiguration configuration) => new(
        FormatVersion,
        configuration.SchemaVersion,
        new GatewayDocument(configuration.Gateway.Port),
        configuration.Providers.Select(provider => new ProviderDocument(
            provider.Id,
            provider.DisplayName,
            provider.BaseUri.AbsoluteUri,
            provider.IsEnabled,
            provider.Protocol,
            provider.Models.Select(model => new ModelDocument(
                model.Id,
                model.DisplayName,
                model.Capability)).ToArray())).ToArray(),
        configuration.Nodes.Select(node => new NodeDocument(
            node.Id,
            node.Name,
            node.ProxyUri.AbsoluteUri,
            node.IsSelected,
            node.SelectorGroup)).ToArray(),
        (configuration.CredentialPools ?? []).Select(pool => new PoolDocument(
            pool.ProviderId,
            pool.IsEnabled,
            pool.ManualCredentialId,
            pool.Entries.Select(entry => new PoolEntryDocument(
                entry.Id,
                entry.DisplayName,
                entry.CredentialTarget,
                entry.Priority,
                entry.RequiresReauthorization)).ToArray())).ToArray(),
        (configuration.Routes ?? []).Select(route => new RouteDocument(
            route.Alias,
            route.IsEnabled,
            route.Strategy,
            route.Targets.Select(target => new RouteTargetDocument(
                target.ProviderId,
                target.ModelId,
                target.Priority,
                target.Weight)).ToArray())).ToArray(),
        (configuration.ProviderEndpointPaths ?? []).Select(endpoint =>
            new ProviderEndpointPathDocument(
                endpoint.ProviderId,
                endpoint.Endpoint,
                endpoint.Path,
                endpoint.IsAsynchronous,
                endpoint.PollPathTemplate,
                endpoint.TaskIdentifierField)).ToArray(),
        (configuration.ModelNodeAssignments ?? []).Select(assignment =>
            new ModelNodeAssignmentDocument(
                assignment.ProviderId,
                assignment.ModelId,
                assignment.NodeId)).ToArray());

    private static ModelHubConfiguration FromDocument(ImportDocument? document)
    {
        if (document is null
            || document.FormatVersion != FormatVersion
            || document.SchemaVersion != 1
            || document.Gateway is null
            || document.Providers is null
            || document.Nodes is null
            || document.CredentialPools is null)
        {
            throw new InvalidDataException("The imported configuration format is unsupported.");
        }
        try
        {
            var providers = document.Providers.Select(provider =>
            {
                if (provider is null || provider.Models is null)
                {
                    throw new InvalidDataException("A provider entry is incomplete.");
                }
                return new ProviderConfiguration(
                    provider.Id,
                    provider.DisplayName ?? string.Empty,
                    new Uri(provider.BaseUri ?? string.Empty, UriKind.Absolute),
                    provider.IsEnabled,
                    provider.Models.Select(model => model is null
                        ? throw new InvalidDataException("A model entry is incomplete.")
                        : new ModelDefinition(
                            model.Id ?? string.Empty,
                            model.DisplayName ?? string.Empty,
                            model.Capability ?? string.Empty)).ToArray(),
                    provider.Protocol);
            }).ToArray();
            var nodes = document.Nodes.Select(node => node is null
                ? throw new InvalidDataException("A node entry is incomplete.")
                : new NodeConfiguration(
                    node.Id,
                    node.Name ?? string.Empty,
                    new Uri(node.ProxyUri ?? string.Empty, UriKind.Absolute),
                    node.IsSelected,
                    node.SelectorGroup)).ToArray();
            var pools = document.CredentialPools.Select(pool =>
            {
                if (pool is null || pool.Entries is null)
                {
                    throw new InvalidDataException("A credential-pool entry is incomplete.");
                }
                return new CredentialPoolConfiguration(
                    pool.ProviderId,
                    pool.IsEnabled,
                    pool.ManualCredentialId,
                    pool.Entries.Select(entry => entry is null
                        ? throw new InvalidDataException("A credential entry is incomplete.")
                        : new CredentialPoolEntry(
                            entry.Id,
                            entry.DisplayName ?? string.Empty,
                            entry.CredentialTarget ?? string.Empty,
                            entry.Priority,
                            entry.RequiresReauthorization)).ToArray());
            }).ToArray();
            var routes = (document.Routes ?? []).Select(route =>
            {
                if (route is null || route.Targets is null)
                {
                    throw new InvalidDataException("A model-route entry is incomplete.");
                }
                return new ModelRouteDefinition(
                    route.Alias ?? string.Empty,
                    route.IsEnabled,
                    route.Strategy,
                    route.Targets.Select(target => target is null
                        ? throw new InvalidDataException("A route-target entry is incomplete.")
                        : new ModelRouteTarget(
                            target.ProviderId,
                            target.ModelId ?? string.Empty,
                            target.Priority,
                            target.Weight)).ToArray());
            }).ToArray();
            var endpointPaths = (document.ProviderEndpointPaths ?? []).Select(endpoint =>
                endpoint is null
                    ? throw new InvalidDataException("A provider-endpoint entry is incomplete.")
                    : new ProviderEndpointPath(
                        endpoint.ProviderId,
                        endpoint.Endpoint,
                        endpoint.Path ?? string.Empty,
                        endpoint.IsAsynchronous,
                        endpoint.PollPathTemplate,
                        endpoint.TaskIdentifierField)).ToArray();
            var assignments = (document.ModelNodeAssignments ?? []).Select(assignment =>
                assignment is null
                    ? throw new InvalidDataException("A model-node assignment is incomplete.")
                    : new ModelNodeAssignment(
                        assignment.ProviderId,
                        assignment.ModelId ?? string.Empty,
                        assignment.NodeId)).ToArray();
            return new ModelHubConfiguration(
                document.SchemaVersion,
                new GatewaySettings(
                    document.Gateway.Port,
                    GatewaySettings.DefaultCredentialTarget),
                providers,
                nodes,
                pools,
                routes,
                endpointPaths,
                assignments);
        }
        catch (UriFormatException exception)
        {
            throw new InvalidDataException("The imported configuration contains an invalid URL.", exception);
        }
    }

    private static bool IsSafeExportConfiguration(ModelHubConfiguration configuration)
    {
        if (!ConfigurationStore.IsSafe(configuration)
            || !string.Equals(
                configuration.Gateway.TokenCredentialTarget,
                GatewaySettings.DefaultCredentialTarget,
                StringComparison.Ordinal)
            || configuration.Providers.Any(provider => !Enum.IsDefined(provider.Protocol))
            || configuration.Providers.Select(provider => provider.Id).Distinct().Count()
                != configuration.Providers.Count
            || configuration.Nodes.Select(node => node.Id).Distinct().Count()
                != configuration.Nodes.Count
            || configuration.Nodes.Any(node => !node.ProxyUri.IsLoopback))
        {
            return false;
        }
        if (configuration.CredentialPools is null)
        {
            return true;
        }
        return configuration.CredentialPools.Select(pool => pool.ProviderId).Distinct().Count()
                == configuration.CredentialPools.Count
            && configuration.CredentialPools.All(pool => pool.Entries.All(entry =>
                IsSafeCredentialTarget(entry.CredentialTarget, pool.ProviderId)
                && entry.DisplayName.Length <= 128));
    }

    private static bool IsSafeCredentialTarget(string value, Guid providerId)
    {
        var expectedPrefix = $"ModelHub.Windows/Pool/{providerId:N}/";
        return value.Length > expectedPrefix.Length
            && value.Length <= 512
            && value.StartsWith(expectedPrefix, StringComparison.Ordinal)
            && !value.Contains("..", StringComparison.Ordinal)
            && value.All(character => character is >= 'a' and <= 'z'
                or >= 'A' and <= 'Z'
                or >= '0' and <= '9'
                or '/' or '_' or '-' or '.');
    }

    private static string ValidateExportPath(string path)
    {
        var fullPath = ValidateAbsolutePath(path);
        var parent = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidDataException("The export path has no parent directory.");
        if (!Directory.Exists(parent) || IsLinkOrReparsePoint(new DirectoryInfo(parent)))
        {
            throw new InvalidDataException("The export directory is missing or unsafe.");
        }
        if (Directory.Exists(fullPath))
        {
            throw new InvalidDataException("The export target is not a regular file.");
        }
        EnsureNotLinkOrReparsePoint(fullPath, allowMissing: true);
        return fullPath;
    }

    private static string ValidateImportPath(string path)
    {
        var fullPath = ValidateAbsolutePath(path);
        EnsureNotLinkOrReparsePoint(fullPath, allowMissing: false);
        if (!File.Exists(fullPath) || Directory.Exists(fullPath))
        {
            throw new InvalidDataException("The import target is not a regular file.");
        }
        return fullPath;
    }

    private static string ValidateAbsolutePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)
            || path.Length > 32_768
            || !Path.IsPathFullyQualified(path))
        {
            throw new InvalidDataException("The configuration path must be absolute.");
        }
        try
        {
            return Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new InvalidDataException("The configuration path is invalid.", exception);
        }
    }

    private static void EnsureNotLinkOrReparsePoint(string path, bool allowMissing)
    {
        var info = new FileInfo(path);
        bool exists;
        try
        {
            exists = info.Exists || info.LinkTarget is not null;
        }
        catch (IOException exception)
        {
            throw new InvalidDataException("The configuration path is unsafe.", exception);
        }
        if (!exists)
        {
            if (allowMissing) { return; }
            throw new InvalidDataException("The configuration file does not exist.");
        }
        if (IsLinkOrReparsePoint(info))
        {
            throw new InvalidDataException("Symbolic links are not accepted for configuration exchange.");
        }
    }

    private static bool IsLinkOrReparsePoint(FileSystemInfo info) =>
        info.LinkTarget is not null
        || (info.Attributes & FileAttributes.ReparsePoint) != 0;

    private static FileStream OpenPrivateTemporaryFile(string path)
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
        else
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream(Math.Min(maximumBytes, 64 * 1024));
        var buffer = new byte[Math.Min(maximumBytes + 1, 64 * 1024)];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) { break; }
            if (output.Length + read > maximumBytes)
            {
                throw new InvalidDataException("The imported configuration is too large.");
            }
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken)
                .ConfigureAwait(false);
        }
        return output.ToArray();
    }

    private sealed record ExportDocument(
        int FormatVersion,
        int SchemaVersion,
        GatewayDocument Gateway,
        ProviderDocument[] Providers,
        NodeDocument[] Nodes,
        PoolDocument[] CredentialPools,
        RouteDocument[] Routes,
        ProviderEndpointPathDocument[] ProviderEndpointPaths,
        ModelNodeAssignmentDocument[] ModelNodeAssignments);

    private sealed record ImportDocument(
        int FormatVersion,
        int SchemaVersion,
        GatewayDocument? Gateway,
        ProviderDocument?[]? Providers,
        NodeDocument?[]? Nodes,
        PoolDocument?[]? CredentialPools,
        RouteDocument?[]? Routes,
        ProviderEndpointPathDocument?[]? ProviderEndpointPaths,
        ModelNodeAssignmentDocument?[]? ModelNodeAssignments);

    private sealed record GatewayDocument(int Port);

    private sealed record ProviderDocument(
        Guid Id,
        string? DisplayName,
        string? BaseUri,
        bool IsEnabled,
        ProviderProtocol Protocol,
        ModelDocument?[]? Models);

    private sealed record ModelDocument(string? Id, string? DisplayName, string? Capability);

    private sealed record NodeDocument(
        Guid Id,
        string? Name,
        string? ProxyUri,
        bool IsSelected,
        string? SelectorGroup = null);

    private sealed record PoolDocument(
        Guid ProviderId,
        bool IsEnabled,
        Guid? ManualCredentialId,
        PoolEntryDocument?[]? Entries);

    private sealed record PoolEntryDocument(
        Guid Id,
        string? DisplayName,
        string? CredentialTarget,
        int Priority,
        bool RequiresReauthorization);

    private sealed record RouteDocument(
        string? Alias,
        bool IsEnabled,
        ModelRouteStrategy Strategy,
        RouteTargetDocument?[]? Targets);

    private sealed record RouteTargetDocument(
        Guid ProviderId,
        string? ModelId,
        int Priority,
        int Weight);

    private sealed record ProviderEndpointPathDocument(
        Guid ProviderId,
        GatewayEndpointKind Endpoint,
        string? Path,
        bool IsAsynchronous,
        string? PollPathTemplate,
        GatewayTaskIdentifierField TaskIdentifierField);

    private sealed record ModelNodeAssignmentDocument(
        Guid ProviderId,
        string? ModelId,
        Guid NodeId);
}
