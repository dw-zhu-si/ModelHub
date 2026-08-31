using System.Collections.ObjectModel;

namespace ModelHub.Windows.Services;

/// <summary>
/// Non-secret node metadata extracted from a Clash/Mihomo subscription. Subscription source URLs and
/// proxy credentials are intentionally excluded so this value can be persisted by a future UI safely.
/// </summary>
public sealed class ProxySubscriptionNode
{
    public ProxySubscriptionNode(
        Guid id,
        string name,
        ProxyNodeProtocol protocol,
        string server,
        int port,
        bool usesTls,
        IReadOnlyDictionary<string, string>? metadata = null)
    {
        Id = id;
        Name = name;
        Protocol = protocol;
        Server = server;
        Port = port;
        UsesTls = usesTls;
        Metadata = new ReadOnlyDictionary<string, string>(
            new Dictionary<string, string>(metadata ?? new Dictionary<string, string>(), StringComparer.Ordinal));
    }

    public Guid Id { get; }
    public string Name { get; }
    public ProxyNodeProtocol Protocol { get; }
    public string Server { get; }
    public int Port { get; }
    public bool UsesTls { get; }
    public IReadOnlyDictionary<string, string> Metadata { get; }

    public override string ToString() => $"{Name} ({Protocol}, {Server}:{Port})";
}

public sealed record ProxySubscriptionSnapshot(
    string DisplayName,
    IReadOnlyList<ProxySubscriptionNode> Nodes,
    DateTimeOffset ImportedAt);

public enum ProxyNodeProtocol
{
    Http,
    Socks5,
    Shadowsocks,
    ShadowsocksR,
    Vmess,
    Vless,
    Trojan,
    Hysteria,
    Hysteria2,
    Tuic,
    WireGuard,
    Snell,
    Ssh,
}

public static class ProxySubscriptionPolicy
{
    public const int MaximumPayloadBytes = 4 * 1024 * 1024;
    public const int MaximumNodeCount = 1024;
    private const int MaximumSourceUrlLength = 4096;

    public static void ValidateSourceUri(Uri source)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (!source.IsAbsoluteUri ||
            source.AbsoluteUri.Length > MaximumSourceUrlLength ||
            !source.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(source.Host) ||
            !string.IsNullOrEmpty(source.UserInfo) ||
            !string.IsNullOrEmpty(source.Fragment))
        {
            throw new ProxySubscriptionSecurityException("Subscription sources must use a credential-free HTTPS URL.");
        }
    }

    public static bool IsSameOriginRedirect(Uri source, Uri redirect)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(redirect);

        try
        {
            ValidateSourceUri(source);
            ValidateSourceUri(redirect);
        }
        catch (ProxySubscriptionSecurityException)
        {
            return false;
        }

        return source.Scheme.Equals(redirect.Scheme, StringComparison.OrdinalIgnoreCase) &&
            source.IdnHost.Equals(redirect.IdnHost, StringComparison.OrdinalIgnoreCase) &&
            EffectivePort(source) == EffectivePort(redirect);
    }

    private static int EffectivePort(Uri uri) => uri.IsDefaultPort ? 443 : uri.Port;
}

public sealed class ProxySubscriptionSecurityException : InvalidOperationException
{
    public ProxySubscriptionSecurityException()
    {
    }

    public ProxySubscriptionSecurityException(string message)
        : base(message)
    {
    }

    public ProxySubscriptionSecurityException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ProxySubscriptionLimitException : InvalidOperationException
{
    public ProxySubscriptionLimitException()
    {
    }

    public ProxySubscriptionLimitException(string message)
        : base(message)
    {
    }

    public ProxySubscriptionLimitException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ProxySubscriptionFormatException : InvalidOperationException
{
    public ProxySubscriptionFormatException()
    {
    }

    public ProxySubscriptionFormatException(string message)
        : base(message)
    {
    }

    public ProxySubscriptionFormatException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
