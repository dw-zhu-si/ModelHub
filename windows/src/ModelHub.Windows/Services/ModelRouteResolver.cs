using System.Collections.Concurrent;
using System.Security.Cryptography;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public enum ModelRouteStrategy
{
    PriorityFailover,
    RoundRobin,
    WeightedRandom,
}

public enum RouteTargetState
{
    Available,
    Degraded,
    ConfigurationRequired,
    Unavailable,
}

public sealed record ModelRouteTarget(Guid ProviderId, string ModelId, int Priority = 0, int Weight = 1)
{
    public bool IsValid => ProviderId != Guid.Empty
        && !string.IsNullOrWhiteSpace(ModelId)
        && ModelId.Length <= 256
        && ModelId.Equals(ModelId.Trim(), StringComparison.Ordinal)
        && !ModelId.Any(char.IsControl)
        && Priority is >= 0 and <= 999
        && Weight is >= 1 and <= 10_000;
}

public sealed record ModelRouteDefinition(string Alias, bool IsEnabled, ModelRouteStrategy Strategy, IReadOnlyList<ModelRouteTarget> Targets)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(Alias)
        && Alias.Length <= 256
        && Alias.Equals(Alias.Trim(), StringComparison.Ordinal)
        && !Alias.Any(char.IsControl)
        && Enum.IsDefined(Strategy)
        && Targets is { Count: > 0 and <= 64 }
        && Targets.All(target => target is not null && target.IsValid)
        && Targets.Select(target => (target.ProviderId, target.ModelId)).Distinct().Count()
            == Targets.Count;
}

public sealed record ModelRouteResolution(string RequestedModel, ProviderConfiguration Provider, ModelDefinition Model, bool UsedAlias);

/// <summary>
/// Resolves direct model IDs and local aliases without changing provider health. Configuration/auth failures are never routed,
/// while degraded targets may remain eligible behind currently available targets.
/// </summary>
public sealed class ModelRouteResolver
{
    private readonly ConcurrentDictionary<string, long> _roundRobinCursors = new(StringComparer.Ordinal);
    private readonly Func<int, int> _randomIndex;

    public ModelRouteResolver(Func<int, int>? randomIndex = null)
    {
        _randomIndex = randomIndex ?? RandomNumberGenerator.GetInt32;
    }

    public ModelRouteResolution? Resolve(
        ModelHubConfiguration configuration,
        IReadOnlyList<ModelRouteDefinition> routes,
        string? requestedModel,
        Func<Guid, string, RouteTargetState>? state = null)
    {
        if (string.IsNullOrWhiteSpace(requestedModel))
        {
            return null;
        }

        var direct = ProviderCatalog.FindEnabledProvider(configuration, requestedModel);
        if (direct is not null)
        {
            var directModels = direct.Models.Where(model =>
                model.Id.Equals(requestedModel, StringComparison.Ordinal)).Take(2).ToArray();
            return directModels.Length == 1
                ? new ModelRouteResolution(
                    requestedModel,
                    direct,
                    directModels[0],
                    false)
                : null;
        }

        var matchingRoutes = routes.Where(candidate => candidate is not null
            && candidate.IsEnabled
            && candidate.Alias.Equals(requestedModel, StringComparison.Ordinal)).Take(2).ToArray();
        if (matchingRoutes.Length != 1 || !matchingRoutes[0].IsValid)
        {
            return null;
        }
        var route = matchingRoutes[0];

        state ??= static (_, _) => RouteTargetState.Available;
        var eligible = route.Targets
            .Select(target => ResolveTarget(configuration, target, state(target.ProviderId, target.ModelId)))
            .Where(candidate => candidate is not null)
            .Select(candidate => candidate!)
            .OrderBy(candidate => candidate.State == RouteTargetState.Available ? 0 : 1)
            .ThenBy(candidate => candidate.Target.Priority)
            .ThenBy(candidate => candidate.Target.ProviderId)
            .ThenBy(candidate => candidate.Target.ModelId, StringComparer.Ordinal)
            .ToArray();
        if (eligible.Length == 0)
        {
            return null;
        }

        var selected = route.Strategy switch
        {
            ModelRouteStrategy.PriorityFailover => eligible[0],
            ModelRouteStrategy.RoundRobin => SelectRoundRobin(route.Alias, eligible),
            ModelRouteStrategy.WeightedRandom => SelectWeighted(eligible),
            _ => eligible[0],
        };
        return new ModelRouteResolution(requestedModel, selected.Provider, selected.Model, true);
    }

    private static ResolvedTarget? ResolveTarget(ModelHubConfiguration configuration, ModelRouteTarget target, RouteTargetState state)
    {
        if (state is RouteTargetState.ConfigurationRequired or RouteTargetState.Unavailable)
        {
            return null;
        }
        var provider = configuration.Providers.SingleOrDefault(candidate => candidate.Id == target.ProviderId && candidate.IsEnabled);
        var model = provider?.Models.SingleOrDefault(candidate => candidate.Id.Equals(target.ModelId, StringComparison.Ordinal));
        return provider is null || model is null ? null : new ResolvedTarget(target, provider, model, state);
    }

    private ResolvedTarget SelectRoundRobin(string alias, ResolvedTarget[] eligible)
    {
        var cursor = _roundRobinCursors.AddOrUpdate(alias, 0, static (_, previous) => unchecked(previous + 1));
        return eligible[(int)((ulong)cursor % (ulong)eligible.Length)];
    }

    private ResolvedTarget SelectWeighted(ResolvedTarget[] eligible)
    {
        var available = eligible.Where(candidate => candidate.State == RouteTargetState.Available).ToArray();
        var candidates = available.Length > 0 ? available : eligible;
        var total = candidates.Sum(candidate => candidate.Target.Weight);
        var value = _randomIndex(total);
        if (value < 0 || value >= total)
        {
            throw new InvalidOperationException("The injected route random source returned an out-of-range value.");
        }
        foreach (var candidate in candidates)
        {
            if (value < candidate.Target.Weight)
            {
                return candidate;
            }
            value -= candidate.Target.Weight;
        }
        throw new InvalidOperationException("Weighted route selection failed safely.");
    }

    private sealed record ResolvedTarget(ModelRouteTarget Target, ProviderConfiguration Provider, ModelDefinition Model, RouteTargetState State);
}
