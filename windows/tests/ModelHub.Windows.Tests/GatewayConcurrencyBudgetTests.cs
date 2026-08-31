using System.Net;
using System.Net.Sockets;
using System.Text;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.Tests;

public sealed class GatewayConcurrencyBudgetTests
{
    [Fact]
    public async Task FifthConcurrentMediaRequestIsRejectedBeforeAnotherUpstreamSend()
    {
        var provider = new ProviderConfiguration(
            Guid.NewGuid(),
            "bounded-media",
            new Uri("https://media.example.com/"),
            true,
            [new ModelDefinition("image-model", "image-model", "image")]);
        var port = ReservePort();
        var configuration = new ModelHubConfiguration(
            1,
            new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget),
            [provider],
            [],
            []);
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, "gateway-concurrency-test-token");
        vault.Write(provider.CredentialTarget, "provider-concurrency-test-secret");
        var handler = new BlockingMediaHandler(expectedArrivals: 4);
        await using var gateway = new LocalGatewayService(
            () => configuration,
            vault,
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(port);

        var active = Enumerable.Range(0, 4)
            .Select(_ => client.PostAsync(
                "/v1/images/generations",
                JsonContent("{\"model\":\"image-model\",\"prompt\":\"bounded\"}")))
            .ToArray();
        await handler.AllExpectedArrived.WaitAsync(TimeSpan.FromSeconds(5));

        using var rejected = await client.PostAsync(
            "/v1/images/generations",
            JsonContent("{\"model\":\"image-model\",\"prompt\":\"overflow\"}"));
        var rejectedBody = await rejected.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.TooManyRequests, rejected.StatusCode);
        Assert.Contains("media_capacity_exhausted", rejectedBody, StringComparison.Ordinal);
        Assert.Equal(4, handler.SendCount);

        handler.Release();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var completed = await Task.WhenAll(active).WaitAsync(timeout.Token);
        Assert.All(completed, response =>
        {
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            response.Dispose();
        });
    }

    [Fact]
    public async Task ThirdConcurrentMultipartRequestIsRejectedBeforeBufferAmplification()
    {
        var provider = new ProviderConfiguration(
            Guid.NewGuid(),
            "bounded-multipart",
            new Uri("https://media.example.com/"),
            true,
            [new ModelDefinition("image-model", "image-model", "image")]);
        var port = ReservePort();
        var configuration = new ModelHubConfiguration(
            1,
            new GatewaySettings(port, GatewaySettings.DefaultCredentialTarget),
            [provider],
            [],
            []);
        var vault = new FakeCredentialVault();
        vault.Write(GatewaySettings.DefaultCredentialTarget, "gateway-concurrency-test-token");
        vault.Write(provider.CredentialTarget, "provider-concurrency-test-secret");
        var handler = new BlockingMediaHandler(expectedArrivals: 2);
        await using var gateway = new LocalGatewayService(
            () => configuration,
            vault,
            handler,
            new UsageLedgerStore(CreateTemporaryDirectory()));
        await gateway.StartAsync();
        using var client = AuthorizedClient(port);

        var active = new[]
        {
            client.PostAsync("/v1/images/edits", CreateImageEditContent()),
            client.PostAsync("/v1/images/edits", CreateImageEditContent()),
        };
        await handler.AllExpectedArrived.WaitAsync(TimeSpan.FromSeconds(5));

        using var rejected = await client.PostAsync(
            "/v1/images/edits",
            CreateImageEditContent());
        var rejectedBody = await rejected.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.TooManyRequests, rejected.StatusCode);
        Assert.Contains("multipart_capacity_exhausted", rejectedBody, StringComparison.Ordinal);
        Assert.Equal(2, handler.SendCount);

        handler.Release();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var completed = await Task.WhenAll(active).WaitAsync(timeout.Token);
        Assert.All(completed, response =>
        {
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            response.Dispose();
        });
    }

    private static HttpClient AuthorizedClient(int port)
    {
        var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/") };
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue(
                "Bearer",
                "gateway-concurrency-test-token");
        return client;
    }

    private static StringContent JsonContent(string json) =>
        new(json, Encoding.UTF8, "application/json");

    private static MultipartFormDataContent CreateImageEditContent()
    {
        var content = new MultipartFormDataContent();
        content.Add(new StringContent("image-model"), "model");
        var image = new ByteArrayContent([1, 2, 3, 4]);
        image.Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
        content.Add(image, "image", "input.png");
        return content;
    }

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static string CreateTemporaryDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            "modelhub-gateway-budget-tests",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed class BlockingMediaHandler(int expectedArrivals) : HttpMessageHandler
    {
        private readonly TaskCompletionSource _allExpectedArrived =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _release =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _sendCount;

        public Task AllExpectedArrived => _allExpectedArrived.Task;
        public int SendCount => Volatile.Read(ref _sendCount);

        public void Release() => _release.TrySetResult();

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (Interlocked.Increment(ref _sendCount) == expectedArrivals)
            {
                _allExpectedArrived.TrySetResult();
            }
            await _release.Task.WaitAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    "{\"data\":[{\"url\":\"https://cdn.example.com/image.png\"}]}",
                    Encoding.UTF8,
                    "application/json"),
            };
        }
    }

    private sealed class FakeCredentialVault : ICredentialVault
    {
        private readonly Dictionary<string, string> _entries = new(StringComparer.Ordinal);

        public void Write(string targetName, string secret) => _entries[targetName] = secret;
        public string? Read(string targetName) => _entries.GetValueOrDefault(targetName);
        public bool Exists(string targetName) => _entries.ContainsKey(targetName);
        public void Delete(string targetName) => _entries.Remove(targetName);
    }
}
