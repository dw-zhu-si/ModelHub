using System.Diagnostics;
using System.Net;
using ModelHub.Windows.Models;

namespace ModelHub.Windows.Services;

/// <summary>Measures a selected subscription node by issuing a bounded HTTPS 204 request through that node's explicit proxy endpoint.</summary>
public sealed class NodeLatencyTester
{
    private static readonly Uri ProbeUri = new("https://www.gstatic.com/generate_204");

    public static async Task<NodeLatencyResult> TestAsync(NodeConfiguration node, CancellationToken cancellationToken)
    {
        if (!ConfigurationStore.IsLocalProxyEndpoint(node.ProxyUri))
        {
            return new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, null, "拒绝", "节点代理地址不安全或无效。");
        }

        using var handler = new SocketsHttpHandler
        {
            UseProxy = true,
            Proxy = new WebProxy(node.ProxyUri),
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(8),
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(12) };
        var stopwatch = Stopwatch.StartNew();
        try
        {
            using var response = await client.GetAsync(ProbeUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            stopwatch.Stop();
            if (response.StatusCode is not (System.Net.HttpStatusCode.NoContent or System.Net.HttpStatusCode.OK))
            {
                return new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, null, "失败", $"探针返回 HTTP {(int)response.StatusCode}。");
            }
            return new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, (int)Math.Ceiling(stopwatch.Elapsed.TotalMilliseconds), "可用", "通过节点访问 HTTPS 探针。");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, null, "已取消", "测速已取消。");
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return new NodeLatencyResult(node.Id, DateTimeOffset.UtcNow, null, "失败", "节点无法访问外网 HTTPS 探针。");
        }
    }
}
