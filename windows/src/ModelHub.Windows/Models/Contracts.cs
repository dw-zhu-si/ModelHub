using ModelHub.Windows.Services;

namespace ModelHub.Windows.Models;

public sealed record ModelHubConfiguration(
    int SchemaVersion,
    GatewaySettings Gateway,
    IReadOnlyList<ProviderConfiguration> Providers,
    IReadOnlyList<NodeConfiguration> Nodes,
    IReadOnlyList<CredentialPoolConfiguration>? CredentialPools = null,
    IReadOnlyList<ModelRouteDefinition>? Routes = null,
    IReadOnlyList<ProviderEndpointPath>? ProviderEndpointPaths = null,
    IReadOnlyList<ModelNodeAssignment>? ModelNodeAssignments = null,
    MihomoSettings? Mihomo = null)
{
    public static ModelHubConfiguration Empty { get; } = new(
        SchemaVersion: 1,
        Gateway: new GatewaySettings(11435, GatewaySettings.DefaultCredentialTarget),
        Providers: [],
        Nodes: [],
        CredentialPools: [],
        Routes: [],
        ProviderEndpointPaths: [],
        ModelNodeAssignments: [],
        Mihomo: null);
}

/// <summary>
/// Non-secret, user-selected Mihomo runtime metadata. The Controller authorization
/// token is deliberately represented only by a fixed Credential Manager target and
/// is never a configuration member.
/// </summary>
public sealed record MihomoSettings(
    string ExecutablePath,
    string ConfigurationPath,
    int ControllerPort,
    string ProxyGroup)
{
    public const string ControllerSecretCredentialTarget =
        "ModelHub.Windows/Mihomo/ControllerAuthorizationToken";
}

public sealed record GatewaySettings(int Port, string TokenCredentialTarget)
{
    public const string DefaultCredentialTarget = "ModelHub.Windows/GatewayToken";

    public bool IsValid => Port is >= 1024 and <= 65535 && !string.IsNullOrWhiteSpace(TokenCredentialTarget);
}

public sealed record ProviderConfiguration(
    Guid Id,
    string DisplayName,
    Uri BaseUri,
    bool IsEnabled,
    IReadOnlyList<ModelDefinition> Models,
    ProviderProtocol Protocol = ProviderProtocol.OpenAICompatible)
{
    public string CredentialTarget => $"ModelHub.Windows/Provider/{Id:N}";
}

public enum ProviderProtocol
{
    OpenAICompatible,
    Anthropic,
    Gemini,
}

public enum GatewayEndpointKind
{
    ChatCompletions,
    Responses,
    Native,
    ImageGeneration,
    ImageEdit,
    VideoGeneration,
    MusicGeneration,
    AudioSpeech,
    AudioTranscription,
    Embeddings,
    Rerank,
}

public enum GatewayTaskIdentifierField
{
    TaskId,
    DataTaskId,
    OutputTaskId,
}

/// <summary>
/// Non-secret protocol metadata for one provider endpoint. Paths are validated
/// as same-origin root-relative paths before persistence or use.
/// </summary>
public sealed record ProviderEndpointPath(
    Guid ProviderId,
    GatewayEndpointKind Endpoint,
    string Path,
    bool IsAsynchronous = false,
    string? PollPathTemplate = null,
    GatewayTaskIdentifierField TaskIdentifierField = GatewayTaskIdentifierField.TaskId);

public enum DeveloperOAuthProvider
{
    GoogleGemini,
}

/// <summary>Developer-owned OAuth application metadata only. Consumer subscription accounts are deliberately unsupported.</summary>
public sealed record DeveloperOAuthRegistration(
    DeveloperOAuthProvider Provider,
    string ClientId,
    Uri RedirectUri,
    IReadOnlyList<string> Scopes,
    Guid CredentialId)
{
    public string CredentialTarget => $"ModelHub.Windows/OAuth/{Provider}/{CredentialId:N}";
}

public sealed record ModelDefinition(string Id, string DisplayName, string Capability)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(Id) && Id.Length <= 256;
}

public sealed record NodeConfiguration(
    Guid Id,
    string Name,
    Uri ProxyUri,
    bool IsSelected,
    string? SelectorGroup = null);

public sealed record HealthSnapshot(
    string Subject,
    HealthState State,
    DateTimeOffset ObservedAt,
    int? LatencyMilliseconds,
    string Detail);

public enum HealthState
{
    Unknown,
    Healthy,
    Degraded,
    Failed,
}

public sealed record NodeLatencyResult(Guid NodeId, DateTimeOffset TestedAt, int? LatencyMilliseconds, string Status, string Detail);

/// <summary>Metadata only. OAuth/browser automation, subscription account capture, and quota rotation are intentionally out of scope.</summary>
public sealed record CredentialPoolConfiguration(Guid ProviderId, bool IsEnabled, Guid? ManualCredentialId, IReadOnlyList<CredentialPoolEntry> Entries);

public sealed record CredentialPoolEntry(Guid Id, string DisplayName, string CredentialTarget, int Priority, bool RequiresReauthorization)
{
    public const int MaximumPriority = 999;

    public bool IsValid => Id != Guid.Empty && !string.IsNullOrWhiteSpace(DisplayName) && CredentialTarget.StartsWith("ModelHub.Windows/Pool/", StringComparison.Ordinal) && Priority is >= 0 and <= MaximumPriority;
}

public enum CredentialFailureEvidence
{
    TransientNetwork,
    RateLimited,
    AccessDenied,
    InvalidGrantOrRevoked,
}

public sealed record MediaArtifact(string Kind, Uri? RemoteUrl, string? LocalPath, long ByteCount)
{
    public bool IsUsable => ByteCount > 0 && (RemoteUrl is { Scheme: "https" } || !string.IsNullOrWhiteSpace(LocalPath));
}

public enum MediaTaskState { Pending, Running, Succeeded, Failed, Cancelled }

public sealed record MediaTaskSnapshot(Guid Id, string Endpoint, string Model, MediaTaskState State, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, MediaArtifact? Artifact, string? ErrorCode);

public sealed record UsageLedgerEntry(Guid Id, DateTimeOffset Timestamp, string Endpoint, string? Model, string? Provider, int StatusCode, int RequestBytes, long ResponseBytes, Guid? MediaTaskId);

public sealed record UsageLedgerPage(IReadOnlyList<UsageLedgerEntry> Entries, string? NextCursor);
