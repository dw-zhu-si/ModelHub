using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using ModelHub.Windows.Models;
using ModelHub.Windows.Services;

namespace ModelHub.Windows.ViewModels;

public interface ISystemBrowserLauncher
{
    void Open(Uri uri);
}

public sealed class SystemBrowserLauncher : ISystemBrowserLauncher
{
    public void Open(Uri uri)
    {
        if (uri.Scheme != Uri.UriSchemeHttps) { throw new InvalidOperationException("Only HTTPS authorization pages may be opened."); }
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
}

public interface IProxySubscriptionClient
{
    Task<byte[]> FetchAsync(Uri source, CancellationToken cancellationToken);
}

public sealed class BoundedHttpsProxySubscriptionClient : IProxySubscriptionClient, IDisposable
{
    private readonly HttpClient _client = new(new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(8) }) { Timeout = TimeSpan.FromSeconds(20) };

    public async Task<byte[]> FetchAsync(Uri source, CancellationToken cancellationToken)
    {
        ProxySubscriptionPolicy.ValidateSourceUri(source);
        var current = source;
        for (var redirect = 0; redirect <= 3; redirect++)
        {
            using var response = await _client.GetAsync(current, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                var location = response.Headers.Location is { } raw ? (raw.IsAbsoluteUri ? raw : new Uri(current, raw)) : throw new HttpRequestException("Subscription redirect omitted Location.");
                if (!ProxySubscriptionPolicy.IsSameOriginRedirect(source, location)) { throw new ProxySubscriptionSecurityException("Subscription redirect left the exact HTTPS origin."); }
                current = location;
                continue;
            }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is > ProxySubscriptionPolicy.MaximumPayloadBytes) { throw new ProxySubscriptionLimitException("Subscription exceeds the 4 MiB limit."); }
            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[ProxySubscriptionPolicy.MaximumPayloadBytes];
            var length = 0;
            try
            {
                while (true)
                {
                    var read = await input.ReadAsync(
                        buffer.AsMemory(length),
                        cancellationToken).ConfigureAwait(false);
                    if (read == 0) { return buffer.AsSpan(0, length).ToArray(); }
                    length += read;
                    if (length == buffer.Length)
                    {
                        var extra = new byte[1];
                        try
                        {
                            if (await input.ReadAsync(extra, cancellationToken)
                                    .ConfigureAwait(false) != 0)
                            {
                                throw new ProxySubscriptionLimitException(
                                    "Subscription exceeds the 4 MiB limit.");
                            }
                        }
                        finally
                        {
                            CryptographicOperations.ZeroMemory(extra);
                        }
                        return buffer.ToArray();
                    }
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(buffer);
            }
        }
        throw new HttpRequestException("Subscription exceeded the redirect limit.");
    }

    public void Dispose() => _client.Dispose();
}

public sealed class UnavailableMihomoStatus : IMihomoRuntimeStatus
{
    public bool IsReady => false;
}

/// <summary>Runs an explicit, potentially billable probe through the authenticated loopback gateway.</summary>
public sealed class LoopbackGatewayHealthProbe(
    Func<ModelHubConfiguration> configuration,
    ICredentialVault vault) : IModelHealthProbe
{
    public async Task<ModelHealthObservation> ProbeAsync(ModelHealthTarget target, CancellationToken cancellationToken)
    {
        var snapshot = configuration();
        var token = vault.Read(snapshot.Gateway.TokenCredentialTarget);
        if (string.IsNullOrWhiteSpace(token))
        {
            return new ModelHealthObservation(ModelHealthOutcome.AuthenticationFailure, null, "gateway_token_missing");
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{snapshot.Gateway.Port}/v1/chat/completions");
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new { model = target.ModelId, messages = new[] { new { role = "user", content = "Reply OK" } }, max_tokens = 1 });
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var started = Stopwatch.GetTimestamp();
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            var latency = Stopwatch.GetElapsedTime(started);
            return response.StatusCode switch
            {
                HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => new(ModelHealthOutcome.AuthenticationFailure, latency, "gateway_authentication_failed"),
                HttpStatusCode.TooManyRequests => new(ModelHealthOutcome.RateLimited, latency, "upstream_rate_limited"),
                HttpStatusCode.NotFound => new(ModelHealthOutcome.PermanentModelFailure, latency, "model_not_found"),
                _ when response.IsSuccessStatusCode => new(ModelHealthOutcome.Healthy, latency, "verified_via_loopback_gateway"),
                _ => new(ModelHealthOutcome.TransientFailure, latency, $"gateway_http_{(int)response.StatusCode}"),
            };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new ModelHealthObservation(ModelHealthOutcome.TransientFailure, null, "gateway_timeout");
        }
        catch (HttpRequestException)
        {
            return new ModelHealthObservation(ModelHealthOutcome.TransientFailure, null, "gateway_unavailable");
        }
    }
}

public sealed partial class MainWindowViewModel : ObservableObject, IDisposable
{
    private readonly ConfigurationStore _configurationStore;
    private readonly ConfigurationState _configurationState;
    private readonly ICredentialVault _vault;
    private readonly LocalGatewayService _gateway;
    private readonly HealthMonitor _health;
    private readonly NodeLatencyTester _nodeTester;
    private readonly WindowsUpdateCoordinator _updates;
    private readonly bool _ownsUpdates;
    private readonly Func<DeveloperOAuthRegistration, WindowsDeveloperOAuth>? _developerOAuthFactory;
    private readonly ISystemBrowserLauncher _browser;
    private readonly IProxySubscriptionClient? _subscriptionClient;
    private readonly IMihomoRuntimeStatus _mihomoRuntime;
    private readonly IMihomoRuntimeController? _mihomoLifecycle;
    private readonly BatchHealthVerifier? _batchHealthVerifier;
    private readonly ConfigurationImportExport _configurationExchange;
    private readonly Func<NodeConfiguration, CancellationToken, Task<NodeLatencyResult>> _nodeLatencyProbe;
    private ModelHubConfiguration _configuration;
    private WindowsDeveloperOAuth? _developerOAuth;
    private WindowsUpdateCandidate? _updateCandidate;
    private Uri? _subscriptionSource;
    private CancellationTokenSource? _subscriptionCancellation;
    private CancellationTokenSource? _healthCancellation;

