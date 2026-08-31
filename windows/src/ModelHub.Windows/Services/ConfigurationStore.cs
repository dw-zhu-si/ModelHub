using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Persists only non-secret configuration. API keys and gateway tokens stay in Credential Manager.</summary>
public sealed class ConfigurationStore
{
    private const int MaximumDisplayNameLength = 128;
    private const int MaximumModelIdLength = 256;
    private const int MaximumEndpointLength = 2048;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _directory;
    private readonly string _path;

    public ConfigurationStore(string? directory = null)
    {
        _directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ModelHub");
        _path = Path.Combine(_directory, "configuration.json");
    }

    public ModelHubConfiguration Load()
    {
        if (!File.Exists(_path))
        {
            return ModelHubConfiguration.Empty;
        }

        try
        {
            using var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var configuration = JsonSerializer.Deserialize<ModelHubConfiguration>(stream, JsonOptions);
            return IsSafe(configuration) ? configuration! : ModelHubConfiguration.Empty;
        }
        catch (JsonException)
        {
            return ModelHubConfiguration.Empty;
        }
        catch (IOException)
        {
            return ModelHubConfiguration.Empty;
        }
    }

    public void Save(ModelHubConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        if (!IsSafe(configuration))
        {
            throw new InvalidOperationException("Configuration contains an unsafe endpoint, port, or duplicate model ID.");
        }

        Directory.CreateDirectory(_directory);
        var temporaryPath = Path.Combine(_directory, $".{Path.GetRandomFileName()}.tmp");
        try
        {
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, configuration, JsonOptions);
                stream.Flush(flushToDisk: true);
            }

            if (OperatingSystem.IsWindows())
            {
                ApplyCurrentUserAcl(temporaryPath);
            }

            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    public static bool IsSafe(ModelHubConfiguration? configuration)
    {
        if (configuration is null
            || configuration.SchemaVersion != 1
            || configuration.Gateway is null
            || !configuration.Gateway.IsValid
            || !IsSafeMihomoSettings(configuration.Mihomo)
            || configuration.Providers is null
            || configuration.Nodes is null
            || configuration.Providers.Count > 64
            || configuration.Nodes.Count > 256)
        {
            return false;
        }

        var modelIds = new HashSet<string>(StringComparer.Ordinal);
        var providerIds = new HashSet<Guid>();
        foreach (var provider in configuration.Providers)
        {
            if (provider is null
                || provider.Id == Guid.Empty
                || !providerIds.Add(provider.Id)
                || string.IsNullOrWhiteSpace(provider.DisplayName)
                || provider.DisplayName.Length > MaximumDisplayNameLength
                || !Enum.IsDefined(provider.Protocol)
                || !IsSecureProviderEndpoint(provider.BaseUri)
                || provider.Models is null
                || provider.Models.Count > 1024)
            {
                return false;
            }
            foreach (var model in provider.Models)
            {
                if (model is null
                    || !model.IsValid
                    || !model.Id.Equals(model.Id.Trim(), StringComparison.Ordinal)
                    || model.Id.Any(char.IsControl)
                    || model.Id.Length > MaximumModelIdLength
                    || string.IsNullOrWhiteSpace(model.DisplayName)
                    || model.DisplayName.Length > MaximumDisplayNameLength
                    || model.Capability is null
                    || model.Capability.Length > 64
                    || !modelIds.Add(model.Id))
                {
                    return false;
                }
            }
        }

        var nodeIds = new HashSet<Guid>();
        if (!configuration.Nodes.All(node => node is not null
            && node.Id != Guid.Empty
            && nodeIds.Add(node.Id)
            && !string.IsNullOrWhiteSpace(node.Name)
            && node.Name.Length <= MaximumDisplayNameLength
            && !node.Name.Any(char.IsControl)
            && (node.SelectorGroup is null
                || !string.IsNullOrWhiteSpace(node.SelectorGroup)
                && node.SelectorGroup.Equals(node.SelectorGroup.Trim(), StringComparison.Ordinal)
                && node.SelectorGroup.Length <= MaximumDisplayNameLength
                && !node.SelectorGroup.Any(char.IsControl))
            && IsLocalProxyEndpoint(node.ProxyUri))
            || !CredentialPoolSelector.IsValid(
                configuration.CredentialPools ?? [],
                configuration.Providers))
        {
            return false;
        }

        var routes = configuration.Routes ?? [];
        if (routes.Count > 256
            || !AreRoutesSafe(routes, configuration, modelIds))
        {
            return false;
        }
        var endpoints = configuration.ProviderEndpointPaths ?? [];
        if (endpoints.Count > 1024
            || !AreProviderEndpointsSafe(endpoints, configuration.Providers))
        {
            return false;
        }
        var assignments = configuration.ModelNodeAssignments ?? [];
        return assignments.Count <= ModelNodeAssignmentService.MaximumAssignments
            && AreAssignmentsSafe(assignments, configuration.Providers, configuration.Nodes);
    }

