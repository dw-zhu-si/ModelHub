import AppKit
import Foundation
import ModelHubCore
import ModelHubWidgetSupport
import ServiceManagement
import UniformTypeIdentifiers
import WidgetKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case providers
    case routes
    case analytics
    case operations
    case console
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "概览", locale: AppLanguage.saved.locale)
        case .providers: String(localized: "模型供应商", locale: AppLanguage.saved.locale)
        case .routes: String(localized: "模型路由", locale: AppLanguage.saved.locale)
        case .analytics: String(localized: "用量分析", locale: AppLanguage.saved.locale)
        case .operations: String(localized: "路由与协议", locale: AppLanguage.saved.locale)
        case .console: String(localized: "API 调试", locale: AppLanguage.saved.locale)
        case .logs: String(localized: "请求日志", locale: AppLanguage.saved.locale)
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
        case .console: "terminal"
        case .logs: "list.bullet.rectangle"
        case .settings: "gearshape"
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

private struct ModelTestTarget: Sendable {
    let provider: ProviderConfig
    let model: String
    let apiKey: String

    var key: String {
        AppModel.modelTestKey(providerID: provider.id, model: model)
    }
}

struct ManualModelTestCandidate: Sendable {
    let provider: ProviderConfig
    let model: String
}

struct ManualModelTestPlan: Sendable {
    let candidates: [ManualModelTestCandidate]
    let preflightSkipped: Int
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

    private let router = RoutingEngine()
    private let providerClient = ProviderClient()
    private let resilience = ResilienceController()
    private var server: LocalAPIServer?
    private var didBootstrap = false
    private var modelTestTask: Task<Void, Never>?
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingWidgetPublicationTask: Task<Void, Never>?
    private var healthIndex = ModelHealthIndex(records: [])
    private var availableModelListCache: HTTPResponse?
    private var providerListCache: HTTPResponse?
    private var cachedGatewayToken: String?
    private var cachedAgentToken: String?
    private var reviewDemoBackup: ReviewDemoBackup?
    private static let launchAtLoginRequestedKey = "launchAtLoginRequested"
    private static let launchAtLoginStatusKey = "launchAtLoginStatus"
    private static let launchAtLoginErrorKey = "launchAtLoginLastError"

