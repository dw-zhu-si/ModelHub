using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class ProviderProtocolAndOAuthTests
{
    [Theory]
    [InlineData(ProviderProtocol.OpenAICompatible, "https://api.example.test/v1/chat/completions", "Authorization")]
    [InlineData(ProviderProtocol.Anthropic, "https://api.example.test/v1/messages", "x-api-key")]
    [InlineData(ProviderProtocol.Gemini, "https://api.example.test/v1beta/models/demo:generateContent", "x-goog-api-key")]
    public void BuildsProtocolSpecificRequestWithoutSecretsInUrls(ProviderProtocol protocol, string expectedUrl, string expectedCredentialHeader)
    {
        var provider = Provider(protocol);
        using var request = ProviderProtocolAdapter.CreateChatRequest(provider, OpenAiRequest(), "test-secret", false);

        Assert.Equal(expectedUrl, request.RequestUri!.AbsoluteUri);
        Assert.True(request.Headers.Contains(expectedCredentialHeader));
        Assert.DoesNotContain("test-secret", request.RequestUri.AbsoluteUri, StringComparison.Ordinal);
        Assert.DoesNotContain("api_key", request.RequestUri.Query, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AnthropicRequestAndResponseRoundTripOpenAiContract()
    {
        using var request = ProviderProtocolAdapter.CreateChatRequest(Provider(ProviderProtocol.Anthropic), OpenAiRequest(), "secret", false);
        var upstreamBody = await request.Content!.ReadAsStringAsync();
        Assert.Contains("\"max_tokens\"", upstreamBody, StringComparison.Ordinal);
        Assert.Contains("\"system\":\"be concise\"", upstreamBody, StringComparison.Ordinal);

        var normalized = ProviderProtocolAdapter.NormalizeNonStreamingResponse(ProviderProtocol.Anthropic,
            Encoding.UTF8.GetBytes("{\"id\":\"msg_1\",\"model\":\"demo\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}"));
        using var json = JsonDocument.Parse(normalized);
        Assert.Equal("hello", json.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString());
        Assert.Equal("stop", json.RootElement.GetProperty("choices")[0].GetProperty("finish_reason").GetString());
    }

    [Fact]
    public async Task GeminiRequestAndResponseRoundTripOpenAiContract()
    {
        using var request = ProviderProtocolAdapter.CreateChatRequest(Provider(ProviderProtocol.Gemini), OpenAiRequest(), "secret", false);
        var upstreamBody = await request.Content!.ReadAsStringAsync();
        Assert.Contains("\"contents\"", upstreamBody, StringComparison.Ordinal);
        Assert.Contains("\"systemInstruction\"", upstreamBody, StringComparison.Ordinal);

        var normalized = ProviderProtocolAdapter.NormalizeNonStreamingResponse(ProviderProtocol.Gemini,
            Encoding.UTF8.GetBytes("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":1,\"totalTokenCount\":4}}"));
        using var json = JsonDocument.Parse(normalized);
        Assert.Equal("hello", json.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString());
        Assert.Equal(4, json.RootElement.GetProperty("usage").GetProperty("total_tokens").GetInt32());
    }

    [Theory]
    [InlineData(ProviderProtocol.Anthropic, "tools")]
    [InlineData(ProviderProtocol.Anthropic, "tool_choice")]
    [InlineData(ProviderProtocol.Gemini, "response_format")]
    [InlineData(ProviderProtocol.Gemini, "parallel_tool_calls")]
    public void ProprietaryProtocolsRejectOpenAiSemanticsTheyCannotPreserve(ProviderProtocol protocol, string field)
    {
        var body = Encoding.UTF8.GetBytes($"{{\"model\":\"demo\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],\"{field}\":{{}}}}");
        Assert.Throws<NotSupportedException>(() => ProviderProtocolAdapter.CreateChatRequest(Provider(protocol), body, "secret", false));
    }

    public static TheoryData<string, string> UnsupportedOpenAiFields => new()
    {
        { "logprobs", "true" },
        { "top_logprobs", "2" },
        { "seed", "42" },
        { "service_tier", "\"auto\"" },
        { "stream_options", "{}" },
        { "modalities", "[\"text\"]" },
        { "audio", "{}" },
        { "presence_penalty", "0.1" },
        { "frequency_penalty", "0.1" },
        { "logit_bias", "{}" },
        { "user", "\"local-user\"" },
    };

    [Theory]
    [MemberData(nameof(UnsupportedOpenAiFields))]
    public void ProprietaryProtocolsRejectEveryAdditionalLossyOpenAiField(string field, string jsonValue)
    {
        foreach (var protocol in new[] { ProviderProtocol.Anthropic, ProviderProtocol.Gemini })
        {
            var body = Encoding.UTF8.GetBytes($"{{\"model\":\"demo\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],\"{field}\":{jsonValue}}}");
            Assert.Throws<NotSupportedException>(() => ProviderProtocolAdapter.CreateChatRequest(Provider(protocol), body, "secret", false));
        }
    }

    [Theory]
    [InlineData(ProviderProtocol.Anthropic, "\"max_completion_tokens\":77", "\"max_tokens\":77")]
    [InlineData(ProviderProtocol.Gemini, "\"max_completion_tokens\":77", "\"maxOutputTokens\":77")]
    [InlineData(ProviderProtocol.Anthropic, "\"max_tokens\":77,\"max_completion_tokens\":77", "\"max_tokens\":77")]
    public async Task ProprietaryProtocolsMapCompatibleCompletionTokenLimits(ProviderProtocol protocol, string fields, string expected)
    {
        var body = Encoding.UTF8.GetBytes($"{{\"model\":\"demo\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],{fields}}}");
        using var request = ProviderProtocolAdapter.CreateChatRequest(Provider(protocol), body, "secret", false);
        Assert.Contains(expected, await request.Content!.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(ProviderProtocol.Anthropic)]
    [InlineData(ProviderProtocol.Gemini)]
    public void ProprietaryProtocolsRejectConflictingCompletionTokenLimits(ProviderProtocol protocol)
    {
        var body = Encoding.UTF8.GetBytes("{\"model\":\"demo\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":64,\"max_completion_tokens\":128}");
        Assert.Throws<NotSupportedException>(() => ProviderProtocolAdapter.CreateChatRequest(Provider(protocol), body, "secret", false));
    }

    [Theory]
    [InlineData(ProviderProtocol.Anthropic, "\"top_p\":0.8,\"stop\":[\"END\"]", "\"top_p\":0.8", "\"stop_sequences\":[\"END\"]")]
    [InlineData(ProviderProtocol.Gemini, "\"top_p\":0.8,\"stop\":\"END\"", "\"topP\":0.8", "\"stopSequences\":[\"END\"]")]
    public async Task ProprietaryProtocolsMapSafeTopPAndStop(ProviderProtocol protocol, string fields, string expectedTopP, string expectedStop)
    {
        var body = Encoding.UTF8.GetBytes($"{{\"model\":\"demo\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],{fields}}}");
        using var request = ProviderProtocolAdapter.CreateChatRequest(Provider(protocol), body, "secret", false);
        var upstream = await request.Content!.ReadAsStringAsync();
        Assert.Contains(expectedTopP, upstream, StringComparison.Ordinal);
        Assert.Contains(expectedStop, upstream, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(ProviderProtocol.Anthropic, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n", "hi")]
    [InlineData(ProviderProtocol.Gemini, "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}]}}]}\n\n", "hi")]
    public void NormalizesProprietarySseEventToOpenAiChunk(ProviderProtocol protocol, string input, string expectedText)
    {
        var normalized = Encoding.UTF8.GetString(ProviderProtocolAdapter.NormalizeStreamingEvent(protocol, Encoding.UTF8.GetBytes(input)));
        Assert.StartsWith("data: ", normalized, StringComparison.Ordinal);
        Assert.Contains($"\"content\":\"{expectedText}\"", normalized, StringComparison.Ordinal);
        Assert.EndsWith("\n\n", normalized, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DeveloperOAuthUsesPkceAndStoresTokenInDedicatedCredentialTarget()
    {
        var vault = new FakeVault();
        var handler = new TokenHandler();
        var registration = Registration();
        using var oauth = new WindowsDeveloperOAuth(registration, vault, handler, TimeSpan.FromSeconds(1));
        var query = ParseQuery(oauth.AuthorizationUri.Query);

        Assert.Equal("S256", query["code_challenge_method"]);
        Assert.True(query["code_challenge"].Length >= 43);
        Assert.True(query["state"].Length >= 32);
        Assert.True(query["nonce"].Length >= 32);
        var callback = new Uri($"http://127.0.0.1:18443/oauth/callback?code=owned-developer-code&state={Uri.EscapeDataString(query["state"])}");
        await oauth.RedeemCallbackAsync(callback);

        Assert.Equal("developer-access-token", vault.Read(registration.CredentialTarget));
        Assert.Equal("developer-refresh-token", vault.Read(oauth.RefreshCredentialTarget));
        Assert.NotNull(vault.Read(oauth.ExpiryMetadataTarget));
        Assert.False(vault.Exists(oauth.ReauthorizationMetadataTarget));
        Assert.Equal("https://oauth2.googleapis.com/token", handler.LastRequestUri!.AbsoluteUri);
        Assert.DoesNotContain("owned-developer-code", handler.LastRequestUri.Query, StringComparison.Ordinal);
        await Assert.ThrowsAsync<InvalidOperationException>(() => oauth.RedeemCallbackAsync(callback));
    }

    [Theory]
    [InlineData("https://127.0.0.1:18443/oauth/callback")]
    [InlineData("http://localhost:18443/oauth/callback")]
    [InlineData("http://127.0.0.1:18443/other")]
    public void DeveloperOAuthRejectsNonExactLoopbackRedirects(string redirect)
    {
        var registration = Registration() with { RedirectUri = new Uri(redirect) };
        Assert.Throws<ArgumentException>(() => new WindowsDeveloperOAuth(registration, new FakeVault(), new TokenHandler()));
    }

    [Fact]
    public void DeveloperOAuthRejectsUnapprovedScopesAndConsumerAutomation()
    {
        Assert.Throws<ArgumentException>(() => new WindowsDeveloperOAuth(Registration() with { Scopes = ["https://www.googleapis.com/auth/drive"] }, new FakeVault(), new TokenHandler()));
        Assert.Throws<NotSupportedException>(() => WindowsDeveloperOAuth.CreateConsumerSubscriptionAutomation());
        Assert.Throws<NotSupportedException>(() => WindowsDeveloperOAuth.EnableQuotaRotation());
    }

    [Fact]
    public async Task DeveloperOAuthRejectsOversizedHeadersWithoutConsumingValidCallback()
    {
        var oauth = new WindowsDeveloperOAuth(Registration(), new FakeVault(), new TokenHandler());
        var state = ParseQuery(oauth.AuthorizationUri.Query)["state"];
        var callback = new Uri($"http://127.0.0.1:18443/oauth/callback?code=code&state={Uri.EscapeDataString(state)}");
        await Assert.ThrowsAsync<InvalidOperationException>(() => oauth.RedeemCallbackAsync(callback, new Dictionary<string, string> { ["X-Oversized"] = new string('a', 16 * 1024) }));
        await oauth.RedeemCallbackAsync(callback);
        oauth.Dispose();
    }

    [Fact]
    public async Task DeveloperOAuthRejectsExpandedOrIncompleteGrantedScope()
    {
        var handler = new TokenHandler
        {
            ResponseJson = "{\"access_token\":\"developer-access-token\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/drive\"}",
        };
        using var oauth = new WindowsDeveloperOAuth(Registration(), new FakeVault(), handler);
        var state = ParseQuery(oauth.AuthorizationUri.Query)["state"];
        var callback = new Uri($"http://127.0.0.1:18443/oauth/callback?code=code&state={Uri.EscapeDataString(state)}");

        await Assert.ThrowsAsync<InvalidOperationException>(() => oauth.RedeemCallbackAsync(callback));
    }

    [Fact]
    public async Task DeveloperOAuthWithoutRefreshTokenRecordsReauthorizationRequirement()
    {
        var vault = new FakeVault();
        var handler = new TokenHandler
        {
            ResponseJson = "{\"access_token\":\"developer-access-token\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/generative-language\"}",
        };
        using var oauth = new WindowsDeveloperOAuth(Registration(), vault, handler);
        var state = ParseQuery(oauth.AuthorizationUri.Query)["state"];
        var callback = new Uri($"http://127.0.0.1:18443/oauth/callback?code=code&state={Uri.EscapeDataString(state)}");

        await oauth.RedeemCallbackAsync(callback);

        Assert.Equal("true", vault.Read(oauth.ReauthorizationMetadataTarget));
        Assert.False(vault.Exists(oauth.RefreshCredentialTarget));
        Assert.NotNull(vault.Read(oauth.ExpiryMetadataTarget));
    }

    [Fact]
    public async Task LoopbackListenerIgnoresUnrelatedRequestsUntilExactValidCallback()
    {
        var port = ReservePort();
        var registration = Registration() with { RedirectUri = new Uri($"http://127.0.0.1:{port}/oauth/callback") };
        var handler = new TokenHandler();
        using var oauth = new WindowsDeveloperOAuth(registration, new FakeVault(), handler, callbackTotalTimeout: TimeSpan.FromSeconds(2), callbackConnectionTimeout: TimeSpan.FromSeconds(1));
        var state = ParseQuery(oauth.AuthorizationUri.Query)["state"];
        var callback = new Uri($"http://127.0.0.1:{port}/oauth/callback?code=code&state={Uri.EscapeDataString(state)}");
        var listenerTask = oauth.ListenAndRedeemCallbackAsync();

        using var client = new HttpClient();
        using var response = await client.PostAsync(callback, new StringContent(string.Empty));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        using var wrongPath = await client.GetAsync(new Uri($"http://127.0.0.1:{port}/other?code=code&state={Uri.EscapeDataString(state)}"));
        Assert.Equal(HttpStatusCode.BadRequest, wrongPath.StatusCode);
        using var wrongState = await client.GetAsync(new Uri($"http://127.0.0.1:{port}/oauth/callback?code=code&state=wrong"));
        Assert.Equal(HttpStatusCode.BadRequest, wrongState.StatusCode);
        using var accepted = await client.GetAsync(callback);
        Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
        await listenerTask;
        Assert.Equal(new Uri("https://oauth2.googleapis.com/token"), handler.LastRequestUri);
    }

    private static ProviderConfiguration Provider(ProviderProtocol protocol) => new(Guid.NewGuid(), "provider", new Uri("https://api.example.test/"), true, [new ModelDefinition("demo", "Demo", "text")], protocol);

    private static byte[] OpenAiRequest() => Encoding.UTF8.GetBytes("{\"model\":\"demo\",\"messages\":[{\"role\":\"system\",\"content\":\"be concise\"},{\"role\":\"user\",\"content\":\"hello\"}],\"temperature\":0.2}");

    private static DeveloperOAuthRegistration Registration() => new(
        DeveloperOAuthProvider.GoogleGemini,
        "developer-owned-client-id.apps.googleusercontent.com",
        new Uri("http://127.0.0.1:18443/oauth/callback"),
        ["https://www.googleapis.com/auth/generative-language"],
        Guid.NewGuid());

    private static Dictionary<string, string> ParseQuery(string query) => query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
        .Select(part => part.Split('=', 2)).ToDictionary(parts => Uri.UnescapeDataString(parts[0]), parts => Uri.UnescapeDataString(parts[1]), StringComparer.Ordinal);

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private sealed class FakeVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _values = [];
        public void Write(string targetName, string secret) => _values[targetName] = secret;
        public string? Read(string targetName) => _values.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _values.ContainsKey(targetName);
        public void Delete(string targetName) => _values.Remove(targetName);
    }

    private sealed class TokenHandler : HttpMessageHandler
    {
        public Uri? LastRequestUri { get; private set; }
        public string ResponseJson { get; init; } = "{\"access_token\":\"developer-access-token\",\"refresh_token\":\"developer-refresh-token\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"https://www.googleapis.com/auth/generative-language\"}";
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequestUri = request.RequestUri;
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Assert.Contains("code_verifier=", body, StringComparison.Ordinal);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(ResponseJson, Encoding.UTF8, "application/json") };
        }
    }
}
