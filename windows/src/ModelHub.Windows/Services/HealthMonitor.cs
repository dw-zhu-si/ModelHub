using System.Collections.Concurrent;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public sealed class HealthMonitor
{
    private readonly ConcurrentDictionary<string, HealthSnapshot> _snapshots = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<ModelTargetKey, RouteTargetState> _modelStates = new();

    public IReadOnlyList<HealthSnapshot> Snapshot() => _snapshots.Values
        .OrderBy(snapshot => snapshot.Subject, StringComparer.Ordinal)
        .ToArray();

    public void RecordSuccess(string subject, TimeSpan latency, string detail = "在线验证") =>
        Record(subject, HealthState.Healthy, (int)Math.Ceiling(latency.TotalMilliseconds), detail);

    public void RecordFailure(string subject, string detail) =>
        Record(subject, HealthState.Failed, null, detail);

    public void RecordDegraded(string subject, string detail) =>
        Record(subject, HealthState.Degraded, null, detail);

    public void RecordModel(ModelHealthVerificationResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        var state = result.State switch
        {
            HealthState.Healthy => RouteTargetState.Available,
            HealthState.Failed when result.ShouldPermanentlyQuarantine => RouteTargetState.Unavailable,
            _ => RouteTargetState.Degraded,
        };
        _modelStates[new ModelTargetKey(result.Target.ProviderId, result.Target.ModelId)] = state;
    }

    public RouteTargetState RouteState(Guid providerId, string modelId) =>
        _modelStates.GetValueOrDefault(
            new ModelTargetKey(providerId, modelId),
            RouteTargetState.Available);

    private void Record(string subject, HealthState state, int? latency, string detail)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(subject);
        _snapshots[subject] = new HealthSnapshot(subject, state, DateTimeOffset.UtcNow, latency, detail);
    }

    private readonly record struct ModelTargetKey(Guid ProviderId, string ModelId);
}