    public static bool IsSafeMihomoSettings(MihomoSettings? settings)
    {
        if (settings is null)
        {
            return true;
        }

        return IsSafeAbsoluteLocalFilePath(settings.ExecutablePath)
            && IsSafeAbsoluteLocalFilePath(settings.ConfigurationPath)
            && settings.ControllerPort is >= 1024 and <= 65535
            && IsSafeSelectorGroup(settings.ProxyGroup);
    }

    public static bool IsSafeSelectorGroup(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Equals(value.Trim(), StringComparison.Ordinal)
        && value.Length <= MaximumDisplayNameLength
        && !value.Any(char.IsControl);

    private static bool IsSafeAbsoluteLocalFilePath(string value)
    {
        if (string.IsNullOrWhiteSpace(value)
            || !value.Equals(value.Trim(), StringComparison.Ordinal)
            || value.Length > MaximumEndpointLength
            || value.Any(char.IsControl)
            || value.Contains('"')
            || value.EndsWith('/')
            || value.EndsWith('\\')
            || value.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return false;
        }

        var isWindowsDrivePath = value.Length >= 3
            && char.IsAsciiLetter(value[0])
            && value[1] == ':'
            && value[2] is '\\' or '/';
        if (!isWindowsDrivePath && !Path.IsPathFullyQualified(value))
        {
            return false;
        }

        var segments = value.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.All(segment => segment is not "." and not "..");
    }

    private static bool AreRoutesSafe(
        IReadOnlyList<ModelRouteDefinition> routes,
        ModelHubConfiguration configuration,
        HashSet<string> realModelIds)
    {
        var aliases = new HashSet<string>(StringComparer.Ordinal);
        foreach (var route in routes)
        {
            if (route is null
                || !route.IsValid
                || !Enum.IsDefined(route.Strategy)
                || !aliases.Add(route.Alias)
                || realModelIds.Contains(route.Alias))
            {
                return false;
            }
            var targets = new HashSet<(Guid ProviderId, string ModelId)>();
            foreach (var target in route.Targets)
            {
                if (!targets.Add((target.ProviderId, target.ModelId)))
                {
                    return false;
                }
                var provider = configuration.Providers.SingleOrDefault(
                    candidate => candidate.Id == target.ProviderId);
                if (provider?.Models.Any(model =>
                    model.Id.Equals(target.ModelId, StringComparison.Ordinal)) != true)
                {
                    return false;
                }
            }
        }
        return true;
    }

    private static bool AreProviderEndpointsSafe(
        IReadOnlyList<ProviderEndpointPath> endpoints,
        IReadOnlyList<ProviderConfiguration> providers)
    {
        var keys = new HashSet<(Guid ProviderId, GatewayEndpointKind Endpoint)>();
        foreach (var endpoint in endpoints)
        {
            if (endpoint is null
                || !Enum.IsDefined(endpoint.Endpoint)
                || !Enum.IsDefined(endpoint.TaskIdentifierField)
                || providers.All(provider => provider.Id != endpoint.ProviderId)
                || !keys.Add((endpoint.ProviderId, endpoint.Endpoint))
                || !IsSafeEndpointPath(
                    endpoint.Path,
                    allowModelPlaceholder: endpoint.Endpoint is
                        GatewayEndpointKind.ChatCompletions or GatewayEndpointKind.Native))
            {
                return false;
            }

            if (endpoint.IsAsynchronous)
            {
                var provider = providers.Single(provider => provider.Id == endpoint.ProviderId);
                if (provider.Protocol != ProviderProtocol.OpenAICompatible
                    || endpoint.Endpoint is not (
                        GatewayEndpointKind.ImageGeneration
                        or GatewayEndpointKind.VideoGeneration
                        or GatewayEndpointKind.MusicGeneration)
                    || !IsSafeTaskPollPath(endpoint.PollPathTemplate))
                {
                    return false;
                }
            }
            else if (!string.IsNullOrEmpty(endpoint.PollPathTemplate)
                || endpoint.TaskIdentifierField != GatewayTaskIdentifierField.TaskId)
            {
                return false;
            }
        }
        return true;
    }

    private static bool AreAssignmentsSafe(
        IReadOnlyList<ModelNodeAssignment> assignments,
        IReadOnlyList<ProviderConfiguration> providers,
        IReadOnlyList<NodeConfiguration> nodes)
    {
        var keys = new HashSet<(Guid ProviderId, string ModelId)>();
        foreach (var assignment in assignments)
        {
            if (assignment is null
                || assignment.ProviderId == Guid.Empty
                || assignment.NodeId == Guid.Empty
                || string.IsNullOrWhiteSpace(assignment.ModelId)
                || assignment.ModelId.Length > MaximumModelIdLength
                || !assignment.ModelId.Equals(assignment.ModelId.Trim(), StringComparison.Ordinal)
                || assignment.ModelId.Any(char.IsControl)
                || !keys.Add((assignment.ProviderId, assignment.ModelId)))
            {
                return false;
            }
            var provider = providers.SingleOrDefault(
                candidate => candidate.Id == assignment.ProviderId);
            var node = nodes.SingleOrDefault(candidate => candidate.Id == assignment.NodeId);
            if (provider?.Models.Any(model =>
                    model.Id.Equals(assignment.ModelId, StringComparison.Ordinal)) != true
                || node is null
                || !ProxyHttpClientPool.IsSafeExplicitProxy(node.ProxyUri))
            {
                return false;
            }
        }
        return true;
    }

    internal static bool IsSafeEndpointPath(
        string? path,
        bool allowModelPlaceholder = false)
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
        var modelPlaceholders = path.Split("{model}", StringSplitOptions.None).Length - 1;
        if (modelPlaceholders > (allowModelPlaceholder ? 1 : 0))
        {
            return false;
        }
        var withoutModel = path.Replace("{model}", string.Empty, StringComparison.Ordinal);
        return !withoutModel.Contains('{') && !withoutModel.Contains('}');
    }

    internal static bool IsSafeTaskPollPath(string? path)
    {
        if (string.IsNullOrEmpty(path)) { return false; }
        var placeholders = path.Split("{task_id}", StringSplitOptions.None).Length - 1;
        return placeholders == 1
            && IsSafeEndpointPath(
                path.Replace("{task_id}", string.Empty, StringComparison.Ordinal));
    }

    public static bool IsSecureProviderEndpoint(Uri uri) =>
        uri.IsAbsoluteUri && uri.AbsoluteUri.Length <= MaximumEndpointLength && uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) && string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment);

    public static bool IsLocalProxyEndpoint(Uri uri) =>
        uri.IsAbsoluteUri && uri.AbsoluteUri.Length <= MaximumEndpointLength && uri.Scheme is "http" or "https" && string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment) && !string.IsNullOrWhiteSpace(uri.Host);

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserAcl(string path)
    {
        var security = new FileSecurity();
        var user = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("The current Windows user is unavailable.");
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}
