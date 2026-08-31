using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Single process-wide configuration snapshot shared by UI and loopback gateway.</summary>
public sealed class ConfigurationState
{
    private readonly object _gate = new();
    private ModelHubConfiguration _configuration;

    public ConfigurationState(ModelHubConfiguration configuration) => _configuration = configuration;

    public ModelHubConfiguration Snapshot()
    {
        lock (_gate) { return _configuration; }
    }

    public void Replace(ModelHubConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        lock (_gate) { _configuration = configuration; }
    }
}