    [ObservableProperty] private string _gatewayToken = string.Empty;
    [ObservableProperty] private string _providerName = string.Empty;
    [ObservableProperty] private string _providerBaseUrl = "https://api.example.com/";
    [ObservableProperty] private string _providerModelId = string.Empty;
    [ObservableProperty] private string _providerSecret = string.Empty;
    [ObservableProperty] private ProviderProtocol _selectedProviderProtocol = ProviderProtocol.OpenAICompatible;
    [ObservableProperty] private string _nodeName = string.Empty;
    [ObservableProperty] private string _nodeProxyUrl = "http://127.0.0.1:7890";
    [ObservableProperty] private string _status = "本地配置尚未保存；凭证不会写入配置文件。";
    [ObservableProperty] private bool _isGatewayRunning;
    [ObservableProperty] private string _oAuthClientId = string.Empty;
    [ObservableProperty] private string _oAuthCloudProject = string.Empty;
    [ObservableProperty] private string _oAuthRedirectUri = "http://127.0.0.1:18443/oauth/callback";
    [ObservableProperty] private string _oAuthAuthorizationUrl = string.Empty;
    [ObservableProperty] private string _updateStatus = string.Empty;
    [ObservableProperty] private int _updateProgress;
    [ObservableProperty] private bool _canCheckUpdates;
    [ObservableProperty] private bool _canDownloadUpdate;
    [ObservableProperty] private bool _canRestartToUpdate;
    [ObservableProperty] private string _subscriptionName = string.Empty;
    [ObservableProperty] private string _subscriptionUrl = string.Empty;
    [ObservableProperty] private string _nodeSearch = string.Empty;
    [ObservableProperty] private string _mihomoExecutablePath = string.Empty;
    [ObservableProperty] private string _mihomoConfigurationPath = string.Empty;
    [ObservableProperty] private string _mihomoProxyGroup = string.Empty;
    [ObservableProperty] private int _mihomoControllerPort;
    [ObservableProperty] private string _mihomoControllerSecret = string.Empty;
    [ObservableProperty] private string _mihomoStatus = "Mihomo 未启动；已分配模型将失败关闭，不会直连。";
    [ObservableProperty] private bool _isSubscriptionBusy;
    [ObservableProperty] private ModelChoiceViewModel? _selectedAssignmentModel;
    [ObservableProperty] private NodeRowViewModel? _selectedAssignmentNode;
    [ObservableProperty] private string _assignmentStatus = "未分配模型将失败关闭；已分配节点不可用时绝不直连。";
    [ObservableProperty] private string _routeAlias = string.Empty;
    [ObservableProperty] private bool _routeEnabled = true;
    [ObservableProperty] private ModelRouteStrategy _selectedRouteStrategy = ModelRouteStrategy.PriorityFailover;
    [ObservableProperty] private ModelChoiceViewModel? _selectedRouteModel;
    [ObservableProperty] private int _routePriority;
    [ObservableProperty] private int _routeWeight = 1;
    [ObservableProperty] private ProviderRowViewModel? _selectedEndpointProvider;
    [ObservableProperty] private GatewayEndpointKind _selectedEndpointKind = GatewayEndpointKind.ChatCompletions;
    [ObservableProperty] private string _endpointPath = "/v1/chat/completions";
    [ObservableProperty] private bool _endpointIsAsynchronous;
    [ObservableProperty] private string _endpointPollPath = string.Empty;
    [ObservableProperty] private GatewayTaskIdentifierField _selectedTaskIdentifierField = GatewayTaskIdentifierField.TaskId;
    [ObservableProperty] private bool _isHealthVerificationRunning;
    [ObservableProperty] private int _healthProgress;
    [ObservableProperty] private string _healthVerificationStatus = "批量验证会发起真实模型请求，可能产生费用，仅在显式点击后执行。";
    [ObservableProperty] private string _configurationFilePath = string.Empty;

    public ObservableCollection<ProviderRowViewModel> Providers { get; } = [];
    public ObservableCollection<NodeRowViewModel> Nodes { get; } = [];
    public ObservableCollection<HealthRowViewModel> Health { get; } = [];
    public ObservableCollection<ModelChoiceViewModel> Models { get; } = [];
    public ObservableCollection<RouteTargetDraftViewModel> RouteTargetDrafts { get; } = [];
    public ObservableCollection<RouteRowViewModel> Routes { get; } = [];
    public ObservableCollection<EndpointRowViewModel> EndpointPaths { get; } = [];
    public IReadOnlyList<ProviderProtocol> ProviderProtocols { get; } = Enum.GetValues<ProviderProtocol>();
    public IReadOnlyList<ModelRouteStrategy> RouteStrategies { get; } = Enum.GetValues<ModelRouteStrategy>();
    public IReadOnlyList<GatewayEndpointKind> EndpointKinds { get; } = Enum.GetValues<GatewayEndpointKind>();
    public IReadOnlyList<GatewayTaskIdentifierField> TaskIdentifierFields { get; } = Enum.GetValues<GatewayTaskIdentifierField>();