    private struct ReviewDemoBackup {
        let configuration: AppConfiguration
        let logs: [GatewayLogEntry]
        let totalRequests: Int
        let successfulRequests: Int
        let consoleOutput: String
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
            return L10n.format("本月已知价格估算 $%.4f，已达到 $%.2f 上限。", spent, limit)
        }
        if fraction >= configuration.operational.budget.warningFraction {
            return L10n.format("本月已知价格估算 $%.4f，已使用预算的 %.0f%%。", spent, fraction * 100)
        }
        return nil
    }

    func enterReviewDemoMode() {
        guard !isReviewDemoMode else { return }
        flushPendingPersistence()
        reviewDemoBackup = ReviewDemoBackup(
            configuration: configuration,
            logs: logs,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            consoleOutput: consoleOutput
        )
        isReviewDemoMode = true
        configuration = Self.reviewDemoConfiguration()
        logs = Self.reviewDemoLogs()
        totalRequests = 128
        successfulRequests = 124
        consoleOutput = String(localized: "演示模式已就绪。选择任一演示模型并发送请求，可查看本机生成的示例响应。", locale: AppLanguage.saved.locale)
        rebuildHealthIndex()
        selection = .overview
    }

    func exitReviewDemoMode() {
        guard isReviewDemoMode, let backup = reviewDemoBackup else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        configuration = backup.configuration
        logs = backup.logs
        totalRequests = backup.totalRequests
        successfulRequests = backup.successfulRequests
        consoleOutput = backup.consoleOutput
        reviewDemoBackup = nil
        isReviewDemoMode = false
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
            musicModel: TargetProfile(capabilities: [.audio]),
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
                ModelHealthRecord(
                    providerID: provider.id,
                    model: model,
                    status: .available,
                    checkedAt: now,
                    latencyMilliseconds: 180 + (index * 45),
                    statusCode: 200,
                    detail: "审核演示数据：可用"
                )
            }
        }
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
        return AppConfiguration(
            providers: providers,
            routes: routes,
            routing: RoutingRuleSettings(activeRule: .sameModelLowestCost),
            modelHealth: health,
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
        initializeSecretsWithoutInteraction()
        initializeAgentSecretWithoutInteraction()
        launchAtLoginRequested = UserDefaults.standard.bool(
            forKey: Self.launchAtLoginRequestedKey
        )
        refreshLaunchAtLoginStatus()
        if configuration.server.startAutomatically {
            startServer()
        }
        if initializeSecrets {
            _ = gatewayToken
        }
        publishWidgetSnapshot()
    }

    func initializeSecrets() {
        _ = gatewayToken
    }

    func initializeSecretsWithoutInteraction() {
        guard cachedGatewayToken == nil else { return }
        switch KeychainStore.readWithoutInteraction(account: KeychainStore.gatewayTokenAccount) {
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

    func initializeAgentSecretWithoutInteraction() {
        guard cachedAgentToken == nil else { return }
        switch KeychainStore.readWithoutInteraction(account: KeychainStore.agentTokenAccount) {
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
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        let replacementKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        configuration.operational = settings
        persistConfiguration()
        notice = String(localized: "本机路由、预算与协议设置已保存。", locale: AppLanguage.saved.locale)
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
        guard let provider = providers.first(where: { $0.id == providerID }),
              provider.models.contains(model)
        else { return nil }
        if isReviewDemoMode {
            notice = String(localized: "审核演示模式只使用合成数据，不会连接模型供应商或产生费用。", locale: AppLanguage.saved.locale)
            return healthRecord(providerID: providerID, model: model)
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

        let target = ModelTestTarget(
            provider: provider,
            model: model,
            apiKey: apiKey(for: provider)
        )
        testingModelIDs.insert(target.key)
        defer { testingModelIDs.remove(target.key) }

        let record = await Self.probeModel(
            target,
            allowNativeProbe: allowNativeProbe
        )
        upsertHealthRecord(record)
        persistConfiguration()
        return record
    }

    func startTestingAllModels(providerID: UUID? = nil) {
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

        let plan = Self.makeManualModelTestPlan(
            providers: selectedProviders,
            health: healthIndex
        )
        let targets = plan.candidates.map { candidate in
            ModelTestTarget(
                provider: candidate.provider,
                model: candidate.model,
                apiKey: apiKey(for: candidate.provider)
            )
        }
        guard !targets.isEmpty else {
            notice = String(localized: "没有可测试的模型。", locale: AppLanguage.saved.locale)
            return
        }

        isTestingModels = true
        modelTestProgress = ModelTestProgress(
            total: targets.count,
            completed: 0,
            available: 0,
            unavailable: 0,
            skipped: 0,
            currentProvider: targets.first?.provider.name ?? "",
            isCancelled: false
        )
        modelTestTask = Task { [weak self] in
            await self?.runModelTests(targets)
        }
    }

    nonisolated static func makeManualModelTestPlan(
        providers: [ProviderConfig],
        health: ModelHealthIndex
    ) -> ManualModelTestPlan {
        var seen = Set<String>()
        var candidates: [ManualModelTestCandidate] = []

        for provider in providers {
            for model in provider.models {
                let key = modelTestKey(providerID: provider.id, model: model)
                guard seen.insert(key).inserted else { continue }
                candidates.append(
                    ManualModelTestCandidate(provider: provider, model: model)
                )
            }
        }

        return ManualModelTestPlan(
            candidates: candidates,
            preflightSkipped: 0
        )
    }

    func cancelModelTesting() {
        modelTestTask?.cancel()
    }

    private func runModelTests(_ targets: [ModelTestTarget]) async {
        let concurrency = 3
        var cancelled = false

        for start in stride(from: 0, to: targets.count, by: concurrency) {
            if Task.isCancelled {
                cancelled = true
                break
            }

            let end = min(start + concurrency, targets.count)
            let batch = Array(targets[start..<end])
            testingModelIDs.formUnion(batch.map(\.key))
            modelTestProgress?.currentProvider = batch.first?.provider.name ?? ""

            let records = await withTaskGroup(of: ModelHealthRecord.self) { group in
                for target in batch {
                    group.addTask {
                        await Self.probeModel(target)
                    }
                }
                var results: [ModelHealthRecord] = []
                for await record in group {
                    results.append(record)
                }
                return results
            }

            for record in records {
                upsertHealthRecord(record)
                modelTestProgress?.completed += 1
                if record.status == .available {
                    modelTestProgress?.available += 1
                } else if record.status == .unavailable {
                    modelTestProgress?.unavailable += 1
                } else {
                    modelTestProgress?.skipped += 1
                }
            }
            testingModelIDs.subtract(batch.map(\.key))

            if (modelTestProgress?.completed ?? 0).isMultiple(of: 30) {
                persistConfiguration()
            }
        }

        testingModelIDs.removeAll()
        modelTestProgress?.isCancelled = cancelled
        persistConfiguration()
        isTestingModels = false
        modelTestTask = nil

        let progress = modelTestProgress
        if cancelled {
            notice = L10n.format(
                "模型检测已停止，已完成 %d/%d。",
                progress?.completed ?? 0,
                progress?.total ?? 0
            )
        } else {
            notice = L10n.format(
                "模型检测完成：可用 %d，不可用 %d，未发起或需处理 %d。",
                progress?.available ?? 0,
                progress?.unavailable ?? 0,
                progress?.skipped ?? 0
            )
        }
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
        detail: String
    ) {
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

    nonisolated private static func probeModel(
        _ target: ModelTestTarget,
        allowNativeProbe: Bool = false
    ) async -> ModelHealthRecord {
        switch ModelProbePolicy.disposition(
            provider: target.provider,
            model: target.model,
            hasAPIKey: !target.apiKey.isEmpty
        ) {
        case .configurationRequired:
            return ModelHealthRecord(
                providerID: target.provider.id,
                model: target.model,
                status: .configurationRequired,
                detail: "需要配置 API Key（未发起请求）"
            )
        case .readyForNativeProtocol(let nativeProtocol):
            guard allowNativeProbe,
                  let operation = ModelProbePolicy.nativeOperation(for: nativeProtocol),
                  let body = ModelProbePolicy.nativeProbeBody(
                      for: nativeProtocol,
                      model: target.model
                  )
            else {
                return ModelHealthRecord(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    detail: "\(nativeProtocol.displayName)尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
                )
            }

            let started = ContinuousClock.now
            do {
                let response = try await ProviderClient().sendNative(
                    rawBody: body,
                    targetModel: target.model,
                    provider: target.provider,
                    apiKey: target.apiKey,
                    operation: operation,
                    timeoutInterval: 60
                )
                let latency = milliseconds(from: started.duration(to: .now))
                let status = ModelAvailability(statusCode: response.statusCode)
                let detail: String
                if status == .available {
                    detail = "原生\(nativeProtocol.displayName)验证成功 · HTTP \(response.statusCode) · \(latency) ms"
                } else if status == .configurationRequired {
                    detail = "API Key 无效或无权限 · HTTP \(response.statusCode)"
                } else {
                    detail = "原生\(nativeProtocol.displayName)验证失败，已隔离 · HTTP \(response.statusCode)"
                }
                return ModelHealthRecord(
                    providerID: target.provider.id,
                    model: target.model,
                    status: status,
                    latencyMilliseconds: latency,
                    statusCode: response.statusCode,
                    detail: detail
                )
            } catch let error as ProviderClientError {
                return ModelHealthRecord(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: error.localizedDescription
                )
            } catch let error as URLError {
                return ModelHealthRecord(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "网络错误（\(error.code.rawValue)）"
                )
            } catch {
                return ModelHealthRecord(
                    providerID: target.provider.id,
                    model: target.model,
                    status: .unavailable,
                    latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                    detail: "请求失败"
                )
            }
        case .readyForChatProbe:
            break
        }

        let object: [String: Any] = [
            "model": target.model,
            "messages": [["role": "user", "content": "只回复 OK"]],
            "stream": false,
            "max_tokens": 1
        ]
        let started = ContinuousClock.now

        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = try await ProviderClient().send(
                rawBody: data,
                targetModel: target.model,
                provider: target.provider,
                apiKey: target.apiKey,
                timeoutInterval: 30
            )
            let latency = milliseconds(from: started.duration(to: .now))
            let status = ModelAvailability(statusCode: response.statusCode)
            let detail: String
            if status == .configurationRequired {
                detail = "API Key 无效或无权限 · HTTP \(response.statusCode)"
            } else {
                detail = "HTTP \(response.statusCode) · \(latency) ms"
            }
            return ModelHealthRecord(
                providerID: target.provider.id,
                model: target.model,
                status: status,
                latencyMilliseconds: latency,
                statusCode: response.statusCode,
                detail: detail
            )
        } catch let error as ProviderClientError {
            return ModelHealthRecord(
                providerID: target.provider.id,
                model: target.model,
                status: .unavailable,
                latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                detail: error.localizedDescription
            )
        } catch let error as URLError {
            return ModelHealthRecord(
                providerID: target.provider.id,
                model: target.model,
                status: .unavailable,
                latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                detail: "网络错误（\(error.code.rawValue)）"
            )
        } catch {
            return ModelHealthRecord(
                providerID: target.provider.id,
                model: target.model,
                status: .unavailable,
                latencyMilliseconds: milliseconds(from: started.duration(to: .now)),
                detail: "请求失败"
            )
        }
    }

    func runConsole(model: String, prompt: String) async {
        consoleIsRunning = true
        defer { consoleIsRunning = false }
        if isReviewDemoMode {
            try? await Task.sleep(for: .milliseconds(250))
            let response: [String: Any] = [
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
            let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            consoleOutput = "HTTP 200 · REVIEW DEMO\n\n" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            record(model: model, provider: "Review Demo", statusCode: 200, latency: 250, detail: "本机合成响应（未访问上游）")
            return
        }
        guard isServerRunning else {
            consoleOutput = String(localized: "本地 API 服务尚未启动。", locale: AppLanguage.saved.locale)
            return
        }

        guard let url = URL(string: "\(endpointURL)/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
        let object: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false
        ]
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

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 204, headers: [:], body: Data())
        }
        if request.method == "GET" && request.path == "/health" {
            return .json(statusCode: 200, object: [
                "status": "ok",
                "service": "ModelHub",
                "providers": providers.filter(\.enabled).count,
                "routes": routes.filter(\.enabled).count
            ])
        }
        if let allowedMethods = allowedMethods(for: request.path),
           !allowedMethods.contains(request.method)
        {
            return methodNotAllowedResponse(request.method, allowedMethods: allowedMethods)
        }
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
        } else if configuration.server.requireAuthentication && !isAuthorized(request) {
            return .json(
                statusCode: 401,
                object: Self.errorObject("invalid_api_key", "缺少或无效的 Bearer 访问令牌")
            )
        }
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
        if request.method == "POST" && request.path == "/v1/images/generations" {
            return await nativeCompletion(request, operation: .imageGeneration)
        }
        if request.method == "POST"
            && (request.path == "/v1/videos/generations" || request.path == "/v1/videos")
        {
            return await nativeCompletion(request, operation: .videoGeneration)
        }
        if request.method == "POST" && request.path == "/v1/audio/speech" {
            return await nativeCompletion(request, operation: .speech)
        }
        if request.method == "POST" && request.path == "/v1/audio/transcriptions" {
            return await nativeCompletion(request, operation: .transcription)
        }
        if request.method == "POST" && request.path == "/v1/embeddings" {
            return await nativeCompletion(request, operation: .embeddings)
        }
        if request.method == "POST" && request.path == "/v1/rerank" {
            return await nativeCompletion(request, operation: .reranking)
        }
        if request.method == "GET",
           let taskID = videoTaskID(from: request.path)
        {
            return await nativeCompletion(request, operation: .videoTask, taskID: taskID)
        }
        return .json(statusCode: 404, object: Self.errorObject("not_found", "接口不存在"))
    }

    private func streamingResponse(for request: HTTPRequest) async -> HTTPStreamResponse? {
        guard request.method == "POST",
              request.path == "/v1/chat/completions" || request.path == "/v1/responses",
              let envelope = try? JSONDecoder().decode(ModelRequestEnvelope.self, from: request.body),
              envelope.stream == true
        else { return nil }

        if configuration.server.requireAuthentication && !isAuthorized(request) {
            return streamResponse(from: .json(
                statusCode: 401,
                object: Self.errorObject("invalid_api_key", "缺少或无效的 Bearer 访问令牌")
            ))
        }
        switch await resilience.admitGatewayRequest(
            settings: configuration.operational.resilience
        ) {
        case .allowed:
            break
        case .rateLimited(let retryAfterSeconds):
            return streamResponse(from: HTTPResponse(
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
        if let budget = budgetBlockResponse() { return streamResponse(from: budget) }

        let candidates = await router.candidates(
            for: envelope.model,
            routes: routes,
            providers: providers,
            health: healthIndex,
            usage: configuration.usage,
            requiredCapabilities: requestCapabilities(from: request.body),
            defaultRule: configuration.routing.activeRule
        )
        let settings = configuration.operational.resilience
        var lastResponse: HTTPResponse?
        for (attemptIndex, target) in candidates
            .prefix(max(1, settings.maxFallbackAttempts))
            .enumerated()
        {
            guard let provider = providers.first(where: { $0.id == target.providerID }),
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
            if let blocked = await targetBlockResponse(target: target, settings: settings) {
                lastResponse = blocked
                continue
            }
            let key = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            do {
                let upstream: ProviderStreamResponse
                if request.path == "/v1/responses" {
                    upstream = try await providerClient.startResponsesStream(
                        rawBody: request.body,
                        targetModel: target.model,
                        provider: provider,
                        apiKey: apiKey(for: provider)
                    )
                } else {
                    let optimized = ContextOptimizer.optimizeChatBody(
                        request.body,
                        settings: configuration.operational.contextOptimization
                    )
                    upstream = try await providerClient.startChatStream(
                        rawBody: optimized.body,
                        targetModel: target.model,
                        provider: provider,
                        apiKey: apiKey(for: provider)
                    )
                }

                if upstream.statusCode == 429 || upstream.statusCode >= 500 {
                    let failureBody = try await collect(upstream.body, maximumBytes: 1_048_576)
                    let latency = milliseconds(from: started.duration(to: .now))
                    await resilience.finishTarget(
                        key,
                        succeeded: false,
                        transientFailure: true,
                        settings: settings
                    )
                    recordUsage(
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
                return trackedStreamResponse(
                    upstream: upstream,
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    runtimeKey: key,
                    started: started,
                    settings: settings
                )
            } catch let error as ProviderClientError {
                await resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: !error.isInvalidClientRequest,
                    settings: settings
                )
                lastResponse = .json(
                    statusCode: error.isInvalidClientRequest ? 400 : 502,
                    object: Self.errorObject("upstream_error", error.localizedDescription)
                )
            } catch {
                await resilience.finishTarget(
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
        return streamResponse(from: response)
    }

    private func trackedStreamResponse(
        upstream: ProviderStreamResponse,
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        runtimeKey: TargetRuntimeKey,
        started: ContinuousClock.Instant,
        settings: ResilienceSettings
    ) -> HTTPStreamResponse {
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
                    continuation.finish()
                    guard let self else { return }
                    let latency = self.milliseconds(from: started.duration(to: .now))
                    await self.resilience.finishTarget(
                        runtimeKey,
                        succeeded: (200..<300).contains(upstream.statusCode),
                        transientFailure: false,
                        settings: settings
                    )
                    self.recordStreamingUsage(
                        requestedModel: requestedModel,
                        provider: provider,
                        target: target,
                        statusCode: upstream.statusCode,
                        latency: latency,
                        eventStream: accountingBuffer
                    )
                    self.record(
                        model: requestedModel,
                        provider: "\(provider.name) / \(target.model)",
                        statusCode: upstream.statusCode,
                        latency: latency,
                        detail: "增量流式响应完成"
                    )
                    self.updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: ModelAvailability(statusCode: upstream.statusCode),
                        latency: latency,
                        statusCode: upstream.statusCode,
                        detail: "增量流式调用完成"
                    )
                } catch {
                    continuation.finish(throwing: error)
                    guard let self else { return }
                    await self.resilience.finishTarget(
                        runtimeKey,
                        succeeded: false,
                        transientFailure: !Task.isCancelled,
                        settings: settings
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(
            statusCode: upstream.statusCode,
            headers: ["Content-Type": upstream.contentType],
            body: stream
        )
    }

    private func streamResponse(from response: HTTPResponse) -> HTTPStreamResponse {
        HTTPStreamResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                if !response.body.isEmpty { continuation.yield(response.body) }
                continuation.finish()
            }
        )
    }

    private func collect(
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
        case "/v1/chat/completions", "/v1/responses", "/v1/images/generations", "/v1/videos/generations",
             "/v1/audio/speech", "/v1/audio/transcriptions", "/v1/embeddings", "/v1/rerank":
            return ["POST", "OPTIONS"]
        case "/v1/videos":
            return ["POST", "OPTIONS"]
        default:
            return videoTaskID(from: path) == nil ? nil : ["GET", "OPTIONS"]
        }
    }

    private func chatCompletion(_ request: HTTPRequest) async -> HTTPResponse {
        let envelope: ModelRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelRequestEnvelope.self, from: request.body)
        } catch {
            return .json(statusCode: 400, object: Self.errorObject("invalid_request", "请求 JSON 无效或缺少 model"))
        }

        if let response = budgetBlockResponse() { return response }
        let optimized = ContextOptimizer.optimizeChatBody(
            request.body,
            settings: configuration.operational.contextOptimization
        )
        let candidates = await router.candidates(
            for: envelope.model,
            routes: routes,
            providers: providers,
            health: healthIndex,
            usage: configuration.usage,
            requiredCapabilities: requestCapabilities(from: request.body),
            defaultRule: configuration.routing.activeRule
        )
        guard !candidates.isEmpty else {
            let quarantined = quarantinedTargets(for: envelope.model)
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
        let settings = configuration.operational.resilience
        let attemptedTargets = candidates.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = providers.first(where: { $0.id == target.providerID }) else { continue }
            guard ModelProbePolicy.nativeProtocol(provider: provider, model: target.model) == nil else {
                continue
            }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await targetBlockResponse(target: target, settings: settings) {
                lastResponse = blocked
                continue
            }
            let runtimeKey = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            do {
                let response = try await providerClient.send(
                    rawBody: optimized.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: apiKey(for: provider)
                )
                let latency = milliseconds(from: started.duration(to: .now))
                let isSuccess = (200..<300).contains(response.statusCode)
                let transient = response.statusCode == 429 || response.statusCode >= 500
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: isSuccess,
                    transientFailure: transient,
                    settings: settings
                )
                recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: response.statusCode,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: optimized.charactersSaved
                )
                record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: response.statusCode,
                    latency: latency,
                    detail: (200..<300).contains(response.statusCode) ? "成功" : "上游响应"
                )
                updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: ModelAvailability(statusCode: response.statusCode),
                    latency: latency,
                    statusCode: response.statusCode,
                    detail: (200..<300).contains(response.statusCode)
                        ? "运行调用成功"
                        : "运行调用失败，已隔离 · HTTP \(response.statusCode)"
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
                let latency = milliseconds(from: started.duration(to: .now))
                let status: ModelAvailability?
                let responseStatus: Int
                switch error {
                case .invalidRequest:
                    status = nil
                    responseStatus = 400
                case .missingAPIKey:
                    status = .configurationRequired
                    responseStatus = 502
                case .invalidBaseURL, .nonHTTPResponse:
                    status = .unavailable
                    responseStatus = 502
                }
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: responseStatus >= 500,
                    settings: settings
                )
                recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: responseStatus,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: optimized.charactersSaved
                )
                if let status {
                    updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: status,
                        latency: latency,
                        statusCode: nil,
                        detail: "\(error.localizedDescription)，已隔离"
                    )
                }
                record(
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
                let latency = milliseconds(from: started.duration(to: .now))
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: 502,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: optimized.charactersSaved
                )
                updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: .unavailable,
                    latency: latency,
                    statusCode: nil,
                    detail: "运行调用失败，已隔离 · \(error.localizedDescription)"
                )
                record(
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

    private func responsesCompletion(_ request: HTTPRequest) async -> HTTPResponse {
        let envelope: ModelRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelRequestEnvelope.self, from: request.body)
        } catch {
            return .json(
                statusCode: 400,
                object: Self.errorObject("invalid_request", "请求 JSON 无效或缺少 model")
            )
        }
        if let response = budgetBlockResponse() { return response }

        let candidates = await router.candidates(
            for: envelope.model,
            routes: routes,
            providers: providers,
            health: healthIndex,
            usage: configuration.usage,
            requiredCapabilities: requestCapabilities(from: request.body),
            defaultRule: configuration.routing.activeRule
        )
        guard !candidates.isEmpty else {
            let quarantined = quarantinedTargets(for: envelope.model)
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
        let settings = configuration.operational.resilience
        let attemptedTargets = candidates.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = providers.first(where: { $0.id == target.providerID }),
                  provider.kind.usesUnifiedProtocol,
                  ModelProbePolicy.nativeProtocol(provider: provider, model: target.model) == nil
            else { continue }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await targetBlockResponse(target: target, settings: settings) {
                lastResponse = blocked
                continue
            }

            let key = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            do {
                let response = try await providerClient.sendResponses(
                    rawBody: request.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: apiKey(for: provider)
                )
                let latency = milliseconds(from: started.duration(to: .now))
                let succeeded = (200..<300).contains(response.statusCode)
                await resilience.finishTarget(
                    key,
                    succeeded: succeeded,
                    transientFailure: response.statusCode == 429 || response.statusCode >= 500,
                    settings: settings
                )
                recordUsage(
                    requestedModel: envelope.model,
                    provider: provider,
                    target: target,
                    statusCode: response.statusCode,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: 0
                )
                record(
                    model: envelope.model,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: response.statusCode,
                    latency: latency,
                    detail: "Responses API 上游响应"
                )
                updateModelHealth(
                    providerID: provider.id,
                    model: target.model,
                    status: ModelAvailability(statusCode: response.statusCode),
                    latency: latency,
                    statusCode: response.statusCode,
                    detail: succeeded ? "Responses API 调用成功" : "Responses API 调用失败，已隔离"
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
                let latency = milliseconds(from: started.duration(to: .now))
                let statusCode = error.isInvalidClientRequest ? 400 : 502
                await resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: statusCode >= 500,
                    settings: settings
                )
                recordUsage(
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
                let latency = milliseconds(from: started.duration(to: .now))
                await resilience.finishTarget(
                    key,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                recordUsage(
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

    private func nativeCompletion(
        _ request: HTTPRequest,
        operation: NativeAPIOperation,
        taskID: String? = nil
    ) async -> HTTPResponse {
        guard let requestedModel = requestModel(from: request), !requestedModel.isEmpty else {
            let hint = operation == .videoTask
                ? "查询视频任务时请通过 ?model=供应商/模型 指定模型"
                : "请求 JSON 缺少 model"
            return .json(statusCode: 400, object: Self.errorObject("invalid_request", hint))
        }
        if let response = budgetBlockResponse() { return response }

        let candidates = await router.candidates(
            for: requestedModel,
            routes: routes,
            providers: providers,
            health: healthIndex,
            usage: configuration.usage,
            defaultRule: configuration.routing.activeRule
        )
        if candidates.isEmpty {
            let quarantined = quarantinedTargets(for: requestedModel)
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
            guard let provider = providers.first(where: { $0.id == target.providerID }) else {
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
        let settings = configuration.operational.resilience
        let attemptedTargets = matching.prefix(max(1, settings.maxFallbackAttempts))
        for (attemptIndex, target) in attemptedTargets.enumerated() {
            guard let provider = providers.first(where: { $0.id == target.providerID }) else {
                continue
            }
            if attemptIndex > 0 {
                try? await Task.sleep(for: ResilienceController.backoffDuration(
                    attempt: attemptIndex - 1,
                    baseMilliseconds: settings.backoffBaseMilliseconds
                ))
            }
            if let blocked = await targetBlockResponse(target: target, settings: settings) {
                lastResponse = blocked
                continue
            }
            let runtimeKey = TargetRuntimeKey(providerID: provider.id, model: target.model)
            let started = ContinuousClock.now
            do {
                let response = try await providerClient.sendNative(
                    rawBody: request.body,
                    targetModel: target.model,
                    provider: provider,
                    apiKey: apiKey(for: provider),
                    operation: operation,
                    taskID: taskID,
                    contentType: request.header("Content-Type") ?? "application/json"
                )
                let latency = milliseconds(from: started.duration(to: .now))
                let isSuccess = (200..<300).contains(response.statusCode)
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: isSuccess,
                    transientFailure: response.statusCode == 429 || response.statusCode >= 500,
                    settings: settings
                )
                recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: response.statusCode,
                    latency: latency,
                    responseBody: response.body,
                    contextCharactersSaved: 0
                )
                record(
                    model: requestedModel,
                    provider: "\(provider.name) / \(target.model)",
                    statusCode: response.statusCode,
                    latency: latency,
                    detail: "\(operation.modelProtocol.displayName)上游响应"
                )
                if operation != .videoTask {
                    let health = ModelHealthRecord(
                        providerID: provider.id,
                        model: target.model,
                        status: ModelAvailability(statusCode: response.statusCode),
                        latencyMilliseconds: latency,
                        statusCode: response.statusCode,
                        detail: (200..<300).contains(response.statusCode)
                            ? "原生\(operation.modelProtocol.displayName)调用成功 · HTTP \(response.statusCode) · \(latency) ms"
                            : "原生\(operation.modelProtocol.displayName)调用失败，已隔离 · HTTP \(response.statusCode) · \(latency) ms"
                    )
                    upsertHealthRecord(health)
                    scheduleConfigurationPersistence()
                }
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
                let latency = milliseconds(from: started.duration(to: .now))
                let status: ModelAvailability?
                let responseStatus: Int
                switch error {
                case .invalidRequest:
                    status = nil
                    responseStatus = 400
                case .missingAPIKey:
                    status = .configurationRequired
                    responseStatus = 502
                case .invalidBaseURL, .nonHTTPResponse:
                    status = .unavailable
                    responseStatus = 502
                }
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: responseStatus >= 500,
                    settings: settings
                )
                recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: responseStatus,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                if operation != .videoTask, let status {
                    updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: status,
                        latency: latency,
                        statusCode: nil,
                        detail: "原生\(operation.modelProtocol.displayName)失败，已隔离 · \(error.localizedDescription)"
                    )
                }
                record(
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
                let latency = milliseconds(from: started.duration(to: .now))
                await resilience.finishTarget(
                    runtimeKey,
                    succeeded: false,
                    transientFailure: true,
                    settings: settings
                )
                recordUsage(
                    requestedModel: requestedModel,
                    provider: provider,
                    target: target,
                    statusCode: 502,
                    latency: latency,
                    responseBody: Data(),
                    contextCharactersSaved: 0
                )
                if operation != .videoTask {
                    updateModelHealth(
                        providerID: provider.id,
                        model: target.model,
                        status: .unavailable,
                        latency: latency,
                        statusCode: nil,
                        detail: "原生\(operation.modelProtocol.displayName)失败，已隔离 · \(error.localizedDescription)"
                    )
                }
                record(
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

    private func nativePassthrough(_ request: HTTPRequest) async -> HTTPResponse {
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
        guard let provider = providers.first(where: {
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
        let currentStatus = healthIndex.status(providerID: provider.id, model: targetModel)
        guard currentStatus.isRoutable else {
            return .json(
                statusCode: 409,
                object: Self.errorObject(
                    "model_quarantined",
                    "模型已隔离，需先在应用中标记为可用：\(provider.name)/\(targetModel)"
                )
            )
        }
        if let response = budgetBlockResponse() { return response }
        let target = RouteTarget(
            providerID: provider.id,
            model: targetModel,
            profile: provider.modelProfiles?[targetModel]
        )
        let settings = configuration.operational.resilience
        if let blocked = await targetBlockResponse(target: target, settings: settings) {
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
        do {
            let response = try await providerClient.sendNativePassthrough(
                rawBody: request.body,
                method: request.method,
                upstreamPath: upstreamPath,
                orderedQueryItems: upstreamQueryItems,
                provider: provider,
                apiKey: apiKey(for: provider),
                headers: request.headers
            )
            let latency = milliseconds(from: started.duration(to: .now))
            await resilience.finishTarget(
                runtimeKey,
                succeeded: (200..<300).contains(response.statusCode),
                transientFailure: response.statusCode == 429 || response.statusCode >= 500,
                settings: settings
            )
            recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: response.statusCode,
                latency: latency,
                responseBody: response.body,
                contextCharactersSaved: 0
            )
            record(
                model: targetModel,
                provider: provider.name,
                statusCode: response.statusCode,
                latency: latency,
                detail: "供应商专用原生响应"
            )
            updateModelHealth(
                providerID: provider.id,
                model: targetModel,
                status: ModelAvailability(statusCode: response.statusCode),
                latency: latency,
                statusCode: response.statusCode,
                detail: (200..<300).contains(response.statusCode)
                    ? "原生供应商专用调用成功"
                    : "原生供应商专用调用失败，已隔离 · HTTP \(response.statusCode)"
            )
            return HTTPResponse(
                statusCode: response.statusCode,
                headers: ["Content-Type": response.contentType],
                body: response.body
            )
        } catch let error as ProviderClientError {
            let latency = milliseconds(from: started.duration(to: .now))
            let responseStatus = error.isInvalidClientRequest ? 400 : 502
            await resilience.finishTarget(
                runtimeKey,
                succeeded: false,
                transientFailure: responseStatus >= 500,
                settings: settings
            )
            recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: responseStatus,
                latency: latency,
                responseBody: Data(),
                contextCharactersSaved: 0
            )
            switch error {
            case .missingAPIKey:
                updateModelHealth(
                    providerID: provider.id,
                    model: targetModel,
                    status: .configurationRequired,
                    latency: milliseconds(from: started.duration(to: .now)),
                    statusCode: nil,
                    detail: "原生供应商专用调用缺少密钥，已隔离"
                )
            case .invalidBaseURL, .nonHTTPResponse:
                updateModelHealth(
                    providerID: provider.id,
                    model: targetModel,
                    status: .unavailable,
                    latency: milliseconds(from: started.duration(to: .now)),
                    statusCode: nil,
                    detail: "原生供应商专用调用失败，已隔离 · \(error.localizedDescription)"
                )
            case .invalidRequest:
                break
            }
            return .json(
                statusCode: responseStatus,
                object: Self.errorObject("invalid_native_request", error.localizedDescription)
            )
        } catch {
            let latency = milliseconds(from: started.duration(to: .now))
            await resilience.finishTarget(
                runtimeKey,
                succeeded: false,
                transientFailure: true,
                settings: settings
            )
            recordUsage(
                requestedModel: targetModel,
                provider: provider,
                target: target,
                statusCode: 502,
                latency: latency,
                responseBody: Data(),
                contextCharactersSaved: 0
            )
            updateModelHealth(
                providerID: provider.id,
                model: targetModel,
                status: .unavailable,
                latency: latency,
                statusCode: nil,
                detail: "原生供应商专用调用失败，已隔离 · \(error.localizedDescription)"
            )
            record(
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

    private func requestModel(from request: HTTPRequest) -> String? {
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

    private func requestCapabilities(from body: Data) -> Set<ModelCapability> {
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
        if let availableModelListCache { return availableModelListCache }
        let entries = AvailableModelCatalog.entries(
            routes: routes,
            providers: providers,
            health: healthIndex
        )
        let models = entries.map { entry -> [String: Any] in
            var object = modelObject(entry.id, owner: entry.owner)
            object["availability"] = ModelAvailability.available.rawValue
            object["quarantined"] = false
            object["source"] = entry.isRoute ? "route" : "provider"
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
        availableModelListCache = response
        return response
    }

    private func providerListResponse() -> HTTPResponse {
        if let providerListCache { return providerListCache }
        let data: [[String: Any]] = providers.map {
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
        providerListCache = response
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
        guard request.method != "GET" || videoTaskID(from: request.path) != nil else {
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

    private func recordUsage(
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        statusCode: Int,
        latency: Int,
        responseBody: Data,
        contextCharactersSaved: Int
    ) {
        let tokens = UsageAccounting.tokenCounts(from: responseBody)
        let profile = target.profile ?? provider.modelProfiles?[target.model]
        let cost = UsageAccounting.estimatedCostUSD(tokens: tokens, profile: profile)
        configuration.usage = UsageAccounting.recording(
            aggregates: configuration.usage,
            requestedModel: requestedModel,
            providerID: provider.id,
            providerName: provider.name,
            model: target.model,
            statusCode: statusCode,
            latencyMilliseconds: latency,
            tokens: tokens,
            estimatedCostUSD: cost,
            contextCharactersSaved: contextCharactersSaved,
            retentionMonths: configuration.operational.analyticsRetentionMonths
        )
        scheduleConfigurationPersistence()
    }

    private func recordStreamingUsage(
        requestedModel: String,
        provider: ProviderConfig,
        target: RouteTarget,
        statusCode: Int,
        latency: Int,
        eventStream: Data
    ) {
        let tokens = UsageAccounting.tokenCounts(fromEventStream: eventStream)
        let profile = target.profile ?? provider.modelProfiles?[target.model]
        let cost = UsageAccounting.estimatedCostUSD(tokens: tokens, profile: profile)
        configuration.usage = UsageAccounting.recording(
            aggregates: configuration.usage,
            requestedModel: requestedModel,
            providerID: provider.id,
            providerName: provider.name,
            model: target.model,
            statusCode: statusCode,
            latencyMilliseconds: latency,
            tokens: tokens,
            estimatedCostUSD: cost,
            contextCharactersSaved: 0,
            retentionMonths: configuration.operational.analyticsRetentionMonths
        )
        scheduleConfigurationPersistence()
    }

    private func modelObject(_ id: String, owner: String) -> [String: Any] {
        [
            "id": id,
            "object": "model",
            "created": Int(Date().timeIntervalSince1970),
            "owned_by": owner
        ]
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let value = request.header("Authorization") else {
            return false
        }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else { return false }
        guard let gatewayToken = gatewayTokenWithoutInteraction() else { return false }
        return String(parts[1]) == gatewayToken
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
        if let cachedGatewayToken { return cachedGatewayToken }
        guard case .value(let existing) = KeychainStore.readWithoutInteraction(
            account: KeychainStore.gatewayTokenAccount
        ) else { return nil }
        cachedGatewayToken = existing
        return existing
    }

    private func agentTokenWithoutInteraction() -> String? {
        if let cachedAgentToken { return cachedAgentToken }
        guard case .value(let existing) = KeychainStore.readWithoutInteraction(
            account: KeychainStore.agentTokenAccount
        ) else { return nil }
        cachedAgentToken = existing
        return existing
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
                detail: detail
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
        let normalizedHealth = ModelHealthMigration.normalize(
            records: decoded.modelHealth,
            providers: decoded.providers
        )
        let didMigrateHealth = normalizedHealth != decoded.modelHealth
        decoded.modelHealth = normalizedHealth
        configuration = decoded
        rebuildHealthIndex()
        if didMigrateHealth || didMigrateProviderKinds || !hadRoutingSettings {
            persistConfiguration()
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

    func flushPendingPersistence() {
        guard !isReviewDemoMode else {
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = nil
            return
        }
        guard pendingPersistenceTask != nil else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        persistConfiguration()
    }

    private func persistConfiguration() {
        guard !isReviewDemoMode else { return }
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        do {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(configuration)
            try data.write(to: configurationURL, options: .atomic)
            publishWidgetSnapshot()
        } catch {
            notice = L10n.format("配置保存失败：%@", error.localizedDescription)
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
        guard ModelHubWidgetSnapshotStore.save(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: ModelHubWidgetSnapshotStore.widgetKind)
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
