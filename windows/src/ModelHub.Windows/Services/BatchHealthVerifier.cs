using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public sealed record ModelHealthTarget(Guid ProviderId, string ModelId);

public enum ModelHealthOutcome
{
    Healthy,
    TransientFailure,
    RateLimited,
    AuthenticationFailure,
    PermanentModelFailure,
}

public sealed record ModelHealthObservation(
    ModelHealthOutcome Outcome,
    TimeSpan? Latency,
    string DetailCode);

public sealed record ModelHealthVerificationResult(
    ModelHealthTarget Target,
    HealthState State,
    int? LatencyMilliseconds,
    string DetailCode,
    bool ShouldPermanentlyQuarantine);

public interface IModelHealthProbe
{
    Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken);
}

/// <summary>
/// Executes a fixed number of workers instead of creating one task per model. Only explicit, permanent
/// model-level evidence can request quarantine; transport, quota, credential, and unknown failures remain retryable.
/// </summary>
public sealed class BatchHealthVerifier
{
    public const int MaximumTargets = 4096;
    public const int MaximumAllowedConcurrency = 32;
    private readonly IModelHealthProbe _probe;
    private readonly int _maximumConcurrency;

    public BatchHealthVerifier(IModelHealthProbe probe, int maximumConcurrency = 4)
    {
        _probe = probe ?? throw new ArgumentNullException(nameof(probe));
        if (maximumConcurrency is < 1 or > MaximumAllowedConcurrency)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumConcurrency),
                $"Concurrency must be between 1 and {MaximumAllowedConcurrency}.");
        }

        _maximumConcurrency = maximumConcurrency;
    }

    public async Task<IReadOnlyList<ModelHealthVerificationResult>> VerifyAsync(
        IReadOnlyList<ModelHealthTarget> targets,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(targets);
        if (targets.Count > MaximumTargets)
        {
            throw new ArgumentOutOfRangeException(nameof(targets), "The batch health target limit was exceeded.");
        }

        ValidateTargets(targets);
        if (targets.Count == 0)
        {
            return [];
        }

        var results = new ModelHealthVerificationResult[targets.Count];
        var nextIndex = -1;
        var workerCount = Math.Min(_maximumConcurrency, targets.Count);
        var workers = new Task[workerCount];
        for (var workerIndex = 0; workerIndex < workerCount; workerIndex++)
        {
            workers[workerIndex] = WorkerAsync();
        }

        await Task.WhenAll(workers).ConfigureAwait(false);
        return results;

        async Task WorkerAsync()
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var index = Interlocked.Increment(ref nextIndex);
                if (index >= targets.Count)
                {
                    return;
                }

                var target = targets[index];
                try
                {
                    var observation = await _probe.ProbeAsync(target, cancellationToken).ConfigureAwait(false);
                    results[index] = Map(target, observation);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception)
                {
                    results[index] = new ModelHealthVerificationResult(
                        target,
                        HealthState.Degraded,
                        null,
                        "probe_unavailable",
                        ShouldPermanentlyQuarantine: false);
                }
            }
        }
    }

    private static void ValidateTargets(IReadOnlyList<ModelHealthTarget> targets)
    {
        var unique = new HashSet<ModelTargetKey>();
        foreach (var target in targets)
        {
            if (target.ProviderId == Guid.Empty ||
                string.IsNullOrWhiteSpace(target.ModelId) ||
                target.ModelId.Length > 256 ||
                !target.ModelId.Equals(target.ModelId.Trim(), StringComparison.Ordinal) ||
                target.ModelId.Any(char.IsControl))
            {
                throw new ArgumentException("A batch health target is invalid.", nameof(targets));
            }

            if (!unique.Add(new ModelTargetKey(target.ProviderId, target.ModelId)))
            {
                throw new ArgumentException("A batch health target is duplicated.", nameof(targets));
            }
        }
    }

    private static ModelHealthVerificationResult Map(ModelHealthTarget target, ModelHealthObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        var latency = ToLatencyMilliseconds(observation.Latency);
        var detailCode = SanitizeDetailCode(observation.DetailCode);
        return observation.Outcome switch
        {
            ModelHealthOutcome.Healthy => new ModelHealthVerificationResult(
                target,
                HealthState.Healthy,
                latency,
                detailCode,
                ShouldPermanentlyQuarantine: false),
            ModelHealthOutcome.PermanentModelFailure => new ModelHealthVerificationResult(
                target,
                HealthState.Failed,
                null,
                detailCode,
                ShouldPermanentlyQuarantine: true),
            _ => new ModelHealthVerificationResult(
                target,
                HealthState.Degraded,
                null,
                detailCode,
                ShouldPermanentlyQuarantine: false),
        };
    }

    private static int? ToLatencyMilliseconds(TimeSpan? latency)
    {
        if (latency is null || latency.Value < TimeSpan.Zero || latency.Value.TotalMilliseconds > int.MaxValue)
        {
            return null;
        }

        return (int)Math.Ceiling(latency.Value.TotalMilliseconds);
    }

    private static string SanitizeDetailCode(string detailCode)
    {
        if (string.IsNullOrWhiteSpace(detailCode) ||
            detailCode.Length > 64 ||
            detailCode.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '_' or '-' or '.')))
        {
            return "probe_result";
        }

        return detailCode;
    }

    private readonly record struct ModelTargetKey(Guid ProviderId, string ModelId);
}
