using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

public static class ProviderCatalog
{
    public static IReadOnlyList<(ProviderConfiguration Provider, ModelDefinition Model)> Models(ModelHubConfiguration configuration) =>
        configuration.Providers
            .Where(provider => provider.IsEnabled)
            .SelectMany(provider => provider.Models.Select(model => (provider, model)))
            .OrderBy(entry => entry.model.Id, StringComparer.Ordinal)
            .ToArray();

    public static ProviderConfiguration? FindEnabledProvider(ModelHubConfiguration configuration, string? modelId) =>
        string.IsNullOrWhiteSpace(modelId)
            ? null
            : configuration.Providers.FirstOrDefault(provider => provider.IsEnabled && provider.Models.Any(model => model.Id.Equals(modelId, StringComparison.Ordinal)));
}
