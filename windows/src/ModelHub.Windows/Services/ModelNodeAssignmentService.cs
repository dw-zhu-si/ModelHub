using System.Net;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public sealed record ModelNodeAssignment(Guid ProviderId, string ModelId, Guid NodeId);

public enum ModelNodeRouteKind
{
    Proxy,
    Blocked,
}

public sealed record ModelNodeRouteDecision(
    ModelNodeRouteKind Kind,
    Guid? NodeId,
    Uri? ProxyUri,
    string ErrorCode,
    string? SelectorGroup = null,
    string? NodeName = null)
{
    public static ModelNodeRouteDecision Blocked(string errorCode) =>
        new(ModelNodeRouteKind.Blocked, null, null, errorCode);
}

/// <summary>
/// Resolves only an exact provider UUID + ordinal model ID assignment. Every incomplete or unsafe state
/// returns Blocked; this service deliberately has no direct-connect or best-match result.
/// </summary>
public sealed class ModelNodeAssignmentService
{
    public const int MaximumAssignments = 4096;
    private readonly Dictionary<ModelAssignmentKey, Guid> _assignments;

    public ModelNodeAssignmentService(IEnumerable<ModelNodeAssignment> assignments)
    {
        ArgumentNullException.ThrowIfNull(assignments);
        var map = new Dictionary<ModelAssignmentKey, Guid>();
        foreach (var assignment in assignments)
        {
            if (map.Count >= MaximumAssignments)
            {
                throw new InvalidOperationException("The model-to-node assignment limit was exceeded.");
            }

            if (!IsValidIdentity(assignment.ProviderId, assignment.ModelId) || assignment.NodeId == Guid.Empty)
            {
                throw new ArgumentException("A model-to-node assignment is invalid.", nameof(assignments));
            }

            if (!map.TryAdd(new ModelAssignmentKey(assignment.ProviderId, assignment.ModelId), assignment.NodeId))
            {
                throw new ArgumentException("A model has more than one node assignment.", nameof(assignments));
            }
        }

        _assignments = map;
    }

    public ModelNodeRouteDecision Resolve(
        Guid providerId,
        string modelId,
        IReadOnlyCollection<NodeConfiguration> nodes,
        IMihomoRuntimeStatus runtime)
    {
        ArgumentNullException.ThrowIfNull(nodes);
        ArgumentNullException.ThrowIfNull(runtime);
        if (!IsValidIdentity(providerId, modelId))
        {
            return ModelNodeRouteDecision.Blocked("invalid_model_identity");
        }

        if (!_assignments.TryGetValue(new ModelAssignmentKey(providerId, modelId), out var nodeId))
        {
            return ModelNodeRouteDecision.Blocked("node_assignment_missing");
        }

        var matchingNodes = nodes.Where(node => node.Id == nodeId).Take(2).ToArray();
        if (matchingNodes.Length != 1)
        {
            return ModelNodeRouteDecision.Blocked("assigned_node_missing");
        }

        var node = matchingNodes[0];
        if (node.SelectorGroup is null && !node.IsSelected)
        {
            return ModelNodeRouteDecision.Blocked("assigned_node_disabled");
        }

        if (!IsSafeLoopbackProxy(node.ProxyUri))
        {
            return ModelNodeRouteDecision.Blocked("unsafe_proxy_endpoint");
        }

        if (!runtime.IsReady)
        {
            return ModelNodeRouteDecision.Blocked("mihomo_runtime_unavailable");
        }

        if (node.SelectorGroup is { } selectorGroup
            && (!IsSafeSelectorValue(selectorGroup) || !IsSafeSelectorValue(node.Name)))
        {
            return ModelNodeRouteDecision.Blocked("invalid_node_selector");
        }

        return new ModelNodeRouteDecision(
            ModelNodeRouteKind.Proxy,
            node.Id,
            node.ProxyUri,
            string.Empty,
            node.SelectorGroup,
            node.Name);
    }

    private static bool IsValidIdentity(Guid providerId, string modelId) =>
        providerId != Guid.Empty &&
        !string.IsNullOrWhiteSpace(modelId) &&
        modelId.Length <= 256 &&
        modelId.Equals(modelId.Trim(), StringComparison.Ordinal) &&
        !modelId.Any(char.IsControl);

    private static bool IsSafeSelectorValue(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Equals(value.Trim(), StringComparison.Ordinal)
        && value.Length <= 128
        && !value.Any(char.IsControl);

    private static bool IsSafeLoopbackProxy(Uri uri)
    {
        if (!uri.IsAbsoluteUri ||
            uri.Scheme is not ("http" or "https") ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            (uri.AbsolutePath.Length > 0 && uri.AbsolutePath != "/"))
        {
            return false;
        }

        var host = uri.Host.Length > 2 && uri.Host[0] == '[' && uri.Host[^1] == ']'
            ? uri.Host[1..^1]
            : uri.Host;
        if (!IPAddress.TryParse(host, out var address) ||
            !IPAddress.IsLoopback(address))
        {
            return false;
        }

        return uri.Port is >= 1 and <= 65535;
    }

    private readonly record struct ModelAssignmentKey(Guid ProviderId, string ModelId);
}