    public MainWindowViewModel(
        ConfigurationState configurationState,
        ConfigurationStore configurationStore,
        ICredentialVault vault,
        LocalGatewayService gateway,
        HealthMonitor health,
        NodeLatencyTester nodeTester,
        WindowsUpdateCoordinator? updates = null,
        ISystemBrowserLauncher? browser = null,
        Func<DeveloperOAuthRegistration, WindowsDeveloperOAuth>? developerOAuthFactory = null,
        IProxySubscriptionClient? subscriptionClient = null,
        IMihomoRuntimeStatus? mihomoRuntime = null,
        BatchHealthVerifier? batchHealthVerifier = null,
        ConfigurationImportExport? configurationExchange = null,
        Func<NodeConfiguration, CancellationToken, Task<NodeLatencyResult>>? nodeLatencyProbe = null)
    {
        _configurationState = configurationState;
        _configuration = configurationState.Snapshot();
        _configurationStore = configurationStore;
        _vault = vault;
        _gateway = gateway;
        _health = health;
        _nodeTester = nodeTester;
        _ownsUpdates = updates is null;
        _updates = updates ?? new WindowsUpdateCoordinator(new DisabledUpdateEngine());
        _developerOAuthFactory = developerOAuthFactory;
        _browser = browser ?? new SystemBrowserLauncher();
        _subscriptionClient = subscriptionClient;
        _mihomoRuntime = mihomoRuntime ?? new UnavailableMihomoStatus();
        _mihomoLifecycle = mihomoRuntime as IMihomoRuntimeController;
        _batchHealthVerifier = batchHealthVerifier;
        _configurationExchange = configurationExchange ?? new ConfigurationImportExport();
        _nodeLatencyProbe = nodeLatencyProbe ?? NodeLatencyTester.TestAsync;
        if (_configuration.Mihomo is { } mihomo)
        {
            MihomoExecutablePath = mihomo.ExecutablePath;
            MihomoConfigurationPath = mihomo.ConfigurationPath;
            MihomoControllerPort = mihomo.ControllerPort;
            MihomoProxyGroup = mihomo.ProxyGroup;
        }
        var tokenExists = vault.Exists(_configuration.Gateway.TokenCredentialTarget);
        var mihomoControllerSecretExists = vault.Exists(
            MihomoSettings.ControllerSecretCredentialTarget);
        GatewayToken = string.Empty;
        MihomoControllerSecret = string.Empty;
        Status = tokenExists ? "本地 API 令牌已安全保存；输入框不会回填凭证。" : Status;
        if (mihomoControllerSecretExists)
        {
            MihomoStatus = "Mihomo Controller 凭证已安全保存；输入框不会回填。当前尚未启动。";
        }
        CanCheckUpdates = _updates.IsInstalled;
        UpdateStatus = _updates.IsInstalled
            ? "已安装版本：仅在点击“检查更新”后访问项目官方 HTTPS 更新源。"
            : "便携或未安装状态：热更新已禁用，请使用签名安装包升级。";
        RefreshCollections();
    }

