using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Converts the local OpenAI chat contract to supported upstream text protocols without putting credentials in URLs.</summary>
public static class ProviderProtocolAdapter
{
    private const int DefaultMaxTokens = 1024;

    public static HttpRequestMessage CreateChatRequest(ProviderConfiguration provider, ReadOnlySpan<byte> openAiBody, string credential, bool stream)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(credential);
        using var document = JsonDocument.Parse(openAiBody.ToArray());
        var model = RequiredString(document.RootElement, "model");
        if (provider.Protocol is ProviderProtocol.Anthropic or ProviderProtocol.Gemini)
        {
            RejectUnsupportedOpenAiSemantics(document.RootElement);
        }
        byte[] body;
        Uri endpoint;
        var request = provider.Protocol switch
        {
            ProviderProtocol.OpenAICompatible => CreateOpenAi(provider, openAiBody, credential, out endpoint, out body),
            ProviderProtocol.Anthropic => CreateAnthropic(provider, document.RootElement, credential, stream, out endpoint, out body),
            ProviderProtocol.Gemini => CreateGemini(provider, document.RootElement, credential, stream, model, out endpoint, out body),
            _ => throw new NotSupportedException("The provider protocol is not supported."),
        };
        request.RequestUri = endpoint;
        request.Content = new ByteArrayContent(body);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.TryAddWithoutValidation("X-ModelHub-Request-ID", Guid.NewGuid().ToString("N"));
        return request;
    }

    public static bool IsExpectedStreamingContentType(ProviderProtocol protocol, string contentType) =>
        protocol switch
        {
            ProviderProtocol.OpenAICompatible or ProviderProtocol.Anthropic or ProviderProtocol.Gemini => contentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase),
            _ => false,
        };

    public static byte[] NormalizeNonStreamingResponse(ProviderProtocol protocol, ReadOnlySpan<byte> upstreamBody)
    {
        if (protocol == ProviderProtocol.OpenAICompatible) { return upstreamBody.ToArray(); }
        using var document = JsonDocument.Parse(upstreamBody.ToArray());
        return protocol switch
        {
            ProviderProtocol.Anthropic => NormalizeAnthropicResponse(document.RootElement),
            ProviderProtocol.Gemini => NormalizeGeminiResponse(document.RootElement),
            _ => throw new NotSupportedException("The provider protocol is not supported."),
        };
    }

    /// <summary>Normalizes exactly one complete SSE event. Callers must frame events and enforce byte/time limits.</summary>
    public static byte[] NormalizeStreamingEvent(ProviderProtocol protocol, ReadOnlySpan<byte> eventBytes)
    {
        if (protocol == ProviderProtocol.OpenAICompatible) { return eventBytes.ToArray(); }
        var eventText = Encoding.UTF8.GetString(eventBytes);
        var data = eventText.Split('\n').FirstOrDefault(line => line.StartsWith("data:", StringComparison.Ordinal))?[5..].Trim();
        if (string.IsNullOrWhiteSpace(data)) { return []; }
        if (data == "[DONE]") { return "data: [DONE]\n\n"u8.ToArray(); }
        using var document = JsonDocument.Parse(data);
        string? text = null;
        string? finishReason = null;
        if (protocol == ProviderProtocol.Anthropic)
        {
            var root = document.RootElement;
            if (root.TryGetProperty("delta", out var delta) && delta.TryGetProperty("text", out var textElement)) { text = textElement.GetString(); }
            if (root.TryGetProperty("type", out var type) && type.GetString() == "message_stop") { finishReason = "stop"; }
        }
        else if (protocol == ProviderProtocol.Gemini)
        {
            var candidate = document.RootElement.TryGetProperty("candidates", out var candidates) && candidates.GetArrayLength() > 0 ? candidates[0] : default;
            text = ReadParts(candidate);
            if (candidate.ValueKind == JsonValueKind.Object && candidate.TryGetProperty("finishReason", out var finish)) { finishReason = MapFinishReason(finish.GetString()); }
        }
        if (text is null && finishReason is null) { return []; }
        var chunk = new
        {
            id = "modelhub-protocol-chunk",
            @object = "chat.completion.chunk",
            choices = new[] { new { index = 0, delta = new { content = text }, finish_reason = finishReason } },
        };
        var terminator = finishReason is null ? string.Empty : "data: [DONE]\n\n";
        return Encoding.UTF8.GetBytes($"data: {JsonSerializer.Serialize(chunk)}\n\n{terminator}");
    }

    private static HttpRequestMessage CreateOpenAi(ProviderConfiguration provider, ReadOnlySpan<byte> input, string credential, out Uri endpoint, out byte[] body)
    {
        endpoint = new Uri(provider.BaseUri, "v1/chat/completions");
        body = input.ToArray();
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
        return request;
    }

    private static HttpRequestMessage CreateAnthropic(ProviderConfiguration provider, JsonElement root, string credential, bool stream, out Uri endpoint, out byte[] body)
    {
        endpoint = new Uri(provider.BaseUri, "v1/messages");
        var messages = ReadMessages(root, "assistant");
        var payload = new Dictionary<string, object?>
        {
            ["model"] = RequiredString(root, "model"),
            ["messages"] = messages.Where(message => message.Role != "system").Select(message => new { role = message.Role, content = message.Content }).ToArray(),
            ["max_tokens"] = ReadMaxTokens(root) ?? DefaultMaxTokens,
            ["stream"] = stream,
        };
        var system = messages.FirstOrDefault(message => message.Role == "system")?.Content;
        if (system is not null) { payload["system"] = system; }
        CopyNumber(root, payload, "temperature");
        CopyNumber(root, payload, "top_p");
        if (ReadStopSequences(root) is { } stopSequences) { payload["stop_sequences"] = stopSequences; }
        body = JsonSerializer.SerializeToUtf8Bytes(payload);
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.TryAddWithoutValidation("x-api-key", credential);
        request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        return request;
    }

    private static HttpRequestMessage CreateGemini(ProviderConfiguration provider, JsonElement root, string credential, bool stream, string model, out Uri endpoint, out byte[] body)
    {
        if (!IsSafeModelSegment(model)) { throw new JsonException("The model identifier contains unsupported characters."); }
        endpoint = new Uri(provider.BaseUri, $"v1beta/models/{Uri.EscapeDataString(model)}:{(stream ? "streamGenerateContent?alt=sse" : "generateContent")}");
        var messages = ReadMessages(root, "model");
        var payload = new Dictionary<string, object?>
        {
            ["contents"] = messages.Where(message => message.Role != "system").Select(message => new { role = message.Role == "assistant" ? "model" : message.Role, parts = new[] { new { text = message.Content } } }).ToArray(),
        };
        var system = messages.FirstOrDefault(message => message.Role == "system")?.Content;
        if (system is not null) { payload["systemInstruction"] = new { parts = new[] { new { text = system } } }; }
        var generation = new Dictionary<string, object?>();
        CopyNumber(root, generation, "temperature");
        CopyNumber(root, generation, "top_p", "topP");
        if (ReadMaxTokens(root) is { } maxTokens) { generation["maxOutputTokens"] = maxTokens; }
        if (ReadStopSequences(root) is { } stopSequences) { generation["stopSequences"] = stopSequences; }
        if (generation.Count > 0) { payload["generationConfig"] = generation; }
        body = JsonSerializer.SerializeToUtf8Bytes(payload);
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.TryAddWithoutValidation("x-goog-api-key", credential);
        return request;
    }

    private static byte[] NormalizeAnthropicResponse(JsonElement root)
    {
        var text = root.TryGetProperty("content", out var content) ? string.Concat(content.EnumerateArray().Where(item => item.TryGetProperty("type", out var type) && type.GetString() == "text").Select(item => item.GetProperty("text").GetString())) : string.Empty;
        var usage = root.TryGetProperty("usage", out var u) ? u : default;
        var prompt = ReadInt(usage, "input_tokens") ?? 0;
        var completion = ReadInt(usage, "output_tokens") ?? 0;
        return JsonSerializer.SerializeToUtf8Bytes(new { id = OptionalString(root, "id") ?? "modelhub-anthropic", @object = "chat.completion", model = OptionalString(root, "model"), choices = new[] { new { index = 0, message = new { role = "assistant", content = text }, finish_reason = MapFinishReason(OptionalString(root, "stop_reason")) } }, usage = new { prompt_tokens = prompt, completion_tokens = completion, total_tokens = prompt + completion } });
    }

    private static byte[] NormalizeGeminiResponse(JsonElement root)
    {
        var candidate = root.TryGetProperty("candidates", out var candidates) && candidates.GetArrayLength() > 0 ? candidates[0] : default;
        var usage = root.TryGetProperty("usageMetadata", out var u) ? u : default;
        return JsonSerializer.SerializeToUtf8Bytes(new { id = "modelhub-gemini", @object = "chat.completion", choices = new[] { new { index = 0, message = new { role = "assistant", content = ReadParts(candidate) ?? string.Empty }, finish_reason = MapFinishReason(OptionalString(candidate, "finishReason")) } }, usage = new { prompt_tokens = ReadInt(usage, "promptTokenCount") ?? 0, completion_tokens = ReadInt(usage, "candidatesTokenCount") ?? 0, total_tokens = ReadInt(usage, "totalTokenCount") ?? 0 } });
    }

    private static List<Message> ReadMessages(JsonElement root, string assistantRole)
    {
        if (!root.TryGetProperty("messages", out var messages) || messages.ValueKind != JsonValueKind.Array) { throw new JsonException("messages must be an array."); }
        var result = new List<Message>();
        foreach (var item in messages.EnumerateArray())
        {
            var role = RequiredString(item, "role");
            if (role is not ("system" or "user" or "assistant")) { throw new JsonException("Unsupported chat role."); }
            var content = RequiredString(item, "content");
            result.Add(new Message(role == "assistant" ? assistantRole : role, content));
        }
        return result;
    }

    private static string? ReadParts(JsonElement candidate)
    {
        if (candidate.ValueKind != JsonValueKind.Object || !candidate.TryGetProperty("content", out var content) || !content.TryGetProperty("parts", out var parts)) { return null; }
        return string.Concat(parts.EnumerateArray().Where(part => part.TryGetProperty("text", out _)).Select(part => part.GetProperty("text").GetString()));
    }

    private static string RequiredString(JsonElement element, string name) => OptionalString(element, name) is { Length: > 0 } value ? value : throw new JsonException($"{name} is required.");
    private static string? OptionalString(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static int? ReadInt(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : null;
    private static void CopyNumber(JsonElement root, Dictionary<string, object?> target, string sourceName, string? targetName = null) { if (root.TryGetProperty(sourceName, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number)) { target[targetName ?? sourceName] = number; } }
    private static void RejectUnsupportedOpenAiSemantics(JsonElement root)
    {
        foreach (var name in new[]
        {
            "tools", "tool_choice", "response_format", "functions", "function_call", "parallel_tool_calls",
            "logprobs", "top_logprobs", "seed", "service_tier", "stream_options", "modalities", "audio",
            "presence_penalty", "frequency_penalty", "logit_bias", "user",
        })
        {
            if (root.TryGetProperty(name, out _)) { throw new NotSupportedException($"OpenAI field '{name}' cannot be preserved by the selected provider protocol."); }
        }
        if (root.TryGetProperty("n", out var n) && (!n.TryGetInt32(out var count) || count != 1)) { throw new NotSupportedException("Only n=1 can be preserved by the selected provider protocol."); }
        _ = ReadMaxTokens(root);
    }

    private static int? ReadMaxTokens(JsonElement root)
    {
        var legacy = ReadInt(root, "max_tokens");
        var completion = ReadInt(root, "max_completion_tokens");
        if (root.TryGetProperty("max_tokens", out _) && legacy is null
            || root.TryGetProperty("max_completion_tokens", out _) && completion is null)
        {
            throw new NotSupportedException("Token limits must be 32-bit integers.");
        }
        if (legacy is <= 0 || completion is <= 0) { throw new NotSupportedException("Token limits must be positive."); }
        if (legacy is not null && completion is not null && legacy != completion)
        {
            throw new NotSupportedException("Conflicting max_tokens and max_completion_tokens cannot be preserved.");
        }
        return completion ?? legacy;
    }

    private static string[]? ReadStopSequences(JsonElement root)
    {
        if (!root.TryGetProperty("stop", out var stop)) { return null; }
        string[] values = stop.ValueKind switch
        {
            JsonValueKind.String => [stop.GetString()!],
            JsonValueKind.Array => stop.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString()! : throw new NotSupportedException("stop entries must be strings.")).ToArray(),
            _ => throw new NotSupportedException("stop must be a string or string array."),
        };
        if (values.Length is < 1 or > 16 || values.Any(value => string.IsNullOrEmpty(value) || value.Length > 256 || value.Any(char.IsControl)))
        {
            throw new NotSupportedException("stop sequences exceed the safe interoperable contract.");
        }
        return values;
    }
    private static bool IsSafeModelSegment(string model) => model.Length is > 0 and <= 256 && model.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.');
    private static string? MapFinishReason(string? reason) => reason?.ToUpperInvariant() switch { "END_TURN" or "STOP" => "stop", "MAX_TOKENS" or "MAX_TOKENS_REACHED" => "length", "SAFETY" => "content_filter", null => null, _ => "stop" };
    private sealed record Message(string Role, string Content);
}
