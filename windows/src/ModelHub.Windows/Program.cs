using Avalonia;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Velopack;

namespace ModelHub.Windows;

internal static class Program
{
    private static readonly JsonSerializerOptions AcceptanceReceiptJsonOptions = new() { WriteIndented = true };

    [STAThread]
    public static void Main(string[] args)
    {
        // Updates are checked and staged only after an explicit user action. Never replace a running build silently.
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        if (TryRunAcceptanceProbe(args))
        {
            return;
        }
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    private static bool TryRunAcceptanceProbe(string[] args)
    {
        if (args.Length == 0 || !args[0].Equals("--acceptance-probe-output", StringComparison.Ordinal))
        {
            return false;
        }

        if (args.Length != 2 || !Path.IsPathFullyQualified(args[1]))
        {
            Environment.ExitCode = 64;
            return true;
        }

        var outputPath = Path.GetFullPath(args[1]);
        var outputRoot = Path.GetPathRoot(outputPath);
        var outputDirectory = Path.GetDirectoryName(outputPath);
        if (string.IsNullOrWhiteSpace(outputRoot)
            || string.IsNullOrWhiteSpace(outputDirectory)
            || string.Equals(outputPath, outputRoot, StringComparison.OrdinalIgnoreCase)
            || !Directory.Exists(outputDirectory)
            || File.Exists(outputPath))
        {
            Environment.ExitCode = 64;
            return true;
        }

        try
        {
            var assembly = Assembly.GetExecutingAssembly();
            var receipt = new
            {
                SchemaVersion = 1,
                Product = "ModelHub.Windows",
                Version = assembly.GetName().Version?.ToString(3) ?? string.Empty,
                FileVersion = assembly.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version ?? string.Empty,
                InformationalVersion = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? string.Empty,
                IsWindows = OperatingSystem.IsWindows(),
                OSDescription = RuntimeInformation.OSDescription,
                OSArchitecture = RuntimeInformation.OSArchitecture.ToString(),
                ProcessArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                Is64BitProcess = Environment.Is64BitProcess,
                CreatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
            };
            using var stream = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            JsonSerializer.Serialize(stream, receipt, AcceptanceReceiptJsonOptions);
            stream.Flush(flushToDisk: true);
            Environment.ExitCode = receipt.IsWindows && receipt.Is64BitProcess ? 0 : 1;
        }
        catch (IOException)
        {
            Environment.ExitCode = 74;
        }
        catch (UnauthorizedAccessException)
        {
            Environment.ExitCode = 77;
        }
        return true;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