    [RelayCommand]
    private void SaveGatewayToken()
    {
        if (GatewayToken.Length < 24)
        {
            Status = "本地 API 令牌至少需要 24 个字符。";
            return;
        }
        try
        {
            _vault.Write(_configuration.Gateway.TokenCredentialTarget, GatewayToken);
            GatewayToken = string.Empty;
            Status = "本地 API 令牌已保存到 Windows Credential Manager。";
        }
        catch (Exception exception) when (exception is PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        {
            Status = "Windows Credential Manager 不可用，网关保持关闭。";
        }
    }

    [RelayCommand]
    private async Task StartGatewayAsync()
    {
        try
        {
            await _gateway.StartAsync();
            IsGatewayRunning = true;
            Status = $"本地 OpenAI 兼容 API 正在 http://127.0.0.1:{_configuration.Gateway.Port}/v1 监听。";
            _health.RecordSuccess("本地 API", TimeSpan.Zero, "仅回环监听");
        }
        catch (Exception exception) when (exception is InvalidOperationException or HttpListenerException or PlatformNotSupportedException)
        {
            IsGatewayRunning = false;
            Status = "本地 API 无法启动：先保存令牌、确认端口未占用，并仅在 Windows 上运行。";
            _health.RecordFailure("本地 API", Status);
        }
        RefreshHealth();
    }

    [RelayCommand]
    private async Task StopGatewayAsync()
    {
        await _gateway.StopAsync();
        IsGatewayRunning = false;
        Status = "本地 API 已停止。";
    }

    [RelayCommand]
    private void AddProvider()
    {
        if (!Uri.TryCreate(ProviderBaseUrl, UriKind.Absolute, out var uri) || !ConfigurationStore.IsSecureProviderEndpoint(uri) || string.IsNullOrWhiteSpace(ProviderName) || string.IsNullOrWhiteSpace(ProviderModelId))
        {
            Status = "供应商需要名称、HTTPS 基址和模型 ID。";
            return;
        }
        if (ProviderSecret.Length < 8)
        {
            Status = "请填写供应商 API Key；它只会保存到 Windows Credential Manager。";
            return;
        }
        if (_configuration.Providers.SelectMany(provider => provider.Models).Any(model => model.Id.Equals(ProviderModelId, StringComparison.Ordinal)))
        {
            Status = "模型 ID 必须在本地目录中唯一。";
            return;
        }

        var provider = new ProviderConfiguration(Guid.NewGuid(), ProviderName.Trim(), EnsureTrailingSlash(uri), true, [new ModelDefinition(ProviderModelId.Trim(), ProviderModelId.Trim(), "text")], SelectedProviderProtocol);
        var credentialWritten = false;
        try
        {
            _vault.Write(provider.CredentialTarget, ProviderSecret);
            credentialWritten = true;
            var nextConfiguration = _configuration with { Providers = [.. _configuration.Providers, provider] };
            _configurationStore.Save(nextConfiguration);
            _configuration = nextConfiguration;
            _configurationState.Replace(nextConfiguration);
            ProviderName = ProviderModelId = ProviderSecret = string.Empty;
            ProviderBaseUrl = "https://api.example.com/";
            SelectedProviderProtocol = ProviderProtocol.OpenAICompatible;
            Status = $"已保存供应商“{provider.DisplayName}”及 1 个模型；密钥没有写入磁盘。";
            _health.RecordDegraded(provider.DisplayName, "尚未执行真实模型调用。");
            RefreshCollections();
        }
        catch (Exception exception) when (exception is PlatformNotSupportedException or System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            if (credentialWritten)
            {
                try { _vault.Delete(provider.CredentialTarget); } catch (Exception rollbackException) when (rollbackException is PlatformNotSupportedException or System.ComponentModel.Win32Exception) { }
            }
            Status = "保存供应商失败；配置没有被部分写入。";
        }
    }

    [RelayCommand]
    private void AddNode()
    {
        if (!Uri.TryCreate(NodeProxyUrl, UriKind.Absolute, out var uri) || !ConfigurationStore.IsLocalProxyEndpoint(uri) || string.IsNullOrWhiteSpace(NodeName))
        {
            Status = "节点需要名称和有效的 HTTP/HTTPS 代理地址。";
            return;
        }
        var node = new NodeConfiguration(Guid.NewGuid(), NodeName.Trim(), uri, !_configuration.Nodes.Any(candidate => candidate.IsSelected));
        var nextConfiguration = _configuration with { Nodes = [.. _configuration.Nodes, node] };
        _configurationStore.Save(nextConfiguration);
        _configuration = nextConfiguration;
        _configurationState.Replace(nextConfiguration);
        NodeName = string.Empty;
        NodeProxyUrl = "http://127.0.0.1:7890";
        Status = $"已添加节点“{node.Name}”。测速会通过该节点访问固定 HTTPS 204 探针。";
        RefreshCollections();
    }

    [RelayCommand]
    private async Task SelectNodeAsync(Guid id)
    {
        var node = _configuration.Nodes.SingleOrDefault(candidate => candidate.Id == id);
        if (node is null)
        {
            return;
        }

        await SelectNodeCoreAsync(node).ConfigureAwait(true);
    }

    [RelayCommand]
    private async Task TestNodeAsync(Guid id)
    {
        var node = _configuration.Nodes.SingleOrDefault(candidate => candidate.Id == id);
        if (node is null)
        {
            return;
        }
        if (!await SelectNodeCoreAsync(node).ConfigureAwait(true))
        {
            return;
        }
        Status = $"正在通过“{node.Name}”测试外网 HTTPS 连通性…";
        var result = await _nodeLatencyProbe(node, CancellationToken.None);
        if (result.LatencyMilliseconds is int latency)
        {
            _health.RecordSuccess($"节点/{node.Name}", TimeSpan.FromMilliseconds(latency), result.Detail);
            Status = $"节点“{node.Name}”可用，HTTPS 延迟 {latency} ms。";
        }
        else
        {
            _health.RecordFailure($"节点/{node.Name}", result.Detail);
            Status = $"节点“{node.Name}”测速{result.Status}：{result.Detail}";
        }
        RefreshCollections();
    }

    [RelayCommand]
    private async Task ImportSubscriptionAsync()
    {
        if (_subscriptionClient is null
            || !Uri.TryCreate(SubscriptionUrl, UriKind.Absolute, out var source)
            || string.IsNullOrWhiteSpace(SubscriptionName)
            || !IsSafeSelectorGroup(MihomoProxyGroup)
            || !Uri.TryCreate(NodeProxyUrl, UriKind.Absolute, out var proxy)
            || !ConfigurationStore.IsLocalProxyEndpoint(proxy))
        {
            Status = "订阅需要名称、不含用户信息的 HTTPS URL、Mihomo 选择器组名，以及本地回环代理地址。";
            return;
        }
        try { ProxySubscriptionPolicy.ValidateSourceUri(source); }
        catch (ProxySubscriptionSecurityException) { Status = "订阅 URL 必须是凭证无用户信息的 HTTPS 地址。"; return; }
        _subscriptionSource = source;
        SubscriptionUrl = string.Empty;
        await RefreshSubscriptionCoreAsync(SubscriptionName.Trim(), proxy).ConfigureAwait(true);
    }

    [RelayCommand]
    private async Task RefreshSubscriptionAsync()
    {
        if (_subscriptionSource is null
            || !IsSafeSelectorGroup(MihomoProxyGroup)
            || !Uri.TryCreate(NodeProxyUrl, UriKind.Absolute, out var proxy)
            || !ConfigurationStore.IsLocalProxyEndpoint(proxy))
        {
            Status = "请先导入 HTTPS 订阅，并配置 Mihomo 选择器组与回环代理。";
            return;
        }
        await RefreshSubscriptionCoreAsync(SubscriptionName.Trim(), proxy).ConfigureAwait(true);
    }

    [RelayCommand]
    private void CancelSubscriptionOperation() => _subscriptionCancellation?.Cancel();

    [RelayCommand]
    private void SaveMihomoSettings()
    {
        var settings = new MihomoSettings(
            MihomoExecutablePath.Trim(),
            MihomoConfigurationPath.Trim(),
            MihomoControllerPort,
            MihomoProxyGroup.Trim());
        if (!ConfigurationStore.IsSafeMihomoSettings(settings))
        {
            MihomoStatus = "Mihomo 设置需要本地绝对文件路径、已分配的 1024–65535 回环端口和有效选择器组名。";
            return;
        }

        try
        {
            Persist(_configuration with { Mihomo = settings });
            MihomoExecutablePath = settings.ExecutablePath;
            MihomoConfigurationPath = settings.ConfigurationPath;
            MihomoProxyGroup = settings.ProxyGroup;
            MihomoStatus = "Mihomo 的非秘密运行设置已仅保存到本机配置仓储；订阅 URL 和 Controller 凭证不持久化到配置导出。";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.Security.SecurityException)
        {
            MihomoStatus = "Mihomo 设置保存失败；原配置保持不变。";
        }
    }

    [RelayCommand]
    private void SaveMihomoControllerSecret()
    {
        var byteCount = Encoding.UTF8.GetByteCount(MihomoControllerSecret);
        if (string.IsNullOrWhiteSpace(MihomoControllerSecret)
            || !MihomoControllerSecret.Equals(MihomoControllerSecret.Trim(), StringComparison.Ordinal)
            || MihomoControllerSecret.Length > 1024
            || byteCount > 4096
            || MihomoControllerSecret.Any(char.IsControl))
        {
            MihomoStatus = "Mihomo Controller 凭证需要 1–1024 个无首尾空白的非控制字符，且不超过 4096 字节。";
            return;
        }

        try
        {
            _vault.Write(
                MihomoSettings.ControllerSecretCredentialTarget,
                MihomoControllerSecret);
            MihomoControllerSecret = string.Empty;
            MihomoStatus = "Mihomo Controller 凭证已保存到 Windows Credential Manager；输入框已清空且不会回填。";
        }
        catch (Exception exception) when (exception is PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        {
            MihomoStatus = "Windows Credential Manager 不可用；Controller 凭证未保存。";
        }
    }

    [RelayCommand]
    private void DeleteMihomoControllerSecret()
    {
        try
        {
            _vault.Delete(MihomoSettings.ControllerSecretCredentialTarget);
            MihomoControllerSecret = string.Empty;
            MihomoStatus = "Mihomo Controller 凭证已从 Windows Credential Manager 删除。";
        }
        catch (Exception exception) when (exception is PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        {
            MihomoStatus = "Mihomo Controller 凭证删除失败；未改变已保存状态。";
        }
    }

    [RelayCommand]
    private async Task StartMihomoAsync()
    {
        if (_mihomoLifecycle is null)
        {
            MihomoStatus = "当前环境没有配置 Mihomo 生命周期服务；继续失败关闭。";
            return;
        }
        try
        {
            var controllerAuthorizationToken = _vault.Read(
                MihomoSettings.ControllerSecretCredentialTarget);
            await _mihomoLifecycle.StartAsync(new MihomoRuntimeOptions(
                MihomoExecutablePath,
                MihomoConfigurationPath,
                MihomoControllerPort,
                TimeSpan.FromSeconds(15),
                TimeSpan.FromSeconds(3),
                controllerAuthorizationToken)).ConfigureAwait(true);
            var selected = _configuration.Nodes.SingleOrDefault(node => node.IsSelected && node.SelectorGroup is not null);
            if (selected is not null)
            {
                await _mihomoLifecycle.SelectNodeAsync(
                    selected.SelectorGroup!,
                    selected.Name,
                    CancellationToken.None).ConfigureAwait(true);
                MihomoStatus = $"Mihomo 已启动并恢复节点“{selected.Name}”：回环 controller 127.0.0.1:{MihomoControllerPort}。";
            }
            else
            {
                MihomoStatus = $"Mihomo 已启动：回环 controller 127.0.0.1:{MihomoControllerPort}。";
            }
        }
        catch (Exception exception) when (exception is MihomoRuntimeConfigurationException or MihomoRuntimeUnavailableException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        {
            if (_mihomoLifecycle.IsReady)
            {
                try { await _mihomoLifecycle.StopAsync().ConfigureAwait(true); }
                catch (Exception stopException) when (stopException is MihomoRuntimeUnavailableException or OperationCanceledException) { }
            }
            MihomoStatus = "Mihomo 启动或节点恢复失败：检查 mihomo.exe、配置、已分配回环端口、选择器组名及 Controller 鉴权；当前失败关闭。";
        }
    }

    [RelayCommand]
    private async Task StopMihomoAsync()
    {
        if (_mihomoLifecycle is not null) { await _mihomoLifecycle.StopAsync().ConfigureAwait(true); }
        MihomoStatus = "Mihomo 已停止；已分配模型将失败关闭，不会直连。";
    }

    private async Task RefreshSubscriptionCoreAsync(string displayName, Uri proxy)
    {
        _subscriptionCancellation?.Cancel();
        _subscriptionCancellation?.Dispose();
        _subscriptionCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        IsSubscriptionBusy = true;
        Status = "正在有界下载并解析 Clash/Mihomo HTTPS 订阅…";
        try
        {
            var ownedPayload = await _subscriptionClient!.FetchAsync(
                _subscriptionSource!,
                _subscriptionCancellation.Token).ConfigureAwait(true);
            ProxySubscriptionSnapshot snapshot;
            try { snapshot = ProxySubscriptionParser.Parse(ownedPayload, displayName, DateTimeOffset.UtcNow); }
            finally { CryptographicOperations.ZeroMemory(ownedPayload); }
            if (snapshot.Nodes.Count > 256) { throw new ProxySubscriptionLimitException("UI configuration supports at most 256 nodes."); }
            var selectedName = _configuration.Nodes.SingleOrDefault(node => node.IsSelected)?.Name;
            var canRestoreSelection = selectedName is not null
                && snapshot.Nodes.Any(node => node.Name.Equals(selectedName, StringComparison.Ordinal));
            var selectorGroup = MihomoProxyGroup.Trim();
            var nodes = snapshot.Nodes.Select((node, index) => new NodeConfiguration(
                node.Id,
                node.Name,
                proxy,
                canRestoreSelection
                    ? node.Name.Equals(selectedName, StringComparison.Ordinal)
                    : index == 0,
                selectorGroup)).ToArray();
            Persist(_configuration with { Nodes = nodes });
            Status = $"已导入 {nodes.Length} 个节点卡片；选择或测速会先在 Mihomo 组“{selectorGroup}”切换真实节点。";
        }
        catch (OperationCanceledException) { Status = "订阅导入/刷新已取消；原节点保持不变。"; }
        catch (Exception exception) when (exception is HttpRequestException or ProxySubscriptionSecurityException or ProxySubscriptionFormatException or ProxySubscriptionLimitException or IOException)
        {
            Status = "订阅导入/刷新失败；没有保存部分节点或订阅凭证。";
        }
        finally { IsSubscriptionBusy = false; RefreshCollections(); }
    }

    private async Task<bool> SelectNodeCoreAsync(NodeConfiguration node)
    {
        if (node.SelectorGroup is not null)
        {
            if (_mihomoLifecycle is null || !_mihomoLifecycle.IsReady)
            {
                Status = $"无法选择“{node.Name}”：Mihomo Controller 未就绪；选择未保存且不会直连。";
                return false;
            }

            try
            {
                await _mihomoLifecycle.SelectNodeAsync(
                    node.SelectorGroup,
                    node.Name,
                    CancellationToken.None).ConfigureAwait(true);
            }
            catch (Exception exception) when (exception is MihomoRuntimeConfigurationException or MihomoRuntimeUnavailableException or OperationCanceledException)
            {
                Status = $"Mihomo 未能切换到“{node.Name}”；原选择保持不变且不会直连。";
                return false;
            }
        }

        var nextConfiguration = _configuration with
        {
            Nodes = _configuration.Nodes.Select(candidate => candidate with
            {
                IsSelected = candidate.Id == node.Id,
            }).ToArray(),
        };
        _configurationStore.Save(nextConfiguration);
        _configuration = nextConfiguration;
        _configurationState.Replace(nextConfiguration);
        Status = node.SelectorGroup is null
            ? $"已选择独立代理节点“{node.Name}”。"
            : $"Mihomo 已切换并选择节点“{node.Name}”。";
        RefreshCollections();
        return true;
    }

    private static bool IsSafeSelectorGroup(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Equals(value.Trim(), StringComparison.Ordinal)
        && value.Length <= 128
        && !value.Any(char.IsControl);

    [RelayCommand]
    private void AssignModelToNode()
    {
        if (SelectedAssignmentModel is null || SelectedAssignmentNode is null) { AssignmentStatus = "请选择精确供应商+模型和节点。"; return; }
        var assignment = new ModelNodeAssignment(SelectedAssignmentModel.ProviderId, SelectedAssignmentModel.ModelId, SelectedAssignmentNode.Id);
        var assignments = (_configuration.ModelNodeAssignments ?? []).Where(candidate => candidate.ProviderId != assignment.ProviderId || !candidate.ModelId.Equals(assignment.ModelId, StringComparison.Ordinal)).Append(assignment).ToArray();
        Persist(_configuration with { ModelNodeAssignments = assignments });
        UpdateAssignmentStatus(assignment);
    }

    [RelayCommand]
    private void ClearModelNodeAssignment()
    {
        if (SelectedAssignmentModel is null) { return; }
        var assignments = (_configuration.ModelNodeAssignments ?? []).Where(candidate => candidate.ProviderId != SelectedAssignmentModel.ProviderId || !candidate.ModelId.Equals(SelectedAssignmentModel.ModelId, StringComparison.Ordinal)).ToArray();
        Persist(_configuration with { ModelNodeAssignments = assignments });
        AssignmentStatus = "已清除分配；该模型将失败关闭，不会直连。";
    }

    private void UpdateAssignmentStatus(ModelNodeAssignment assignment)
    {
        var decision = new ModelNodeAssignmentService(_configuration.ModelNodeAssignments ?? []).Resolve(assignment.ProviderId, assignment.ModelId, _configuration.Nodes, _mihomoRuntime);
        AssignmentStatus = decision.Kind == ModelNodeRouteKind.Proxy
            ? $"已分配到回环代理 {decision.ProxyUri}；请求不会直连。"
            : $"分配已保存，但当前阻止请求（{decision.ErrorCode}）；不会回退到直连。";
    }

    [RelayCommand]
    private void AddRouteTarget()
    {
        if (SelectedRouteModel is null || RoutePriority is < 0 or > 999 || RouteWeight is < 1 or > 10_000) { Status = "路由目标需要模型、0-999 优先级和 1-10000 权重。"; return; }
        if (RouteTargetDrafts.Any(target => target.ProviderId == SelectedRouteModel.ProviderId && target.ModelId == SelectedRouteModel.ModelId)) { Status = "路由目标不能重复。"; return; }
        RouteTargetDrafts.Add(new RouteTargetDraftViewModel(SelectedRouteModel.ProviderId, SelectedRouteModel.ModelId, SelectedRouteModel.Label, RoutePriority, RouteWeight));
    }

    [RelayCommand]
    private void ClearRouteTargets() => RouteTargetDrafts.Clear();

    [RelayCommand]
    private void SaveRoute()
    {
        var route = new ModelRouteDefinition(RouteAlias.Trim(), RouteEnabled, SelectedRouteStrategy, RouteTargetDrafts.Select(target => new ModelRouteTarget(target.ProviderId, target.ModelId, target.Priority, target.Weight)).ToArray());
        if (!route.IsValid || _configuration.Providers.SelectMany(provider => provider.Models).Any(model => model.Id == route.Alias)) { Status = "路由 alias/目标无效，或 alias 与真实模型 ID 冲突。"; return; }
        var routes = (_configuration.Routes ?? []).Where(candidate => !candidate.Alias.Equals(route.Alias, StringComparison.Ordinal)).Append(route).ToArray();
        Persist(_configuration with { Routes = routes });
        RouteAlias = string.Empty;
        RouteTargetDrafts.Clear();
        Status = "模型路由已保存。";
    }

    [RelayCommand]
    private void ToggleRoute(string alias)
    {
        Persist(_configuration with { Routes = (_configuration.Routes ?? []).Select(route => route.Alias == alias ? route with { IsEnabled = !route.IsEnabled } : route).ToArray() });
    }

    [RelayCommand]
    private void DeleteRoute(string alias) => Persist(_configuration with { Routes = (_configuration.Routes ?? []).Where(route => route.Alias != alias).ToArray() });

    [RelayCommand]
    private void SaveEndpointPath()
    {
        if (SelectedEndpointProvider is null || !ConfigurationStore.IsSafeEndpointPath(EndpointPath)) { Status = "端点路径必须是安全的根相对路径。"; return; }
        var poll = string.IsNullOrWhiteSpace(EndpointPollPath) ? null : EndpointPollPath.Trim();
        var entry = new ProviderEndpointPath(SelectedEndpointProvider.Provider.Id, SelectedEndpointKind, EndpointPath.Trim(), EndpointIsAsynchronous, poll, SelectedTaskIdentifierField);
        var endpoints = (_configuration.ProviderEndpointPaths ?? []).Where(candidate => candidate.ProviderId != entry.ProviderId || candidate.Endpoint != entry.Endpoint).Append(entry).ToArray();
        try { Persist(_configuration with { ProviderEndpointPaths = endpoints }); Status = "供应商端点协议已保存。"; }
        catch (InvalidOperationException) { Status = "异步端点需要安全的 task_id 轮询路径模板。"; }
    }

    [RelayCommand]
    private async Task StartBatchHealthVerificationAsync()
    {
        if (_batchHealthVerifier is null || IsHealthVerificationRunning) { HealthVerificationStatus = "当前环境未配置真实健康验证探针。"; return; }
        var targets = Models.Select(model => new ModelHealthTarget(model.ProviderId, model.ModelId)).ToArray();
        _healthCancellation?.Dispose();
        _healthCancellation = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        IsHealthVerificationRunning = true;
        HealthProgress = 0;
        HealthVerificationStatus = $"正在验证 {targets.Length} 个模型；请求可能计费…";
        try
        {
            var completed = 0;
            foreach (var batch in targets.Chunk(16))
            {
                var results = await _batchHealthVerifier.VerifyAsync(batch, _healthCancellation.Token).ConfigureAwait(true);
                foreach (var result in results)
                {
                    _health.RecordModel(result);
                    var subject = $"{Models.Single(model => model.ProviderId == result.Target.ProviderId && model.ModelId == result.Target.ModelId).Label}";
                    if (result.State == HealthState.Healthy) { _health.RecordSuccess(subject, TimeSpan.FromMilliseconds(result.LatencyMilliseconds ?? 0), result.DetailCode); }
                    else if (result.State == HealthState.Failed) { _health.RecordFailure(subject, result.DetailCode); }
                    else { _health.RecordDegraded(subject, result.DetailCode); }
                }
                completed += batch.Length;
                HealthProgress = targets.Length == 0 ? 100 : completed * 100 / targets.Length;
                RefreshHealth();
            }
            HealthVerificationStatus = $"批量健康验证完成：{targets.Length} 个模型。瞬态/配额/凭证故障不会永久隔离。";
        }
        catch (OperationCanceledException) { HealthVerificationStatus = "批量健康验证已取消；已完成的观测保留。"; }
        finally { IsHealthVerificationRunning = false; }
    }

    [RelayCommand]
    private void CancelBatchHealthVerification() => _healthCancellation?.Cancel();

    [RelayCommand]
    private async Task ExportConfigurationAsync()
    {
        try { await _configurationExchange.ExportAsync(_configuration, ConfigurationFilePath).ConfigureAwait(true); Status = "已导出非秘密配置；API Key、OAuth token、Controller 凭证、订阅 URL 和 Mihomo 本机路径/端口未包含。"; }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException) { Status = "配置导出失败；未写入部分文件。"; }
    }

    [RelayCommand]
    private async Task ImportConfigurationAsync()
    {
        try
        {
            var imported = await _configurationExchange.ImportAsync(ConfigurationFilePath).ConfigureAwait(true);
            Persist(imported with { Mihomo = _configuration.Mihomo });
            Status = "已导入并验证非秘密配置；Mihomo 本机运行设置与 Credential Manager 凭证保持不变。";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException) { Status = "配置导入失败；当前配置保持不变。"; }
    }

    [RelayCommand]
    private void GenerateGatewayToken()
    {
        GatewayToken = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        Status = "已生成 256 位随机令牌；保存后将清空输入框。";
    }

    [RelayCommand]
    private async Task PrepareDeveloperOAuthAsync()
    {
        if (_developerOAuthFactory is null)
        {
            Status = "当前环境没有启用开发者 OAuth。";
            return;
        }
        if (!OAuthClientId.EndsWith(".apps.googleusercontent.com", StringComparison.Ordinal) || OAuthClientId.Length is < 32 or > 512)
        {
            Status = "请输入你自己 Google Cloud 项目创建的 Desktop client ID。";
            return;
        }
        if (!IsSafeCloudProjectId(OAuthCloudProject) || !Uri.TryCreate(OAuthRedirectUri, UriKind.Absolute, out var redirect))
        {
            Status = "请输入自己的 Cloud project ID，并使用精确的 127.0.0.1 OAuth 回调地址。";
            return;
        }
        try
        {
            _developerOAuth?.Dispose();
            _developerOAuth = _developerOAuthFactory(new DeveloperOAuthRegistration(
                DeveloperOAuthProvider.GoogleGemini,
                OAuthClientId.Trim(),
                redirect,
                ["https://www.googleapis.com/auth/generative-language"],
                Guid.NewGuid()));
            OAuthAuthorizationUrl = _developerOAuth.AuthorizationUri.AbsoluteUri;
            var callbackTask = _developerOAuth.ListenAndRedeemCallbackAsync();
            _browser.Open(_developerOAuth.AuthorizationUri);
            Status = $"已为 Cloud project“{OAuthCloudProject.Trim()}”打开一次性 PKCE 授权。仅接受 127.0.0.1 的单次回调；应用不会显示或回填令牌。";
            await callbackTask.ConfigureAwait(true);
            Status = _vault.Exists(_developerOAuth.RefreshCredentialTarget)
                ? "开发者 OAuth 已完成；访问令牌与续期令牌已分离保存到 Windows Credential Manager。"
                : "开发者 OAuth 已完成；授权端未返回续期令牌，到期后需要重新授权。";
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or HttpRequestException or HttpListenerException or TimeoutException or TaskCanceledException)
        {
            Status = "开发者 OAuth 未完成；配置、浏览器或一次性回环回调未通过安全校验。";
        }
        finally
        {
            _developerOAuth?.Dispose();
            _developerOAuth = null;
            OAuthAuthorizationUrl = string.Empty;
        }
    }

    [RelayCommand]
    private async Task CheckForUpdateAsync()
    {
        if (!CanCheckUpdates) { return; }
        CanCheckUpdates = false;
        CanDownloadUpdate = false;
        CanRestartToUpdate = false;
        UpdateProgress = 0;
        UpdateStatus = "正在显式检查项目官方更新源…";
        try
        {
            _updateCandidate = await _updates.CheckAsync().ConfigureAwait(true);
            CanDownloadUpdate = _updateCandidate is not null;
            UpdateStatus = _updateCandidate is null ? "当前已是最新版本。" : $"发现版本 {_updateCandidate.Version}（{FormatBytes(_updateCandidate.SizeBytes)}）；尚未下载。";
        }
        catch (Exception exception) when (exception is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            _updateCandidate = null;
            UpdateStatus = "更新检查失败；当前版本保持不变。";
        }
        finally { CanCheckUpdates = _updates.IsInstalled; }
    }

    [RelayCommand]
    private async Task DownloadUpdateAsync()
    {
        var candidate = _updateCandidate;
        if (!CanDownloadUpdate || candidate is null) { return; }
        CanDownloadUpdate = false;
        UpdateStatus = $"正在显式下载版本 {candidate.Version}…";
        try
        {
            await _updates.StageAsync(candidate, value => UpdateProgress = value).ConfigureAwait(true);
            CanRestartToUpdate = true;
            UpdateStatus = $"版本 {candidate.Version} 已下载并暂存；只有点击“重启并更新”才会安装。";
        }
        catch (Exception exception) when (exception is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            UpdateProgress = 0;
            CanDownloadUpdate = true;
            UpdateStatus = "更新下载失败；当前版本保持不变。";
        }
    }

    [RelayCommand]
    private void RestartToUpdate()
    {
        if (!CanRestartToUpdate) { return; }
        try { _updates.ApplyStagedAndRestart(); }
        catch (InvalidOperationException) { CanRestartToUpdate = false; UpdateStatus = "暂存更新不可用；没有替换当前版本。"; }
    }

    private void RefreshCollections()
    {
        Providers.Clear();
        foreach (var provider in _configuration.Providers.OrderBy(provider => provider.DisplayName, StringComparer.OrdinalIgnoreCase))
        {
            Providers.Add(new ProviderRowViewModel(provider));
        }
        Models.Clear();
        foreach (var provider in _configuration.Providers.OrderBy(provider => provider.DisplayName, StringComparer.OrdinalIgnoreCase))
        {
            foreach (var model in provider.Models.OrderBy(model => model.Id, StringComparer.Ordinal)) { Models.Add(new ModelChoiceViewModel(provider.Id, model.Id, $"{provider.DisplayName} / {model.Id}")); }
        }
        Nodes.Clear();
        foreach (var node in _configuration.Nodes.Where(node => string.IsNullOrWhiteSpace(NodeSearch) || node.Name.Contains(NodeSearch.Trim(), StringComparison.OrdinalIgnoreCase)).OrderByDescending(node => node.IsSelected).ThenBy(node => node.Name, StringComparer.OrdinalIgnoreCase))
        {
            Nodes.Add(new NodeRowViewModel(node));
        }
        Routes.Clear();
        foreach (var route in (_configuration.Routes ?? []).OrderBy(route => route.Alias, StringComparer.Ordinal)) { Routes.Add(new RouteRowViewModel(route)); }
        EndpointPaths.Clear();
        foreach (var endpoint in (_configuration.ProviderEndpointPaths ?? []).OrderBy(endpoint => endpoint.ProviderId).ThenBy(endpoint => endpoint.Endpoint)) { EndpointPaths.Add(new EndpointRowViewModel(endpoint, _configuration.Providers.Single(provider => provider.Id == endpoint.ProviderId).DisplayName)); }
        RefreshHealth();
    }

    partial void OnNodeSearchChanged(string value) => RefreshCollections();

    private void Persist(ModelHubConfiguration nextConfiguration)
    {
        _configurationStore.Save(nextConfiguration);
        _configuration = nextConfiguration;
        _configurationState.Replace(nextConfiguration);
        RefreshCollections();
    }

    private void RefreshHealth()
    {
        Health.Clear();
        foreach (var snapshot in _health.Snapshot())
        {
            Health.Add(new HealthRowViewModel(snapshot));
        }
    }

    private static Uri EnsureTrailingSlash(Uri uri) => uri.AbsoluteUri.EndsWith('/') ? uri : new Uri(uri.AbsoluteUri + "/");
    private static bool IsSafeCloudProjectId(string value) => value.Length is >= 6 and <= 63 && value[0] != '-' && value[^1] != '-' && value.All(character => char.IsAsciiLetterOrDigit(character) || character == '-');
    private static string FormatBytes(long value) => value >= 1024 * 1024 ? $"{value / (1024d * 1024d):0.0} MiB" : $"{Math.Max(0, value) / 1024d:0.0} KiB";
    public void Dispose()
    {
        MihomoControllerSecret = string.Empty;
        _subscriptionCancellation?.Cancel();
        _subscriptionCancellation?.Dispose();
        _healthCancellation?.Cancel();
        _healthCancellation?.Dispose();
        _developerOAuth?.Dispose();
        _developerOAuth = null;
        if (_ownsUpdates) { _updates.Dispose(); }
        if (_subscriptionClient is IDisposable disposable) { disposable.Dispose(); }
    }

    private sealed class DisabledUpdateEngine : IWindowsUpdateEngine
    {
        public bool IsInstalled => false;
        public Task<WindowsUpdateCandidate?> CheckAsync(CancellationToken cancellationToken) => Task.FromResult<WindowsUpdateCandidate?>(null);
        public Task DownloadAsync(WindowsUpdateCandidate candidate, Action<int>? progress, CancellationToken cancellationToken) => throw new InvalidOperationException("Updates are disabled for this portable session.");
        public void ApplyAndRestart(WindowsUpdateCandidate candidate) => throw new InvalidOperationException("Updates are disabled for this portable session.");
    }
}

public sealed record ProviderRowViewModel(ProviderConfiguration Provider)
{
    public string Name => Provider.DisplayName;
    public string Endpoint => Provider.BaseUri.GetLeftPart(UriPartial.Authority);
    public string Models => string.Join(", ", Provider.Models.Select(model => model.Id));
    public string Protocol => Provider.Protocol switch { ProviderProtocol.OpenAICompatible => "OpenAI 兼容", ProviderProtocol.Anthropic => "Anthropic", ProviderProtocol.Gemini => "Gemini", _ => "未知协议" };
    public string State => Provider.IsEnabled ? "已启用" : "已停用";
}

public sealed record NodeRowViewModel(NodeConfiguration Node)
{
    public Guid Id => Node.Id;
    public string Name => Node.Name;
    public string Endpoint => Node.ProxyUri.ToString();
    public string State => Node.IsSelected ? "当前节点" : "可选择";
}

public sealed record HealthRowViewModel(HealthSnapshot Snapshot)
{
    public string Subject => Snapshot.Subject;
    public string State => Snapshot.State.ToString();
    public string Detail => Snapshot.LatencyMilliseconds is int latency ? $"{Snapshot.Detail} · {latency} ms" : Snapshot.Detail;
}

public sealed record ModelChoiceViewModel(Guid ProviderId, string ModelId, string Label);
public sealed record RouteTargetDraftViewModel(Guid ProviderId, string ModelId, string Label, int Priority, int Weight);

public sealed record RouteRowViewModel(ModelRouteDefinition Route)
{
    public string Alias => Route.Alias;
    public string State => Route.IsEnabled ? "已启用" : "已停用";
    public string Detail => $"{Route.Strategy} · {Route.Targets.Count} 个目标";
}

public sealed record EndpointRowViewModel(ProviderEndpointPath Endpoint, string ProviderName)
{
    public string Detail => $"{Endpoint.Endpoint}: {Endpoint.Path}" + (Endpoint.IsAsynchronous ? $" → {Endpoint.PollPathTemplate} ({Endpoint.TaskIdentifierField})" : string.Empty);
}
