using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Chooses a developer-owned credential manually or only after irreversible credential evidence. It never automates consumer OAuth or quota rotation.</summary>
public static class CredentialPoolSelector
{
    public static CredentialPoolEntry? Select(CredentialPoolConfiguration? pool) =>
        pool is not { IsEnabled: true }
            ? null
            : pool.ManualCredentialId is { } selected
                ? pool.Entries.SingleOrDefault(entry => entry.Id == selected && !entry.RequiresReauthorization)
                : pool.Entries.Where(entry => !entry.RequiresReauthorization).OrderBy(entry => entry.Priority).ThenBy(entry => entry.Id).FirstOrDefault();

    public static CredentialPoolEntry? SelectAfterFailure(CredentialPoolConfiguration pool, Guid currentCredentialId, CredentialFailureEvidence evidence) =>
        evidence != CredentialFailureEvidence.InvalidGrantOrRevoked
            ? null
            : pool.Entries.Where(entry => entry.Id != currentCredentialId && !entry.RequiresReauthorization)
                .OrderBy(entry => entry.Priority).ThenBy(entry => entry.Id).FirstOrDefault();

    public static bool IsValid(IReadOnlyList<CredentialPoolConfiguration>? pools, IReadOnlyList<ProviderConfiguration> providers)
    {
        if (pools is null || pools.Count > 64)
        {
            return pools is not null;
        }
        var providerIds = providers.Select(provider => provider.Id).ToHashSet();
        var entries = new HashSet<Guid>();
        return pools.All(pool => providerIds.Contains(pool.ProviderId) && pool.Entries.Count <= 32 &&
            (pool.ManualCredentialId is null || pool.Entries.Any(entry => entry.Id == pool.ManualCredentialId)) &&
            pool.Entries.All(entry => entry.IsValid && entries.Add(entry.Id)));
    }
}
