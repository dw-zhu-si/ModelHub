using Avalonia;
using Velopack;

namespace ModelHub.Windows;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // Updates are checked and staged only after an explicit user action. Never replace a running build silently.
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
