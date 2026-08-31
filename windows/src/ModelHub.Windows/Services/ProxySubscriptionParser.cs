using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ModelHub.Windows.Services;

/// <summary>
/// Parses the bounded, scalar node metadata subset shared by Clash and Mihomo JSON/YAML documents.
/// Credential-bearing fields are validated only as document structure and are deliberately discarded.
/// A caller that launches Mihomo must continue using the original user-owned configuration file.
/// </summary>
public static class ProxySubscriptionParser
{
    private const int MaximumDisplayNameLength = 128;
    private const int MaximumNodeNameLength = 128;
    private const int MaximumServerLength = 253;
    private const int MaximumScalarLength = 2048;
    private const int MaximumYamlLines = 100_000;
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly string[] SafeMetadataKeys =
    [
        "network",
        "cipher",
        "udp",
        "sni",
        "servername",
        "alpn",
        "client-fingerprint",
    ];

    public static ProxySubscriptionSnapshot Parse(
        ReadOnlyMemory<byte> payload,
        string displayName,
        DateTimeOffset importedAt)
    {
        ValidateEnvelope(payload, displayName);
        var first = FirstNonWhitespace(payload.Span);
        List<Dictionary<string, string>> rawNodes;
        if (first is (byte)'{' or (byte)'[')
        {
            rawNodes = ParseJson(payload);
        }
        else
        {
            rawNodes = ParseYaml(payload.Span);
        }

        if (rawNodes.Count == 0)
        {
            throw new ProxySubscriptionFormatException("The subscription does not contain any supported proxy nodes.");
        }

        if (rawNodes.Count > ProxySubscriptionPolicy.MaximumNodeCount)
        {
            throw new ProxySubscriptionLimitException("The subscription exceeds the maximum node count.");
        }

        var nodes = new List<ProxySubscriptionNode>(rawNodes.Count);
        var names = new HashSet<string>(StringComparer.Ordinal);
        var identifiers = new HashSet<Guid>();
        foreach (var rawNode in rawNodes)
        {
            var node = BuildNode(rawNode);
            if (!names.Add(node.Name) || !identifiers.Add(node.Id))
            {
                throw new ProxySubscriptionFormatException("The subscription contains duplicate proxy nodes.");
            }

            nodes.Add(node);
        }

        return new ProxySubscriptionSnapshot(displayName, nodes.AsReadOnly(), importedAt);
    }

    private static void ValidateEnvelope(ReadOnlyMemory<byte> payload, string displayName)
    {
        ArgumentNullException.ThrowIfNull(displayName);
        if (payload.IsEmpty)
        {
            throw new ProxySubscriptionFormatException("The subscription payload is empty.");
        }

        if (payload.Length > ProxySubscriptionPolicy.MaximumPayloadBytes)
        {
            throw new ProxySubscriptionLimitException("The subscription exceeds the 4 MiB payload limit.");
        }

        if (string.IsNullOrWhiteSpace(displayName) ||
            displayName.Length > MaximumDisplayNameLength ||
            displayName.Any(char.IsControl))
        {
            throw new ProxySubscriptionFormatException("The subscription display name is invalid.");
        }
    }

    private static List<Dictionary<string, string>> ParseJson(ReadOnlyMemory<byte> payload)
    {
        try
        {
            using var document = JsonDocument.Parse(payload, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 32,
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !TryGetUniqueProperty(document.RootElement, "proxies", out var proxies) ||
                proxies.ValueKind != JsonValueKind.Array)
            {
                throw new ProxySubscriptionFormatException("The JSON subscription must contain a proxies array.");
            }

            if (proxies.GetArrayLength() > ProxySubscriptionPolicy.MaximumNodeCount)
            {
                throw new ProxySubscriptionLimitException("The subscription exceeds the maximum node count.");
            }

            var nodes = new List<Dictionary<string, string>>(proxies.GetArrayLength());
            foreach (var element in proxies.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object)
                {
                    throw new ProxySubscriptionFormatException("Each proxy node must be an object.");
                }

                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var property in element.EnumerateObject())
                {
                    if (property.Value.ValueKind is not (JsonValueKind.String or JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False))
                    {
                        continue;
                    }

                    if (!values.TryAdd(property.Name, ScalarText(property.Value)))
                    {
                        throw new ProxySubscriptionFormatException("A proxy node contains a duplicate field.");
                    }
                }

                nodes.Add(values);
            }

