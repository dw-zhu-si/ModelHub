import AppKit
import Foundation
import ModelHubCore
import ModelHubWidgetSupport
import ServiceManagement
import UniformTypeIdentifiers
import WidgetKit

private struct GatewayAccessContext: Sendable {
    let virtualKeyID: UUID?
    let workspaceID: UUID?
    let allowedModels: Set<String>
    let accessPolicy: RoutingAccessPolicy

    static let primary = GatewayAccessContext(
        virtualKeyID: nil,
        workspaceID: nil,
        allowedModels: [],
        accessPolicy: .unrestricted
    )
}

private enum GatewayRequestScope {
    @TaskLocal static var access: GatewayAccessContext?
    @TaskLocal static var requestID: String?
}

/// Immutable request-scoped state copied from the UI model in one bounded hop.
/// Expensive JSON/context work, routing, Keychain lookup and upstream I/O then
/// execute on the cooperative executor instead of serializing SwiftUI updates.
private struct GatewayDataPlaneSnapshot: Sendable {
    let providers: [ProviderConfig]
    let routes: [RouteConfig]
    let health: ModelHealthIndex
    let usage: [UsageAggregate]
    let routingRule: DefaultRoutingRule
    let accessPolicy: RoutingAccessPolicy
    let resilienceSettings: ResilienceSettings
    let contextOptimization: ContextOptimizationSettings
    let budget: BudgetSettings
    let router: RoutingEngine
    let providerClient: ProviderClient
    let resilience: ResilienceController
}

private struct GatewayUsageSample: Sendable {
    let tokens: UsageTokenCounts
    let estimatedCostUSD: Double?
}

private struct GatewayCacheRequestMetadata: Sendable {
    let model: String
}

/// Binds an upstream request to the exact automatic-failover node selected for
/// that attempt. Late responses from an older node must never mutate the state
/// of a newer active node.
private struct GatewayProxyAttempt: Sendable {
    let endpoint: ProviderProxyEndpoint?
    let failoverNodeID: String?
}

/// A stream may expose EOF only after the target slot and node outcome have
/// been finalized. Keeping this gate testable prevents regressions where the
/// next request races stale in-flight or failover state.
struct GatewayStreamingTargetFinalizer {
    static func finishBeforeEOF(
        resilience: ResilienceController,
        runtimeKey: TargetRuntimeKey,
        succeeded: Bool,
        transientFailure: Bool,
        settings: ResilienceSettings,
        observeProxyOutcome: @Sendable () async -> Void
    ) async {
        // Publish the outcome while the completed attempt still owns its slot,
        // so a newly admitted request cannot race this feedback and switch the
        // node before the older success is applied.
        await observeProxyOutcome()
        await resilience.finishTarget(
            runtimeKey,
            succeeded: succeeded,
            transientFailure: transientFailure,
            settings: settings
        )
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case providers
    case routes
    case analytics
    case operations
    case governance
    case console
    case logs
    case proxy
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "概览", locale: AppLanguage.saved.locale)
        case .providers: String(localized: "模型供应商", locale: AppLanguage.saved.locale)
        case .routes: String(localized: "模型路由", locale: AppLanguage.saved.locale)
        case .analytics: String(localized: "用量分析", locale: AppLanguage.saved.locale)
        case .operations: String(localized: "路由与协议", locale: AppLanguage.saved.locale)
        case .governance: String(localized: "访问与安全", locale: AppLanguage.saved.locale)
        case .console: String(localized: "API 调试", locale: AppLanguage.saved.locale)
        case .logs: String(localized: "请求日志", locale: AppLanguage.saved.locale)
        case .proxy: String(localized: "代理订阅", locale: AppLanguage.saved.locale)
        case .settings: String(localized: "服务设置", locale: AppLanguage.saved.locale)
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .providers: "server.rack"
        case .routes: "arrow.triangle.branch"
        case .analytics: "chart.xyaxis.line"
        case .operations: "switch.2"
        case .governance: "lock.shield"
        case .console: "terminal"
        case .logs: "list.bullet.rectangle"
        case .proxy: "network.badge.shield.half.filled"
        case .settings: "gearshape"
        }
    }
}

enum ConsoleOperation: String, CaseIterable, Identifiable {
    case chat
    case musicGeneration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: String(localized: "文字聊天", locale: AppLanguage.saved.locale)
        case .musicGeneration: String(localized: "音乐生成", locale: AppLanguage.saved.locale)
        }
    }
}

struct ModelHealthSummary: Equatable {
    let total: Int
    let available: Int
    let unavailable: Int
    let unknown: Int
    let configurationRequired: Int
    let unsupported: Int
}

struct ModelTestProgress: Equatable {
    let total: Int
    var completed: Int
    var available: Int
    var unavailable: Int
    var skipped: Int
    var currentProvider: String
    var isCancelled: Bool

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

struct ModelPriceRefreshProgress: Equatable {
    let total: Int
    var completed: Int

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

enum ProxyNodeLatencyFailure: Equatable, Sendable {
    case subscriptionUnavailable
    case runtimeUnavailable
    case timeout
    case controllerRejected(statusCode: Int)
    case invalidResponse
    case unknown

    static func classify(_ error: Error) -> Self {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timeout
        }
        guard let runtimeError = error as? ProxySubscriptionRuntimeError else {
            return .unknown
        }
        switch runtimeError {
        case .nodeDelayHTTPStatus(let statusCode):
            return .controllerRejected(statusCode: statusCode)
        case .nodeDelayInvalidResponse:
            return .invalidResponse
        case .nodeDelayFailed:
            return .timeout
        case .controllerUnavailable, .providerNotLoaded, .coreExited,
             .missingCore, .coreValidationFailed:
            return .runtimeUnavailable
        default:
            return .unknown
        }
    }

    var shortDescription: String {
        switch self {
        case .subscriptionUnavailable: L10n.text("订阅尚未就绪")
        case .runtimeUnavailable: L10n.text("节点内核未就绪")
        case .timeout: L10n.text("访问外网超时")
        case .controllerRejected(let statusCode):
            L10n.format("节点内核 HTTP %d", statusCode)
        case .invalidResponse: L10n.text("测速响应无效")
        case .unknown: L10n.text("外网测速失败")
        }
    }
}

struct ProxyNodeLatencyResult: Equatable, Sendable {
    let latencyMilliseconds: Int?
    let testedAt: Date
    let failure: ProxyNodeLatencyFailure?

    init(
        latencyMilliseconds: Int?,
        testedAt: Date,
        failure: ProxyNodeLatencyFailure? = nil
    ) {
        self.latencyMilliseconds = latencyMilliseconds
        self.testedAt = testedAt
        self.failure = latencyMilliseconds == nil ? (failure ?? .unknown) : nil
    }

    var succeeded: Bool { latencyMilliseconds != nil }
}

private struct ModelTestTarget: Sendable {
    let provider: ProviderConfig
    let model: String
    let apiKey: String
    let proxy: ProviderProxyEndpoint?

    var key: String {
        AppModel.modelTestKey(providerID: provider.id, model: model)
    }
}

enum ModelTestProxyPreflightDecision: Equatable, Sendable {
    case ready
    case requiresManagedRuntimeRecovery
}

enum ModelTestProxyPreflightPolicy {
    nonisolated static func decision(
        settings: ModelProxySettings,
        providerID: UUID,
        model: String,
        managedRuntimeIsRunning: Bool
    ) -> ModelTestProxyPreflightDecision {
        guard settings.enabled, !managedRuntimeIsRunning else { return .ready }
        let exactModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.assignments.contains(where: {
            $0.providerID == providerID && $0.model == exactModel
        }) else {
            return .ready
        }
        return .requiresManagedRuntimeRecovery
    }
}

private struct ProxyNodeLatencyMeasurement: Sendable {
    let nodeID: String
    let latencyMilliseconds: Int?
    let failure: ProxyNodeLatencyFailure?
}

struct ManualModelTestCandidate: Sendable {
    let provider: ProviderConfig
    let model: String
}

struct ManualModelTestPlan: Sendable {
    let candidates: [ManualModelTestCandidate]
    let preflightSkipped: Int
}

enum DataPlaneCredentialAccessPolicy {
    static let allowsInteraction = false

    static func apiKey(from result: KeychainStore.LookupResult) throws -> String {
        switch result {
        case .value(let value): return value
        case .notFound: return ""
        case .interactionRequired, .failure:
            throw ProviderClientError.credentialAccessUnavailable
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .overview
    @Published var configuration = AppConfiguration()
    @Published var logs: [GatewayLogEntry] = []
    @Published var isServerRunning = false
    @Published var activePort: UInt16?
    @Published var serverError: String?
    @Published var notice: String?
    @Published var totalRequests = 0
    @Published var successfulRequests = 0
    @Published var consoleOutput = ""
    @Published var consoleIsRunning = false
    @Published private(set) var isTestingModels = false
    @Published private(set) var testingModelIDs: Set<String> = []
    @Published private(set) var modelTestProgress: ModelTestProgress?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequested = false
    @Published private(set) var launchAtLoginStatusText = String(localized: "尚未启用", locale: AppLanguage.saved.locale)
    @Published private(set) var preferredLanguage = AppLanguage.saved
    @Published private(set) var isReviewDemoMode = false
    @Published private(set) var isProviderLayoutStressDemo = false
    @Published private(set) var lastIssuedVirtualKeyToken: String?
    @Published private(set) var isRefreshingModelPrices = false
    @Published private(set) var modelPriceRefreshProgress: ModelPriceRefreshProgress?
    @Published private(set) var refreshingProviderCatalogIDs: Set<UUID> = []
    @Published private(set) var isRefreshingCurrencyRates = false
    @Published private(set) var refreshingProxySubscriptionIDs: Set<UUID> = []
    @Published private(set) var proxySubscriptionMessages: [UUID: String] = [:]
    @Published private(set) var proxyRuntimeStatus = String(localized: "未启动", locale: AppLanguage.saved.locale)
    @Published private(set) var testingProxyNodeIDs: Set<String> = []
    @Published private(set) var proxyNodeLatencyResults: [String: ProxyNodeLatencyResult] = [:]

    private let router = RoutingEngine()
    private let providerClient = ProviderClient()
    private let resilience = ResilienceController()
    private let scopedRateLimiter = ScopedRateLimiter()
    private let responseCache = BoundedResponseCache()
    private let configurationPersistence = ConfigurationPersistence()
    private let currencyRateClient = CurrencyRateClient()
    private let modelProxyRuntime = ModelProxyRuntimeManager()
    private var server: LocalAPIServer?
    private var didBootstrap = false
    private var modelTestTask: Task<Void, Never>?
    private var pendingPersistenceTask: Task<Void, Never>?
    private var persistenceRevision: UInt64 = 0
    private var hasUnflushedConfigurationChanges = false
    private var pendingWidgetPublicationTask: Task<Void, Never>?
    private var widgetSnapshotWriteInFlight = false
    private var pricingUpdateTask: Task<Void, Never>?
    private var proxySubscriptionUpdateTask: Task<Void, Never>?
    private var proxyNodeLatencyTask: Task<Void, Never>?
    private var healthIndex = ModelHealthIndex(records: [])
    private var proxyEndpointIndex = ModelProxyEndpointIndex(settings: .init())
    private var proxyFailoverIndex = ModelProxyFailoverIndex(settings: .init())
    private var proxyFailoverStates: [String: ModelProxyFailoverState] = [:]
    private var exhaustedProxyFailoverKeys: Set<String> = []
    private var availableModelListCache: HTTPResponse?
    private var availableModelListCacheExpiresAt: Date?
    private var providerListCache: HTTPResponse?
    private var proxySubscriptionPayloads: [UUID: Data] = [:]
    private var cachedGatewayToken: String?
    private var cachedAgentToken: String?
    private var reviewDemoBackup: ReviewDemoBackup?
    private static let launchAtLoginRequestedKey = "launchAtLoginRequested"
    private static let launchAtLoginStatusKey = "launchAtLoginStatus"
    private static let launchAtLoginErrorKey = "launchAtLoginLastError"
    private static let verificationTimestampFormatter = ISO8601DateFormatter()

    private struct ReviewDemoBackup {
        let configuration: AppConfiguration
        let logs: [GatewayLogEntry]
        let totalRequests: Int
        let successfulRequests: Int
        let consoleOutput: String
        let proxyNodeLatencyResults: [String: ProxyNodeLatencyResult]
    }

    var interfaceLocale: Locale {
        preferredLanguage.locale
    }

    func setPreferredLanguage(_ language: AppLanguage) {
        preferredLanguage = language
        language.save()
        notice = String(localized: "界面语言已更新。", locale: AppLanguage.saved.locale)
    }

    var providers: [ProviderConfig] {
        get { configuration.providers }
        set {
            configuration.providers = newValue
            invalidateCatalogCaches()
        }
    }

    var routes: [RouteConfig] {
        get { configuration.routes }
        set {
            configuration.routes = newValue
            invalidateCatalogCaches()
        }
    }

    var gatewayToken: String {
        if let cachedGatewayToken { return cachedGatewayToken }
        switch KeychainStore.readWithoutInteraction(account: KeychainStore.gatewayTokenAccount) {
        case .value(let existing):
            cachedGatewayToken = existing
            return existing
        case .notFound:
            return createGatewayToken()
        case .interactionRequired:
            if let existing = KeychainStore.read(account: KeychainStore.gatewayTokenAccount) {
                cachedGatewayToken = existing
                return existing
            }
            notice = String(localized: "钥匙串拒绝了访问；请在主动显示或复制令牌时确认一次访问权限。", locale: AppLanguage.saved.locale)
            return ""
        case .failure(let status):
            notice = KeychainStore.KeychainError.status(status).localizedDescription
            return ""
        }
    }

    var agentToken: String {
        if let cachedAgentToken { return cachedAgentToken }
        switch KeychainStore.readWithoutInteraction(account: KeychainStore.agentTokenAccount) {
        case .value(let existing):
            cachedAgentToken = existing
            return existing
        case .notFound:
            return createAgentToken()
        case .interactionRequired:
            if let existing = KeychainStore.read(account: KeychainStore.agentTokenAccount) {
                cachedAgentToken = existing
                return existing
            }
            notice = String(localized: "Agent 令牌的钥匙串访问被拒绝；后台不会重复弹出授权窗口。", locale: AppLanguage.saved.locale)
            return ""
        case .failure(let status):
            notice = KeychainStore.KeychainError.status(status).localizedDescription
            return ""
        }
    }

    var endpointURL: String {
        "\(serverRootURL)/v1"
    }

    var mcpURL: String {
        "\(serverRootURL)/mcp"
    }

    private var serverRootURL: String {
        "http://127.0.0.1:\(activePort ?? configuration.server.port)"
    }

    var successRate: String {
        guard totalRequests > 0 else { return "—" }
        return "\(Int((Double(successfulRequests) / Double(totalRequests)) * 100))%"
    }

    var budgetStatusText: String? {
        guard let limit = configuration.operational.budget.monthlyLimitUSD, limit > 0 else {
            return nil
        }
        let spent = UsageAccounting.currentMonthCost(in: configuration.usage)
        let fraction = spent / limit
        if fraction >= 1 {
            return L10n.format(
                "本月已知价格估算 %@，已达到 %@ 上限。",
                formattedDisplayCost(spent),
                formattedDisplayCost(limit, fractionDigits: 2)
            )
        }
        if fraction >= configuration.operational.budget.warningFraction {
            return L10n.format(
                "本月已知价格估算 %@，已使用预算的 %.0f%%。",
                formattedDisplayCost(spent),
                fraction * 100
            )
        }
        return nil
    }

    var currencyDisplaySettings: CurrencyDisplaySettings {
        (configuration.operational.currencyDisplay ?? .init()).sanitized
    }

    var currencyRateStatusText: String {
        let settings = currencyDisplaySettings
        guard settings.currency != .usd,
              let rate = settings.unitsPerUSD[settings.currency.rawValue]
        else {
            return String(localized: "费用以美元（USD）显示。", locale: AppLanguage.saved.locale)
        }
        let source = settings.rateSource ?? String(
            localized: "已保存汇率",
            locale: AppLanguage.saved.locale
        )
        return L10n.format(
            "1 USD = %.4f %@ · %@",
            rate,
            settings.currency.rawValue,
            source
        )
    }

    func formattedDisplayCost(_ valueUSD: Double, fractionDigits: Int = 4) -> String {
        currencyDisplaySettings.formattedUSD(
            valueUSD,
            minimumFractionDigits: fractionDigits,
            maximumFractionDigits: fractionDigits
        )
    }

    func selectDisplayCurrency(_ currency: DisplayCurrency) {
        guard !isReviewDemoMode, !isRefreshingCurrencyRates else { return }
        var settings = currencyDisplaySettings
        let hasFreshRate = settings.unitsPerUSD[currency.rawValue] != nil
            && settings.rateUpdatedAt.map { Date().timeIntervalSince($0) < 86_400 } == true
        if currency == .usd || hasFreshRate {
            settings.currency = currency
            configuration.operational.currencyDisplay = settings.sanitized
            persistConfiguration()
            return
        }
        Task { await refreshCurrencyRates(selecting: currency) }
    }

    func refreshCurrencyRatesNow() {
        guard !isReviewDemoMode, !isRefreshingCurrencyRates else { return }
        Task { await refreshCurrencyRates(selecting: currencyDisplaySettings.currency) }
    }

    private func refreshCurrencyRates(selecting currency: DisplayCurrency) async {
        guard !isRefreshingCurrencyRates else { return }
        if currency == .usd {
            var settings = currencyDisplaySettings
            settings.currency = .usd
            configuration.operational.currencyDisplay = settings.sanitized
            persistConfiguration()
            return
        }
        isRefreshingCurrencyRates = true
        defer { isRefreshingCurrencyRates = false }
        do {
            let snapshot = try await currencyRateClient.fetch()
            guard snapshot.unitsPerUSD[currency.rawValue] != nil else {
                throw CurrencyRateError.invalidDocument
            }
            var settings = currencyDisplaySettings
            settings.unitsPerUSD.merge(snapshot.unitsPerUSD) { _, new in new }
            settings.currency = currency
            settings.rateUpdatedAt = .now
            settings.rateSource = snapshot.effectiveDate.map {
                "\(snapshot.source) · \($0)"
            } ?? snapshot.source
            configuration.operational.currencyDisplay = settings.sanitized
            persistConfiguration()
            notice = String(localized: "展示币种与官方参考汇率已更新。", locale: AppLanguage.saved.locale)
        } catch {
            notice = L10n.format("官方参考汇率更新失败：%@", error.localizedDescription)
        }
    }

    func enterReviewDemoMode() {
        guard !isReviewDemoMode else { return }
        flushPendingPersistence()
        reviewDemoBackup = ReviewDemoBackup(
            configuration: configuration,
            logs: logs,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            consoleOutput: consoleOutput,
            proxyNodeLatencyResults: proxyNodeLatencyResults
        )
        isReviewDemoMode = true
        configuration = Self.reviewDemoConfiguration()
        rebuildProxyEndpointIndex()
        let demoNodes = (configuration.operational.modelProxy ?? .init()).nodes
        proxyNodeLatencyResults = Dictionary(uniqueKeysWithValues: demoNodes.enumerated().map {
            index, node in
            let latency = index < 2 ? [86, 142][index] : nil
            return (node.id, ProxyNodeLatencyResult(
                latencyMilliseconds: latency,
                testedAt: .now.addingTimeInterval(TimeInterval(-index * 15))
            ))
        })
        logs = Self.reviewDemoLogs()
        totalRequests = 128
        successfulRequests = 124
        consoleOutput = String(localized: "演示模式已就绪。选择任一演示模型并发送请求，可查看本机生成的示例响应。", locale: AppLanguage.saved.locale)
        rebuildHealthIndex()
        selection = .overview
    }

    #if DEBUG
    /// 仅供无凭证界面回归使用：复现批量检测时的高密度供应商布局。
    func prepareProviderLayoutStressDemo() {
        guard isReviewDemoMode, let template = configuration.providers.first else { return }
        isProviderLayoutStressDemo = true
        let names = [
            "seedance",
            "千问AI平台",
            "Agnes AI",
            "云雾 API",
            "claude-fable-5（0.7）",
            "claude-fable-5(0.5)"
        ]
        configuration.providers = names.enumerated().map { index, name in
            var provider = template
            provider.id = UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", 201 + index)
            )!
            provider.name = name
            provider.kind = index == 1 ? .qwen : .unifiedCompatible
            provider.models = (1...max(21, 281 - index * 43)).map {
                "layout-stress-\(index + 1)-\($0)"
            }
            provider.modelProfiles = nil
            provider.endpointURLs = [:]
            return provider
        }
        configuration.modelHealth = []
        configuration.routes = []
        rebuildHealthIndex()
        isTestingModels = true
        modelTestProgress = ModelTestProgress(
            total: 804,
            completed: 441,
            available: 203,
            unavailable: 227,
            skipped: 11,
            currentProvider: "云雾 API",
            isCancelled: false
        )
        selection = .providers
    }
    #endif

    func exitReviewDemoMode() {
        guard isReviewDemoMode, let backup = reviewDemoBackup else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        configuration = backup.configuration
        rebuildProxyEndpointIndex()
        logs = backup.logs
        totalRequests = backup.totalRequests
        successfulRequests = backup.successfulRequests
        consoleOutput = backup.consoleOutput
        proxyNodeLatencyResults = backup.proxyNodeLatencyResults
        reviewDemoBackup = nil
        isReviewDemoMode = false
        isProviderLayoutStressDemo = false
        rebuildHealthIndex()
        selection = .overview
    }

    nonisolated static func reviewDemoConfiguration(now: Date = .now) -> AppConfiguration {
        let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let secondaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let textModel = "review-text-1"
        let reasoningModel = "review-reasoning-1"
        let imageModel = "review-image-1"
        let musicModel = "review-music-1"
        let videoModel = "review-video-1"
        let primaryModels = [textModel, reasoningModel, imageModel, musicModel, videoModel]
        let primaryProfiles: [String: TargetProfile] = [
            textModel: TargetProfile(contextWindow: 128_000, capabilities: [.chat, .tools]),
            reasoningModel: TargetProfile(contextWindow: 64_000, capabilities: [.chat, .reasoning]),
            imageModel: TargetProfile(capabilities: [.imageGeneration]),
            musicModel: TargetProfile(capabilities: [.musicGeneration]),
            videoModel: TargetProfile(capabilities: [.videoGeneration])
        ]
        let providers = [
            ProviderConfig(
                id: primaryID,
                name: "Review Cloud",
                kind: .gemini,
                baseURL: "https://review.invalid",
                models: primaryModels,
                modelProfiles: primaryProfiles
            ),
            ProviderConfig(
                id: secondaryID,
                name: "Review Edge",
                kind: .unifiedCompatible,
                baseURL: "https://review-edge.invalid",
                models: [textModel, reasoningModel],
                modelProfiles: [
                    textModel: TargetProfile(
                        contextWindow: 64_000,
                        inputCostPerMillionTokens: 0.15,
                        outputCostPerMillionTokens: 0.60,
                        capabilities: [.chat, .tools],
                        pricingSource: "Review fixture"
                    ),
                    reasoningModel: TargetProfile(
                        contextWindow: 64_000,
                        capabilities: [.chat, .reasoning]
                    )
                ]
            )
        ]
        let routes = [
            RouteConfig(
                alias: "smart",
                strategy: .balanced,
                targets: [
                    RouteTarget(providerID: primaryID, model: textModel, priority: 0),
                    RouteTarget(providerID: secondaryID, model: textModel, priority: 1)
                ]
            ),
            RouteConfig(
                alias: "reasoning",
                strategy: .lowestLatency,
                targets: [
                    RouteTarget(providerID: primaryID, model: reasoningModel, priority: 0),
                    RouteTarget(providerID: secondaryID, model: reasoningModel, priority: 1)
                ]
            ),
            RouteConfig(
                alias: "creative-media",
                strategy: .priority,
                targets: [
                    RouteTarget(providerID: primaryID, model: imageModel),
                    RouteTarget(providerID: primaryID, model: musicModel),
                    RouteTarget(providerID: primaryID, model: videoModel)
                ]
            )
        ]
        let health = providers.flatMap { provider in
            provider.models.enumerated().map { index, model in
                let isSyntheticTransportFailure = provider.id == primaryID && model == textModel
                return ModelHealthRecord(
                    providerID: provider.id,
                    model: model,
                    status: isSyntheticTransportFailure ? .unavailable : .available,
                    checkedAt: now,
                    latencyMilliseconds: isSyntheticTransportFailure
                        ? nil
                        : 180 + (index * 45),
                    statusCode: isSyntheticTransportFailure ? nil : 200,
                    detail: isSyntheticTransportFailure
                        ? "审核演示数据：网络错误（-1200）"
                        : "审核演示数据：可用"
                )
            }
        }
        let healthActivities = [
            ModelHealthActivity(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                kind: .probe,
                startedAt: now.addingTimeInterval(-150),
                completedAt: now.addingTimeInterval(-120),
                total: 7,
                completed: 7,
                available: 2,
                unavailable: 1,
                skipped: 4,
                transientFailures: 1,
                retryAttempts: 1,
                circuitOpenedProviderIDs: [primaryID],
                circuitSkipped: 4
            )
        ]
        let month = UsageAccounting.monthKey(for: now)
        let usage = [
            UsageAggregate(
                month: month,
                requestedModel: "smart",
                providerID: primaryID,
                providerName: "Review Cloud",
                model: textModel,
                requests: 84,
                successfulRequests: 82,
                totalLatencyMilliseconds: 18_480,
                inputTokens: 31_200,
                outputTokens: 9_600,
                pricedRequests: 84,
                estimatedCostUSD: 0.0104,
                contextCharactersSaved: 12_800,
                lastUsedAt: now
            ),
            UsageAggregate(
                month: month,
                requestedModel: "reasoning",
                providerID: secondaryID,
                providerName: "Review Edge",
                model: reasoningModel,
                requests: 44,
                successfulRequests: 42,
                totalLatencyMilliseconds: 14_520,
                inputTokens: 18_400,
                outputTokens: 7_900,
                pricedRequests: 44,
                estimatedCostUSD: 0.0075,
                contextCharactersSaved: 4_200,
                lastUsedAt: now.addingTimeInterval(-600)
            )
        ]
        let subscriptionID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let subscription = ProxySubscription(
            id: subscriptionID,
            name: "Review Global",
            sourceHost: "subscription.example",
            updateIntervalHours: 24,
            lastUpdatedAt: now.addingTimeInterval(-3_600),
            nodeCount: 3,
            uploadBytes: 1_610_612_736,
            downloadBytes: 12_884_901_888,
            totalBytes: 161_061_273_600,
            expiresAt: now.addingTimeInterval(86_400 * 30)
        )
        let proxyNodes = [
            ProxySubscriptionNode(
                subscriptionID: subscriptionID,
                name: "Hong Kong 01",
                type: "Trojan"
            ),
            ProxySubscriptionNode(
                subscriptionID: subscriptionID,
                name: "Singapore 02",
                type: "VMess"
            ),
            ProxySubscriptionNode(
                subscriptionID: subscriptionID,
                name: "Tokyo 03",
                type: "Shadowsocks"
            )
        ]
        let proxySettings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: proxyNodes,
            assignments: [ModelProxyAssignment(
                providerID: primaryID,
                model: reasoningModel,
                nodeID: proxyNodes[0].id
            )]
        )
        return AppConfiguration(
            providers: providers,
            routes: routes,
            routing: RoutingRuleSettings(activeRule: .sameModelLowestCost),
            modelHealth: health,
            modelHealthActivities: healthActivities,
            operational: OperationalSettings(modelProxy: proxySettings),
            usage: usage
        )
    }

