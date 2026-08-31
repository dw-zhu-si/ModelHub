using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using ModelHub.Windows.Services;
using ModelHub.Windows.ViewModels;
using ModelHub.Windows.Views;

namespace ModelHub.Windows;

public sealed partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var vault = new WindowsCredentialVault();
            var configurationStore = new ConfigurationStore();
            var configuration = configurationStore.Load();
            var configurationState = new ConfigurationState(configuration);
            var mihomo = new MihomoRuntimeService();
            var health = new HealthMonitor();
            var gateway = new LocalGatewayService(
                configurationState.Snapshot,
                vault,
                mihomoRuntime: mihomo,
                routeState: health.RouteState);
            var nodes = new NodeLatencyTester();
            var updates = new WindowsUpdateCoordinator(new VelopackUpdateEngine(
                new Uri("https://github.com/dw-zhu-si/ModelHub/releases/latest/download/"),
                ["github.com"]));
            var viewModel = new MainWindowViewModel(configurationState, configurationStore, vault, gateway, health, nodes, updates, new SystemBrowserLauncher(),
                registration => new WindowsDeveloperOAuth(registration, vault),
                subscriptionClient: new BoundedHttpsProxySubscriptionClient(),
                mihomoRuntime: mihomo,
                batchHealthVerifier: new BatchHealthVerifier(new LoopbackGatewayHealthProbe(configurationState.Snapshot, vault), 4),
                configurationExchange: new ConfigurationImportExport());
            desktop.MainWindow = new MainWindow { DataContext = viewModel };
            desktop.Exit += async (_, _) =>
            {
                viewModel.Dispose();
                updates.Dispose();
                await gateway.DisposeAsync();
                await mihomo.DisposeAsync();
            };
        }

        base.OnFrameworkInitializationCompleted();
    }
}