            return nodes;
        }
        catch (JsonException)
        {
            throw new ProxySubscriptionFormatException("The JSON subscription is malformed.");
        }
    }

    private static List<Dictionary<string, string>> ParseYaml(ReadOnlySpan<byte> payload)
    {
        string text;
        try
        {
            text = StrictUtf8.GetString(payload);
        }
        catch (DecoderFallbackException)
        {
            throw new ProxySubscriptionFormatException("The YAML subscription is not valid UTF-8.");
        }

        if (text.Contains('\0') || text.Contains('\t', StringComparison.Ordinal))
        {
            throw new ProxySubscriptionFormatException("The YAML subscription contains unsupported control characters.");
        }

        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
        if (lines.Length > MaximumYamlLines)
        {
            throw new ProxySubscriptionLimitException("The YAML subscription contains too many lines.");
        }

        var nodes = new List<Dictionary<string, string>>();
        Dictionary<string, string>? current = null;
        var inProxies = false;
        var proxiesIndent = -1;
        var itemIndent = -1;

        foreach (var originalLine in lines)
        {
            var uncommented = StripYamlComment(originalLine);
            if (string.IsNullOrWhiteSpace(uncommented))
            {
                continue;
            }

            var indent = CountLeadingSpaces(uncommented);
            var trimmed = uncommented.AsSpan(indent).TrimEnd().ToString();
            if (!inProxies)
            {
                if (trimmed.Equals("proxies:", StringComparison.Ordinal) && indent == 0)
                {
                    inProxies = true;
                    proxiesIndent = indent;
                }

                continue;
            }

            if (indent <= proxiesIndent)
            {
                CommitCurrent(nodes, ref current);
                break;
            }

            if (trimmed.StartsWith("- ", StringComparison.Ordinal) &&
                (itemIndent < 0 || indent == itemIndent))
            {
                CommitCurrent(nodes, ref current);
                if (nodes.Count >= ProxySubscriptionPolicy.MaximumNodeCount)
                {
                    throw new ProxySubscriptionLimitException("The subscription exceeds the maximum node count.");
                }

                itemIndent = indent;
                current = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var firstField = trimmed[2..].Trim();
                if (firstField.StartsWith('{') || firstField.StartsWith('['))
                {
                    throw new ProxySubscriptionFormatException("Flow-style YAML proxy nodes are not supported.");
                }

                AddYamlField(current, firstField);
                continue;
            }

            if (current is not null && indent > itemIndent && !trimmed.StartsWith("- ", StringComparison.Ordinal))
            {
                AddYamlField(current, trimmed);
            }
        }

        CommitCurrent(nodes, ref current);
        return nodes;
    }

    private static void CommitCurrent(
        List<Dictionary<string, string>> nodes,
        ref Dictionary<string, string>? current)
    {
        if (current is not null)
        {
            nodes.Add(current);
            current = null;
        }
    }

    private static void AddYamlField(IDictionary<string, string> values, string field)
    {
        if (string.IsNullOrWhiteSpace(field))
        {
            return;
        }

        var separator = FindYamlSeparator(field);
        if (separator <= 0)
        {
            return;
        }

        var key = field[..separator].Trim();
        var rawValue = field[(separator + 1)..].Trim();
        if (rawValue.Length == 0)
        {
            return;
        }

        if (key.Length > 64 || key.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_')))
        {
            throw new ProxySubscriptionFormatException("A YAML proxy field name is invalid.");
        }

        var value = ParseYamlScalar(rawValue);
        if (!values.TryAdd(key, value))
        {
            throw new ProxySubscriptionFormatException("A proxy node contains a duplicate field.");
        }
    }

    private static ProxySubscriptionNode BuildNode(Dictionary<string, string> values)
    {
        var name = Required(values, "name");
        var type = Required(values, "type");
        var server = Required(values, "server");
        var portText = Required(values, "port");

        if (name.Length > MaximumNodeNameLength || name.Any(char.IsControl))
        {
            throw new ProxySubscriptionFormatException("A proxy node name is invalid.");
        }

        if (!TryMapProtocol(type, out var protocol))
        {
            throw new ProxySubscriptionFormatException("A proxy node uses an unsupported protocol.");
        }

        if (!IsSafeServer(server))
        {
            throw new ProxySubscriptionFormatException("A proxy node server is invalid.");
        }

        if (!int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
        {
            throw new ProxySubscriptionFormatException("A proxy node port is invalid.");
        }

        var tls = values.TryGetValue("tls", out var tlsValue) && ParseBoolean(tlsValue);
        var metadata = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var key in SafeMetadataKeys)
        {
            if (values.TryGetValue(key, out var value) && value.Length <= 256)
            {
                metadata[key] = value;
            }
        }

        return new ProxySubscriptionNode(
            DeterministicIdentifier(name, protocol, server, port),
            name,
            protocol,
            server,
            port,
            tls,
            metadata);
    }

    private static bool TryGetUniqueProperty(JsonElement element, string name, out JsonElement value)
    {
        var found = false;
        value = default;
        foreach (var property in element.EnumerateObject())
        {
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                if (found)
                {
                    throw new ProxySubscriptionFormatException("The JSON subscription contains a duplicate proxies field.");
                }

                value = property.Value;
                found = true;
            }
        }

        return found;
    }

    private static string ScalarText(JsonElement element)
    {
        var value = element.ValueKind == JsonValueKind.String ? element.GetString() : element.GetRawText();
        if (value is null || value.Length > MaximumScalarLength || value.Any(char.IsControl))
        {
            throw new ProxySubscriptionFormatException("A proxy node scalar value is invalid.");
        }

        return value;
    }

    private static string Required(Dictionary<string, string> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
        {
            throw new ProxySubscriptionFormatException("A proxy node is missing a required field.");
        }

        return value;
    }

    private static bool IsSafeServer(string server)
    {
        if (server.Length is 0 or > MaximumServerLength ||
            server.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)) ||
            server.IndexOfAny(['/', '\\', '@', '?', '#']) >= 0 ||
            server.Contains("://", StringComparison.Ordinal))
        {
            return false;
        }

        var candidate = server.Length > 2 && server[0] == '[' && server[^1] == ']'
            ? server[1..^1]
            : server;
        return IPAddress.TryParse(candidate, out _) || Uri.CheckHostName(candidate) == UriHostNameType.Dns;
    }

    private static bool TryMapProtocol(string value, out ProxyNodeProtocol protocol)
    {
        protocol = value.ToLowerInvariant() switch
        {
            "http" => ProxyNodeProtocol.Http,
            "socks5" or "socks" => ProxyNodeProtocol.Socks5,
            "ss" => ProxyNodeProtocol.Shadowsocks,
            "ssr" => ProxyNodeProtocol.ShadowsocksR,
            "vmess" => ProxyNodeProtocol.Vmess,
            "vless" => ProxyNodeProtocol.Vless,
            "trojan" => ProxyNodeProtocol.Trojan,
            "hysteria" => ProxyNodeProtocol.Hysteria,
            "hysteria2" or "hysteria-2" => ProxyNodeProtocol.Hysteria2,
            "tuic" => ProxyNodeProtocol.Tuic,
            "wireguard" => ProxyNodeProtocol.WireGuard,
            "snell" => ProxyNodeProtocol.Snell,
            "ssh" => ProxyNodeProtocol.Ssh,
            _ => default,
        };
        return value.Equals("http", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("socks5", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("socks", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("ss", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("ssr", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("vmess", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("vless", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("trojan", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("hysteria", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("hysteria2", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("hysteria-2", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("tuic", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("wireguard", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("snell", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("ssh", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ParseBoolean(string value) => value.Equals("true", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("yes", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("on", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("1", StringComparison.Ordinal);

    private static Guid DeterministicIdentifier(string name, ProxyNodeProtocol protocol, string server, int port)
    {
        var canonical = $"{name}\n{protocol}\n{server.ToLowerInvariant()}\n{port.ToString(CultureInfo.InvariantCulture)}";
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(Encoding.UTF8.GetBytes(canonical), hash);
        return new Guid(hash[..16]);
    }

    private static byte FirstNonWhitespace(ReadOnlySpan<byte> payload)
    {
        foreach (var value in payload)
        {
            if (value is not ((byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n'))
            {
                return value;
            }
        }

        throw new ProxySubscriptionFormatException("The subscription payload is empty.");
    }

    private static int CountLeadingSpaces(string value)
    {
        var index = 0;
        while (index < value.Length && value[index] == ' ')
        {
            index++;
        }

        return index;
    }

    private static int FindYamlSeparator(string value)
    {
        var singleQuoted = false;
        var doubleQuoted = false;
        var escaped = false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (doubleQuoted && character == '\\' && !escaped)
            {
                escaped = true;
                continue;
            }

            if (character == '\'' && !doubleQuoted)
            {
                singleQuoted = !singleQuoted;
            }
            else if (character == '"' && !singleQuoted && !escaped)
            {
                doubleQuoted = !doubleQuoted;
            }
            else if (character == ':' && !singleQuoted && !doubleQuoted)
            {
                return index;
            }

            escaped = false;
        }

        return -1;
    }

    private static string StripYamlComment(string value)
    {
        var singleQuoted = false;
        var doubleQuoted = false;
        var escaped = false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (doubleQuoted && character == '\\' && !escaped)
            {
                escaped = true;
                continue;
            }

            if (character == '\'' && !doubleQuoted)
            {
                singleQuoted = !singleQuoted;
            }
            else if (character == '"' && !singleQuoted && !escaped)
            {
                doubleQuoted = !doubleQuoted;
            }
            else if (character == '#' && !singleQuoted && !doubleQuoted &&
                (index == 0 || char.IsWhiteSpace(value[index - 1])))
            {
                return value[..index];
            }

            escaped = false;
        }

        return value;
    }

    private static string ParseYamlScalar(string value)
    {
        if (value.Length > MaximumScalarLength || value.StartsWith('&') || value.StartsWith('*') || value.StartsWith('!'))
        {
            throw new ProxySubscriptionFormatException("A YAML proxy scalar is invalid.");
        }

        string parsed;
        if (value.StartsWith('"'))
        {
            if (!value.EndsWith('"'))
            {
                throw new ProxySubscriptionFormatException("A YAML proxy scalar is malformed.");
            }

            try
            {
                parsed = JsonSerializer.Deserialize<string>(value) ?? string.Empty;
            }
            catch (JsonException)
            {
                throw new ProxySubscriptionFormatException("A YAML proxy scalar is malformed.");
            }
        }
        else if (value.StartsWith('\''))
        {
            if (!value.EndsWith('\''))
            {
                throw new ProxySubscriptionFormatException("A YAML proxy scalar is malformed.");
            }

            parsed = value[1..^1].Replace("''", "'", StringComparison.Ordinal);
        }
        else
        {
            parsed = value;
        }

        if (parsed.Length > MaximumScalarLength || parsed.Any(char.IsControl))
        {
            throw new ProxySubscriptionFormatException("A YAML proxy scalar is invalid.");
        }

        return parsed;
    }
}