    nonisolated private static func reviewDemoLogs(now: Date = .now) -> [GatewayLogEntry] {
        [
            GatewayLogEntry(timestamp: now, model: "smart", provider: "Review Cloud", statusCode: 200, latencyMilliseconds: 218, detail: "演示请求成功"),
            GatewayLogEntry(timestamp: now.addingTimeInterval(-120), model: "reasoning", provider: "Review Edge", statusCode: 200, latencyMilliseconds: 334, detail: "演示故障转移成功"),
            GatewayLogEntry(timestamp: now.addingTimeInterval(-300), model: "creative-media", provider: "Review Cloud", statusCode: 200, latencyMilliseconds: 421, detail: "演示多模态路由成功")
        ]
    }

    func bootstrap(initializeSecrets: Bool = true) {
        guard !didBootstrap else { return }
        didBootstrap = true
        loadConfiguration()
        schedulePricingUpdates()
        Task { await initializeSecretsWithoutInteraction() }
        Task { await initializeAgentSecretWithoutInteraction() }
        launchAtLoginRequested = UserDefaults.standard.bool(
            forKey: Self.launchAtLoginRequestedKey
        )
        refreshLaunchAtLoginStatus()
        #if DEBUG
        let disablesAutomaticServer = ProcessInfo.processInfo.environment[
            "MODELHUB_DISABLE_AUTOSTART"
        ] == "1"
        #else
        let disablesAutomaticServer = false
        #endif
        if configuration.server.startAutomatically && !disablesAutomaticServer {
            startServer()
        }
        if initializeSecrets {
            _ = gatewayToken
        }
        let proxySubscriptions = (configuration.operational.modelProxy ?? .init())
            .subscriptions
            .filter(\.enabled)
        if !proxySubscriptions.isEmpty {
            Task { await refreshProxySubscriptions(
                ids: proxySubscriptions.map(\.id),
                allowKeychainInteraction: false,
                announceResult: false
            ) }
        }
        publishWidgetSnapshot()
    }

    func initializeSecrets() {
        _ = gatewayToken
    }

    func initializeSecretsWithoutInteraction() async {
        guard cachedGatewayToken == nil else { return }
        switch await KeychainStore.readWithoutInteractionAsync(
            account: KeychainStore.gatewayTokenAccount
        ) {
        case .value(let existing):
            cachedGatewayToken = existing
        case .notFound:
            _ = createGatewayToken()
        case .interactionRequired:
            notice = String(localized: "钥匙串中的网关令牌需要重新授权；后台检查不会弹出授权窗口。", locale: AppLanguage.saved.locale)
        case .failure(let status):
            notice = KeychainStore.KeychainError.status(status).localizedDescription
        }
    }

    func initializeAgentSecretWithoutInteraction() async {
        guard cachedAgentToken == nil else { return }
        switch await KeychainStore.readWithoutInteractionAsync(
            account: KeychainStore.agentTokenAccount
        ) {
        case .value(let existing):
            cachedAgentToken = existing
        case .notFound:
            _ = createAgentToken()
        case .interactionRequired:
            notice = String(localized: "Agent 令牌需要重新授权；后台检查不会弹出授权窗口。", locale: AppLanguage.saved.locale)
        case .failure(let status):
            notice = KeychainStore.KeychainError.status(status).localizedDescription
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginRequested = enabled
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginRequestedKey)
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            UserDefaults.standard.set(
                error.localizedDescription,
                forKey: Self.launchAtLoginErrorKey
            )
            notice = L10n.format("更新登录启动设置失败：%@", error.localizedDescription)
        }
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            UserDefaults.standard.set("enabled", forKey: Self.launchAtLoginStatusKey)
            UserDefaults.standard.removeObject(forKey: Self.launchAtLoginErrorKey)
            launchAtLoginEnabled = true
            launchAtLoginRequested = true
            UserDefaults.standard.set(true, forKey: Self.launchAtLoginRequestedKey)
            launchAtLoginStatusText = String(localized: "已启用；下次登录后自动启动 ModelHub", locale: AppLanguage.saved.locale)
        case .requiresApproval:
            UserDefaults.standard.set("requiresApproval", forKey: Self.launchAtLoginStatusKey)
            launchAtLoginEnabled = false
            launchAtLoginStatusText = String(localized: "等待在“系统设置 → 通用 → 登录项”中批准", locale: AppLanguage.saved.locale)
        case .notFound:
            UserDefaults.standard.set("notFound", forKey: Self.launchAtLoginStatusKey)
            launchAtLoginEnabled = false
            launchAtLoginStatusText = String(localized: "当前应用包不支持登录启动，请使用已安装的签名版本", locale: AppLanguage.saved.locale)
        case .notRegistered:
            UserDefaults.standard.set("notRegistered", forKey: Self.launchAtLoginStatusKey)
            launchAtLoginEnabled = false
            launchAtLoginStatusText = String(localized: "尚未启用", locale: AppLanguage.saved.locale)
        @unknown default:
            UserDefaults.standard.set("unknown", forKey: Self.launchAtLoginStatusKey)
            launchAtLoginEnabled = false
            launchAtLoginStatusText = String(localized: "登录启动状态未知", locale: AppLanguage.saved.locale)
        }
    }

    func restoreRequestedLaunchAtLogin() {
        launchAtLoginRequested = UserDefaults.standard.bool(
            forKey: Self.launchAtLoginRequestedKey
        )
        guard launchAtLoginRequested else { return }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        do {
            try SMAppService.mainApp.register()
            refreshLaunchAtLoginStatus()
        } catch {
            UserDefaults.standard.set(
                error.localizedDescription,
                forKey: Self.launchAtLoginErrorKey
            )
            notice = L10n.format("恢复登录启动设置失败：%@", error.localizedDescription)
        }
    }

    @discardableResult
    func saveProvider(_ provider: ProviderConfig, apiKey: String) -> Bool {
        guard !isReviewDemoMode else {
            notice = String(localized: "审核演示模式不会保存供应商或凭证。退出演示模式后可正常配置。", locale: AppLanguage.saved.locale)
            return false
        }
        let replacementKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var providerToSave = provider
        let credentialToValidate = replacementKey.isEmpty
            ? providerAPIKeyWithoutInteraction(provider)
            : replacementKey
        if let message = ProviderCredentialPolicy.validationMessage(
            for: provider.kind,
            apiKey: credentialToValidate
        ) {
            notice = mhLocalized(message)
            return false
        }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            if providers[index].kind != provider.kind,
               provider.kind.isBailian,
               replacementKey.isEmpty,
               !ProviderCredentialPolicy.canReuseCredential(
                   from: providers[index].kind,
                   to: provider.kind,
                   apiKey: providerAPIKeyWithoutInteraction(provider)
               ),
               KeychainStore.existsWithoutInteraction(account: KeychainStore.providerAccount(provider.id))
            {
                notice = String(
                    localized: "千问AI平台版本已变更。为避免复用不兼容的凭证，请输入新版本专属 API Key 后再保存。",
                    locale: AppLanguage.saved.locale
                )
                return false
            }
            if providers[index].baseURL != provider.baseURL,
               providers[index].endpointURLs == provider.endpointURLs
            {
                providerToSave.endpointURLs = [:]
            }
            if let message = BailianEndpointPolicy.validationMessage(for: providerToSave) {
                notice = mhLocalized(message)
                return false
            }
            providers[index] = providerToSave
        } else {
            if let message = BailianEndpointPolicy.validationMessage(for: providerToSave) {
                notice = mhLocalized(message)
                return false
            }
            providers.append(providerToSave)
        }
        if !replacementKey.isEmpty {
            do {
                try KeychainStore.save(
                    replacementKey,
                    account: KeychainStore.providerAccount(provider.id)
                )
                notice = L10n.format("“%@”的 API Key 已安全更新；既有隔离记录保持不变。", provider.name)
            } catch {
                notice = error.localizedDescription
                return false
            }
        }
        let currentModels = Set(provider.models.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        configuration.modelHealth.removeAll {
            $0.providerID == provider.id && !currentModels.contains($0.model.lowercased())
        }
        configuration.modelHealth = ModelHealthMigration.normalize(
            records: configuration.modelHealth,
            providers: providers
        )
        rebuildHealthIndex()
        persistConfiguration()
        return true
    }

    func apiKey(for provider: ProviderConfig) -> String {
        guard !isReviewDemoMode else { return "" }
        return KeychainStore.read(account: KeychainStore.providerAccount(provider.id)) ?? ""
    }

    private func providerAPIKeyWithoutInteraction(_ provider: ProviderConfig) -> String {
        switch KeychainStore.readWithoutInteraction(
            account: KeychainStore.providerAccount(provider.id)
        ) {
        case .value(let stored): stored
        case .notFound, .interactionRequired, .failure: ""
        }
    }

    private func dataPlaneAPIKey(for provider: ProviderConfig) throws -> String {
        try DataPlaneCredentialAccessPolicy.apiKey(from: KeychainStore.readWithoutInteraction(
            account: KeychainStore.providerAccount(provider.id)
        ))
    }

    func providerCredentialValidationMessage(
        for provider: ProviderConfig,
        enteredAPIKey: String
    ) -> String? {
        guard provider.kind.isBailian else { return nil }
        let replacement = enteredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = replacement.isEmpty
            ? providerAPIKeyWithoutInteraction(provider)
            : replacement
        return ProviderCredentialPolicy.validationMessage(
            for: provider.kind,
            apiKey: key
        )
    }

    func providerCredentialRequiresReplacement(
        from previousKind: ProviderKind,
        to provider: ProviderConfig,
        enteredAPIKey: String
    ) -> Bool {
        guard previousKind != provider.kind,
              provider.kind.isBailian,
              enteredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              KeychainStore.existsWithoutInteraction(
                  account: KeychainStore.providerAccount(provider.id)
              )
        else { return false }
        return !ProviderCredentialPolicy.canReuseCredential(
            from: previousKind,
            to: provider.kind,
            apiKey: providerAPIKeyWithoutInteraction(provider)
        )
    }

    func fetchProviderModelCatalog(
        for provider: ProviderConfig,
        enteredAPIKey: String
    ) async throws -> ProviderModelCatalogResult {
        guard !isReviewDemoMode else {
            throw ProviderModelCatalogError.invalidResponse
        }
        let replacement = enteredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = replacement.isEmpty
            ? providerAPIKeyWithoutInteraction(provider)
            : replacement
        return try await providerClient.fetchModelCatalog(
            provider: provider,
            apiKey: key.isEmpty ? nil : key
        )
    }

    func isHotRefreshingProviderCatalog(_ providerID: UUID) -> Bool {
        refreshingProviderCatalogIDs.contains(providerID)
    }

    func hotRefreshProviderCatalog(providerID: UUID) async {
        guard !isReviewDemoMode,
              !refreshingProviderCatalogIDs.contains(providerID),
              let providerIndex = providers.firstIndex(where: { $0.id == providerID })
        else { return }

        let snapshot = providers[providerIndex]
        var catalogProvider = snapshot
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        let configuredCatalog = snapshot.endpointURLs[catalogKey]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        if configuredCatalog.isEmpty,
           let suggestion = ProviderModelCatalogSuggestions.suggestion(for: snapshot)
        {
            catalogProvider.endpointURLs[catalogKey] = suggestion.exactURL.absoluteString
        }
        guard catalogProvider.endpointURLs[catalogKey]?.isEmpty == false else {
            notice = String(
                localized: "该供应商没有已保存或已核验的精确模型名录 URL；不会使用或补全 Base URL。",
                locale: AppLanguage.saved.locale
            )
            return
        }

        let apiKey = providerAPIKeyWithoutInteraction(snapshot)
        guard !snapshot.kind.needsAPIKey || !apiKey.isEmpty else {
            notice = String(
                localized: "缺少 API Key，未向供应商发起请求",
                locale: AppLanguage.saved.locale
            )
            return
        }

        refreshingProviderCatalogIDs.insert(providerID)
        defer { refreshingProviderCatalogIDs.remove(providerID) }
        do {
            let result = try await providerClient.fetchModelCatalog(
                provider: catalogProvider,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                timeoutInterval: 20
            )
            guard ProviderModelCatalogMergePolicy.shouldHotUpdate(
                provider: catalogProvider,
                endpoint: result.endpoint
            ) else {
                notice = L10n.format(
                    "读取到 %lld 个目录参考项，但该目录不代表可直接调用模型，未执行热更新。",
                    Int64(result.models.count)
                )
                return
            }
            guard let currentIndex = providers.firstIndex(where: { $0.id == providerID }) else {
                return
            }
            var current = providers[currentIndex]
            let summary = ProviderModelCatalogHotUpdater.apply(
                importedModels: result.models,
                to: &current,
                healthRecords: &configuration.modelHealth
            )
            let capabilityCount = ProviderModelCapabilityUpdater.apply(
                details: result.capabilityDetails,
                to: &current
            )
            providers[currentIndex] = current
            rebuildHealthIndex()
            persistConfiguration()
            notice = L10n.format(
                "热更新完成：读取 %lld 个目录项，新增 %lld 个模型，更新 %lld 个模型能力参数；新增模型保持隔离，现有模型和检测状态未修改。",
                Int64(summary.catalogModelCount),
                Int64(summary.addedModelCount),
                Int64(capabilityCount)
            )
        } catch {
            notice = L10n.format("模型热更新失败：%@", error.localizedDescription)
        }
    }

    func hasAPIKey(for provider: ProviderConfig) -> Bool {
        KeychainStore.existsWithoutInteraction(account: KeychainStore.providerAccount(provider.id))
    }

    func deleteAPIKey(for provider: ProviderConfig) {
        KeychainStore.delete(account: KeychainStore.providerAccount(provider.id))
        let providerModelNames = Set(provider.models.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        configuration.modelHealth.removeAll {
            $0.providerID == provider.id
                && providerModelNames.contains(
                    $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
        }
        configuration.modelHealth.append(contentsOf: provider.models.map { model in
                ModelHealthRecord(
                    providerID: provider.id,
                    model: model,
                    status: .configurationRequired,
                    detail: "API Key 已删除，模型已隔离"
                )
        })
        rebuildHealthIndex()
        persistConfiguration()
        notice = L10n.format("“%@”的 API Key 已删除，所属模型已隔离。", provider.name)
    }

    func deleteProvider(_ provider: ProviderConfig) {
        providers.removeAll { $0.id == provider.id }
        configuration.modelHealth.removeAll { $0.providerID == provider.id }
        rebuildHealthIndex()
        routes = routes.map { route in
            var updated = route
            updated.targets.removeAll { $0.providerID == provider.id }
            return updated
        }
        KeychainStore.delete(account: KeychainStore.providerAccount(provider.id))
        persistConfiguration()
    }

    func saveRoute(_ route: RouteConfig) {
        if let index = routes.firstIndex(where: { $0.id == route.id }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
        persistConfiguration()
    }

    func setDefaultRoutingRule(_ rule: DefaultRoutingRule) {
        configuration.routing.activeRule = rule
        persistConfiguration()
        notice = L10n.format("默认路由规则已切换为“%@”。", rule.displayName)
    }

    func simulateRoute(
        requestedModel: String,
        requiredCapabilities: Set<ModelCapability> = []
    ) async -> RouteDecisionReport {
        await router.explain(
            requestedModel: requestedModel,
            routes: routes,
            providers: providers,
            healthRecords: configuration.modelHealth,
            usage: configuration.usage,
            requiredCapabilities: requiredCapabilities,
            defaultRule: configuration.routing.activeRule
        )
    }

    func deleteRoute(_ route: RouteConfig) {
        routes.removeAll { $0.id == route.id }
        persistConfiguration()
    }

    func persistServerSettings(_ settings: ServerSettings, restart: Bool = true) {
        let portChanged = configuration.server.port != settings.port
        configuration.server = settings
        persistConfiguration()
        if restart && isServerRunning && portChanged {
            stopServer()
            startServer()
        }
    }

    func persistOperationalSettings(_ settings: OperationalSettings) {
        var sanitized = settings
        if let responseCache = settings.responseCache {
            sanitized.responseCache = responseCache.sanitized
            if !responseCache.enabled {
                Task { await self.responseCache.removeAll() }
            }
        }
        sanitized.pricingUpdate = (settings.pricingUpdate ?? .init()).sanitized
        sanitized.currencyDisplay = (settings.currencyDisplay ?? .init()).sanitized
        if let modelProxy = settings.modelProxy {
            let proxy = modelProxy.sanitized
            guard proxy.validationMessage == nil else {
                notice = proxy.validationMessage
                return
            }
            sanitized.modelProxy = proxy
        }
        configuration.operational = sanitized
        rebuildProxyEndpointIndex()
        persistConfiguration()
        schedulePricingUpdates()
        notice = String(localized: "本机路由、预算与协议设置已保存。", locale: AppLanguage.saved.locale)
    }

    @discardableResult
    func persistModelProxySettings(_ settings: ModelProxySettings) -> Bool {
        let sanitized = settings.sanitized
        guard let validationMessage = sanitized.validationMessage else {
            replaceModelProxySettings(sanitized)
            persistConfiguration()
            let count = sanitized.enabled
                ? sanitized.selections.count + sanitized.assignments.count
                : 0
            notice = sanitized.enabled
                ? L10n.format("模型代理已保存：%d 个精确模型将使用代理，其余请求保持直连。", count)
                : L10n.text("模型代理已关闭；所有上游请求保持直连。")
            if !sanitized.enabled {
                modelProxyRuntime.stop()
                proxyRuntimeStatus = L10n.text("未启动")
            } else if !sanitized.assignments.isEmpty {
                scheduleModelProxyRuntimeActivation(announceResult: true)
            }
            return true
        }
        notice = validationMessage
        return false
    }

    private func proxyEndpoint(providerID: UUID, model: String) -> ProviderProxyEndpoint? {
        proxyAttempt(providerID: providerID, model: model).endpoint
    }

    private func proxyAttempt(providerID: UUID, model: String) -> GatewayProxyAttempt {
        let key = Self.modelTestKey(providerID: providerID, model: model)
        if let state = proxyFailoverStates[key]
            ?? proxyFailoverIndex.initialState(providerID: providerID, model: model)
        {
            proxyFailoverStates[key] = state
            if let endpoint = proxyFailoverIndex.endpoint(for: state) {
                return GatewayProxyAttempt(
                    endpoint: endpoint,
                    failoverNodeID: state.activeNodeID
                )
            }
        }
        return GatewayProxyAttempt(
            endpoint: proxyEndpointIndex.endpoint(providerID: providerID, model: model),
            failoverNodeID: nil
        )
    }

    private func replaceModelProxySettings(_ settings: ModelProxySettings) {
        configuration.operational.modelProxy = settings
        rebuildProxyEndpointIndex()
    }

    private func rebuildProxyEndpointIndex() {
        let settings = configuration.operational.modelProxy ?? .init()
        proxyEndpointIndex = ModelProxyEndpointIndex(settings: settings)
        proxyFailoverIndex = ModelProxyFailoverIndex(settings: settings)
        proxyFailoverStates.removeAll(keepingCapacity: true)
        exhaustedProxyFailoverKeys.removeAll(keepingCapacity: true)
    }

    var proxySubscriptions: [ProxySubscription] {
        (configuration.operational.modelProxy ?? .init()).subscriptions
    }

    var proxySubscriptionNodes: [ProxySubscriptionNode] {
        (configuration.operational.modelProxy ?? .init()).nodes
    }

    var modelProxyEnabled: Bool {
        (configuration.operational.modelProxy ?? .init()).enabled
    }

    var modelProxyAssignmentCount: Int {
        (configuration.operational.modelProxy ?? .init()).assignments.count
    }

    var proxyAutomaticFailoverSettings: ModelProxyAutomaticFailoverSettings {
        (configuration.operational.modelProxy ?? .init()).automaticFailover.sanitized
    }

    func setModelProxyEnabled(_ enabled: Bool) {
        var settings = configuration.operational.modelProxy ?? .init()
        settings.enabled = enabled
        _ = persistModelProxySettings(settings)
    }

    func proxySubscriptionHasStoredURL(_ id: UUID) -> Bool {
        if isReviewDemoMode { return true }
        return KeychainStore.existsWithoutInteraction(
            account: KeychainStore.proxySubscriptionAccount(id)
        )
    }

    @discardableResult
    func addProxySubscription(
        name: String,
        url rawURL: String,
        updateIntervalHours: Int
    ) -> Bool {
        do {
            let url = try ProxySubscriptionURLValidator.validate(rawURL)
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw ProxySubscriptionRuntimeError.invalidURL
            }
            var settings = configuration.operational.modelProxy ?? .init()
            guard !settings.subscriptions.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
            }) else {
                notice = L10n.text("订阅名称已存在")
                return false
            }
            let subscription = ProxySubscription(
                name: trimmedName,
                sourceHost: url.host ?? "",
                updateIntervalHours: updateIntervalHours
            ).sanitized
            try KeychainStore.save(
                url.absoluteString,
                account: KeychainStore.proxySubscriptionAccount(subscription.id)
            )
            settings.subscriptions.append(subscription)
            replaceModelProxySettings(settings.sanitized)
            persistConfiguration()
            Task { await refreshProxySubscriptions(
                ids: [subscription.id],
                allowKeychainInteraction: true,
                announceResult: true
            ) }
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func removeProxySubscription(_ id: UUID) {
        var settings = configuration.operational.modelProxy ?? .init()
        let removedNodeIDs = Set(settings.nodes.filter {
            $0.subscriptionID == id
        }.map(\.id))
        settings.subscriptions.removeAll { $0.id == id }
        settings.nodes.removeAll { $0.subscriptionID == id }
        settings.assignments.removeAll { removedNodeIDs.contains($0.nodeID) }
        replaceModelProxySettings(settings.sanitized)
        proxySubscriptionPayloads.removeValue(forKey: id)
        refreshingProxySubscriptionIDs.remove(id)
        proxySubscriptionMessages.removeValue(forKey: id)
        KeychainStore.delete(account: KeychainStore.proxySubscriptionAccount(id))
        persistConfiguration()
        scheduleProxySubscriptionUpdates()
        scheduleModelProxyRuntimeActivation(announceResult: false)
    }

    func refreshProxySubscription(_ id: UUID) {
        Task { await refreshProxySubscriptions(
            ids: [id],
            allowKeychainInteraction: true,
            announceResult: true
        ) }
    }

    func refreshAllProxySubscriptions() {
        let ids = proxySubscriptions.filter(\.enabled).map(\.id)
        Task { await refreshProxySubscriptions(
            ids: ids,
            allowKeychainInteraction: true,
            announceResult: true
        ) }
    }

    func setProxySubscriptionEnabled(_ enabled: Bool, id: UUID) {
        var settings = configuration.operational.modelProxy ?? .init()
        guard let index = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        settings.subscriptions[index].enabled = enabled
        if !enabled {
            let disabledNodeIDs = Set(settings.nodes.filter {
                $0.subscriptionID == id
            }.map(\.id))
            settings.assignments.removeAll { disabledNodeIDs.contains($0.nodeID) }
        }
        replaceModelProxySettings(settings.sanitized)
        persistConfiguration()
        scheduleProxySubscriptionUpdates()
        Task {
            if enabled {
                await refreshProxySubscriptions(
                    ids: [id],
                    allowKeychainInteraction: true,
                    announceResult: true
                )
            } else {
                do {
                    try await activateModelProxyRuntime(announceResult: false)
                } catch {
                    proxyRuntimeStatus = L10n.text("启动失败")
                }
            }
        }
    }

    func assignProxyNode(
        _ nodeID: String?,
        providerID: UUID,
        model: String
    ) {
        assignProxyNode(nodeID, providerID: providerID, models: [model])
    }

    @discardableResult
    func assignProxyNode(
        _ nodeID: String?,
        providerID: UUID,
        models: [String],
        enableWhenAssigned: Bool = false
    ) -> Bool {
        assignProxyNodes(
            primaryNodeID: nodeID,
            candidateNodeIDs: [],
            providerID: providerID,
            models: models,
            enableWhenAssigned: enableWhenAssigned,
            automaticFailover: proxyAutomaticFailoverSettings
        )
    }

    @discardableResult
    func assignProxyNodes(
        primaryNodeID: String?,
        candidateNodeIDs: [String],
        providerID: UUID,
        models: [String],
        enableWhenAssigned: Bool = false,
        automaticFailover: ModelProxyAutomaticFailoverSettings
    ) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            notice = L10n.text("供应商不存在")
            return false
        }
        let validModels = models.filter(provider.models.contains)
        guard !validModels.isEmpty else {
            notice = L10n.text("没有可分配的模型")
            return false
        }
        var settings = configuration.operational.modelProxy ?? .init()
        settings.automaticFailover = automaticFailover.sanitized
        let validNodeIDs = Set(settings.nodes.map(\.id))
        let primary = primaryNodeID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = candidateNodeIDs.filter {
            validNodeIDs.contains($0) && $0 != primary
        }
        for model in validModels {
            let assignmentID = ModelProxyAssignment(
                providerID: providerID,
                model: model,
                nodeID: ""
            ).id
            settings.assignments.removeAll { $0.id == assignmentID }
            if let primary, validNodeIDs.contains(primary) {
                settings.assignments.append(ModelProxyAssignment(
                    providerID: providerID,
                    model: model,
                    nodeID: primary,
                    candidateNodeIDs: candidates
                ))
            }
        }
        if enableWhenAssigned, primary != nil {
            settings.enabled = true
        }
        let changedCount = validModels.count
        let sanitized = settings.sanitized
        guard sanitized.validationMessage == nil else {
            notice = sanitized.validationMessage
            return false
        }
        replaceModelProxySettings(sanitized)
        persistConfiguration()
        if primary == nil {
            notice = L10n.format("已取消 %d 个模型的订阅节点分配。", changedCount)
        } else if sanitized.enabled {
            if sanitized.automaticFailover.enabled, !candidates.isEmpty {
                notice = L10n.format(
                    "已为 %d 个模型保存主节点和 %d 个有序备选；只在连续瞬态故障后切换，不会直连。",
                    changedCount,
                    candidates.count
                )
            } else {
                notice = enableWhenAssigned
                    ? L10n.format("已为 %d 个模型分配并启用订阅节点。", changedCount)
                    : L10n.format("已为 %d 个模型分配订阅节点。", changedCount)
            }
        } else {
            notice = L10n.format("已为 %d 个模型保存节点分配；启用模型专用代理后生效。", changedCount)
        }
        scheduleModelProxyRuntimeActivation(announceResult: true)
        return true
    }

    func assignedProxyNodeID(providerID: UUID, model: String) -> String? {
        let exact = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return (configuration.operational.modelProxy ?? .init()).assignments.first {
            $0.providerID == providerID && $0.model == exact
        }?.nodeID
    }

    func assignedProxyCandidateNodeIDs(providerID: UUID, model: String) -> [String] {
        let exact = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return (configuration.operational.modelProxy ?? .init()).assignments.first {
            $0.providerID == providerID && $0.model == exact
        }?.candidateNodeIDs ?? []
    }

    var isTestingProxyNodeLatency: Bool {
        proxyNodeLatencyTask != nil
    }

    func testProxyNodeLatency(_ nodeID: String) {
        testProxyNodeLatencies([nodeID])
    }

    func testProxyNodeLatencies(_ nodeIDs: [String]) {
        guard proxyNodeLatencyTask == nil else {
            notice = L10n.text("节点出站测速正在进行，请等待本轮完成。")
            return
        }
        guard refreshingProxySubscriptionIDs.isEmpty else {
            notice = L10n.text("订阅更新期间不能测速，请等待节点读取完成。")
            return
        }
        guard !isReviewDemoMode else {
            notice = L10n.text("审核演示使用合成节点出站延迟，不会访问外部测速端点。")
            return
        }
        let validNodeIDs = Set(proxySubscriptionNodes.map(\.id))
        let allRequestedIDs = Array(Set(nodeIDs).intersection(validNodeIDs)).sorted()
        let requestedIDs = Array(allRequestedIDs.prefix(200))
        guard !requestedIDs.isEmpty else {
            notice = L10n.text("没有可进行外网测速的订阅节点。")
            return
        }
        if allRequestedIDs.count > requestedIDs.count {
            notice = L10n.format("本轮最多对 %d 个节点进行外网测速，已自动截断。", requestedIDs.count)
        }
        testingProxyNodeIDs.formUnion(requestedIDs)
        proxyNodeLatencyTask = Task { [weak self] in
            await self?.runProxyNodeLatencyTests(nodeIDs: requestedIDs)
        }
    }

    private func runProxyNodeLatencyTests(nodeIDs: [String]) async {
        defer {
            testingProxyNodeIDs.subtract(nodeIDs)
            proxyNodeLatencyTask = nil
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: proxySubscriptionNodes.map {
            ($0.id, $0)
        })
        let requestedNodes = nodeIDs.compactMap { nodesByID[$0] }
        let grouped = Dictionary(grouping: requestedNodes, by: \.subscriptionID)
        var succeeded = 0
        var failed = 0

        for subscriptionID in grouped.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard !Task.isCancelled else { break }
            let nodes = grouped[subscriptionID] ?? []
            guard let subscription = proxySubscriptions.first(where: {
                $0.id == subscriptionID && $0.enabled
            }), let payload = proxySubscriptionPayloads[subscriptionID]
            else {
                let now = Date()
                for node in nodes {
                    proxyNodeLatencyResults[node.id] = ProxyNodeLatencyResult(
                        latencyMilliseconds: nil,
                        testedAt: now,
                        failure: .subscriptionUnavailable
                    )
                    testingProxyNodeIDs.remove(node.id)
                    failed += 1
                }
                continue
            }

            do {
                let secret = try await proxyControllerSecret(allowInteraction: false)
                let temporarySettings = ModelProxySettings(
                    enabled: false,
                    subscriptions: [subscription]
                ).sanitized
                try modelProxyRuntime.start(
                    settings: temporarySettings,
                    payloads: [subscriptionID: payload],
                    controllerSecret: secret
                )
                proxyRuntimeStatus = L10n.format("正在通过 %d 个节点测试外网延迟", nodes.count)
                _ = try await waitForProxyProvider(
                    subscriptionID: subscriptionID,
                    secret: secret
                )
                let measurements = await Self.measureProxyNodeLatencies(
                    nodes,
                    subscription: subscription,
                    secret: secret
                )
                let now = Date()
                for measurement in measurements {
                    proxyNodeLatencyResults[measurement.nodeID] = ProxyNodeLatencyResult(
                        latencyMilliseconds: measurement.latencyMilliseconds,
                        testedAt: now,
                        failure: measurement.failure
                    )
                    testingProxyNodeIDs.remove(measurement.nodeID)
                    if measurement.latencyMilliseconds == nil {
                        failed += 1
                    } else {
                        succeeded += 1
                    }
                }
            } catch {
                let now = Date()
                for node in nodes {
                    proxyNodeLatencyResults[node.id] = ProxyNodeLatencyResult(
                        latencyMilliseconds: nil,
                        testedAt: now,
                        failure: .classify(error)
                    )
                    testingProxyNodeIDs.remove(node.id)
                    failed += 1
                }
            }
            modelProxyRuntime.stop()
        }

        modelProxyRuntime.stop()
        guard !Task.isCancelled else { return }
        do {
            try await activateModelProxyRuntime(announceResult: false)
        } catch {
            modelProxyRuntime.stop()
            proxyRuntimeStatus = L10n.text("启动失败")
        }
        notice = L10n.format(
            "节点出站测速完成：成功 %d，失败/超时 %d；流量经各被测节点访问固定 HTTPS 探针，未调用任何模型。",
            succeeded,
            failed
        )
    }

    nonisolated private static func measureProxyNodeLatencies(
        _ nodes: [ProxySubscriptionNode],
        subscription: ProxySubscription,
        secret: String
    ) async -> [ProxyNodeLatencyMeasurement] {
        let maximumConcurrentTests = ProxyNodeLatencyPolicy.maximumConcurrentTests
        var measurements: [ProxyNodeLatencyMeasurement] = []
        for start in stride(from: 0, to: nodes.count, by: maximumConcurrentTests) {
            guard !Task.isCancelled else { break }
            let batch = Array(nodes[start..<min(start + maximumConcurrentTests, nodes.count)])
            let batchResults = await withTaskGroup(
                of: ProxyNodeLatencyMeasurement.self,
                returning: [ProxyNodeLatencyMeasurement].self
            ) { group in
                for node in batch {
                    group.addTask {
                        let runtimeName = subscription.runtimePrefix + " " + node.name
                        do {
                            let latency = try await ModelProxyControllerClient.delay(
                                subscriptionID: subscription.id,
                                proxyName: runtimeName,
                                secret: secret
                            )
                            return ProxyNodeLatencyMeasurement(
                                nodeID: node.id,
                                latencyMilliseconds: latency,
                                failure: nil
                            )
                        } catch {
                            return ProxyNodeLatencyMeasurement(
                                nodeID: node.id,
                                latencyMilliseconds: nil,
                                failure: .classify(error)
                            )
                        }
                    }
                }
                var results: [ProxyNodeLatencyMeasurement] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            measurements.append(contentsOf: batchResults)
        }
        return measurements
    }

    func stopModelProxyRuntime() {
        proxySubscriptionUpdateTask?.cancel()
        proxySubscriptionUpdateTask = nil
        proxyNodeLatencyTask?.cancel()
        proxyNodeLatencyTask = nil
        testingProxyNodeIDs.removeAll()
        modelProxyRuntime.stop()
        proxyRuntimeStatus = L10n.text("未启动")
    }

    private func scheduleModelProxyRuntimeActivation(announceResult: Bool) {
        guard proxyNodeLatencyTask == nil else { return }
        Task {
            do {
                try await activateModelProxyRuntime(announceResult: announceResult)
            } catch {
                modelProxyRuntime.stop()
                proxyRuntimeStatus = L10n.text("启动失败")
                if announceResult {
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func refreshProxySubscriptions(
        ids: [UUID],
        allowKeychainInteraction: Bool,
        announceResult: Bool
    ) async {
        guard proxyNodeLatencyTask == nil else {
            if announceResult {
                notice = L10n.text("节点出站测速期间不能更新订阅，请等待本轮完成。")
            }
            return
        }
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        var failureMessages: [String] = []
        var downloaded: [DownloadedProxySubscription] = []
        for id in uniqueIDs {
            guard !refreshingProxySubscriptionIDs.contains(id),
                  let subscription = proxySubscriptions.first(where: { $0.id == id })
            else { continue }
            refreshingProxySubscriptionIDs.insert(id)
            defer { refreshingProxySubscriptionIDs.remove(id) }
            do {
                let account = KeychainStore.proxySubscriptionAccount(id)
                let rawURL: String
                if allowKeychainInteraction {
                    guard let value = KeychainStore.read(account: account) else {
                        throw ProxySubscriptionRuntimeError.invalidURL
                    }
                    rawURL = value
                } else {
                    switch await KeychainStore.readWithoutInteractionAsync(account: account) {
                    case .value(let value): rawURL = value
                    case .interactionRequired:
                        proxySubscriptionMessages[id] = L10n.text("需要钥匙串授权后才能更新")
                        continue
                    case .notFound:
                        proxySubscriptionMessages[id] = L10n.text("需要重新填写订阅链接")
                        continue
                    case .failure(let status):
                        throw KeychainStore.KeychainError.status(status)
                    }
                }
                let url = try ProxySubscriptionURLValidator.validate(rawURL)
                let download = try await ProxySubscriptionDownloader.fetch(url)
                let inspection = try ProxySubscriptionPayloadInspector.inspect(download.data)
                updateProxySubscriptionMetadata(
                    subscription,
                    sourceHost: download.sourceHost,
                    usage: download.usage
                )
                downloaded.append(DownloadedProxySubscription(
                    subscription: subscription,
                    payload: download.data,
                    format: inspection.format
                ))
                proxySubscriptionMessages[id] = L10n.format(
                    "订阅内容已下载（%@），正在读取节点",
                    inspection.format.displayName
                )
            } catch {
                let message = error.localizedDescription
                proxySubscriptionMessages[id] = message
                failureMessages.append("\(subscription.name)：\(message)")
            }
        }

        var discoveredCount = 0
        for item in downloaded {
            let retainedNodeCount = proxySubscriptionNodes.lazy.filter {
                $0.subscriptionID == item.subscription.id
            }.count
            do {
                let nodes = try await discoverNodes(
                    for: item.subscription,
                    payload: item.payload
                )
                commitDiscoveredProxyNodes(nodes, subscriptionID: item.subscription.id)
                proxySubscriptionPayloads[item.subscription.id] = item.payload
                proxySubscriptionMessages[item.subscription.id] = L10n.format(
                    "已读取 %d 个节点（%@）",
                    nodes.count,
                    item.format.displayName
                )
                discoveredCount += 1
            } catch {
                let message = ProxySubscriptionStatusMessage.discoveryFailure(
                    error: error,
                    retainedNodeCount: retainedNodeCount,
                    format: item.format
                )
                proxySubscriptionMessages[item.subscription.id] = message
                failureMessages.append("\(item.subscription.name)：\(message)")
            }
        }

        if discoveredCount > 0 || !downloaded.isEmpty {
            do {
                try await activateModelProxyRuntime(announceResult: false)
            } catch {
                modelProxyRuntime.stop()
                proxyRuntimeStatus = L10n.text("启动失败")
                failureMessages.append("模型代理运行时：\(error.localizedDescription)")
            }
        }
        if announceResult {
            notice = failureMessages.isEmpty
                ? L10n.text("代理订阅已更新，节点与模型分配已生效。")
                : failureMessages.joined(separator: "\n")
        }
        scheduleProxySubscriptionUpdates()
    }

    private func scheduleProxySubscriptionUpdates(now: Date = .now) {
        proxySubscriptionUpdateTask?.cancel()
        proxySubscriptionUpdateTask = nil
        let enabled = proxySubscriptions.filter(\.enabled)
        guard !enabled.isEmpty, !isReviewDemoMode else { return }
        let nextDate = enabled.map { subscription in
            let interval = TimeInterval(subscription.updateIntervalHours * 3_600)
            return subscription.lastUpdatedAt?.addingTimeInterval(interval)
                ?? now.addingTimeInterval(interval)
        }.min() ?? now.addingTimeInterval(86_400)
        let delay = max(nextDate.timeIntervalSince(now), 60)
        proxySubscriptionUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.proxySubscriptionUpdateTask = nil
            let dueIDs = self.proxySubscriptions.filter { subscription in
                guard subscription.enabled else { return false }
                let interval = TimeInterval(subscription.updateIntervalHours * 3_600)
                let dueDate = subscription.lastUpdatedAt?.addingTimeInterval(interval)
                    ?? now.addingTimeInterval(interval)
                return dueDate <= .now
            }.map(\.id)
            guard !dueIDs.isEmpty else {
                self.scheduleProxySubscriptionUpdates()
                return
            }
            await self.refreshProxySubscriptions(
                ids: dueIDs,
                allowKeychainInteraction: false,
                announceResult: false
            )
        }
    }

    private func updateProxySubscriptionMetadata(
        _ subscription: ProxySubscription,
        sourceHost: String,
        usage: ProxySubscriptionUsageInfo
    ) {
        var settings = configuration.operational.modelProxy ?? .init()
        guard let index = settings.subscriptions.firstIndex(where: {
            $0.id == subscription.id
        }) else { return }
        settings.subscriptions[index].sourceHost = sourceHost
        settings.subscriptions[index].lastUpdatedAt = .now
        settings.subscriptions[index].uploadBytes = usage.uploadBytes
        settings.subscriptions[index].downloadBytes = usage.downloadBytes
        settings.subscriptions[index].totalBytes = usage.totalBytes
        settings.subscriptions[index].expiresAt = usage.expiresAt
        replaceModelProxySettings(settings.sanitized)
        persistConfiguration()
    }

    private struct DownloadedProxySubscription {
        let subscription: ProxySubscription
        let payload: Data
        let format: ProxySubscriptionPayloadFormat
    }

    private func discoverNodes(
        for subscription: ProxySubscription,
        payload: Data
    ) async throws -> [ProxySubscriptionNode] {
        var discoverySettings = ModelProxySettings(
            enabled: false,
            subscriptions: [subscription],
            nodes: []
        ).sanitized
        discoverySettings.assignments = []
        let secret = try await proxyControllerSecret(allowInteraction: false)
        try modelProxyRuntime.start(
            settings: discoverySettings,
            payloads: [subscription.id: payload],
            controllerSecret: secret
        )
        guard let discoveryProcessID = modelProxyRuntime.process?.processIdentifier else {
            throw ProxySubscriptionRuntimeError.coreExited
        }
        let discoveryWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.modelProxyRuntime.stop(ifProcessIdentifier: discoveryProcessID)
        }
        defer {
            discoveryWatchdog.cancel()
            modelProxyRuntime.stop(ifProcessIdentifier: discoveryProcessID)
        }
        proxyRuntimeStatus = L10n.text("正在读取订阅节点")
        let provider = try await waitForProxyProvider(
            subscriptionID: subscription.id,
            secret: secret
        )
        let prefix = subscription.runtimePrefix + " "
        let nodes = provider.proxies.compactMap { proxy -> ProxySubscriptionNode? in
            guard proxy.name.hasPrefix(prefix) else { return nil }
            return ProxySubscriptionNode(
                subscriptionID: subscription.id,
                name: String(proxy.name.dropFirst(prefix.count)),
                type: proxy.type,
                isAlive: proxy.alive ?? true
            )
        }
        guard !nodes.isEmpty else { throw ProxySubscriptionRuntimeError.noNodes }
        return nodes
    }

    private func commitDiscoveredProxyNodes(
        _ nodes: [ProxySubscriptionNode],
        subscriptionID: UUID
    ) {
        var settings = configuration.operational.modelProxy ?? .init()
        settings.nodes.removeAll { $0.subscriptionID == subscriptionID }
        settings.nodes.append(contentsOf: nodes)
        if let index = settings.subscriptions.firstIndex(where: {
            $0.id == subscriptionID
        }) {
            settings.subscriptions[index].nodeCount = nodes.count
        }
        replaceModelProxySettings(settings.sanitized)
        persistConfiguration()
    }

    private func waitForProxyProvider(
        subscriptionID: UUID,
        secret: String
    ) async throws -> MihomoProvider {
        let providerKey = ModelProxyRuntimeConfiguration.providerKey(subscriptionID)
        var sawController = false
        for _ in 0..<30 {
            if !modelProxyRuntime.isRunning {
                throw ProxySubscriptionRuntimeError.coreExited
            }
            do {
                let response = try await ModelProxyControllerClient.providers(secret: secret)
                sawController = true
                if let provider = response.providers[providerKey], !provider.proxies.isEmpty {
                    return provider
                }
            } catch {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw sawController
            ? ProxySubscriptionRuntimeError.providerNotLoaded
            : ProxySubscriptionRuntimeError.controllerUnavailable
    }

    private func activateModelProxyRuntime(
        announceResult: Bool,
        secret: String? = nil
    ) async throws {
        let settings = (configuration.operational.modelProxy ?? .init()).sanitized
        guard settings.enabled, !settings.assignments.isEmpty else {
            modelProxyRuntime.stop()
            proxyRuntimeStatus = L10n.text("未启动")
            return
        }
        let assignedSubscriptionIDs = Set(settings.nodes.filter {
            settings.activeNodeIDs.contains($0.id)
        }.map(\.subscriptionID))
        guard assignedSubscriptionIDs.allSatisfy({ proxySubscriptionPayloads[$0] != nil }) else {
            modelProxyRuntime.stop()
            proxyRuntimeStatus = L10n.text("等待订阅更新")
            if announceResult {
                notice = L10n.text("请先更新已分配节点所属的订阅。")
            }
            return
        }
        let controllerSecret: String
        if let secret {
            controllerSecret = secret
        } else {
            controllerSecret = try await proxyControllerSecret(allowInteraction: false)
        }
        try modelProxyRuntime.start(
            settings: settings,
            payloads: proxySubscriptionPayloads,
            controllerSecret: controllerSecret
        )
        _ = try await waitForProxyProviders(secret: controllerSecret)
        proxyRuntimeStatus = L10n.format(
            "运行中 · %d 个节点监听",
            settings.activeNodeIDs.count
        )
        if announceResult {
            notice = L10n.text("模型代理分配已应用。")
        }
    }

    private func waitForProxyProviders(secret: String) async throws -> MihomoProvidersResponse {
        var lastError: Error = ProxySubscriptionRuntimeError.controllerUnavailable
        for _ in 0..<30 {
            if !modelProxyRuntime.isRunning {
                throw ProxySubscriptionRuntimeError.coreExited
            }
            do {
                return try await ModelProxyControllerClient.providers(secret: secret)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw lastError
    }

    private func proxyControllerSecret(allowInteraction: Bool) async throws -> String {
        let account = KeychainStore.proxyControllerSecretAccount
        if allowInteraction, let existing = KeychainStore.read(account: account) {
            return existing
        }
        switch await KeychainStore.readWithoutInteractionAsync(account: account) {
        case .value(let existing): return existing
        case .notFound:
            let secret = "mhp_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            try KeychainStore.save(secret, account: account)
            return secret
        case .interactionRequired:
            throw ProxySubscriptionRuntimeError.controllerUnavailable
        case .failure(let status):
            throw KeychainStore.KeychainError.status(status)
        }
    }

    func refreshModelPricesNow() {
        guard !isRefreshingModelPrices else { return }
        Task { await refreshModelPrices(trigger: "手动") }
    }

    private func refreshModelPrices(trigger: String) async {
        guard !isReviewDemoMode, !isRefreshingModelPrices else { return }
        isRefreshingModelPrices = true
        let enabledProviders = providers.filter(\.enabled)
        modelPriceRefreshProgress = ModelPriceRefreshProgress(
            total: enabledProviders.count,
            completed: 0
        )
        defer {
            isRefreshingModelPrices = false
            modelPriceRefreshProgress = nil
        }

        let startedAt = Date()
        var settings = (configuration.operational.pricingUpdate ?? .init()).sanitized
        settings.lastAttemptAt = startedAt
        var checked = 0
        var catalogsFetched = 0
        var modelsUpdated = 0
        var missingPriceSource = 0
        var missingCredential = 0
        var failures = 0
        var failureSummaries: [String] = []

        for snapshot in enabledProviders {
            guard !Task.isCancelled else { break }
            var catalogProvider = snapshot
            let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
            let configured = snapshot.endpointURLs[catalogKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if configured.isEmpty {
                guard let suggestion = ProviderModelCatalogSuggestions.suggestion(for: snapshot),
                      suggestion.canReturnTokenPrices
                else {
                    missingPriceSource += 1
                    modelPriceRefreshProgress?.completed += 1
                    continue
                }
                catalogProvider.endpointURLs[catalogKey] = suggestion.exactURL.absoluteString
            }
            if let rawEndpoint = catalogProvider.endpointURLs[catalogKey],
               let endpoint = URL(string: rawEndpoint),
               !ProviderModelCatalogPricingPolicy.shouldFetch(
                   provider: catalogProvider,
                   endpoint: endpoint
               )
            {
                missingPriceSource += 1
                modelPriceRefreshProgress?.completed += 1
                continue
            }
            let apiKey = providerAPIKeyWithoutInteraction(snapshot)
            if snapshot.kind.needsAPIKey && apiKey.isEmpty {
                missingCredential += 1
                modelPriceRefreshProgress?.completed += 1
                continue
            }
            checked += 1
            do {
                let result = try await providerClient.fetchModelCatalog(
                    provider: catalogProvider,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    timeoutInterval: 20
                )
                catalogsFetched += 1
                guard !result.prices.isEmpty,
                      var currentProvider = providers.first(where: { $0.id == snapshot.id })
                else {
                    modelPriceRefreshProgress?.completed += 1
                    continue
                }
                let updated = ProviderModelPricingUpdater.apply(
                    prices: result.prices,
                    to: &currentProvider,
                    routes: &configuration.routes,
                    updatedAt: startedAt
                )
                if updated > 0,
                   let index = providers.firstIndex(where: { $0.id == currentProvider.id })
                {
                    providers[index] = currentProvider
                    modelsUpdated += updated
                }
            } catch {
                failures += 1
                if failureSummaries.count < 5 {
                    failureSummaries.append("\(snapshot.name)：\(error.localizedDescription)")
                }
            }
            modelPriceRefreshProgress?.completed += 1
        }

        if modelsUpdated > 0 {
            settings.lastSuccessAt = startedAt
        }
        let failureDetail = failureSummaries.isEmpty
            ? ""
            : " 失败详情：" + failureSummaries.joined(separator: "；")
        settings.lastMessage = "\(trigger)：检查 \(checked) 个供应商，成功读取 \(catalogsFetched) 个价格目录，更新 \(modelsUpdated) 个模型价格；无可靠价格来源 \(missingPriceSource)，缺少凭证 \(missingCredential)，失败 \(failures)。\(failureDetail)"
        configuration.operational.pricingUpdate = settings
        persistConfiguration()
        notice = settings.lastMessage
    }

    private func schedulePricingUpdates() {
        pricingUpdateTask?.cancel()
        pricingUpdateTask = nil
        let settings = (configuration.operational.pricingUpdate ?? .init()).sanitized
        guard settings.enabled, !isReviewDemoMode else { return }

        pricingUpdateTask = Task { [weak self] in
            guard let self else { return }
            var current = Date()
            if settings.shouldCatchUp(at: current) {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self.refreshModelPrices(trigger: "自动补更新")
                current = Date()
            }

            while !Task.isCancelled {
                let active = (self.configuration.operational.pricingUpdate ?? .init()).sanitized
                guard active.enabled,
                      let next = active.nextScheduledDate(after: current)
                else { return }
                let seconds = max(1, Int64(next.timeIntervalSinceNow.rounded(.up)))
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshModelPrices(trigger: "定时")
                current = Date()
            }
        }
    }

    func clearResponseCache() {
        Task {
            await responseCache.removeAll()
            notice = "本机内存响应缓存已清空。"
        }
    }

    func saveWorkspace(_ workspace: WorkspaceConfig) {
        var sanitized = workspace
        sanitized.name = String(
            workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        guard !sanitized.name.isEmpty else {
            notice = "工作区名称不能为空。"
            return
        }
        if let index = configuration.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            configuration.workspaces[index] = sanitized
        } else {
            configuration.workspaces.append(sanitized)
        }
        appendSecurityAudit(
            action: .policyChanged,
            actor: "local-user",
            outcome: "saved",
            detail: "更新工作区策略：\(sanitized.name)"
        )
        persistConfiguration()
    }

    @discardableResult
    func issueVirtualKey(
        name: String,
        workspaceID: UUID?,
        allowedModels: Set<String> = [],
        requestsPerMinute: Int = 120,
        monthlyBudgetUSD: Double? = nil,
        expiresAt: Date? = nil
    ) -> String? {
        let sanitizedName = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        guard !sanitizedName.isEmpty else {
            notice = "虚拟密钥名称不能为空。"
            return nil
        }
        if let workspaceID,
           !configuration.workspaces.contains(where: { $0.id == workspaceID && $0.enabled })
        {
            notice = "所选工作区不存在或已停用。"
            return nil
        }
        let token = "mhv_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let key = VirtualAccessKey(
            name: sanitizedName,
            tokenDigest: AccessTokenHasher.digest(token),
            workspaceID: workspaceID,
            allowedModels: Set(allowedModels.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }),
            requestsPerMinute: max(1, min(requestsPerMinute, 10_000)),
            monthlyBudgetUSD: monthlyBudgetUSD.flatMap { $0 > 0 ? $0 : nil },
            expiresAt: expiresAt
        )
        configuration.virtualKeys.append(key)
        lastIssuedVirtualKeyToken = token
        appendSecurityAudit(
            action: .virtualKeyCreated,
            actor: "local-user",
            outcome: "created",
            detail: "创建虚拟密钥：\(sanitizedName)；原始令牌未写入配置"
        )
        persistConfiguration()
        return token
    }

    func revokeVirtualKey(_ key: VirtualAccessKey) {
        guard let index = configuration.virtualKeys.firstIndex(where: { $0.id == key.id }) else {
            return
        }
        configuration.virtualKeys[index].enabled = false
        appendSecurityAudit(
            action: .virtualKeyRevoked,
            actor: "local-user",
            outcome: "revoked",
            detail: "撤销虚拟密钥：\(key.name)"
        )
        persistConfiguration()
    }

    func clearIssuedVirtualKeyToken() {
        lastIssuedVirtualKeyToken = nil
    }

    private func appendSecurityAudit(
        action: SecurityAuditAction,
        actor: String,
        outcome: String,
        detail: String
    ) {
        configuration.securityAudit.insert(
            SecurityAuditEvent(
                action: action,
                actor: String(actor.prefix(120)),
                outcome: String(outcome.prefix(120)),
                detail: String(detail.prefix(500))
            ),
            at: 0
        )
        if configuration.securityAudit.count > 1_000 {
            configuration.securityAudit.removeLast(configuration.securityAudit.count - 1_000)
        }
    }

    private func gatewayDataPlaneSnapshot() -> GatewayDataPlaneSnapshot {
        GatewayDataPlaneSnapshot(
            providers: providers,
            routes: routes,
            health: healthIndex,
            usage: configuration.usage,
            routingRule: configuration.routing.activeRule,
            accessPolicy: currentRoutingAccessPolicy(),
            resilienceSettings: configuration.operational.resilience,
            contextOptimization: configuration.operational.contextOptimization,
            budget: configuration.operational.budget,
            router: router,
            providerClient: providerClient,
            resilience: resilience
        )
    }

    func startServer() {
        guard !isServerRunning else { return }
        serverError = nil
        let instance = LocalAPIServer(
            handler: { [weak self] request in
                guard let self else {
                    return .json(statusCode: 503, object: Self.errorObject("gateway_unavailable", "网关不可用"))
                }
                return await self.handle(request)
            },
            streamHandler: { [weak self] request in
                guard let self else { return nil }
                return await self.streamingResponse(for: request)
            }
        )
        server = instance
        do {
            try instance.start(port: configuration.server.port) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let port):
                        self.activePort = port
                        self.isServerRunning = true
                        self.serverError = nil
                    case .failure(let error):
                        self.isServerRunning = false
                        self.activePort = nil
                        self.serverError = error.localizedDescription
                    }
                    self.publishWidgetSnapshot()
                }
            }
        } catch {
            serverError = error.localizedDescription
            server = nil
            publishWidgetSnapshot()
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isServerRunning = false
        activePort = nil
        flushPendingPersistence()
        publishWidgetSnapshot()
    }

    func regenerateGatewayToken() {
        let token = "mh_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try KeychainStore.save(token, account: KeychainStore.gatewayTokenAccount)
            cachedGatewayToken = token
            objectWillChange.send()
            notice = String(localized: "访问令牌已更新，旧令牌立即失效。", locale: AppLanguage.saved.locale)
        } catch {
            notice = error.localizedDescription
        }
    }

    func regenerateAgentToken() {
        let token = "mha_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try KeychainStore.save(token, account: KeychainStore.agentTokenAccount)
            cachedAgentToken = token
            objectWillChange.send()
            notice = String(localized: "Agent 管理令牌已更新，旧令牌立即失效。", locale: AppLanguage.saved.locale)
        } catch {
            notice = error.localizedDescription
        }
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
        notice = String(localized: "接口地址已复制。", locale: AppLanguage.saved.locale)
    }

    func copyGatewayToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gatewayToken, forType: .string)
        notice = String(localized: "访问令牌已复制。", locale: AppLanguage.saved.locale)
    }

    func copyAgentToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentToken, forType: .string)
        notice = String(localized: "Agent 管理令牌已复制。", locale: AppLanguage.saved.locale)
    }

    func installMCPToCodex() -> String {
        guard configuration.operational.agentProtocols.mcpEnabled else {
            return "请先启用 MCP（/mcp）后再安装。"
        }
        do {
            let url = try MCPInstaller.installCodex(endpoint: mcpURL, token: agentToken)
            let message = "已写入 Codex MCP 配置：\(url.path)"
            notice = message
            return message
        } catch {
            let message = "Codex MCP 安装失败：\(error.localizedDescription)"
            notice = message
            return message
        }
    }

    func installMCPToClaude() -> String {
        guard configuration.operational.agentProtocols.mcpEnabled else {
            return "请先启用 MCP（/mcp）后再安装。"
        }
        do {
            let url = try MCPInstaller.installClaude(endpoint: mcpURL, token: agentToken)
            let message = "已写入 Claude MCP 配置：\(url.path)"
            notice = message
            return message
        } catch {
            let message = "Claude MCP 安装失败：\(error.localizedDescription)"
            notice = message
            return message
        }
    }

    func copyMCPManualConfiguration() {
        do {
            let snippet = try MCPInstaller.manualSnippet(endpoint: mcpURL, token: agentToken)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
            notice = "手动 MCP 配置已复制；剪贴板包含 Agent 令牌，请勿粘贴到公开位置。"
        } catch {
            notice = "生成手动 MCP 配置失败：\(error.localizedDescription)"
        }
    }

    var cliConfigurationPreview: String {
        """
        # ModelHub 通用兼容 CLI
        export MODELHUB_BASE_URL=\(endpointURL)
        export MODELHUB_API_KEY='<从 ModelHub 复制访问令牌>'

        # Responses API
        POST \(endpointURL)/responses

        # 本机 Agent 协议（使用独立 Agent 令牌）
        MCP  \(serverRootURL)/mcp
        A2A  \(serverRootURL)/.well-known/agent-card.json
        ACP  \(serverRootURL)/acp/manifest.json
        """
    }

    func copyCLIConfigurationPreview() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cliConfigurationPreview, forType: .string)
        notice = String(localized: "CLI 配置预览已复制；占位符未包含任何真实令牌。", locale: AppLanguage.saved.locale)
    }

    func exportConfigurationBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ModelHub-backup-\(UsageAccounting.monthKey()).json"
        panel.title = String(localized: "导出 ModelHub 本地备份", locale: AppLanguage.saved.locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ConfigurationBackup.exportData(
                configuration: configuration,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.8.0"
            )
            try data.write(to: url, options: .atomic)
            notice = String(localized: "备份已导出；Keychain 中的供应商密钥和访问令牌未包含在文件中。", locale: AppLanguage.saved.locale)
        } catch {
            notice = L10n.format("备份导出失败：%@", error.localizedDescription)
        }
    }

    func importConfigurationBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "预览并导入 ModelHub 本地备份", locale: AppLanguage.saved.locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= ConfigurationBackup.maximumBytes else {
                throw ConfigurationBackupError.tooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let preview = try ConfigurationBackup.preview(data)
            let alert = NSAlert()
            alert.messageText = String(localized: "确认导入此备份？", locale: AppLanguage.saved.locale)
            alert.informativeText = L10n.format(
                "版本 %@ · 供应商 %d · 路由 %d · 健康记录 %d · 用量聚合 %d\n\n导入前会在本机创建可回滚副本，密钥不会被覆盖。",
                preview.appVersion,
                preview.providerCount,
                preview.routeCount,
                preview.healthRecordCount,
                preview.usageAggregateCount
            )
            alert.addButton(withTitle: String(localized: "导入", locale: AppLanguage.saved.locale))
            alert.addButton(withTitle: String(localized: "取消", locale: AppLanguage.saved.locale))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            try saveRollbackBackup()
            configuration = try ConfigurationBackup.configuration(from: data)
            configuration.modelHealth = ModelHealthMigration.normalize(
                records: configuration.modelHealth,
                providers: configuration.providers
            )
            rebuildHealthIndex()
            rebuildProxyEndpointIndex()
            persistConfiguration()
            notice = String(localized: "备份已导入；如需撤销，请点击“恢复上次导入前配置”。", locale: AppLanguage.saved.locale)
        } catch {
            notice = L10n.format("备份导入失败：%@", error.localizedDescription)
        }
    }

    func restoreLastRollbackBackup() {
        do {
            let data = try Data(contentsOf: rollbackBackupURL, options: [.mappedIfSafe])
            configuration = try ConfigurationBackup.configuration(from: data)
            configuration.modelHealth = ModelHealthMigration.normalize(
                records: configuration.modelHealth,
                providers: configuration.providers
            )
            rebuildHealthIndex()
            rebuildProxyEndpointIndex()
            persistConfiguration()
            notice = String(localized: "已恢复到上次导入前的本机配置。", locale: AppLanguage.saved.locale)
        } catch {
            notice = String(localized: "没有可恢复的回滚副本，或副本已损坏。", locale: AppLanguage.saved.locale)
        }
    }

    func testProvider(
        _ provider: ProviderConfig,
        allowNativeProbe: Bool = false
    ) async -> String {
        guard let model = provider.models.first, !model.isEmpty else {
            return String(localized: "请先填写至少一个模型名称。", locale: AppLanguage.saved.locale)
        }
        guard let record = await testModel(
            providerID: provider.id,
            model: model,
            allowNativeProbe: allowNativeProbe
        ) else {
            return String(localized: "供应商或模型不存在。", locale: AppLanguage.saved.locale)
        }
        return record.detail
    }

    func healthRecord(providerID: UUID, model: String) -> ModelHealthRecord? {
        healthIndex.record(providerID: providerID, model: model)
    }

    func healthSummary(for provider: ProviderConfig) -> ModelHealthSummary {
        var available = 0
        var unavailable = 0
        var unknown = 0
        var configurationRequired = 0
        var unsupported = 0
        for model in provider.models {
            switch healthIndex.status(providerID: provider.id, model: model) {
            case .available: available += 1
            case .unavailable: unavailable += 1
            case .unknown: unknown += 1
            case .configurationRequired: configurationRequired += 1
            case .unsupported: unsupported += 1
            }
        }
        return ModelHealthSummary(
            total: provider.models.count,
            available: available,
            unavailable: unavailable,
            unknown: unknown,
            configurationRequired: configurationRequired,
            unsupported: unsupported
        )
    }

    func orderedModels(for provider: ProviderConfig) -> [String] {
        healthIndex.order(models: provider.models, providerID: provider.id)
    }

    func recoverableTransientHealthCount(providerID: UUID? = nil) -> Int {
        configuration.modelHealth.lazy.filter { record in
            (providerID == nil || record.providerID == providerID)
                && ModelHealthRecoveryPolicy.isRecoverable(record)
        }.count
    }

    func recentModelHealthActivities(
        providerID: UUID? = nil,
        limit: Int = 5
    ) -> [ModelHealthActivity] {
        guard limit > 0 else { return [] }
        return Array(configuration.modelHealthActivities.lazy.filter { activity in
            guard let providerID else { return true }
            return activity.providerID == nil || activity.providerID == providerID
        }.prefix(limit))
    }

    @discardableResult
    func recoverTransientNetworkHealth(providerID: UUID? = nil) -> Int {
        guard !isTestingModels else { return 0 }
        let startedAt = Date()
        let result = ModelHealthRecoveryPolicy.recovering(
            records: configuration.modelHealth,
            providerID: providerID,
            at: startedAt
        )
        guard result.recoveredCount > 0 else {
            notice = String(
                localized: "没有可安全恢复的瞬态网络故障记录。",
                locale: AppLanguage.saved.locale
            )
            return 0
        }

        configuration.modelHealth = result.records
        rebuildHealthIndex()
        invalidateCatalogCaches()
        appendModelHealthActivity(
            ModelHealthActivity(
                kind: .transientRecovery,
                startedAt: startedAt,
                completedAt: .now,
                providerID: providerID,
                total: result.recoveredCount,
                completed: result.recoveredCount,
                recoveredToUnknown: result.recoveredCount
            )
        )
        persistConfiguration()
        notice = L10n.format(
            "已将 %d 条瞬态网络故障隔离恢复为待验证；没有模型被直接标记为可用，也没有调用供应商。",
            result.recoveredCount
        )
        return result.recoveredCount
    }

    func isTesting(providerID: UUID, model: String) -> Bool {
        testingModelIDs.contains(Self.modelTestKey(providerID: providerID, model: model))
    }

    func markModelAvailable(providerID: UUID, model: String) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              provider.models.contains(model)
        else { return }
        upsertHealthRecord(
            ModelHealthRecord(
                providerID: providerID,
                model: model,
                status: .available,
                detail: "人工解除隔离并标记为可用"
            )
        )
        persistConfiguration()
        notice = L10n.format("“%@”已解除隔离并恢复路由。", model)
    }

    func testModel(
        providerID: UUID,
        model: String,
        allowNativeProbe: Bool = false
    ) async -> ModelHealthRecord? {
        guard var provider = providers.first(where: { $0.id == providerID }),
              provider.models.contains(model)
        else { return nil }
        if isReviewDemoMode {
            notice = String(localized: "审核演示模式只使用合成数据，不会连接模型供应商或产生费用。", locale: AppLanguage.saved.locale)
            return healthRecord(providerID: providerID, model: model)
        }
        if ModelTestCatalogRefreshPolicy.shouldRefreshCatalog(for: .singleModel) {
            let catalogRefresh = await refreshProviderCatalogForTesting(providerID: providerID)
            guard let refreshedProvider = providers.first(where: { $0.id == providerID }),
                  refreshedProvider.models.contains(model)
            else { return nil }
            provider = refreshedProvider
            if let catalogRefresh { notice = catalogRefresh }
        }
        let nativeProtocol = ModelProbePolicy.nativeProtocol(
            provider: provider,
            model: model
        )
        if let existing = healthRecord(providerID: providerID, model: model),
           let nativeProtocol,
           ModelProbePolicy.shouldSkipNativeProbe(
               status: existing.status,
               nativeProtocol: nativeProtocol,
               allowNativeProbe: allowNativeProbe
           )
        {
            notice = L10n.format(
                "“%@”已隔离；它需要通过%@接口真实复验，一键聊天检测不会自动解封。",
                model,
                mhLocalized(nativeProtocol.displayName)
            )
            return existing
        }

        var target = ModelTestTarget(
            provider: provider,
            model: model,
            apiKey: providerAPIKeyWithoutInteraction(provider),
            proxy: proxyEndpoint(providerID: provider.id, model: model)
        )
        guard await prepareManagedProxyRuntimeIfNeeded(for: [target]) else {
            return healthRecord(providerID: providerID, model: model)
        }
        target = refreshedProxyTarget(target)
        testingModelIDs.insert(target.key)
        defer { testingModelIDs.remove(target.key) }

        let startedAt = Date()
        let result = await Self.probeModel(
            target,
            allowNativeProbe: allowNativeProbe
        )
        let preservesAvailable = ModelTestHealthUpdatePolicy.shouldPreserve(
            existing: healthRecord(providerID: providerID, model: model),
            after: result
        )
        if preservesAvailable {
            notice = result.record.detail
        } else {
            upsertHealthRecord(result.record)
        }
        var accumulator = ModelTestRunAccumulator(
            total: 1,
            providerID: providerID,
            startedAt: startedAt
        )
        accumulator.observe(result, preservedAvailable: preservesAvailable)
        appendModelHealthActivity(accumulator.activity(cancelled: false))
        persistConfiguration()
        return result.record
    }

    func startTestingQuarantinedModels(
        providerID: UUID,
        selectedModels: [String]
    ) {
        guard !isTestingModels,
              !isReviewDemoMode,
              let provider = providers.first(where: { $0.id == providerID })
        else { return }
        let plan = Self.makeQuarantinedModelTestPlan(
            provider: provider,
            health: healthIndex,
            selectedModels: selectedModels
        )
        guard !plan.candidates.isEmpty else {
            notice = plan.preflightSkipped > 0
                ? L10n.format(
                    "所选的 %d 个生成/原生协议模型继续保持隔离；批量复验不会发起可能高额计费的生成请求。",
                    plan.preflightSkipped
                )
                : L10n.text("所选模型中没有可复验的待验证或已隔离文字模型。")
            return
        }

        let targets = plan.candidates.map { candidate in
            ModelTestTarget(
                provider: candidate.provider,
                model: candidate.model,
                apiKey: providerAPIKeyWithoutInteraction(candidate.provider),
                proxy: proxyEndpoint(
                    providerID: candidate.provider.id,
                    model: candidate.model
                )
            )
        }
        isTestingModels = true
        modelTestProgress = ModelTestProgress(
            total: targets.count + plan.preflightSkipped,
            completed: plan.preflightSkipped,
            available: 0,
            unavailable: 0,
            skipped: plan.preflightSkipped,
            currentProvider: provider.name,
            isCancelled: false
        )
        modelTestTask = Task { [weak self] in
            await self?.runModelTests(
                targets,
                allowNativeProbe: false,
                preflightSkipped: plan.preflightSkipped
            )
        }
    }

    func startTestingAllModels(
        providerID: UUID? = nil,
        allowNativeProbe: Bool = false
    ) {
        guard !isTestingModels else { return }
        guard !isReviewDemoMode else {
            notice = String(localized: "审核演示模式不会发起模型测试；当前健康状态均为合成演示数据。", locale: AppLanguage.saved.locale)
            return
        }

        let selectedProviders: [ProviderConfig]
        if let providerID {
            selectedProviders = providers.filter { $0.id == providerID }
        } else {
            selectedProviders = providers.filter(\.enabled)
        }

        isTestingModels = true
        modelTestProgress = ModelTestProgress(
            total: selectedProviders.reduce(0) { $0 + $1.models.count },
            completed: 0,
            available: 0,
            unavailable: 0,
            skipped: 0,
            currentProvider: L10n.text("正在重新拉取已配置的模型名录"),
            isCancelled: false
        )
        let providerIDs = selectedProviders.map(\.id)
        modelTestTask = Task { [weak self] in
            await self?.prepareAndRunModelTests(
                providerIDs: providerIDs,
                allowNativeProbe: allowNativeProbe
            )
        }
    }

    private func prepareAndRunModelTests(
        providerIDs: [UUID],
        allowNativeProbe: Bool
    ) async {
        for providerID in providerIDs {
            guard !Task.isCancelled else {
                isTestingModels = false
                modelTestTask = nil
                return
            }
            if let provider = providers.first(where: { $0.id == providerID }) {
                modelTestProgress?.currentProvider = L10n.format(
                    "重新拉取 %@ 的模型名录",
                    provider.name
                )
            }
            _ = await refreshProviderCatalogForTesting(providerID: providerID)
        }
        let refreshedProviders = providers.filter { providerIDs.contains($0.id) }
        let plan = Self.makeManualModelTestPlan(
            providers: refreshedProviders,
            health: healthIndex
        )
        let targets = plan.candidates.map { candidate in
            ModelTestTarget(
                provider: candidate.provider,
                model: candidate.model,
                apiKey: providerAPIKeyWithoutInteraction(candidate.provider),
                proxy: proxyEndpoint(
                    providerID: candidate.provider.id,
                    model: candidate.model
                )
            )
        }
        guard !targets.isEmpty else {
            isTestingModels = false
            modelTestTask = nil
            modelTestProgress = nil
            notice = String(localized: "没有可测试的模型。", locale: AppLanguage.saved.locale)
            return
        }
        modelTestProgress = ModelTestProgress(
            total: targets.count,
            completed: 0,
            available: 0,
            unavailable: 0,
            skipped: 0,
            currentProvider: targets.first?.provider.name ?? "",
            isCancelled: false
        )
        await runModelTests(targets, allowNativeProbe: allowNativeProbe)
    }

    private func refreshProviderCatalogForTesting(providerID: UUID) async -> String? {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            return nil
        }
        let provider = providers[index]
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        guard provider.endpointURLs[catalogKey]?.isEmpty == false else { return nil }
        do {
            let result = try await providerClient.fetchModelCatalog(
                provider: provider,
                apiKey: providerAPIKeyWithoutInteraction(provider)
            )
            guard ProviderModelCatalogMergePolicy.shouldAutomaticallyMerge(
                provider: provider,
                endpoint: result.endpoint
            ) else {
                return L10n.format(
                    "测试前已重新拉取 %d 个目录参考项；该目录不代表可直接调用模型，未自动导入或测试。",
                    result.models.count
                )
            }
            let merged = ProviderModelCatalogImporter.merging(
                existing: provider.models,
                imported: result.models
            )
            var refreshedProvider = providers[index]
            refreshedProvider.models = merged
            let capabilityCount = ProviderModelCapabilityUpdater.apply(
                details: result.capabilityDetails,
                to: &refreshedProvider
            )
            if refreshedProvider != providers[index] {
                providers[index] = refreshedProvider
                configuration.modelHealth = ModelHealthMigration.normalize(
                    records: configuration.modelHealth,
                    providers: providers
                )
                rebuildHealthIndex()
                persistConfiguration()
            }
            return L10n.format(
                "测试前已重新拉取 %d 个模型名录项，并更新 %d 个模型能力参数。",
                result.models.count,
                capabilityCount
            )
        } catch {
            return L10n.format(
                "测试前模型名录拉取失败，继续使用已保存模型：%@",
                error.localizedDescription
            )
        }
    }

    nonisolated static func makeManualModelTestPlan(
        providers: [ProviderConfig],
        health: ModelHealthIndex
    ) -> ManualModelTestPlan {
        var seen = Set<String>()
        var candidates: [ManualModelTestCandidate] = []

        for provider in providers {
            var providerCandidates: [ManualModelTestCandidate] = []
            for model in provider.models {
                let key = modelTestKey(providerID: provider.id, model: model)
                guard seen.insert(key).inserted else { continue }
                providerCandidates.append(
                    ManualModelTestCandidate(provider: provider, model: model)
                )
            }
            var chatCandidates: [ManualModelTestCandidate] = []
            var nativeCandidates: [ManualModelTestCandidate] = []
            for candidate in providerCandidates {
                if ModelProbePolicy.nativeProtocol(
                    provider: candidate.provider,
                    model: candidate.model
                ) == nil {
                    chatCandidates.append(candidate)
                } else {
                    nativeCandidates.append(candidate)
                }
            }
            candidates.append(contentsOf: chatCandidates + nativeCandidates)
        }

        return ManualModelTestPlan(
            candidates: candidates,
            preflightSkipped: 0
        )
    }

    nonisolated static func makeQuarantinedModelTestPlan(
        provider: ProviderConfig,
        health: ModelHealthIndex,
        selectedModels: [String]
    ) -> ManualModelTestPlan {
        let selected = Set(selectedModels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        var candidates: [ManualModelTestCandidate] = []
        var skipped = 0
        for model in provider.models where selected.contains(model) {
            let status = health.status(providerID: provider.id, model: model)
            guard status == .unknown || status == .unavailable else {
                continue
            }
            if ModelProbePolicy.nativeProtocol(provider: provider, model: model) == nil {
                candidates.append(ManualModelTestCandidate(provider: provider, model: model))
            } else {
                skipped += 1
            }
        }
        return ManualModelTestPlan(
            candidates: candidates,
            preflightSkipped: skipped
        )
    }

    func cancelModelTesting() {
        modelTestProgress?.isCancelled = true
        notice = String(localized: "正在停止模型检测…", locale: AppLanguage.saved.locale)
        modelTestTask?.cancel()
    }

    private func prepareManagedProxyRuntimeIfNeeded(
        for targets: [ModelTestTarget]
    ) async -> Bool {
        let settings = (configuration.operational.modelProxy ?? .init()).sanitized
        let requiresRecovery = targets.contains { target in
            ModelTestProxyPreflightPolicy.decision(
                settings: settings,
                providerID: target.provider.id,
                model: target.model,
                managedRuntimeIsRunning: modelProxyRuntime.isRunning
            ) == .requiresManagedRuntimeRecovery
        }
        guard requiresRecovery else { return true }

        modelTestProgress?.currentProvider = L10n.text("正在恢复已分配的模型代理节点")
        proxyRuntimeStatus = L10n.text("正在启动")
        do {
            try await activateModelProxyRuntime(announceResult: false)
            if modelProxyRuntime.isRunning { return true }

            let targetKeys = Set(targets.map {
                "\($0.provider.id.uuidString.lowercased())::\($0.model.trimmingCharacters(in: .whitespacesAndNewlines))"
            })
            let assignedNodeIDs = Set(settings.assignments.compactMap { assignment in
                targetKeys.contains(assignment.id) ? assignment.nodeID : nil
            })
            let subscriptionIDs = Set(settings.nodes.compactMap { node in
                assignedNodeIDs.contains(node.id) ? node.subscriptionID : nil
            })
            let enabledSubscriptionIDs = settings.subscriptions.compactMap { subscription in
                subscription.enabled && subscriptionIDs.contains(subscription.id)
                    ? subscription.id
                    : nil
            }
            guard !enabledSubscriptionIDs.isEmpty else {
                proxyRuntimeStatus = L10n.text("启动失败")
                notice = L10n.text("已分配节点的模型代理配置不完整，本轮检测未开始，也没有改为直连。")
                return false
            }

            await refreshProxySubscriptions(
                ids: enabledSubscriptionIDs,
                allowKeychainInteraction: true,
                announceResult: false
            )
            guard !Task.isCancelled else { return false }
            guard modelProxyRuntime.isRunning else {
                proxyRuntimeStatus = L10n.text("启动失败")
                notice = L10n.text("已分配节点的模型代理未就绪，本轮检测未开始，也没有改为直连。请先更新订阅或完成钥匙串授权。")
                return false
            }
            return true
        } catch {
            modelProxyRuntime.stop()
            proxyRuntimeStatus = L10n.text("启动失败")
            if !Task.isCancelled {
                notice = L10n.format(
                    "已分配节点的模型代理恢复失败，本轮检测未开始，也没有改为直连：%@",
                    error.localizedDescription
                )
            }
            return false
        }
    }

    private func finishModelTestingBeforeProbe(cancelled: Bool) {
        testingModelIDs.removeAll()
        modelTestProgress?.isCancelled = cancelled
        isTestingModels = false
        modelTestTask = nil
        if cancelled {
            notice = String(localized: "模型检测已停止，尚未发起模型请求。", locale: AppLanguage.saved.locale)
        }
    }

    private func refreshedProxyTarget(_ target: ModelTestTarget) -> ModelTestTarget {
        ModelTestTarget(
            provider: target.provider,
            model: target.model,
            apiKey: target.apiKey,
            proxy: proxyEndpoint(
                providerID: target.provider.id,
                model: target.model
            )
        )
    }

    private func runModelTests(
        _ initialTargets: [ModelTestTarget],
        allowNativeProbe: Bool,
        preflightSkipped: Int = 0
    ) async {
        guard await prepareManagedProxyRuntimeIfNeeded(for: initialTargets) else {
            finishModelTestingBeforeProbe(cancelled: Task.isCancelled)
            return
        }
        let targets = initialTargets.map(refreshedProxyTarget)

        var batchSize = ModelTestBatchPolicy.maximumSize
        var start = 0
        var cancelled = false
        var interruptedByManagedProxy = false
        var canaryCompletedProviderIDs: Set<UUID> = []
        var circuitBreaker = ModelTestProviderCircuitBreaker()
        let scopeProviderID: UUID? = Set(targets.map { $0.provider.id }).count == 1
            ? targets.first?.provider.id
            : nil
        var accumulator = ModelTestRunAccumulator(
            total: targets.count + max(0, preflightSkipped),
            providerID: scopeProviderID
        )
        accumulator.observePreflightSkipped(preflightSkipped)

        while start < targets.count {
            if Task.isCancelled {
                cancelled = true
                break
            }

            let providerID = targets[start].provider.id
            var providerEnd = start
            while providerEnd < targets.count,
                  targets[providerEnd].provider.id == providerID
            {
                providerEnd += 1
            }

            if circuitBreaker.shouldSkip(providerID: providerID) {
                let skipped = providerEnd - start
                modelTestProgress?.completed += skipped
                modelTestProgress?.skipped += skipped
                accumulator.observeCircuitOpened(providerID: providerID, skipped: skipped)
                start = providerEnd
                continue
            }

            let wasCanary = !canaryCompletedProviderIDs.contains(providerID)
            let requestedBatchSize = wasCanary ? 1 : batchSize
            let end = min(start + requestedBatchSize, providerEnd)
            var batch = Array(targets[start..<end])
            if !(await prepareManagedProxyRuntimeIfNeeded(for: batch)) {
                cancelled = true
                interruptedByManagedProxy = !Task.isCancelled
                break
            }
            batch = batch.map(refreshedProxyTarget)
            testingModelIDs.formUnion(batch.map(\.key))
            modelTestProgress?.currentProvider = batch.first?.provider.name ?? ""

            let results = await withTaskGroup(of: ModelProbeResult.self) { group in
                for target in batch {
                    group.addTask {
                        await Self.probeModel(
                            target,
                            allowNativeProbe: allowNativeProbe
                        )
                    }
                }
                var results: [ModelProbeResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            canaryCompletedProviderIDs.insert(providerID)
            circuitBreaker.observe(
                providerID: providerID,
                wasCanary: wasCanary,
                transientNetworkFailures: results.map(\.transientNetworkFailure)
            )

            for result in results {
                let record = result.record
                modelTestProgress?.completed += 1
                let preservesAvailable = ModelTestHealthUpdatePolicy.shouldPreserve(
                    existing: healthRecord(
                        providerID: record.providerID,
                        model: record.model
                    ),
                    after: result
                )
                accumulator.observe(result, preservedAvailable: preservesAvailable)
                if preservesAvailable {
                    modelTestProgress?.skipped += 1
                } else if record.status == .available {
                    upsertHealthRecord(record)
                    modelTestProgress?.available += 1
                } else if record.status == .unavailable {
                    upsertHealthRecord(record)
                    modelTestProgress?.unavailable += 1
                } else {
                    upsertHealthRecord(record)
                    modelTestProgress?.skipped += 1
                }
            }
            testingModelIDs.subtract(batch.map(\.key))
            batchSize = ModelTestBatchPolicy.nextSize(
                current: batchSize,
                statusCodes: results.compactMap(\.record.statusCode)
            )
            start = end

            if (modelTestProgress?.completed ?? 0).isMultiple(of: 30) {
                persistConfiguration()
            }
        }

        testingModelIDs.removeAll()
        modelTestProgress?.isCancelled = cancelled
        appendModelHealthActivity(accumulator.activity(cancelled: cancelled))
        persistConfiguration()
        isTestingModels = false
        modelTestTask = nil

        let progress = modelTestProgress
        if interruptedByManagedProxy {
            notice = L10n.format(
                "模型代理运行时未就绪，检测已安全停止，已完成 %d/%d；已分配节点的模型没有改为直连。请先更新订阅或完成钥匙串授权后重试。",
                progress?.completed ?? 0,
                progress?.total ?? 0
            )
        } else if cancelled {
            notice = L10n.format(
                "模型检测已停止，已完成 %d/%d。",
                progress?.completed ?? 0,
                progress?.total ?? 0
            )
        } else {
            notice = L10n.format(
                "模型检测完成：可用 %d，不可用 %d，未发起或需处理 %d；重试 %d，保留上一轮可用 %d，熔断跳过 %d。",
                progress?.available ?? 0,
                progress?.unavailable ?? 0,
                progress?.skipped ?? 0,
                accumulator.retryAttempts,
                accumulator.preservedAvailable,
                accumulator.circuitSkipped
            )
        }
    }

    private func appendModelHealthActivity(_ activity: ModelHealthActivity) {
        configuration.modelHealthActivities = ModelHealthActivityStore.appending(
            activity,
            to: configuration.modelHealthActivities
        )
    }

    private func upsertHealthRecord(_ record: ModelHealthRecord) {
        if let index = configuration.modelHealth.firstIndex(where: {
            $0.providerID == record.providerID
                && $0.model.caseInsensitiveCompare(record.model) == .orderedSame
        }) {
            configuration.modelHealth[index] = record
        } else {
            configuration.modelHealth.append(record)
        }
        healthIndex.upsert(record)
        invalidateCatalogCaches()
    }

    private func updateModelHealth(
        providerID: UUID,
        model: String,
        status: ModelAvailability,
        latency: Int?,
        statusCode: Int?,
        detail: String,
        isTransportFailure: Bool = false,
        attemptedProxyNodeID: String? = nil,
        observeProxyOutcome: Bool = true
    ) {
        if observeProxyOutcome {
            observeProxyFailover(
                providerID: providerID,
                model: model,
                statusCode: statusCode,
                isTransportFailure: isTransportFailure,
                attemptedProxyNodeID: attemptedProxyNodeID
            )
        }
        if RuntimeHealthUpdatePolicy.shouldPreserve(
            existing: healthRecord(providerID: providerID, model: model),
            proposedStatus: status,
            statusCode: statusCode,
            detail: detail,
            isTransportFailure: isTransportFailure
        ) {
            return
        }
        upsertHealthRecord(
            ModelHealthRecord(
                providerID: providerID,
                model: model,
                status: status,
                latencyMilliseconds: latency,
                statusCode: statusCode,
                detail: detail
            )
        )
        scheduleConfigurationPersistence()
    }

    private func observeProxyFailover(
        providerID: UUID,
        model: String,
        statusCode: Int?,
        isTransportFailure: Bool,
        attemptedProxyNodeID: String? = nil
    ) {
        let event: ModelProxyFailoverEvent
        if isTransportFailure {
            event = .transportFailure
        } else if let statusCode {
            event = .httpStatus(statusCode)
        } else {
            event = .succeeded
        }
        observeProxyFailover(
            providerID: providerID,
            model: model,
            event: event,
            attemptedProxyNodeID: attemptedProxyNodeID
        )
    }

    private func observeProxyFailover(
        providerID: UUID,
        model: String,
        event: ModelProxyFailoverEvent,
        attemptedProxyNodeID: String? = nil
    ) {
        let key = Self.modelTestKey(providerID: providerID, model: model)
        guard let current = proxyFailoverStates[key] else { return }
        let transition: ModelProxyFailoverTransition?
        if let attemptedProxyNodeID {
            transition = proxyFailoverIndex.transition(
                from: current,
                attemptedNodeID: attemptedProxyNodeID,
                event: event
            )
            // A nil bound transition is stale feedback from a superseded node.
            guard transition != nil else { return }
        } else {
            transition = proxyFailoverIndex.transition(from: current, event: event)
        }
        guard let transition else {
            proxyFailoverStates.removeValue(forKey: key)
            exhaustedProxyFailoverKeys.remove(key)
            return
        }
        proxyFailoverStates[key] = transition.state
        switch transition.outcome {
        case .stayed:
            let isTransientFailure: Bool = switch event {
            case .transportFailure:
                true
            case .httpStatus(let statusCode):
                (500...599).contains(statusCode)
            case .succeeded, .nonTransientFailure:
                false
            }
            if !isTransientFailure {
                exhaustedProxyFailoverKeys.remove(key)
            }
        case .switched:
            exhaustedProxyFailoverKeys.remove(key)
            let previousPort = proxyFailoverIndex.endpoint(for: current)?.port ?? 0
            let nextPort = proxyFailoverIndex.endpoint(for: transition.state)?.port ?? 0
            appendSecurityAudit(
                action: .proxyNodeSwitched,
                actor: "local-gateway",
                outcome: "switched",
                detail: "代理候选自动切换：provider=\(providerID.uuidString.lowercased()) model=\(String(model.prefix(160))) local_port=\(previousPort)->\(nextPort)；未直连"
            )
            scheduleConfigurationPersistence()
        case .exhausted:
            guard exhaustedProxyFailoverKeys.insert(key).inserted else { return }
            appendSecurityAudit(
                action: .proxyNodeExhausted,
                actor: "local-gateway",
                outcome: "failed_closed",
                detail: "代理候选已耗尽：provider=\(providerID.uuidString.lowercased()) model=\(String(model.prefix(160)))；保持最后一个显式节点，未直连"
            )
            scheduleConfigurationPersistence()
        }
    }

    nonisolated private static func probeModel(
        _ target: ModelTestTarget,
        allowNativeProbe: Bool = false
    ) async -> ModelProbeResult {
        switch ModelProbePolicy.disposition(
            provider: target.provider,
            model: target.model,
            hasAPIKey: !target.apiKey.isEmpty
        ) {
        case .configurationRequired:
            return ModelProbeResult(
                providerID: target.provider.id,
                model: target.model,
                status: .configurationRequired,
                detail: "需要配置 API Key（未发起请求）"
            )
        case .readyForNativeProtocol(let nativeProtocol):
            guard allowNativeProbe,
                  let operation = ModelProbePolicy.nativeOperation(for: nativeProtocol),
                  let payload = ModelProbePolicy.nativeProbePayload(
                      for: nativeProtocol,
                      model: target.model
                  )
            else {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unknown,
                    detail: ModelProbePolicy.nativeProbeUnavailableReason(
                        provider: target.provider,
                        model: target.model,
                        nativeProtocol: nativeProtocol
                    ),
                    deferredNativeProbe: true
                )
            }

            let started = ContinuousClock.now
            do {
                let response = try await ProviderClient().sendNative(
                    rawBody: payload.body,
                    targetModel: target.model,
                    provider: target.provider,
                    apiKey: target.apiKey,
                    operation: operation,
                    contentType: payload.contentType,
                    timeoutInterval: 60,
                    proxy: target.proxy
                )
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let assessment = ModelProbePolicy.nativeResponseAssessment(
                    response,
                    provider: target.provider,
                    operation: operation,
                    model: target.model
                )
                let status = assessment.availability
                let detail: String
                if assessment.isAccepted {
                    detail = "原生\(nativeProtocol.displayName)验证成功 · \(assessment.detail) · \(latency) ms"
                } else if status == .configurationRequired {
                    detail = "API Key、权限或账户状态需要处理 · \(assessment.detail)"
                } else {
                    detail = "原生\(nativeProtocol.displayName)验证失败，已隔离 · \(assessment.detail)"
                }
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: status,
                    latencyMilliseconds: latency,
                    statusCode: assessment.gatewayStatusCode,
                    detail: detail,
                    attemptCount: 1
                )
            } catch let error as ProviderClientError {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: error.isCredentialIssue ? .configurationRequired : .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: error.localizedDescription,
                    attemptCount: 1
                )
            } catch let error as URLError {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "网络错误（\(error.code.rawValue)）",
                    transientNetworkFailure: ModelProbeRetryPolicy
                        .isTransientNetworkError(error),
                    attemptCount: 1
                )
            } catch {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "请求失败",
                    attemptCount: 1
                )
            }
        case .readyForChatProbe:
            break
        }

        let started = ContinuousClock.now

        guard let data = ModelProbePolicy.chatProbeBody(
            provider: target.provider,
            model: target.model
        ) else {
            return ModelProbeResult(
                providerID: target.provider.id,
                model: target.model,
                status: .unavailable,
                detail: "测试请求编码失败"
            )
        }
        var attempt = 1
        while attempt <= ModelProbeRetryPolicy.maximumAttempts {
            if Task.isCancelled {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    detail: "测试已取消",
                    attemptCount: max(0, attempt - 1)
                )
            }
            do {
                let response = try await ProviderClient().send(
                    rawBody: data,
                    targetModel: target.model,
                    provider: target.provider,
                    apiKey: target.apiKey,
                    timeoutInterval: 30,
                    proxy: target.proxy
                )
                let assessment = ModelProbePolicy.providerResponseAssessment(
                    response,
                    provider: target.provider
                )
                if case .retry(let delay) = ModelProbeRetryPolicy.decision(
                    statusCode: assessment.gatewayStatusCode,
                    headers: response.headers,
                    attempt: attempt
                ) {
                    attempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let status = assessment.availability
                let detail: String
                if assessment.isAccepted {
                    detail = "\(assessment.detail) · \(latency) ms"
                } else if status == .configurationRequired {
                    detail = "API Key、权限或账户状态需要处理 · \(assessment.detail)"
                } else {
                    detail = "\(assessment.detail) · \(latency) ms"
                }
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: status,
                    latencyMilliseconds: latency,
                    statusCode: assessment.gatewayStatusCode,
                    detail: detail,
                    attemptCount: attempt
                )
            } catch let error as ProviderClientError {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: error.isCredentialIssue ? .configurationRequired : .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: error.localizedDescription,
                    attemptCount: attempt
                )
            } catch let error as URLError {
                if ModelProbeRetryPolicy.shouldRetryNetworkError(error, attempt: attempt) {
                    attempt += 1
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "网络错误（\(error.code.rawValue)）",
                    transientNetworkFailure: ModelProbeRetryPolicy
                        .isTransientNetworkError(error),
                    attemptCount: attempt
                )
            } catch {
                return ModelProbeResult(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "请求失败",
                    attemptCount: attempt
                )
            }
        }
        return ModelProbeResult(
            providerID: target.provider.id,
            model: target.model,
            status: .unavailable,
            latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
            detail: "请求重试已达上限",
            attemptCount: ModelProbeRetryPolicy.maximumAttempts
        )
    }

    func runConsole(model: String, prompt: String) async {
        await runConsole(model: model, prompt: prompt, operation: .chat)
    }

    func runConsole(
        model: String,
        prompt: String,
        operation: ConsoleOperation
    ) async {
        consoleIsRunning = true
        defer { consoleIsRunning = false }
        if isReviewDemoMode {
            try? await Task.sleep(for: .milliseconds(250))
            let response: [String: Any]
            switch operation {
            case .chat:
                response = [
                    "id": "modelhub-review-demo",
                    "object": "chat.completion",
                    "model": model,
                    "choices": [[
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": String(localized: "这是由 ModelHub 在本机生成的审核演示响应；没有访问任何模型供应商，也不会产生费用。", locale: AppLanguage.saved.locale)
                        ],
                        "finish_reason": "stop"
                    ]],
                    "usage": ["prompt_tokens": 8, "completion_tokens": 18, "total_tokens": 26]
                ]
            case .musicGeneration:
                response = [
                    "id": "modelhub-review-music",
                    "object": "music.generation",
                    "model": model,
                    "status": "completed",
                    "demo": true,
                    "message": "本机合成的音乐协议演示响应；未访问上游，也不会产生费用。"
                ]
            }
            let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            consoleOutput = "HTTP 200 · REVIEW DEMO\n\n" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            record(model: model, provider: "Review Demo", statusCode: 200, latency: 250, detail: "本机合成响应（未访问上游）")
            return
        }
        guard isServerRunning else {
            consoleOutput = String(localized: "本地 API 服务尚未启动。", locale: AppLanguage.saved.locale)
            return
        }

        let path = operation == .musicGeneration
            ? "/music/generations"
            : "/chat/completions"
        guard let url = URL(string: endpointURL + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
        let object: [String: Any]
        switch operation {
        case .chat:
            object = [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "stream": false
            ]
        case .musicGeneration:
            object = [
                "model": model,
                "prompt": prompt,
                "duration": 30,
                "instrumental": true
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let pretty: String
            if let object = try? JSONSerialization.jsonObject(with: data),
               let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                pretty = String(data: formatted, encoding: .utf8) ?? ""
            } else {
                pretty = String(data: data, encoding: .utf8) ?? ""
            }
            consoleOutput = "HTTP \(status)\n\n\(pretty)"
        } catch {
            consoleOutput = error.localizedDescription
        }
    }

    @concurrent
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 204, headers: [:], body: Data())
        }
        if request.method == "GET" && request.path == "/health" {
            return await healthResponse()
        }
        let requestedModel = request.path.hasPrefix("/v1/")
            ? Self.requestModel(from: request)
            : nil
        return await authenticateAndDispatch(request, requestedModel: requestedModel)
    }

    /// Deliberately narrow UI-actor boundary: authentication and access quota
    /// state are copied/updated here, then cache and data-plane execution hop
    /// back to the concurrent gateway runtime.
    private func authenticateAndDispatch(
        _ request: HTTPRequest,
        requestedModel: String?
    ) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 204, headers: [:], body: Data())
        }
        if request.method == "GET" && request.path == "/health" {
            return await healthResponse()
        }
        if let allowedMethods = allowedMethods(for: request.path),
           !allowedMethods.contains(request.method)
        {
            return methodNotAllowedResponse(request.method, allowedMethods: allowedMethods)
        }
        let access: GatewayAccessContext
        if isAgentProtocolPath(request.path) {
            guard isLocalOrigin(request) else {
                return .json(
                    statusCode: 403,
                    object: Self.errorObject("forbidden_origin", "Agent 协议只接受本机 Origin")
                )
            }
            guard isAgentAuthorized(request) else {
                return .json(
                    statusCode: 401,
                    object: Self.errorObject("invalid_agent_token", "缺少或无效的 Agent Bearer 令牌")
                )
            }
            access = .primary
        } else if configuration.server.requireAuthentication {
            guard let authenticated = gatewayAccess(request) else {
                return .json(
                    statusCode: 401,
                    object: Self.errorObject("invalid_api_key", "缺少或无效的 Bearer 访问令牌")
                )
            }
            access = authenticated
        } else {
            access = .primary
        }
        if isMeteredDataPlaneRequest(request),
           let blocked = await accessBlockResponse(
               access: access,
               requestedModel: requestedModel
           )
        {
            return blocked
        }
        return await GatewayRequestScope.$requestID.withValue(request.requestID) {
            await GatewayRequestScope.$access.withValue(access) {
                await self.handleAuthorizedWithCache(request, access: access)
            }
        }
    }

    @concurrent
    private func healthResponse() async -> HTTPResponse {
        let (providerSnapshot, routeSnapshot, healthSnapshot, cache, resilienceController) =
            await MainActor.run {
                (providers, routes, healthIndex, responseCache, resilience)
            }
        async let cacheMetricsValue = cache.metrics()
        async let proxyMetricsValue = ProviderClient.proxySessionMetrics()
        async let resilienceMetricsValue = resilienceController.metrics()
        let freshnessPolicy = ModelHealthFreshnessPolicy()
        var freshnessCounts: [ModelHealthFreshness: Int] = [
            .fresh: 0,
            .stale: 0,
            .never: 0
        ]
        let now = Date()
        for provider in providerSnapshot where provider.enabled {
            for model in provider.models {
                let checkedAt = healthSnapshot.record(
                    providerID: provider.id,
                    model: model
                )?.checkedAt
                let freshness = freshnessPolicy.freshness(checkedAt: checkedAt, at: now)
                freshnessCounts[freshness, default: 0] += 1
            }
        }
        let cacheMetrics = await cacheMetricsValue
        let proxySessionMetrics = await proxyMetricsValue
        let resilienceMetrics = await resilienceMetricsValue
        return .json(statusCode: 200, object: [
            "status": "ok",
            "service": "ModelHub",
            "providers": providerSnapshot.filter(\.enabled).count,
            "routes": routeSnapshot.filter(\.enabled).count,
            "observability": [
                "cache": [
                    "entries": cacheMetrics.entries,
                    "bytes": cacheMetrics.bytes,
                    "fresh_lookups": cacheMetrics.freshLookups,
                    "stale_lookups": cacheMetrics.staleLookups,
                    "misses": cacheMetrics.misses,
                    "insertions": cacheMetrics.insertions,
                    "evictions": cacheMetrics.evictions,
                    "clears": cacheMetrics.clears
                ],
                "proxy_sessions": [
                    "active": proxySessionMetrics.activeSessions,
                    "capacity": proxySessionMetrics.capacity,
                    "created": proxySessionMetrics.createdSessions,
                    "reused": proxySessionMetrics.reusedSessions,
                    "evictions": proxySessionMetrics.evictions
                ],
                "model_health_freshness": [
                    "fresh": freshnessCounts[.fresh, default: 0],
                    "stale": freshnessCounts[.stale, default: 0],
                    "never": freshnessCounts[.never, default: 0],
                    "fresh_window_seconds": Int(freshnessPolicy.freshWindow)
                ],
                "resilience": [
                    "gateway_allowed": resilienceMetrics.gatewayAllowed,
                    "gateway_rate_limited": resilienceMetrics.gatewayRateLimited,
                    "target_allowed": resilienceMetrics.targetAllowed,
                    "target_concurrency_limited": resilienceMetrics.targetConcurrencyLimited,
                    "target_circuit_rejected": resilienceMetrics.targetCircuitRejected,
                    "circuits_opened": resilienceMetrics.circuitsOpened,
                    "transient_failures": resilienceMetrics.transientFailures,
                    "successful_targets": resilienceMetrics.successfulTargets
                ]
            ]
        ])
    }

    @concurrent
    private func handleAuthorizedWithCache(
        _ request: HTTPRequest,
        access: GatewayAccessContext
    ) async -> HTTPResponse {
        let (configuredSettings, cache) = await MainActor.run {
            (configuration.operational.responseCache?.sanitized, responseCache)
        }
        guard let settings = configuredSettings,
              settings.enabled,
              let cacheMetadata = Self.responseCacheRequestMetadata(request)
        else { return await handleAuthorized(request) }

        let accessScope = access.virtualKeyID?.uuidString.lowercased() ?? "primary"
        let key = ResponseCacheKey.digest(
            method: request.method,
            path: request.path,
            body: request.body,
            accessScope: accessScope
        )
        let lookup = await cache.lookup(key: key, settings: settings)
        if case .fresh(let cached) = lookup {
            await recordCacheEvent(
                model: cacheMetadata.model,
                requestID: request.requestID,
                response: cached,
                state: "HIT"
            )
            return Self.cachedResponse(cached, state: "HIT")
        }

        let response = await handleAuthorized(request)
        if (200..<300).contains(response.statusCode),
           response.body.count <= settings.maximumBytes
        {
            await cache.insert(
                key: key,
                response: CachedGatewayResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: response.body
                ),
                settings: settings
            )
        } else if (500..<600).contains(response.statusCode),
                  case .stale(let cached) = lookup
        {
            await recordCacheEvent(
                model: cacheMetadata.model,
                requestID: request.requestID,
                response: cached,
                state: "STALE"
            )
            return Self.cachedResponse(cached, state: "STALE")
        }
        return response
    }

    nonisolated private static func responseCacheRequestMetadata(
        _ request: HTTPRequest
    ) -> GatewayCacheRequestMetadata? {
        guard request.method == "POST",
              ["/v1/chat/completions", "/v1/responses"].contains(request.path),
              request.body.count <= 4 * 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              object["stream"] as? Bool != true
        else { return nil }
        let model = (object["model"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return GatewayCacheRequestMetadata(
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? request.path
        )
    }

    nonisolated private static func cachedResponse(
        _ cached: CachedGatewayResponse,
        state: String
    ) -> HTTPResponse {
        var headers = cached.headers
        for name in ["Content-Length", "Transfer-Encoding", "Connection"] {
            headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        }
        headers["X-ModelHub-Cache"] = state
        headers["Cache-Control"] = "private, no-store"
        return HTTPResponse(
            statusCode: cached.statusCode,
            headers: headers,
            body: cached.body
        )
    }

    private func recordCacheEvent(
        model: String,
        requestID: String,
        response: CachedGatewayResponse,
        state: String
    ) {
        logs.insert(
            GatewayLogEntry(
                model: model,
                provider: "response-cache",
                statusCode: response.statusCode,
                latencyMilliseconds: 0,
                detail: state == "HIT" ? "本地响应缓存命中" : "上游失败，已回退到过期缓存",
                requestID: requestID
            ),
            at: 0
        )
        if logs.count > 500 { logs.removeLast(logs.count - 500) }
        scheduleWidgetSnapshotPublication()
    }

    private func handleAuthorized(_ request: HTTPRequest) async -> HTTPResponse {
        if isMeteredDataPlaneRequest(request) {
            switch await resilience.admitGatewayRequest(
                settings: configuration.operational.resilience
            ) {
            case .allowed:
                break
            case .rateLimited(let retryAfterSeconds):
                return HTTPResponse(
                    statusCode: 429,
                    headers: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Retry-After": String(retryAfterSeconds)
                    ],
                    body: (try? JSONSerialization.data(
                        withJSONObject: Self.errorObject(
                            "gateway_rate_limited",
                            "本机网关已达到每分钟请求上限"
                        )
                    )) ?? Data("{}".utf8)
                )
            }
        }
        if request.method == "GET" && request.path == "/v1/models" {
            return availableModelListResponse()
        }
        if request.method == "GET" && request.path == "/v1/models/available" {
            return availableModelListResponse()
        }
        if request.method == "GET",
           request.path.hasPrefix("/v1/models/"),
           request.path.hasSuffix("/capabilities")
        {
            return modelCapabilitiesResponse(path: request.path)
        }
        if request.method == "GET" && request.path == "/v1/providers" {
            return providerListResponse()
        }
        if request.method == "GET" && request.path == "/v1/analytics" {
            return analyticsResponse()
        }
        if request.method == "POST" && request.path == "/mcp",
           configuration.operational.agentProtocols.mcpEnabled
        {
            if let invocation = LocalAgentProtocols.mcpActionInvocation(
                requestBody: request.body
            ) {
                return await handleMCPAction(
                    invocation,
                    requestBody: request.body
                )
            }
            return agentHTTPResponse(LocalAgentProtocols.mcp(
                requestBody: request.body,
                snapshot: agentSnapshot()
            ))
        }
        if request.method == "POST" && request.path == "/a2a",
           configuration.operational.agentProtocols.a2aEnabled
        {
            return agentHTTPResponse(LocalAgentProtocols.a2a(
                requestBody: request.body,
                snapshot: agentSnapshot()
            ))
        }
        if request.method == "GET" && request.path == "/.well-known/agent-card.json",
           configuration.operational.agentProtocols.a2aEnabled
        {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: LocalAgentProtocols.a2aAgentCard(baseURL: serverRootURL)
            )
        }
        if request.method == "GET" && request.path == "/acp/manifest.json",
           configuration.operational.agentProtocols.acpManifestEnabled
        {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: LocalAgentProtocols.acpManifest(
                    baseURL: serverRootURL,
                    command: Bundle.main.executableURL?
                        .deletingLastPathComponent()
                        .appending(path: "ModelHubACP")
                        .path ?? "ModelHubACP"
                )
            )
        }
        if request.method == "GET" && request.path == "/agent/snapshot" {
            return agentSnapshotResponse()
        }
        if request.path == "/v1/native" {
            return await nativePassthrough(request)
        }
        if request.method == "POST" && request.path == "/v1/chat/completions" {
            return await chatCompletion(request)
        }
        if request.method == "POST" && request.path == "/v1/responses" {
            return await responsesCompletion(request)
        }
        if let nativeRoute = NativeGatewayRoute.match(
            method: request.method,
            path: request.path
        ) {
            return await nativeCompletion(
                request,
                operation: nativeRoute.operation,
                taskID: nativeRoute.taskID
            )
        }
        return .json(statusCode: 404, object: Self.errorObject("not_found", "接口不存在"))
    }

    @concurrent
    private func streamingResponse(for request: HTTPRequest) async -> HTTPStreamResponse? {
        guard request.method == "POST",
              request.path == "/v1/chat/completions" || request.path == "/v1/responses",
              let envelope = try? JSONDecoder().decode(
                  ModelRequestEnvelope.self,
                  from: request.body
              ),
              envelope.stream == true
        else { return nil }
        return await authenticateAndDispatchStreaming(request, envelope: envelope)
    }

    private func authenticateAndDispatchStreaming(
        _ request: HTTPRequest,
        envelope: ModelRequestEnvelope
    ) async -> HTTPStreamResponse? {
        let access: GatewayAccessContext
        if configuration.server.requireAuthentication {
            guard let authenticated = gatewayAccess(request) else {
                return Self.streamResponse(from: .json(
                    statusCode: 401,
                    object: Self.errorObject("invalid_api_key", "缺少或无效的 Bearer 访问令牌")
                ))
            }
            access = authenticated
        } else {
            access = .primary
        }
        if let blocked = await accessBlockResponse(
            access: access,
            requestedModel: envelope.model
        ) {
            return Self.streamResponse(from: blocked)
        }
        return await GatewayRequestScope.$requestID.withValue(request.requestID) {
            await GatewayRequestScope.$access.withValue(access) {
                await self.streamingResponseAuthorized(request, envelope: envelope)
            }
        }
    }

    @concurrent
    private func streamingResponseAuthorized(
        _ request: HTTPRequest,
        envelope: ModelRequestEnvelope
    ) async -> HTTPStreamResponse? {
        let snapshot = await gatewayDataPlaneSnapshot()
        switch await snapshot.resilience.admitGatewayRequest(
            settings: snapshot.resilienceSettings
        ) {
        case .allowed:
            break
        case .rateLimited(let retryAfterSeconds):
            return Self.streamResponse(from: HTTPResponse(
                statusCode: 429,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Retry-After": String(retryAfterSeconds)
                ],
                body: (try? JSONSerialization.data(
                    withJSONObject: Self.errorObject(
                        "gateway_rate_limited",
                        "本机网关已达到每分钟请求上限"
                    )
                )) ?? Data("{}".utf8)
            ))
        }
        if let budget = Self.budgetBlockResponse(
            usage: snapshot.usage,
            budget: snapshot.budget
        ) { return Self.streamResponse(from: budget) }

        let candidates = await snapshot.router.candidates(
            for: envelope.model,
            routes: snapshot.routes,
            providers: snapshot.providers,
            health: snapshot.health,
            usage: snapshot.usage,
            requiredCapabilities: Self.requestCapabilities(from: request.body),
            defaultRule: snapshot.routingRule,
            accessPolicy: snapshot.accessPolicy
        )
        let settings = snapshot.resilienceSettings
        var lastResponse: HTTPResponse?
        for (attemptIndex, target) in candidates
            .prefix(max(1, settings.maxFallbackAttempts))
            .enumerated()
        {
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerID }),
                  request.path == "/v1/chat/completions"
                    || provider.kind.usesUnifiedProtocol,
                  ModelProbePolicy.nativeProtocol(provider: provider, model: target.model) == nil
            else { continue }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await Self.targetBlockResponse(
                target: target,
                usage: snapshot.usage,
                settings: settings,
                resilience: snapshot.resilience
            ) {
                lastResponse = blocked
                continue
            }
            let key = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            let proxyAttempt = await proxyAttempt(
                providerID: provider.id,
                model: target.model
            )
            do {
                let upstream: ProviderStreamResponse
                if request.path == "/v1/responses" {
                    upstream = try await snapshot.providerClient.startResponsesStream(
                        rawBody: request.body,
                        targetModel: target.model,
                        provider: provider,
                        apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                        proxy: proxyAttempt.endpoint
                    )
                } else {
                    let optimized = ContextOptimizer.optimizeChatBody(
                        request.body,
                        settings: snapshot.contextOptimization
                    )
                    upstream = try await snapshot.providerClient.startChatStream(
                        rawBody: optimized.body,
                        targetModel: target.model,
                        provider: provider,
                        apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                        proxy: proxyAttempt.endpoint
                    )
                }

                if upstream.statusCode == 429 || upstream.statusCode >= 500 {
                    let failureBody = try await Self.collect(upstream.body, maximumBytes: 1_048_576)
                    let latency = Self.milliseconds(from: started.duration(to: .now))
                    await observeProxyFailover(
                        providerID: provider.id,
                        model: target.model,
                        event: .httpStatus(upstream.statusCode),
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                    await snapshot.resilience.finishTarget(
                        key,
                        succeeded: false,
                        transientFailure: true,
                        settings: settings
                    )
                    await recordUsage(
                        requestedModel: envelope.model,
                        provider: provider,
                        target: target,
                        statusCode: upstream.statusCode,
                        latency: latency,
                        responseBody: failureBody,
                        contextCharactersSaved: 0
                    )
                    lastResponse = HTTPResponse(
                        statusCode: upstream.statusCode,
                        headers: ["Content-Type": upstream.contentType],
                        body: failureBody
                    )
                    continue
                }
                return await trackedStreamResponse(
                    upstream: upstream,
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    runtimeKey: key,
                    started: started,
                    settings: settings,
                    resilience: snapshot.resilience,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
            } catch let error as ProviderClientError {
                await observeProxyFailover(
                    providerID: provider.id,
                    model: target.model,
                    event: StreamingProxyFailoverPolicy.event(for: error),
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                await snapshot.resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: !error.isInvalidClientRequest
                        && !error.isCredentialAccessUnavailable,
                    settings: settings
                )
                lastResponse = .json(
                    statusCode: error.gatewayStatusCode,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            } catch {
                await observeProxyFailover(
                    providerID: provider.id,
                    model: target.model,
                    event: .transportFailure,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                await snapshot.resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                lastResponse = .json(
                    statusCode: 502,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            }
        }
        let response = lastResponse ?? .json(
            statusCode: candidates.isEmpty ? 404 : 503,
            object: Self.errorObject(
                candidates.isEmpty ? "model_not_found" : "no_available_target",
                candidates.isEmpty ? "没有可用的模型或路由：\(envelope.model)" : "没有可用的流式目标"
            )
        )
        return Self.streamResponse(from: response)
    }

    @concurrent
    private func trackedStreamResponse(
        upstream: ProviderStreamResponse,
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        runtimeKey: TargetRuntimeKey,
        started: ContinuousClock.Instant,
        settings: ResilienceSettings,
        resilience: ResilienceController,
        attemptedProxyNodeID: String?
    ) async -> HTTPStreamResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task { [weak self] in
                var accountingBuffer = Data()
                do {
                    for try await chunk in upstream.body {
                        try Task.checkCancellation()
                        if accountingBuffer.count < 4 * 1_024 * 1_024 {
                            let remaining = 4 * 1_024 * 1_024 - accountingBuffer.count
                            accountingBuffer.append(chunk.prefix(remaining))
                        }
                        continuation.yield(chunk)
                    }
                    let latency = Self.milliseconds(from: started.duration(to: .now))
                    await GatewayStreamingTargetFinalizer.finishBeforeEOF(
                        resilience: resilience,
                        runtimeKey: runtimeKey,
                        succeeded: (200..<300).contains(upstream.statusCode),
                        transientFailure: false,
                        settings: settings,
                        observeProxyOutcome: { [weak self] in
                            guard let self else { return }
                            await self.observeProxyFailover(
                                providerID: provider.id,
                                model: target.model,
                                event: .httpStatus(upstream.statusCode),
                                attemptedProxyNodeID: attemptedProxyNodeID
                            )
                        }
                    )
                    // Release the target slot and publish proxy feedback before
                    // the client can observe EOF and immediately issue another
                    // request. Normal finish must not cancel this producer.
                    continuation.finish()
                    guard let self else { return }
                    await self.recordStreamingUsage(
                        requestedModel: requestedModel,
                        provider: provider,
                        target: target,
                        statusCode: upstream.statusCode,
                        latency: latency,
                        eventStream: accountingBuffer
                    )
                    await self.record(
                        model: requestedModel,
                        provider: "\(provider.name) / \(target.model)",
                        statusCode: upstream.statusCode,
                        latency: latency,
                        detail: "增量流式响应完成"
                    )
                    let healthDetail: String
                    if (200..<300).contains(upstream.statusCode) {
                        healthDetail = "增量流式调用完成"
                    } else {
                        let diagnosticResponse = ProviderResponse(
                            statusCode: upstream.statusCode,
                            headers: upstream.headers,
                            body: accountingBuffer
                        )
                        healthDetail = "增量流式调用失败 · \(ProviderErrorDiagnostics.summary(for: diagnosticResponse))"
                    }
                    await self.updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: ModelAvailability(statusCode: upstream.statusCode),
                        latency: latency,
                        statusCode: upstream.statusCode,
                        detail: healthDetail,
                        attemptedProxyNodeID: attemptedProxyNodeID,
                        observeProxyOutcome: false
                    )
                } catch {
                    let wasCancelled = Task.isCancelled
                    if let self {
                        if let event = StreamingProxyFailoverPolicy.transportEvent(
                            isCancelled: wasCancelled
                        ) {
                            await self.observeProxyFailover(
                                providerID: provider.id,
                                model: target.model,
                                event: event,
                                attemptedProxyNodeID: attemptedProxyNodeID
                            )
                        }
                    }
                    await resilience.finishTarget(
                        runtimeKey,
                        succeeded: false,
                        transientFailure: !wasCancelled,
                        settings: settings
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
        return HTTPStreamResponse(
            statusCode: upstream.statusCode,
            headers: ["Content-Type": upstream.contentType],
            body: stream
        )
    }

    nonisolated private static func streamResponse(from response: HTTPResponse) -> HTTPStreamResponse {
        HTTPStreamResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                if !response.body.isEmpty { continuation.yield(response.body) }
                continuation.finish()
            }
        )
    }

    nonisolated private static func collect(
        _ stream: AsyncThrowingStream<Data, Error>,
        maximumBytes: Int
    ) async throws -> Data {
        var result = Data()
        for try await chunk in stream {
            guard result.count <= maximumBytes - chunk.count else { break }
            result.append(chunk)
        }
        return result
    }

    private func methodNotAllowedResponse(_ method: String, allowedMethods: [String]) -> HTTPResponse {
        HTTPResponse(
            statusCode: 405,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Allow": allowedMethods.joined(separator: ", ")
            ],
            body: (try? JSONSerialization.data(
                withJSONObject: Self.errorObject("method_not_allowed", "该接口不支持 \(method) 方法")
            )) ?? Data("{}".utf8)
        )
    }

    private func allowedMethods(for path: String) -> [String]? {
        if path.hasPrefix("/v1/models/"), path.hasSuffix("/capabilities") {
            return ["GET", "OPTIONS"]
        }
        switch path {
        case "/health", "/v1/models", "/v1/models/available", "/v1/providers",
             "/v1/analytics":
            return ["GET", "OPTIONS"]
        case "/mcp", "/a2a":
            return ["POST", "OPTIONS"]
        case "/.well-known/agent-card.json", "/acp/manifest.json", "/agent/snapshot":
            return ["GET", "OPTIONS"]
        case "/v1/native":
            return ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
        case "/v1/chat/completions", "/v1/responses", "/v1/images/generations", "/v1/music/generations", "/v1/videos/generations",
             "/v1/audio/speech", "/v1/audio/transcriptions", "/v1/embeddings", "/v1/rerank":
            return ["POST", "OPTIONS"]
        case "/v1/videos":
            return ["POST", "OPTIONS"]
        default:
            return NativeGatewayRoute.allowedMethods(for: path)
        }
    }

    @concurrent
    private func chatCompletion(_ request: HTTPRequest) async -> HTTPResponse {
        let snapshot = await gatewayDataPlaneSnapshot()
        let envelope: ModelRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelRequestEnvelope.self, from: request.body)
        } catch {
            return .json(statusCode: 400, object: Self.errorObject("invalid_request", "请求 JSON 无效或缺少 model"))
        }

        if let response = Self.budgetBlockResponse(
            usage: snapshot.usage,
            budget: snapshot.budget
        ) { return response }
        let optimized = ContextOptimizer.optimizeChatBody(
            request.body,
            settings: snapshot.contextOptimization
        )
        let candidates = await snapshot.router.candidates(
            for: envelope.model,
            routes: snapshot.routes,
            providers: snapshot.providers,
            health: snapshot.health,
            usage: snapshot.usage,
            requiredCapabilities: Self.requestCapabilities(from: request.body),
            defaultRule: snapshot.routingRule,
            accessPolicy: snapshot.accessPolicy
        )
        guard !candidates.isEmpty else {
            let quarantined = Self.quarantinedTargets(
                for: envelope.model,
                providers: snapshot.providers,
                routes: snapshot.routes,
                health: snapshot.health
            )
            if !quarantined.isEmpty {
                return .json(
                    statusCode: 409,
                    object: Self.errorObject(
                        "model_quarantined",
                        "模型已隔离，未调用上游；请先在应用中标记为可用：\(quarantined.joined(separator: "、"))"
                    )
                )
            }
            return .json(
                statusCode: 404,
                object: Self.errorObject("model_not_found", "没有可用的模型或路由：\(envelope.model)")
            )
        }

        var lastResponse: HTTPResponse?
        let settings = snapshot.resilienceSettings
        let attemptedTargets = candidates.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerID }) else { continue }
            guard ModelProbePolicy.nativeProtocol(provider: provider, model: target.model) == nil else {
                continue
            }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await Self.targetBlockResponse(
                target: target,
                usage: snapshot.usage,
                settings: settings,
                resilience: snapshot.resilience
            ) {
                lastResponse = blocked
                continue
            }
            let runtimeKey = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            let proxyAttempt = await proxyAttempt(
                providerID: provider.id,
                model: target.model
            )
            do {
                let response = try await snapshot.providerClient.send(
                    rawBody: optimized.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                    proxy: proxyAttempt.endpoint
                )
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let assessment = ModelProbePolicy.providerResponseAssessment(
                    response,
                    provider: provider
                )
                let isSuccess = assessment.isAccepted
                let effectiveStatus = assessment.gatewayStatusCode
                let transient = effectiveStatus == 429 || effectiveStatus >= 500
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: isSuccess,
                    transientFailure: transient,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: effectiveStatus,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: optimized.charactersSaved
                )
                await record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: effectiveStatus,
                    latency: latency,
                    detail: assessment.isAccepted ? "成功" : assessment.detail
                )
                await updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: assessment.availability,
                    latency: latency,
                    statusCode: effectiveStatus,
                    detail: assessment.isAccepted
                        ? "运行调用成功"
                        : "运行调用失败，已隔离 · \(assessment.detail)",
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                let gatewayResponse = HTTPResponse(
                    statusCode: effectiveStatus,
                    headers: ["Content-Type": response.contentType],
                    body: response.body
                )
                lastResponse = gatewayResponse
                if effectiveStatus < 500 && effectiveStatus != 429 {
                    return gatewayResponse
                }
            } catch let error as ProviderClientError {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let status: ModelAvailability?
                let responseStatus: Int
                switch error {
                case .invalidRequest:
                    status = nil
                    responseStatus = 400
                case .missingAPIKey, .credentialMismatch:
                    status = .configurationRequired
                    responseStatus = error.gatewayStatusCode
                case .credentialAccessUnavailable:
                    status = nil
                    responseStatus = error.gatewayStatusCode
                case .invalidBaseURL, .nonHTTPResponse:
                    status = .unavailable
                    responseStatus = 502
                }
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: responseStatus >= 500
                        && !error.isCredentialAccessUnavailable,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: responseStatus,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: optimized.charactersSaved
                )
                if let status {
                    await updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: status,
                        latency: latency,
                        statusCode: nil,
                        detail: "\(error.localizedDescription)，已隔离",
                        isTransportFailure: error.isTransportFailure,
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                await record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: responseStatus,
                    latency: latency,
                    detail: error.localizedDescription
                )
                lastResponse = .json(
                    statusCode: responseStatus,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
                if responseStatus == 400 { return lastResponse! }
            } catch {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: 502,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: optimized.charactersSaved
                )
                await updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: .unavailable,
                    latency: latency,
                    statusCode: nil,
                    detail: "运行调用失败，已隔离 · \(error.localizedDescription)",
                    isTransportFailure: true,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                await record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: 502,
                    latency: latency,
                    detail: error.localizedDescription
                )
                lastResponse = .json(
                    statusCode: 502,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            }
        }
        return lastResponse ?? .json(
            statusCode: 503,
            object: Self.errorObject("no_available_target", "路由中的模型均不可用")
        )
    }

    @concurrent
    private func responsesCompletion(_ request: HTTPRequest) async -> HTTPResponse {
        let snapshot = await gatewayDataPlaneSnapshot()
        let envelope: ModelRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelRequestEnvelope.self, from: request.body)
        } catch {
            return .json(
                statusCode: 400,
                object: Self.errorObject("invalid_request", "请求 JSON 无效或缺少 model")
            )
        }
        if let response = Self.budgetBlockResponse(
            usage: snapshot.usage,
            budget: snapshot.budget
        ) { return response }

        let candidates = await snapshot.router.candidates(
            for: envelope.model,
            routes: snapshot.routes,
            providers: snapshot.providers,
            health: snapshot.health,
            usage: snapshot.usage,
            requiredCapabilities: Self.requestCapabilities(from: request.body),
            defaultRule: snapshot.routingRule,
            accessPolicy: snapshot.accessPolicy
        )
        guard !candidates.isEmpty else {
            let quarantined = Self.quarantinedTargets(
                for: envelope.model,
                providers: snapshot.providers,
                routes: snapshot.routes,
                health: snapshot.health
            )
            return quarantined.isEmpty
                ? .json(
                    statusCode: 404,
                    object: Self.errorObject("model_not_found", "没有可用的模型或路由：\(envelope.model)")
                )
                : .json(
                    statusCode: 409,
                    object: Self.errorObject(
                        "model_quarantined",
                        "模型已隔离，未调用上游：\(quarantined.joined(separator: "、"))"
                    )
                )
        }

        var lastResponse: HTTPResponse?
        let settings = snapshot.resilienceSettings
        let attemptedTargets = candidates.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerID }),
                  provider.kind.usesUnifiedProtocol,
                  ModelProbePolicy.nativeProtocol(provider: provider, model: target.model) == nil
            else { continue }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await Self.targetBlockResponse(
                target: target,
                usage: snapshot.usage,
                settings: settings,
                resilience: snapshot.resilience
            ) {
                lastResponse = blocked
                continue
            }

            let key = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            let proxyAttempt = await proxyAttempt(
                providerID: provider.id,
                model: target.model
            )
            do {
                let response = try await snapshot.providerClient.sendResponses(
                    rawBody: request.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                    proxy: proxyAttempt.endpoint
                )
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let succeeded = (200..<300).contains(response.statusCode)
                await snapshot.resilience.finishTarget(
                    key,
                    succeeded: succeeded,
                    transientFailure: response.statusCode == 429 || response.statusCode >= 500,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: response.statusCode,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: 0
                )
                await record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: response.statusCode,
                    latency: latency,
                    detail: "Responses API 上游响应"
                )
                await updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: ModelAvailability(statusCode: response.statusCode),
                    latency: latency,
                    statusCode: response.statusCode,
                    detail: succeeded
                        ? "Responses API 调用成功"
                        : "Responses API 调用失败，已隔离 · \(ProviderErrorDiagnostics.summary(for: response))",
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                let gatewayResponse = HTTPResponse(
                    statusCode: response.statusCode,
                    headers: ["Content-Type": response.contentType],
                    body: response.body
                )
                lastResponse = gatewayResponse
                if response.statusCode < 500 && response.statusCode != 429 {
                    return gatewayResponse
                }
            } catch let error as ProviderClientError {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let statusCode = error.gatewayStatusCode
                await observeProxyFailover(
                    providerID: provider.id,
                    model: target.model,
                    event: StreamingProxyFailoverPolicy.event(for: error),
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                await snapshot.resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: statusCode >= 500
                        && !error.isCredentialAccessUnavailable,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: statusCode,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                lastResponse = .json(
                    statusCode: statusCode,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
                if statusCode == 400 { return lastResponse! }
            } catch {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                await observeProxyFailover(
                    providerID: provider.id,
                    model: target.model,
                    event: .transportFailure,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
                await snapshot.resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: 502,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                lastResponse = .json(
                    statusCode: 502,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            }
        }
        return lastResponse ?? .json(
            statusCode: 503,
            object: Self.errorObject("no_available_target", "没有支持 Responses API 的可用目标")
        )
    }

    @concurrent
    private func nativeCompletion(
        _ request: HTTPRequest,
        operation: NativeAPIOperation,
        taskID: String? = nil
    ) async -> HTTPResponse {
        let snapshot = await gatewayDataPlaneSnapshot()
        let isTaskQuery = operation == .videoTask || operation == .musicTask
        guard let requestedModel = Self.requestModel(from: request), !requestedModel.isEmpty else {
            let hint = isTaskQuery
                ? "查询生成任务时请通过 ?model=供应商/模型 指定模型"
                : "请求 JSON 缺少 model"
            return .json(statusCode: 400, object: Self.errorObject("invalid_request", hint))
        }
        if let response = Self.budgetBlockResponse(
            usage: snapshot.usage,
            budget: snapshot.budget
        ) { return response }

        let candidates = await snapshot.router.candidates(
            for: requestedModel,
            routes: snapshot.routes,
            providers: snapshot.providers,
            health: snapshot.health,
            usage: snapshot.usage,
            defaultRule: snapshot.routingRule,
            accessPolicy: snapshot.accessPolicy
        )
        if candidates.isEmpty {
            let quarantined = Self.quarantinedTargets(
                for: requestedModel,
                providers: snapshot.providers,
                routes: snapshot.routes,
                health: snapshot.health
            )
            if !quarantined.isEmpty {
                return .json(
                    statusCode: 409,
                    object: Self.errorObject(
                        "model_quarantined",
                        "模型已隔离，未调用上游；请先在应用中标记为可用：\(quarantined.joined(separator: "、"))"
                    )
                )
            }
        }
        let matching = candidates.filter { target in
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerID }) else {
                return false
            }
            return ModelProbePolicy.nativeProtocol(
                provider: provider,
                model: target.model
            ) == operation.modelProtocol
        }
        guard !matching.isEmpty else {
            return .json(
                statusCode: 404,
                object: Self.errorObject(
                    "model_protocol_mismatch",
                    "没有匹配\(operation.modelProtocol.displayName)协议的模型或路由：\(requestedModel)"
                )
            )
        }

        var lastResponse: HTTPResponse?
        let settings = snapshot.resilienceSettings
        let attemptedTargets = matching.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = snapshot.providers.first(where: { $0.id == target.providerID }) else {
                continue
            }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await Self.targetBlockResponse(
                target: target,
                usage: snapshot.usage,
                settings: settings,
                resilience: snapshot.resilience
            ) {
                lastResponse = blocked
                continue
            }
            let runtimeKey = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            let proxyAttempt = await proxyAttempt(
                providerID: provider.id,
                model: target.model
            )
            do {
                let response = try await snapshot.providerClient.sendNative(
                    rawBody: request.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                    operation: operation,
                    taskID: taskID,
                    contentType: request.header("Content-Type") ?? "application/json",
                    proxy: proxyAttempt.endpoint
                )
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let assessment = ModelProbePolicy.nativeResponseAssessment(
                    response,
                    provider: provider,
                    operation: operation,
                    model: target.model
                )
                let isSuccess = assessment.isAccepted
                let effectiveStatus = assessment.gatewayStatusCode
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: isSuccess,
                    transientFailure: effectiveStatus == 429 || effectiveStatus >= 500,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: effectiveStatus,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: 0
                )
                await record(
                    model: requestedModel,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: effectiveStatus,
                    latency: latency,
                    detail: assessment.detail
                )
                if isTaskQuery {
                    await observeProxyFailover(
                        providerID: provider.id,
                        model: target.model,
                        event: .httpStatus(effectiveStatus),
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                if !isTaskQuery {
                    await updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: assessment.availability,
                        latency: latency,
                        statusCode: effectiveStatus,
                        detail: assessment.isAccepted
                            ? "原生\(operation.modelProtocol.displayName)调用成功 · HTTP \(response.statusCode) · \(latency) ms"
                            : "原生\(operation.modelProtocol.displayName)调用失败，已隔离 · \(assessment.detail) · \(latency) ms",
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                let gatewayResponse = HTTPResponse(
                    statusCode: effectiveStatus,
                    headers: ["Content-Type": response.contentType],
                    body: response.body
                )
                lastResponse = gatewayResponse
                if effectiveStatus < 500 && effectiveStatus != 429 {
                    return gatewayResponse
                }
            } catch let error as ProviderClientError {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                let status: ModelAvailability?
                let responseStatus: Int
                switch error {
                case .invalidRequest:
                    status = nil
                    responseStatus = 400
                case .missingAPIKey, .credentialMismatch:
                    status = .configurationRequired
                    responseStatus = error.gatewayStatusCode
                case .credentialAccessUnavailable:
                    status = nil
                    responseStatus = error.gatewayStatusCode
                case .invalidBaseURL, .nonHTTPResponse:
                    status = .unavailable
                    responseStatus = 502
                }
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: responseStatus >= 500
                        && !error.isCredentialAccessUnavailable,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: responseStatus,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                if isTaskQuery || status == nil {
                    await observeProxyFailover(
                        providerID: provider.id,
                        model: target.model,
                        event: StreamingProxyFailoverPolicy.event(for: error),
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                if !isTaskQuery, let status {
                    await updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: status,
                        latency: latency,
                        statusCode: nil,
                        detail: "原生\(operation.modelProtocol.displayName)失败，已隔离 · \(error.localizedDescription)",
                        isTransportFailure: error.isTransportFailure,
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                await record(
                    model: requestedModel,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: responseStatus,
                    latency: latency,
                    detail: error.localizedDescription
                )
                lastResponse = .json(
                    statusCode: responseStatus,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
                if responseStatus == 400 { return lastResponse! }
            } catch {
                let latency = Self.milliseconds(from: started.duration(to: .now))
                await snapshot.resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                await recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: 502,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                if isTaskQuery {
                    await observeProxyFailover(
                        providerID: provider.id,
                        model: target.model,
                        event: .transportFailure,
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                if !isTaskQuery {
                    await updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: .unavailable,
                        latency: latency,
                        statusCode: nil,
                        detail: "原生\(operation.modelProtocol.displayName)失败，已隔离 · \(error.localizedDescription)",
                        isTransportFailure: true,
                        attemptedProxyNodeID: proxyAttempt.failoverNodeID
                    )
                }
                await record(
                    model: requestedModel,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: 502,
                    latency: latency,
                    detail: error.localizedDescription
                )
                lastResponse = .json(
                    statusCode: 502,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            }
        }
        return lastResponse ?? .json(
            statusCode: 503,
            object: Self.errorObject("no_available_target", "路由中的原生协议模型均不可用")
        )
    }

    @concurrent
    private func nativePassthrough(_ request: HTTPRequest) async -> HTTPResponse {
        let snapshot = await gatewayDataPlaneSnapshot()
        guard let providerSelector = request.queryItem("provider"),
              !providerSelector.isEmpty,
              let modelSelector = request.queryItem("model"),
              !modelSelector.isEmpty,
              let upstreamPath = request.queryItem("path"),
              !upstreamPath.isEmpty
        else {
            return .json(
                statusCode: 400,
                object: Self.errorObject(
                    "invalid_request",
                    "原生透传需要 ?provider=供应商ID或名称&model=模型&path=/供应商原生路径"
                )
            )
        }
        guard let provider = snapshot.providers.first(where: {
            $0.enabled && (
                $0.id.uuidString.caseInsensitiveCompare(providerSelector) == .orderedSame
                    || $0.name.caseInsensitiveCompare(providerSelector) == .orderedSame
            )
        }) else {
            return .json(
                statusCode: 404,
                object: Self.errorObject("provider_not_found", "没有找到已启用的供应商：\(providerSelector)")
            )
        }
        guard let targetModel = provider.models.first(where: { model in
            [
                model,
                "\(provider.name)/\(model)",
                "\(provider.id.uuidString)/\(model)"
            ].contains {
                $0.caseInsensitiveCompare(modelSelector) == .orderedSame
            }
        }) else {
            return .json(
                statusCode: 404,
                object: Self.errorObject("model_not_found", "供应商中没有模型：\(modelSelector)")
            )
        }
        let currentStatus = snapshot.health.status(providerID: provider.id, model: targetModel)
        guard currentStatus.isRoutable else {
            return .json(
                statusCode: 409,
                object: Self.errorObject(
                    "model_quarantined",
                    "模型已隔离，需先在应用中标记为可用：\(provider.name)/\(targetModel)"
                )
            )
        }
        if let response = Self.budgetBlockResponse(
            usage: snapshot.usage,
            budget: snapshot.budget
        ) { return response }
        let target = RouteTarget(
            providerID: provider.id,
            model: targetModel,
            profile: provider.modelProfiles?[targetModel]
        )
        let policyReasons = RoutingPolicyEvaluator.exclusionReasons(
            target: target,
            provider: provider,
            health: snapshot.health,
            usage: snapshot.usage,
            requiredCapabilities: [],
            constraints: nil,
            access: snapshot.accessPolicy
        )
        guard policyReasons.isEmpty else {
            return .json(
                statusCode: 403,
                object: Self.errorObject(
                    "workspace_policy_denied",
                    "工作区策略拒绝此目标：\(policyReasons.joined(separator: "；"))"
                )
            )
        }
        let settings = snapshot.resilienceSettings
        if let blocked = await Self.targetBlockResponse(
            target: target,
            usage: snapshot.usage,
            settings: settings,
            resilience: snapshot.resilience
        ) {
            return blocked
        }
        let runtimeKey = TargetRuntimeKey(providerID: provider.id, model: targetModel)

        let upstreamQueryItems = request.orderedQueryItems.filter {
            $0.name.caseInsensitiveCompare("provider") != .orderedSame
                && $0.name.caseInsensitiveCompare("path") != .orderedSame
                && $0.name.caseInsensitiveCompare("model") != .orderedSame
        }.map {
            NativeQueryItem(name: $0.name, value: $0.value)
        }
        let started = ContinuousClock.now
        let proxyAttempt = await proxyAttempt(
            providerID: provider.id,
            model: targetModel
        )
        do {
            let response = try await snapshot.providerClient.sendNativePassthrough(
                rawBody: request.body,
                method: request.method,
                upstreamPath: upstreamPath,
                orderedQueryItems: upstreamQueryItems,
                provider: provider,
                apiKey: try await Self.dataPlaneAPIKeyAsync(for: provider),
                headers: request.headers,
                proxy: proxyAttempt.endpoint
            )
            let latency = Self.milliseconds(from: started.duration(to: .now))
            await snapshot.resilience.finishTarget(
                runtimeKey,
                succeeded: (200..<300).contains(response.statusCode),
                transientFailure: response.statusCode == 429 || response.statusCode >= 500,
                settings: settings
            )
            await recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: response.statusCode,
                latency: latency,
                responseBody: response.body,
                contextCharactersSaved: 0
            )
            await record(
                model: targetModel,
                provider: provider.name,
                statusCode: response.statusCode,
                latency: latency,
                detail: "供应商专用原生响应"
            )
            await updateModelHealth(
                providerID: provider.id,
                model: targetModel,
                status: ModelAvailability(statusCode: response.statusCode),
                latency: latency,
                statusCode: response.statusCode,
                detail: (200..<300).contains(response.statusCode)
                    ? "原生供应商专用调用成功"
                    : "原生供应商专用调用失败，已隔离 · \(ProviderErrorDiagnostics.summary(for: response))",
                attemptedProxyNodeID: proxyAttempt.failoverNodeID
            )
            return HTTPResponse(
                statusCode: response.statusCode,
                headers: ["Content-Type": response.contentType],
                body: response.body
            )
        } catch let error as ProviderClientError {
            let latency = Self.milliseconds(from: started.duration(to: .now))
            let responseStatus = error.gatewayStatusCode
            await snapshot.resilience.finishTarget(
                runtimeKey,
                succeeded: false,
                transientFailure: responseStatus >= 500
                    && !error.isCredentialAccessUnavailable,
                settings: settings
            )
            await recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: responseStatus,
                latency: latency,
                responseBody: Data(),
                contextCharactersSaved: 0
            )
            switch error {
            case .missingAPIKey, .credentialMismatch:
                await updateModelHealth(
                    providerID: provider.id,
                    model: targetModel,
                    status: .configurationRequired,
                    latency: Self.milliseconds(from: started.duration(to: .now)),
                    statusCode: nil,
                    detail: "原生供应商专用调用凭证不可用，已隔离 · \(error.localizedDescription)",
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
            case .invalidBaseURL, .nonHTTPResponse:
                await updateModelHealth(
                    providerID: provider.id,
                    model: targetModel,
                    status: .unavailable,
                    latency: Self.milliseconds(from: started.duration(to: .now)),
                    statusCode: nil,
                    detail: "原生供应商专用调用失败，已隔离 · \(error.localizedDescription)",
                    isTransportFailure: error.isTransportFailure,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
            case .invalidRequest:
                await observeProxyFailover(
                    providerID: provider.id,
                    model: targetModel,
                    event: .nonTransientFailure,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
            case .credentialAccessUnavailable:
                await observeProxyFailover(
                    providerID: provider.id,
                    model: targetModel,
                    event: .nonTransientFailure,
                    attemptedProxyNodeID: proxyAttempt.failoverNodeID
                )
            }
            return .json(
                statusCode: responseStatus,
                object: Self.errorObject("invalid_native_request", error.localizedDescription)
            )
        } catch {
            let latency = Self.milliseconds(from: started.duration(to: .now))
            await snapshot.resilience.finishTarget(
                runtimeKey,
                succeeded: false,
                transientFailure: true,
                settings: settings
            )
            await recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: 502,
                latency: latency,
                responseBody: Data(),
                contextCharactersSaved: 0
            )
            await updateModelHealth(
                providerID: provider.id,
                model: targetModel,
                status: .unavailable,
                latency: latency,
                statusCode: nil,
                detail: "原生供应商专用调用失败，已隔离 · \(error.localizedDescription)",
                isTransportFailure: true,
                attemptedProxyNodeID: proxyAttempt.failoverNodeID
            )
            await record(
                model: targetModel,
                provider: provider.name,
                statusCode: 502,
                latency: latency,
                detail: error.localizedDescription
            )
            return .json(
                statusCode: 502,
                object: Self.errorObject("upstream_error", error.localizedDescription)
            )
        }
    }

    nonisolated private static func requestModel(from request: HTTPRequest) -> String? {
        if let queryModel = request.queryItem("model"), !queryModel.isEmpty {
            return queryModel
        }
        guard request.header("Content-Type")?.lowercased().contains("application/json") != false,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else {
            return nil
        }
        return object["model"] as? String
    }

    nonisolated private static func requestCapabilities(from body: Data) -> Set<ModelCapability> {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [.chat]
        }
        var capabilities: Set<ModelCapability> = [.chat]
        if let tools = root["tools"] as? [Any], !tools.isEmpty {
            capabilities.insert(.tools)
        }
        func scan(_ value: Any) {
            if let object = value as? [String: Any] {
                if let type = (object["type"] as? String)?.lowercased() {
                    if ["image_url", "input_image"].contains(type) { capabilities.insert(.vision) }
                    if ["input_audio", "audio_url"].contains(type) { capabilities.insert(.audio) }
                }
                object.values.forEach(scan)
            } else if let array = value as? [Any] {
                array.forEach(scan)
            }
        }
        scan(root)
        return capabilities
    }

    private func videoTaskID(from path: String) -> String? {
        for prefix in ["/v1/tasks/", "/v1/videos/"] where path.hasPrefix(prefix) {
            let taskID = String(path.dropFirst(prefix.count))
            if !taskID.isEmpty { return taskID }
        }
        return nil
    }

    private func musicTaskID(from path: String) -> String? {
        let prefix = "/v1/music/"
        guard path.hasPrefix(prefix) else { return nil }
        let taskID = String(path.dropFirst(prefix.count))
        return taskID.isEmpty || taskID == "generations" ? nil : taskID
    }

    private func quarantinedTargets(for requestedModel: String) -> [String] {
        let routeTargets: [RouteTarget]
        if let route = routes.first(where: {
            $0.enabled && $0.alias.caseInsensitiveCompare(requestedModel) == .orderedSame
        }) {
            routeTargets = route.targets
        } else {
            routeTargets = providers.filter(\.enabled).flatMap { provider in
                provider.models.compactMap { model in
                    let names = [
                        model,
                        "\(provider.name)/\(model)",
                        "\(provider.id.uuidString)/\(model)"
                    ]
                    guard names.contains(where: {
                        $0.caseInsensitiveCompare(requestedModel) == .orderedSame
                    }) else {
                        return nil
                    }
                    return RouteTarget(providerID: provider.id, model: model)
                }
            }
        }

        return routeTargets.compactMap { target in
            guard healthIndex.status(
                providerID: target.providerID,
                model: target.model
            ).isQuarantined,
            let provider = providers.first(where: { $0.id == target.providerID })
            else {
                return nil
            }
            return "\(provider.name)/\(target.model)"
        }
    }

    private func availableModelListResponse() -> HTTPResponse {
        let access = currentRoutingAccessPolicy()
        let unrestricted = access == .unrestricted
        let now = Date()
        if unrestricted,
           let availableModelListCache,
           availableModelListCacheExpiresAt.map({ $0 > now }) == true
        {
            return availableModelListCache
        }
        let entries = availableModelEntries(access: access)
        let models = entries.map { entry -> [String: Any] in
            var object = modelObject(entry.id, owner: entry.owner)
            object["availability"] = ModelAvailability.available.rawValue
            object["quarantined"] = false
            object["source"] = entry.isRoute ? "route" : "provider"
            addCapabilityMetadata(to: &object, entry: entry, access: access)
            return object
        }
        let response = HTTPResponse.json(
            statusCode: 200,
            object: [
                "object": "list",
                "available_count": models.count,
                "data": models
            ]
        )
        if unrestricted {
            availableModelListCache = response
            availableModelListCacheExpiresAt = now.addingTimeInterval(60)
        }
        return response
    }

    func availableModelIDsForConsole(operation: ConsoleOperation) -> [String] {
        let requiredCapabilities: Set<ModelCapability> = switch operation {
        case .chat: [.chat]
        case .musicGeneration: [.musicGeneration]
        }
        return availableModelEntries(
            access: .unrestricted,
            requiredCapabilities: requiredCapabilities
        ).map(\.id)
    }

    private func availableModelEntries(
        access: RoutingAccessPolicy,
        requiredCapabilities: Set<ModelCapability> = []
    ) -> [AvailableModelEntry] {
        AvailableModelCatalog.entries(
            routes: routes,
            providers: providers,
            health: healthIndex
        ).filter { entry in
            if entry.isRoute,
               let route = routes.first(where: {
                   $0.enabled && $0.alias.caseInsensitiveCompare(entry.id) == .orderedSame
               })
            {
                return route.targets.contains { target in
                    guard let provider = providers.first(where: { $0.id == target.providerID }) else {
                        return false
                    }
                    return RoutingPolicyEvaluator.exclusionReasons(
                        target: target,
                        provider: provider,
                        health: healthIndex,
                        usage: configuration.usage,
                        requiredCapabilities: requiredCapabilities,
                        constraints: route.constraints,
                        access: access
                    ).isEmpty
                }
            }
            guard let providerID = entry.providerID,
                  let targetModel = entry.targetModel,
                  let provider = providers.first(where: { $0.id == providerID })
            else { return false }
            let target = RouteTarget(
                providerID: providerID,
                model: targetModel,
                profile: provider.modelProfiles?[targetModel]
            )
            return RoutingPolicyEvaluator.exclusionReasons(
                target: target,
                provider: provider,
                health: healthIndex,
                usage: configuration.usage,
                requiredCapabilities: requiredCapabilities,
                constraints: nil,
                access: access
            ).isEmpty
        }
    }

    private func modelCapabilitiesResponse(path: String) -> HTTPResponse {
        let prefix = "/v1/models/"
        let suffix = "/capabilities"
        guard path.count > prefix.count + suffix.count else {
            return .json(
                statusCode: 404,
                object: Self.errorObject("model_not_found", "没有指定可用模型")
            )
        }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let encodedID = String(path[start..<end])
        let requestedID = encodedID.removingPercentEncoding ?? encodedID
        let access = currentRoutingAccessPolicy()
        guard let entry = availableModelEntries(access: access).first(where: {
            $0.id.caseInsensitiveCompare(requestedID) == .orderedSame
        }) else {
            return .json(
                statusCode: 404,
                object: Self.errorObject(
                    "model_not_found",
                    "模型不存在、已隔离，或当前访问凭证无权读取"
                )
            )
        }
        var object = modelObject(entry.id, owner: entry.owner)
        object["object"] = "model.capabilities"
        object["availability"] = ModelAvailability.available.rawValue
        addCapabilityMetadata(to: &object, entry: entry, access: access)
        return .json(statusCode: 200, object: object)
    }

    private func addCapabilityMetadata(
        to object: inout [String: Any],
        entry: AvailableModelEntry,
        access: RoutingAccessPolicy
    ) {
        let profiles = targetProfiles(for: entry, access: access)
        let capabilities = Set(profiles.flatMap { $0.capabilities }).sorted {
            $0.rawValue < $1.rawValue
        }
        object["capabilities"] = capabilities.map(\.rawValue)
        let details = profiles.compactMap(\.capabilityDetails)
        if let first = details.first, details.count == profiles.count,
           details.dropFirst().allSatisfy({ $0 == first }) {
            object["constraints"] = capabilityConstraintsObject(first)
            object["constraint_scope"] = "exact"
        } else if !profiles.isEmpty {
            object["constraints"] = [:]
            object["constraint_scope"] = entry.isRoute
                ? "provider_specific"
                : "not_published"
        }
        let records = verificationRecords(for: entry, access: access)
        let policy = ModelHealthFreshnessPolicy()
        let now = Date()
        let freshness: ModelHealthFreshness
        if records.isEmpty {
            freshness = .never
        } else if records.contains(where: {
            policy.freshness(checkedAt: $0.checkedAt, at: now) == .stale
        }) {
            freshness = .stale
        } else {
            freshness = .fresh
        }
        object["verification_freshness"] = freshness.rawValue
        if let verifiedAt = records.map(\.checkedAt).min() {
            object["verified_at"] = Self.verificationTimestampFormatter.string(from: verifiedAt)
        }
    }

    private func verificationRecords(
        for entry: AvailableModelEntry,
        access: RoutingAccessPolicy
    ) -> [ModelHealthRecord] {
        if let providerID = entry.providerID, let model = entry.targetModel {
            return healthIndex.record(providerID: providerID, model: model).map { [$0] } ?? []
        }
        guard let route = routes.first(where: {
            $0.enabled && $0.alias.caseInsensitiveCompare(entry.id) == .orderedSame
        }) else { return [] }
        return route.targets.compactMap { target in
            guard let provider = providers.first(where: { $0.id == target.providerID }),
                  RoutingPolicyEvaluator.exclusionReasons(
                    target: target,
                    provider: provider,
                    health: healthIndex,
                    usage: configuration.usage,
                    requiredCapabilities: [],
                    constraints: route.constraints,
                    access: access
                  ).isEmpty
            else { return nil }
            return healthIndex.record(providerID: target.providerID, model: target.model)
        }
    }

    private func targetProfiles(
        for entry: AvailableModelEntry,
        access: RoutingAccessPolicy
    ) -> [TargetProfile] {
        if let providerID = entry.providerID,
           let model = entry.targetModel,
           let provider = providers.first(where: { $0.id == providerID }) {
            let stored = provider.modelProfiles?.first(where: {
                $0.key.caseInsensitiveCompare(model) == .orderedSame
            })?.value
            var profile = stored ?? TargetProfile()
            if profile.capabilityDetails == nil, provider.kind.isBailian {
                profile.capabilityDetails = QianwenModelCapabilityRegistry.details(for: model)
            }
            return [profile]
        }
        guard let route = routes.first(where: {
            $0.enabled && $0.alias.caseInsensitiveCompare(entry.id) == .orderedSame
        }) else { return [] }
        return route.targets.compactMap { target in
            guard let provider = providers.first(where: { $0.id == target.providerID }),
                  RoutingPolicyEvaluator.exclusionReasons(
                    target: target,
                    provider: provider,
                    health: healthIndex,
                    usage: configuration.usage,
                    requiredCapabilities: [],
                    constraints: route.constraints,
                    access: access
                  ).isEmpty
            else { return nil }
            var profile = target.profile
                ?? provider.modelProfiles?.first(where: {
                    $0.key.caseInsensitiveCompare(target.model) == .orderedSame
                })?.value
                ?? TargetProfile()
            if profile.capabilityDetails == nil, provider.kind.isBailian {
                profile.capabilityDetails = QianwenModelCapabilityRegistry.details(for: target.model)
            }
            return profile
        }
    }

    private func capabilityConstraintsObject(
        _ details: ModelCapabilityDetails
    ) -> [String: Any] {
        var result: [String: Any] = [
            "input_modalities": details.inputModalities.map(\.rawValue),
            "output_modalities": details.outputModalities.map(\.rawValue),
            "source": details.source,
            "parameters": details.parameters.map { parameter in
                var object: [String: Any] = [
                    "name": parameter.name,
                    "required": parameter.required,
                    "allowed_values": parameter.allowedValues
                ]
                if let value = parameter.valueType { object["type"] = value }
                if let value = parameter.minimum { object["minimum"] = value }
                if let value = parameter.maximum { object["maximum"] = value }
                if let value = parameter.step { object["step"] = value }
                if let value = parameter.unit { object["unit"] = value }
                if let value = parameter.description { object["description"] = value }
                return object
            }
        ]
        if let image = details.image {
            var object: [String: Any] = [
                "sizes": image.sizes,
                "aspect_ratios": image.aspectRatios
            ]
            if let width = image.widthPixels {
                object["width_pixels"] = numericConstraintObject(width)
            }
            if let height = image.heightPixels {
                object["height_pixels"] = numericConstraintObject(height)
            }
            if let maximum = image.maximumOutputs { object["maximum_outputs"] = maximum }
            result["image"] = object
        }
        if let video = details.video {
            var object: [String: Any] = [
                "resolutions": video.resolutions,
                "aspect_ratios": video.aspectRatios
            ]
            if let duration = video.durationsSeconds {
                switch duration {
                case .values(let values):
                    object["durations_seconds"] = ["values": values]
                case .range(let minimum, let maximum, let step):
                    var range: [String: Any] = ["minimum": minimum, "maximum": maximum]
                    if let step { range["step"] = step }
                    object["durations_seconds"] = range
                }
            }
            result["video"] = object
        }
        if let audio = details.audio {
            result["audio"] = [
                "formats": audio.formats,
                "sample_rates_hz": audio.sampleRatesHz
            ]
        }
        if let updatedAt = details.updatedAt {
            result["updated_at"] = ISO8601DateFormatter().string(from: updatedAt)
        }
        return result
    }

    private func numericConstraintObject(
        _ constraint: ModelNumericConstraint
    ) -> [String: Any] {
        switch constraint {
        case .values(let values):
            return ["values": values]
        case .range(let minimum, let maximum, let step):
            var object: [String: Any] = [
                "minimum": minimum,
                "maximum": maximum
            ]
            if let step { object["step"] = step }
            return object
        }
    }

    private func providerListResponse() -> HTTPResponse {
        let access = currentRoutingAccessPolicy()
        let unrestricted = access == .unrestricted
        if unrestricted, let providerListCache { return providerListCache }
        let data: [[String: Any]] = providers.filter { provider in
            access.allowedProviderIDs.isEmpty || access.allowedProviderIDs.contains(provider.id)
        }.map {
            [
                "id": $0.id.uuidString.lowercased(),
                "name": $0.name,
                "kind": $0.kind.rawValue,
                "enabled": $0.enabled,
                "base_url": $0.baseURL
            ]
        }
        let response = HTTPResponse.json(
            statusCode: 200,
            object: ["object": "list", "data": data]
        )
        if unrestricted { providerListCache = response }
        return response
    }

    private func analyticsResponse() -> HTTPResponse {
        let month = UsageAccounting.monthKey()
        let rows = configuration.usage
            .filter { $0.month == month }
            .map { item -> [String: Any] in
                [
                    "requested_model": item.requestedModel,
                    "provider": item.providerName,
                    "model": item.model,
                    "requests": item.requests,
                    "successful_requests": item.successfulRequests,
                    "success_rate": item.requests > 0
                        ? Double(item.successfulRequests) / Double(item.requests)
                        : 0,
                    "average_latency_ms": item.averageLatencyMilliseconds,
                    "input_tokens": item.inputTokens,
                    "output_tokens": item.outputTokens,
                    "priced_requests": item.pricedRequests,
                    "estimated_cost_usd": item.estimatedCostUSD,
                    "context_characters_saved": item.contextCharactersSaved,
                    "last_used_at": ISO8601DateFormatter().string(from: item.lastUsedAt)
                ]
            }
        return .json(statusCode: 200, object: [
            "object": "local.analytics",
            "month": month,
            "stores_request_bodies": false,
            "estimated_cost_usd": UsageAccounting.currentMonthCost(in: configuration.usage),
            "data": rows
        ])
    }

    private func isMeteredDataPlaneRequest(_ request: HTTPRequest) -> Bool {
        guard request.method != "GET"
                || videoTaskID(from: request.path) != nil
                || musicTaskID(from: request.path) != nil
        else {
            return false
        }
        return request.path.hasPrefix("/v1/")
    }

    private func budgetBlockResponse() -> HTTPResponse? {
        let budget = configuration.operational.budget
        guard budget.hardLimitEnabled,
              let limit = budget.monthlyLimitUSD,
              limit > 0,
              UsageAccounting.currentMonthCost(in: configuration.usage) >= limit
        else { return nil }
        return .json(
            statusCode: 429,
            object: Self.errorObject(
                "monthly_budget_exhausted",
                "已达到本机设置的月度费用上限；未调用上游"
            )
        )
    }

    nonisolated private static func budgetBlockResponse(
        usage: [UsageAggregate],
        budget: BudgetSettings
    ) -> HTTPResponse? {
        guard budget.hardLimitEnabled,
              let limit = budget.monthlyLimitUSD,
              limit > 0,
              UsageAccounting.currentMonthCost(in: usage) >= limit
        else { return nil }
        return .json(
            statusCode: 429,
            object: errorObject(
                "monthly_budget_exhausted",
                "已达到本机设置的月度费用上限；未调用上游"
            )
        )
    }

    nonisolated private static func targetBlockResponse(
        target: RouteTarget,
        usage: [UsageAggregate],
        settings: ResilienceSettings,
        resilience: ResilienceController
    ) async -> HTTPResponse? {
        if let tokenLimit = target.profile?.monthlyTokenLimit,
           tokenLimit > 0,
           UsageAccounting.currentMonthTokens(
               in: usage,
               providerID: target.providerID,
               model: target.model
           ) >= tokenLimit
        {
            return .json(
                statusCode: 429,
                object: errorObject(
                    "model_quota_exhausted",
                    "该模型已达到本机设置的月度 Token 上限；未调用上游"
                )
            )
        }
        let key = TargetRuntimeKey(providerID: target.providerID, model: target.model)
        switch await resilience.beginTarget(key, settings: settings) {
        case .allowed:
            return nil
        case .concurrencyLimited:
            return .json(
                statusCode: 503,
                object: errorObject("target_busy", "该模型已达到并发上限，正在尝试回退目标")
            )
        case .circuitOpen(let retryAfterSeconds):
            return HTTPResponse(
                statusCode: 503,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Retry-After": String(retryAfterSeconds)
                ],
                body: (try? JSONSerialization.data(
                    withJSONObject: errorObject(
                        "target_circuit_open",
                        "该模型熔断器尚未冷却，正在尝试回退目标"
                    )
                )) ?? Data("{}".utf8)
            )
        }
    }

    nonisolated private static func quarantinedTargets(
        for requestedModel: String,
        providers: [ProviderConfig],
        routes: [RouteConfig],
        health: ModelHealthIndex
    ) -> [String] {
        let routeTargets: [RouteTarget]
        if let route = routes.first(where: {
            $0.enabled && $0.alias.caseInsensitiveCompare(requestedModel) == .orderedSame
        }) {
            routeTargets = route.targets
        } else {
            routeTargets = providers.filter(\.enabled).flatMap { provider in
                provider.models.compactMap { model in
                    let names = [
                        model,
                        "\(provider.name)/\(model)",
                        "\(provider.id.uuidString)/\(model)"
                    ]
                    guard names.contains(where: {
                        $0.caseInsensitiveCompare(requestedModel) == .orderedSame
                    }) else { return nil }
                    return RouteTarget(providerID: provider.id, model: model)
                }
            }
        }
        return routeTargets.compactMap { target in
            guard health.status(providerID: target.providerID, model: target.model).isQuarantined,
                  let provider = providers.first(where: { $0.id == target.providerID })
            else { return nil }
            return "\(provider.name)/\(target.model)"
        }
    }

    nonisolated private static func dataPlaneAPIKeyAsync(
        for provider: ProviderConfig
    ) async throws -> String {
        try DataPlaneCredentialAccessPolicy.apiKey(
            from: await KeychainStore.readWithoutInteractionAsync(
                account: KeychainStore.providerAccount(provider.id)
            )
        )
    }

    private func targetBlockResponse(
        target: RouteTarget,
        settings: ResilienceSettings
    ) async -> HTTPResponse? {
        if let tokenLimit = target.profile?.monthlyTokenLimit,
           tokenLimit > 0,
           UsageAccounting.currentMonthTokens(
                in: configuration.usage,
                providerID: target.providerID,
                model: target.model
           ) >= tokenLimit
        {
            return .json(
                statusCode: 429,
                object: Self.errorObject(
                    "model_quota_exhausted",
                    "该模型已达到本机设置的月度 Token 上限；未调用上游"
                )
            )
        }

        let key = TargetRuntimeKey(providerID: target.providerID, model: target.model)
        switch await resilience.beginTarget(key, settings: settings) {
        case .allowed:
            return nil
        case .concurrencyLimited:
            return .json(
                statusCode: 503,
                object: Self.errorObject("target_busy", "该模型已达到并发上限，正在尝试回退目标")
            )
        case .circuitOpen(let retryAfterSeconds):
            return HTTPResponse(
                statusCode: 503,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Retry-After": String(retryAfterSeconds)
                ],
                body: (try? JSONSerialization.data(
                    withJSONObject: Self.errorObject(
                        "target_circuit_open",
                        "该模型熔断器尚未冷却，正在尝试回退目标"
                    )
                )) ?? Data("{}".utf8)
            )
        }
    }

    @concurrent
    private func recordUsage(
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        statusCode: Int,
        latency: Int,
        responseBody: Data,
        contextCharactersSaved: Int
    ) async {
        let tokens = UsageAccounting.tokenCounts(from: responseBody)
        let profile = target.profile ?? provider.modelProfiles?[target.model]
        let cost = UsageAccounting.estimatedCostUSD(tokens: tokens, profile: profile)
        await applyUsage(
            requestedModel: requestedModel,
            provider: provider,
            target: target,
            statusCode: statusCode,
            latency: latency,
            sample: GatewayUsageSample(tokens: tokens, estimatedCostUSD: cost),
            contextCharactersSaved: contextCharactersSaved
        )
    }

    @concurrent
    private func recordStreamingUsage(
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        statusCode: Int,
        latency: Int,
        eventStream: Data
    ) async {
        let tokens = UsageAccounting.tokenCounts(fromEventStream: eventStream)
        let profile = target.profile ?? provider.modelProfiles?[target.model]
        let cost = UsageAccounting.estimatedCostUSD(tokens: tokens, profile: profile)
        await applyUsage(
            requestedModel: requestedModel,
            provider: provider,
            target: target,
            statusCode: statusCode,
            latency: latency,
            sample: GatewayUsageSample(tokens: tokens, estimatedCostUSD: cost),
            contextCharactersSaved: 0
        )
    }

    private func applyUsage(
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        statusCode: Int,
        latency: Int,
        sample: GatewayUsageSample,
        contextCharactersSaved: Int
    ) {
        configuration.usage = UsageAccounting.recording(
            aggregates: configuration.usage,
            requestedModel: requestedModel,
            providerID: provider.id,
            providerName: provider.name,
            model: target.model,
            statusCode: statusCode,
            latencyMilliseconds: latency,
            tokens: sample.tokens,
            estimatedCostUSD: sample.estimatedCostUSD,
            contextCharactersSaved: contextCharactersSaved,
            retentionMonths: configuration.operational.analyticsRetentionMonths
        )
        recordScopedCost(sample.estimatedCostUSD, statusCode: statusCode)
        scheduleConfigurationPersistence()
    }

    private func recordScopedCost(_ cost: Double?, statusCode: Int) {
        guard (200..<300).contains(statusCode), let cost, cost > 0,
              let keyID = GatewayRequestScope.access?.virtualKeyID,
              let index = configuration.virtualKeys.firstIndex(where: { $0.id == keyID })
        else { return }
        let month = UsageAccounting.monthKey()
        if configuration.virtualKeys[index].usageMonth != month {
            configuration.virtualKeys[index].usageMonth = month
            configuration.virtualKeys[index].requestsThisMonth = 0
            configuration.virtualKeys[index].estimatedCostThisMonth = 0
        }
        configuration.virtualKeys[index].estimatedCostThisMonth += cost
    }

    private func modelObject(_ id: String, owner: String) -> [String: Any] {
        [
            "id": id,
            "object": "model",
            "created": Int(Date().timeIntervalSince1970),
            "owned_by": owner
        ]
    }

    private func gatewayAccess(_ request: HTTPRequest) -> GatewayAccessContext? {
        guard let value = request.header("Authorization") else {
            return nil
        }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else { return nil }
        let token = String(parts[1])
        if let gatewayToken = gatewayTokenWithoutInteraction(),
           AccessTokenHasher.matches(token, digest: AccessTokenHasher.digest(gatewayToken))
        {
            return .primary
        }
        guard let key = configuration.virtualKeys.first(where: {
            $0.isUsable() && AccessTokenHasher.matches(token, digest: $0.tokenDigest)
        }) else { return nil }
        let workspace = key.workspaceID.flatMap { id in
            configuration.workspaces.first { $0.id == id && $0.enabled }
        }
        if key.workspaceID != nil, workspace == nil { return nil }
        let keyModels = key.allowedModels
        let workspaceModels = workspace?.allowedModels ?? []
        let allowedModels: Set<String>
        if keyModels.isEmpty { allowedModels = workspaceModels }
        else if workspaceModels.isEmpty { allowedModels = keyModels }
        else { allowedModels = keyModels.intersection(workspaceModels) }
        return GatewayAccessContext(
            virtualKeyID: key.id,
            workspaceID: workspace?.id,
            allowedModels: allowedModels,
            accessPolicy: RoutingAccessPolicy(
                allowedProviderIDs: workspace?.allowedProviderIDs ?? [],
                allowedModels: allowedModels,
                privacy: workspace?.privacy ?? .init()
            )
        )
    }

    private func accessBlockResponse(
        access: GatewayAccessContext,
        requestedModel: String?
    ) async -> HTTPResponse? {
        guard let keyID = access.virtualKeyID,
              let index = configuration.virtualKeys.firstIndex(where: { $0.id == keyID })
        else { return nil }
        var key = configuration.virtualKeys[index]
        let month = UsageAccounting.monthKey()
        if key.usageMonth != month {
            key.usageMonth = month
            key.requestsThisMonth = 0
            key.estimatedCostThisMonth = 0
        }
        if let model = requestedModel, !access.allowedModels.isEmpty,
           !access.allowedModels.contains(model.lowercased())
        {
            appendSecurityAudit(
                action: .accessDenied,
                actor: key.name,
                outcome: "model_denied",
                detail: "虚拟密钥请求了未授权模型；未记录请求正文"
            )
            scheduleConfigurationPersistence()
            return .json(
                statusCode: 403,
                object: Self.errorObject("model_not_allowed", "此虚拟密钥无权访问该模型")
            )
        }
        if let limit = key.monthlyBudgetUSD,
           key.estimatedCostThisMonth >= limit
        {
            return .json(
                statusCode: 429,
                object: Self.errorObject("virtual_key_budget_exhausted", "虚拟密钥已达到月度预算")
            )
        }
        if let workspaceID = access.workspaceID,
           let workspace = configuration.workspaces.first(where: { $0.id == workspaceID }),
           let limit = workspace.monthlyBudgetUSD
        {
            let spent = configuration.virtualKeys.lazy.filter {
                $0.workspaceID == workspaceID && $0.usageMonth == month
            }.reduce(0) { $0 + $1.estimatedCostThisMonth }
            if spent >= limit {
                return .json(
                    statusCode: 429,
                    object: Self.errorObject("workspace_budget_exhausted", "工作区已达到月度预算")
                )
            }
        }
        switch await scopedRateLimiter.admit(
            keyID: key.id,
            requestsPerMinute: key.requestsPerMinute
        ) {
        case .allowed:
            key.requestsThisMonth += 1
            key.lastUsedAt = .now
            configuration.virtualKeys[index] = key
            scheduleConfigurationPersistence()
            return nil
        case .rateLimited(let retryAfterSeconds):
            return HTTPResponse(
                statusCode: 429,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Retry-After": String(retryAfterSeconds)
                ],
                body: (try? JSONSerialization.data(
                    withJSONObject: Self.errorObject(
                        "virtual_key_rate_limited",
                        "虚拟密钥已达到每分钟请求上限"
                    )
                )) ?? Data("{}".utf8)
            )
        }
    }

    private func currentRoutingAccessPolicy() -> RoutingAccessPolicy {
        GatewayRequestScope.access?.accessPolicy ?? .unrestricted
    }

    private func isAgentAuthorized(_ request: HTTPRequest) -> Bool {
        guard let value = request.header("Authorization") else { return false }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame,
              let expected = agentTokenWithoutInteraction()
        else { return false }
        return String(parts[1]) == expected
    }

    private func isAgentProtocolPath(_ path: String) -> Bool {
        ["/mcp", "/a2a", "/.well-known/agent-card.json", "/acp/manifest.json",
         "/agent/snapshot"]
            .contains(path)
    }

    private func isLocalOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.header("Origin") else { return true }
        guard let components = URLComponents(string: origin),
              let host = components.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func createGatewayToken() -> String {
        let token = "mh_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try KeychainStore.save(token, account: KeychainStore.gatewayTokenAccount)
            cachedGatewayToken = token
            return token
        } catch {
            notice = error.localizedDescription
            return ""
        }
    }

    private func createAgentToken() -> String {
        let token = "mha_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try KeychainStore.save(token, account: KeychainStore.agentTokenAccount)
            cachedAgentToken = token
            return token
        } catch {
            notice = error.localizedDescription
            return ""
        }
    }

    private func gatewayTokenWithoutInteraction() -> String? {
        cachedGatewayToken
    }

    private func agentTokenWithoutInteraction() -> String? {
        cachedAgentToken
    }

    private func agentSnapshot() -> AgentReadOnlySnapshot {
        let month = UsageAccounting.monthKey()
        let usage = configuration.usage.filter { $0.month == month }
        return AgentReadOnlySnapshot(
            serviceRunning: isServerRunning,
            baseURL: endpointURL,
            availableModels: AvailableModelCatalog.entries(
                routes: routes,
                providers: providers,
                health: healthIndex
            ).map(\.id),
            enabledProviders: providers.filter(\.enabled).count,
            enabledRoutes: routes.filter(\.enabled).count,
            month: month,
            requests: usage.reduce(0) { $0 + $1.requests },
            successfulRequests: usage.reduce(0) { $0 + $1.successfulRequests },
            estimatedCostUSD: usage.reduce(0) { $0 + $1.estimatedCostUSD },
            taskContext: configuration.operational.agentProtocols.taskContext
        )
    }

    private func agentSnapshotResponse() -> HTTPResponse {
        let snapshot = agentSnapshot()
        return .json(statusCode: 200, object: [
            "running": snapshot.serviceRunning,
            "base_url": snapshot.baseURL,
            "available_models": snapshot.availableModels,
            "enabled_providers": snapshot.enabledProviders,
            "enabled_routes": snapshot.enabledRoutes,
            "usage": [
                "month": snapshot.month,
                "requests": snapshot.requests,
                "successful_requests": snapshot.successfulRequests,
                "estimated_cost_usd": snapshot.estimatedCostUSD,
                "contains_request_or_response_body": false
            ]
        ])
    }

    private func agentHTTPResponse(_ response: AgentProtocolResponse) -> HTTPResponse {
        HTTPResponse(
            statusCode: response.statusCode,
            headers: ["Content-Type": response.contentType + "; charset=utf-8"],
            body: response.body
        )
    }

    private func handleMCPAction(
        _ invocation: MCPActionInvocation,
        requestBody: Data
    ) async -> HTTPResponse {
        let gatewayRequest: MCPGatewayRequest
        do {
            gatewayRequest = try LocalAgentProtocols.gatewayRequest(for: invocation)
        } catch {
            return agentHTTPResponse(LocalAgentProtocols.mcpToolFailure(
                requestBody: requestBody,
                type: "invalid_tool_arguments",
                message: error.localizedDescription
            ))
        }

        let internalRequest = HTTPRequest(
            method: gatewayRequest.method,
            path: gatewayRequest.path,
            queryItems: gatewayRequest.queryItems,
            orderedQueryItems: gatewayRequest.queryItems.sorted { $0.key < $1.key }.map {
                HTTPQueryItem(name: $0.key, value: $0.value)
            },
            headers: [
                "authorization": "Bearer \(gatewayToken)",
                "content-type": "application/json"
            ],
            body: gatewayRequest.body
        )
        let response = await handle(internalRequest)
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? "application/octet-stream"
        return agentHTTPResponse(LocalAgentProtocols.mcpRuntimeResult(
            requestBody: requestBody,
            statusCode: response.statusCode,
            contentType: contentType,
            responseBody: response.body
        ))
    }

    private func record(
        model: String,
        provider: String,
        statusCode: Int,
        latency: Int,
        detail: String
    ) {
        totalRequests += 1
        if (200..<300).contains(statusCode) { successfulRequests += 1 }
        logs.insert(
            GatewayLogEntry(
                model: model,
                provider: provider,
                statusCode: statusCode,
                latencyMilliseconds: latency,
                detail: detail,
                requestID: GatewayRequestScope.requestID
            ),
            at: 0
        )
        if logs.count > 500 { logs.removeLast(logs.count - 500) }
        scheduleWidgetSnapshotPublication()
    }

    private func milliseconds(from duration: Duration) -> Int {
        Self.milliseconds(from: duration)
    }

    nonisolated private static func milliseconds(from duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds * 1_000
        let fractions = components.attoseconds / 1_000_000_000_000_000
        return Int(seconds + fractions)
    }

    nonisolated fileprivate static func modelTestKey(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString.lowercased())/\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    nonisolated private static func errorObject(_ code: String, _ message: String) -> [String: Any] {
        ["error": ["message": message, "type": code, "code": code]]
    }

    private func rebuildHealthIndex() {
        healthIndex = ModelHealthIndex(records: configuration.modelHealth)
        invalidateCatalogCaches()
    }

    private func invalidateCatalogCaches() {
        availableModelListCache = nil
        availableModelListCacheExpiresAt = nil
        providerListCache = nil
    }

    private func loadConfiguration() {
        guard let data = try? Data(contentsOf: configurationURL),
              var decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        else { return }
        let rawConfiguration = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let hadRoutingSettings = rawConfiguration?["routing"] != nil
        let storedProviderKinds = (rawConfiguration?["providers"] as? [[String: Any]])?
            .compactMap { $0["kind"] as? String } ?? []
        let didMigrateProviderKinds = storedProviderKinds.count == decoded.providers.count
            && zip(storedProviderKinds, decoded.providers).contains {
                $0 != $1.kind.rawValue
            }
        var didMigrateConnectionPresets = false
        var didMigrateBaseURLs = false
        var didMigrateCatalogURLs = false
        var didMigrateQianwenProviders = false
        var didMigrateModelProxy = false
        if let storedProxy = decoded.operational.modelProxy {
            let sanitizedProxy = storedProxy.sanitized
            decoded.operational.modelProxy = sanitizedProxy.validationMessage == nil
                ? sanitizedProxy
                : .init()
            didMigrateModelProxy = decoded.operational.modelProxy != storedProxy
        }
        for index in decoded.providers.indices {
            if let migratedProvider = QianwenProviderMigration.migratedProvider(
                decoded.providers[index]
            ) {
                decoded.providers[index] = migratedProvider
                didMigrateQianwenProviders = true
            }
            if let migratedProvider = ProviderConnectionPresetMigration.migratedProvider(
                decoded.providers[index]
            ) {
                decoded.providers[index] = migratedProvider
                didMigrateConnectionPresets = true
            }
            if let migratedProvider = ProviderBaseURLMigration.migratedProvider(
                decoded.providers[index]
            ) {
                decoded.providers[index] = migratedProvider
                didMigrateBaseURLs = true
            }
            if let migratedProvider = ProviderModelCatalogMigration.migratedProvider(
                decoded.providers[index]
            ) {
                decoded.providers[index] = migratedProvider
                didMigrateCatalogURLs = true
            }
        }
        let restoredHealth = ModelHealthRecoveryPolicy.restoringRecordedRecoveries(
            records: decoded.modelHealth,
            activities: decoded.modelHealthActivities
        )
        let normalizedHealth = ModelHealthMigration.normalize(
            records: restoredHealth,
            providers: decoded.providers
        )
        let didMigrateHealth = normalizedHealth != decoded.modelHealth
        decoded.modelHealth = normalizedHealth
        configuration = decoded
        rebuildHealthIndex()
        rebuildProxyEndpointIndex()
        if didMigrateConnectionPresets {
            savePreConnectionPresetMigrationBackup(data)
        }
        if didMigrateBaseURLs {
            savePreBaseURLMigrationBackup(data)
        }
        if didMigrateCatalogURLs {
            savePreCatalogURLMigrationBackup(data)
        }
        if didMigrateHealth || didMigrateProviderKinds || didMigrateConnectionPresets
            || didMigrateBaseURLs || didMigrateCatalogURLs || !hadRoutingSettings
            || didMigrateQianwenProviders || didMigrateModelProxy
        {
            persistConfiguration()
        }
    }

    private func savePreConnectionPresetMigrationBackup(_ data: Data) {
        let backupURL = configurationURL.deletingLastPathComponent()
            .appending(path: "Backups/configuration-before-provider-preset-migration.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: backupURL, options: .atomic)
        } catch {
            notice = L10n.format("供应商连接预设迁移前配置备份失败：%@", error.localizedDescription)
        }
    }

    private func savePreCatalogURLMigrationBackup(_ data: Data) {
        let backupURL = configurationURL.deletingLastPathComponent()
            .appending(path: "Backups/configuration-before-catalog-url-migration.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: backupURL, options: .atomic)
        } catch {
            notice = L10n.format("模型名录迁移前配置备份失败：%@", error.localizedDescription)
        }
    }

    private func savePreBaseURLMigrationBackup(_ data: Data) {
        let backupURL = configurationURL.deletingLastPathComponent()
            .appending(path: "Backups/configuration-before-exact-base-url.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: backupURL, options: .atomic)
        } catch {
            notice = L10n.format("迁移前配置备份失败：%@", error.localizedDescription)
        }
    }

    private func scheduleConfigurationPersistence() {
        guard !isReviewDemoMode else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistConfiguration()
        }
    }

    func flushPendingPersistence(waitUntilFinished: Bool = false) {
        guard !isReviewDemoMode else {
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = nil
            return
        }
        guard pendingPersistenceTask != nil || hasUnflushedConfigurationChanges else {
            return
        }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        // Enqueue a final, newer snapshot without bringing JSON encoding or
        // filesystem IO onto the main actor. App termination may explicitly
        // request a bounded wait so the final snapshot reaches disk.
        persistConfiguration(waitUntilFinished: waitUntilFinished)
    }

    private func persistConfiguration(waitUntilFinished: Bool = false) {
        guard !isReviewDemoMode else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        hasUnflushedConfigurationChanges = true
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let snapshot = configuration
        let url = configurationURL
        let persistence = configurationPersistence
        let completion = waitUntilFinished ? DispatchSemaphore(value: 0) : nil

        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await persistence.persist(
                    snapshot,
                    revision: revision,
                    to: url
                )
                // Release a bounded termination wait as soon as the durable
                // write finishes. UI bookkeeping must never be a prerequisite
                // for unblocking the main actor.
                completion?.signal()
                guard case .written = result else { return }
                await MainActor.run {
                    if self?.persistenceRevision == revision {
                        self?.hasUnflushedConfigurationChanges = false
                    }
                    self?.publishWidgetSnapshot()
                }
            } catch {
                completion?.signal()
                await MainActor.run {
                    self?.notice = L10n.format(
                        "配置保存失败：%@",
                        error.localizedDescription
                    )
                }
            }
        }
        if let completion {
            _ = completion.wait(timeout: .now() + 2)
        }
    }

    private func scheduleWidgetSnapshotPublication() {
        pendingWidgetPublicationTask?.cancel()
        pendingWidgetPublicationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pendingWidgetPublicationTask = nil
            self?.publishWidgetSnapshot()
        }
    }

    private func publishWidgetSnapshot() {
        // App Group storage can occasionally stall while Foundation creates
        // an atomic temporary file. Never let that filesystem wait block the
        // SwiftUI main actor, and avoid queueing more writes behind a stalled
        // snapshot publication.
        guard !widgetSnapshotWriteInFlight else { return }
        let availableModelCount = AvailableModelCatalog.entries(
            routes: routes,
            providers: providers,
            health: healthIndex
        ).count
        let snapshot = ModelHubWidgetSnapshot(
            isServerRunning: isServerRunning,
            endpoint: "127.0.0.1:\(activePort ?? configuration.server.port)/v1",
            providerCount: providers.filter(\.enabled).count,
            routeCount: routes.filter(\.enabled).count,
            availableModelCount: availableModelCount,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests
        )
        widgetSnapshotWriteInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let didSave = ModelHubWidgetSnapshotStore.save(snapshot)
            if didSave {
                WidgetCenter.shared.reloadTimelines(
                    ofKind: ModelHubWidgetSnapshotStore.widgetKind
                )
            }
            await MainActor.run {
                self?.widgetSnapshotWriteInFlight = false
            }
        }
    }

    private var configurationURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "ModelHub/configuration.json")
    }

    private var rollbackBackupURL: URL {
        configurationURL.deletingLastPathComponent()
            .appending(path: "Backups/rollback-latest.json")
    }

    private func saveRollbackBackup() throws {
        let data = try ConfigurationBackup.exportData(
            configuration: configuration,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.8.0"
        )
        try FileManager.default.createDirectory(
            at: rollbackBackupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: rollbackBackupURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
