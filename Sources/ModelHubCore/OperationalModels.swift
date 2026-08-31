import Foundation

public enum ModelCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case tools
    case vision
    case audio
    case reasoning
    case embeddings
    case reranking
    case imageGeneration
    case musicGeneration
    case videoGeneration

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: "聊天"
        case .tools: "工具调用"
        case .vision: "视觉输入"
        case .audio: "音频"
        case .reasoning: "推理"
        case .embeddings: "向量"
        case .reranking: "重排"
        case .imageGeneration: "图像生成"
        case .musicGeneration: "音乐生成"
        case .videoGeneration: "视频生成"
        }
    }
}

/// 同名模型跨供应商时使用的内置选择规则。三项固定存在且只能启用一项。
public enum DefaultRoutingRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case sameModelLowestCost
    case sameModelLowestLatency
    case sameModelOfficial

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sameModelLowestCost: "同模型价格优先"
        case .sameModelLowestLatency: "同模型速度优先"
        case .sameModelOfficial: "同模型官方优先"
        }
    }

    public var detail: String {
        switch self {
        case .sameModelLowestCost: "同一模型由多个供应商提供时，优先已配置且可比较的最低单价。"
        case .sameModelLowestLatency: "同一模型由多个供应商提供时，优先最近健康检查的最低延迟。"
        case .sameModelOfficial: "同一模型由多个供应商提供时，优先模型所属官方供应商，其次按健康状态排序。"
        }
    }
}

public struct RoutingRuleSettings: Codable, Hashable, Sendable {
    public var activeRule: DefaultRoutingRule

    public init(activeRule: DefaultRoutingRule = .sameModelLowestCost) {
        self.activeRule = activeRule
    }
}

/// 用户界面展示用的模型大类。一个模型可以同时属于多个大类；
/// 分类优先使用已配置能力，缺少配置时再根据模型名称做保守推断。
public enum ModelCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case reasoning
    case text
    case image
    case music
    case video

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .reasoning: "逻辑推理"
        case .text: "文字"
        case .image: "图片"
        case .music: "音乐"
        case .video: "视频"
        }
    }

    public static func infer(
        model: String,
        capabilities: Set<ModelCapability>
    ) -> Set<ModelCategory> {
        let name = model.lowercased()
        var categories = Set<ModelCategory>()

        if capabilities.contains(.reasoning) || reasoningMarkers.contains(where: name.contains) {
            categories.insert(.reasoning)
        }
        if capabilities.contains(.imageGeneration) || imageMarkers.contains(where: name.contains) {
            categories.insert(.image)
        }
        if capabilities.contains(.videoGeneration) || videoMarkers.contains(where: name.contains) {
            categories.insert(.video)
        }
        if capabilities.contains(.musicGeneration) || musicMarkers.contains(where: name.contains) {
            categories.insert(.music)
        }

        if categories.isEmpty {
            categories.insert(.text)
        }
        return categories
    }

    private static let reasoningMarkers = [
        "reason", "reasoning", "thinking", "think", "deepseek-r1",
        "qwq", "glm-z", "kimi-k2-thinking", "o1", "o3", "o4"
    ]
    private static let imageMarkers = [
        "image", "seedream", "flux", "dall-e", "stable-diffusion", "midjourney"
    ]
    private static let musicMarkers = [
        "music", "suno", "udio", "song", "musicgen", "ace-step", "audio-generation"
    ]
    private static let videoMarkers = [
        "video", "seedance", "sora", "veo", "kling", "runway", "wan2", "hailuo"
    ]
}

public struct TargetProfile: Codable, Hashable, Sendable {
    public var contextWindow: Int?
    public var inputCostPerMillionTokens: Double?
    public var outputCostPerMillionTokens: Double?
    public var requestCostUSD: Double?
    public var capabilities: Set<ModelCapability>
    public var capabilityDetails: ModelCapabilityDetails?
    public var pricingSource: String
    public var pricingUpdatedAt: Date?
    public var monthlyTokenLimit: Int?

    public init(
        contextWindow: Int? = nil,
        inputCostPerMillionTokens: Double? = nil,
        outputCostPerMillionTokens: Double? = nil,
        requestCostUSD: Double? = nil,
        capabilities: Set<ModelCapability> = [],
        capabilityDetails: ModelCapabilityDetails? = nil,
        pricingSource: String = "",
        pricingUpdatedAt: Date? = nil,
        monthlyTokenLimit: Int? = nil
    ) {
        self.contextWindow = contextWindow
        self.inputCostPerMillionTokens = inputCostPerMillionTokens
        self.outputCostPerMillionTokens = outputCostPerMillionTokens
        self.requestCostUSD = requestCostUSD
        self.capabilities = capabilities
        self.capabilityDetails = capabilityDetails
        self.pricingSource = pricingSource
        self.pricingUpdatedAt = pricingUpdatedAt
        self.monthlyTokenLimit = monthlyTokenLimit
    }

    public var hasKnownPrice: Bool {
        inputCostPerMillionTokens != nil
            || outputCostPerMillionTokens != nil
            || requestCostUSD != nil
    }

    public var configuredUnitCostUSD: Double {
        (inputCostPerMillionTokens ?? 0)
            + (outputCostPerMillionTokens ?? 0)
            + (requestCostUSD ?? 0)
    }
}

public struct ResilienceSettings: Codable, Hashable, Sendable {
    public var requestsPerMinute: Int
    public var maxConcurrentRequestsPerTarget: Int
    public var failureThreshold: Int
    public var cooldownSeconds: Int
    public var maxFallbackAttempts: Int
    public var backoffBaseMilliseconds: Int

    public init(
        requestsPerMinute: Int = 600,
        maxConcurrentRequestsPerTarget: Int = 8,
        failureThreshold: Int = 3,
        cooldownSeconds: Int = 60,
        maxFallbackAttempts: Int = 3,
        backoffBaseMilliseconds: Int = 100
    ) {
        self.requestsPerMinute = requestsPerMinute
        self.maxConcurrentRequestsPerTarget = maxConcurrentRequestsPerTarget
        self.failureThreshold = failureThreshold
        self.cooldownSeconds = cooldownSeconds
        self.maxFallbackAttempts = maxFallbackAttempts
        self.backoffBaseMilliseconds = backoffBaseMilliseconds
    }
}

public struct BudgetSettings: Codable, Hashable, Sendable {
    public var monthlyLimitUSD: Double?
    public var warningFraction: Double
    public var hardLimitEnabled: Bool

    public init(
        monthlyLimitUSD: Double? = nil,
        warningFraction: Double = 0.8,
        hardLimitEnabled: Bool = false
    ) {
        self.monthlyLimitUSD = monthlyLimitUSD
        self.warningFraction = warningFraction
        self.hardLimitEnabled = hardLimitEnabled
    }
}

public enum ContextOptimizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case conservative

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: "关闭"
        case .conservative: "保守文本整理"
        }
    }
}

public struct ContextOptimizationSettings: Codable, Hashable, Sendable {
    public var mode: ContextOptimizationMode
    public var minimumCharacters: Int

    public init(mode: ContextOptimizationMode = .off, minimumCharacters: Int = 4_000) {
        self.mode = mode
        self.minimumCharacters = minimumCharacters
    }
}

public struct AgentProtocolSettings: Codable, Hashable, Sendable {
    public var mcpEnabled: Bool
    public var a2aEnabled: Bool
    public var acpManifestEnabled: Bool
    public var taskContext: String?

    public init(
        mcpEnabled: Bool = true,
        a2aEnabled: Bool = true,
        acpManifestEnabled: Bool = true,
        taskContext: String? = nil
    ) {
        self.mcpEnabled = mcpEnabled
        self.a2aEnabled = a2aEnabled
        self.acpManifestEnabled = acpManifestEnabled
        self.taskContext = taskContext
    }
}

public struct ResponseCacheSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var timeToLiveSeconds: Int
    public var staleFallbackSeconds: Int
    public var maximumEntries: Int
    public var maximumBytes: Int

    public init(
        enabled: Bool = false,
        timeToLiveSeconds: Int = 300,
        staleFallbackSeconds: Int = 3_600,
        maximumEntries: Int = 128,
        maximumBytes: Int = 16 * 1_048_576
    ) {
        self.enabled = enabled
        self.timeToLiveSeconds = timeToLiveSeconds
        self.staleFallbackSeconds = staleFallbackSeconds
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    public var sanitized: ResponseCacheSettings {
        let ttl = min(max(timeToLiveSeconds, 10), 86_400)
        return ResponseCacheSettings(
            enabled: enabled,
            timeToLiveSeconds: ttl,
            staleFallbackSeconds: min(max(staleFallbackSeconds, ttl), 604_800),
            maximumEntries: min(max(maximumEntries, 1), 2_000),
            maximumBytes: min(max(maximumBytes, 1_048_576), 256 * 1_048_576)
        )
    }
}

public struct PricingUpdateSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var localHour: Int
    public var localMinute: Int
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var lastMessage: String

    public init(
        enabled: Bool = true,
        localHour: Int = 0,
        localMinute: Int = 0,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastMessage: String = ""
    ) {
        self.enabled = enabled
        self.localHour = localHour
        self.localMinute = localMinute
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.lastMessage = lastMessage
    }

    public var sanitized: PricingUpdateSettings {
        PricingUpdateSettings(
            enabled: enabled,
            localHour: min(max(localHour, 0), 23),
            localMinute: min(max(localMinute, 0), 59),
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            lastMessage: String(lastMessage.prefix(1_000))
        )
    }

    public func mostRecentScheduledDate(
        before date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        calendar.nextDate(
            after: date.addingTimeInterval(-86_400),
            matching: DateComponents(hour: localHour, minute: localMinute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ).flatMap { $0 <= date ? $0 : nil }
    }

    /// Returns whether a previously established schedule was missed.
    ///
    /// A configuration that has never attempted an update waits for its next
    /// scheduled time instead of issuing provider requests immediately after
    /// installation or migration.
    public func shouldCatchUp(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let lastAttemptAt,
              let scheduled = mostRecentScheduledDate(before: date, calendar: calendar)
        else { return false }
        return lastAttemptAt < scheduled
    }

    public func nextScheduledDate(
        after date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: localHour, minute: localMinute),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

public struct OperationalSettings: Codable, Hashable, Sendable {
    public var resilience: ResilienceSettings
    public var targetQueue: TargetQueueSettings?
    public var budget: BudgetSettings
    public var contextOptimization: ContextOptimizationSettings
    public var agentProtocols: AgentProtocolSettings
    public var responseCache: ResponseCacheSettings?
    public var pricingUpdate: PricingUpdateSettings?
    public var currencyDisplay: CurrencyDisplaySettings?
    public var modelProxy: ModelProxySettings?
    public var analyticsRetentionMonths: Int

    public init(
        resilience: ResilienceSettings = .init(),
        targetQueue: TargetQueueSettings? = .init(),
        budget: BudgetSettings = .init(),
        contextOptimization: ContextOptimizationSettings = .init(),
        agentProtocols: AgentProtocolSettings = .init(),
        responseCache: ResponseCacheSettings? = .init(),
        pricingUpdate: PricingUpdateSettings? = .init(),
        currencyDisplay: CurrencyDisplaySettings? = .init(),
        modelProxy: ModelProxySettings? = .init(),
        analyticsRetentionMonths: Int = 12
    ) {
        self.resilience = resilience
        self.targetQueue = targetQueue
        self.budget = budget
        self.contextOptimization = contextOptimization
        self.agentProtocols = agentProtocols
        self.responseCache = responseCache
        self.pricingUpdate = pricingUpdate
        self.currencyDisplay = currencyDisplay
        self.modelProxy = modelProxy
        self.analyticsRetentionMonths = analyticsRetentionMonths
    }
}

public enum ModelProxyKind: String, Codable, CaseIterable, Hashable, Sendable {
    case http
    case socks5

    public var displayName: String {
        switch self {
        case .http: "HTTP / HTTPS"
        case .socks5: "SOCKS5"
        }
    }
}

public struct ModelProxySelection: Codable, Hashable, Sendable, Identifiable {
    public var providerID: UUID
    public var model: String

    public var id: String { "\(providerID.uuidString.lowercased())::\(model)" }

    public init(providerID: UUID, model: String) {
        self.providerID = providerID
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ProxySubscription: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceHost: String
    public var enabled: Bool
    public var updateIntervalHours: Int
    public var lastUpdatedAt: Date?
    public var nodeCount: Int
    public var uploadBytes: Int64?
    public var downloadBytes: Int64?
    public var totalBytes: Int64?
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceHost: String,
        enabled: Bool = true,
        updateIntervalHours: Int = 24,
        lastUpdatedAt: Date? = nil,
        nodeCount: Int = 0,
        uploadBytes: Int64? = nil,
        downloadBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceHost = sourceHost
        self.enabled = enabled
        self.updateIntervalHours = updateIntervalHours
        self.lastUpdatedAt = lastUpdatedAt
        self.nodeCount = nodeCount
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
    }

    public var runtimePrefix: String {
        "[mh-\(id.uuidString.lowercased().prefix(8))]"
    }

    public var validationMessage: String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = sourceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 120 else {
            return "订阅名称不能为空且不得超过 120 个字符"
        }
        guard !cleanHost.isEmpty, cleanHost.count <= 255,
              !cleanHost.contains("://"),
              !cleanHost.contains("@"),
              !cleanHost.contains("/"),
              !cleanHost.contains("?"),
              !cleanHost.contains("#"),
              !cleanHost.contains("\\")
        else { return "订阅来源只能保存域名或 IP" }
        return nil
    }

    public var sanitized: ProxySubscription {
        var copy = self
        let cleanHost = sourceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = Self.safeDisplayName(cleanName, fallbackHost: cleanHost)
        copy.sourceHost = cleanHost
        copy.updateIntervalHours = min(max(updateIntervalHours, 1), 168)
        copy.nodeCount = max(nodeCount, 0)
        copy.uploadBytes = uploadBytes.map { max($0, 0) }
        copy.downloadBytes = downloadBytes.map { max($0, 0) }
        copy.totalBytes = totalBytes.map { max($0, 0) }
        return copy
    }

    private static func safeDisplayName(_ name: String, fallbackHost: String) -> String {
        let normalized = name.lowercased()
        let looksLikeURL = name.contains("://")
            || URLComponents(string: name)?.query != nil
        let looksLikeCredential = [
            "token=", "key=", "secret=", "password=", "credential="
        ].contains { normalized.contains($0) }
        guard looksLikeURL || looksLikeCredential else { return name }
        return fallbackHost.isEmpty ? "代理订阅" : fallbackHost
    }
}

public struct ProxySubscriptionNode: Codable, Hashable, Sendable, Identifiable {
    public var subscriptionID: UUID
    public var name: String
    public var type: String
    public var isAlive: Bool

    public var id: String {
        "\(subscriptionID.uuidString.lowercased())::\(name)"
    }

    public init(
        subscriptionID: UUID,
        name: String,
        type: String,
        isAlive: Bool = true
    ) {
        self.subscriptionID = subscriptionID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAlive = isAlive
    }
}

public struct ModelProxyAssignment: Codable, Hashable, Sendable, Identifiable {
    public var providerID: UUID
    public var model: String
    public var nodeID: String
    /// Explicit, ordered fallback candidates. `nodeID` remains the primary
    /// node for source and persisted-configuration compatibility.
    public var candidateNodeIDs: [String]

    public var id: String {
        "\(providerID.uuidString.lowercased())::\(model)"
    }

    public init(
        providerID: UUID,
        model: String,
        nodeID: String,
        candidateNodeIDs: [String] = []
    ) {
        self.providerID = providerID
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nodeID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.candidateNodeIDs = Self.normalizedCandidateNodeIDs(
            candidateNodeIDs,
            excluding: self.nodeID
        )
    }

    public var orderedNodeIDs: [String] {
        nodeID.isEmpty ? candidateNodeIDs : [nodeID] + candidateNodeIDs
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, model, nodeID, candidateNodeIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(UUID.self, forKey: .providerID),
            model: try container.decode(String.self, forKey: .model),
            nodeID: try container.decode(String.self, forKey: .nodeID),
            candidateNodeIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .candidateNodeIDs
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(model, forKey: .model)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(candidateNodeIDs, forKey: .candidateNodeIDs)
    }

    private static func normalizedCandidateNodeIDs(
        _ nodeIDs: [String],
        excluding primaryNodeID: String
    ) -> [String] {
        var seen: Set<String> = primaryNodeID.isEmpty ? [] : [primaryNodeID]
        return nodeIDs.compactMap { rawNodeID in
            let nodeID = rawNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nodeID.isEmpty, seen.insert(nodeID).inserted else { return nil }
            return nodeID
        }
    }
}

public struct ProviderProxyEndpoint: Hashable, Sendable {
    public let kind: ModelProxyKind
    public let host: String
    public let port: Int

    public init(kind: ModelProxyKind, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }
}

public struct ModelProxyAutomaticFailoverSettings: Codable, Hashable, Sendable {
    public static let defaultConsecutiveFailureThreshold = 2
    public static let maximumConsecutiveFailureThreshold = 10

    public var enabled: Bool
    public var consecutiveFailureThreshold: Int

    public init(
        enabled: Bool = false,
        consecutiveFailureThreshold: Int = Self.defaultConsecutiveFailureThreshold
    ) {
        self.enabled = enabled
        self.consecutiveFailureThreshold = consecutiveFailureThreshold
    }

    public var sanitized: ModelProxyAutomaticFailoverSettings {
        ModelProxyAutomaticFailoverSettings(
            enabled: enabled,
            consecutiveFailureThreshold: min(
                max(consecutiveFailureThreshold, 1),
                Self.maximumConsecutiveFailureThreshold
            )
        )
    }
}

public struct ModelProxySettings: Codable, Hashable, Sendable {
    public static let controllerPort = 11_453
    public static let firstNodePort = 11_454
    public static let maximumActiveNodes = 16

    public var enabled: Bool
    public var kind: ModelProxyKind
    public var host: String
    public var port: Int
    public var selections: [ModelProxySelection]
    public var subscriptions: [ProxySubscription]
    public var nodes: [ProxySubscriptionNode]
    public var assignments: [ModelProxyAssignment]
    public var automaticFailover: ModelProxyAutomaticFailoverSettings

    public init(
        enabled: Bool = false,
        kind: ModelProxyKind = .http,
        host: String = "127.0.0.1",
        port: Int = 7897,
        selections: [ModelProxySelection] = [],
        subscriptions: [ProxySubscription] = [],
        nodes: [ProxySubscriptionNode] = [],
        assignments: [ModelProxyAssignment] = [],
        automaticFailover: ModelProxyAutomaticFailoverSettings = .init()
    ) {
        self.enabled = enabled
        self.kind = kind
        self.host = host
        self.port = port
        self.selections = selections
        self.subscriptions = subscriptions
        self.nodes = nodes
        self.assignments = assignments
        self.automaticFailover = automaticFailover
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, kind, host, port, selections, subscriptions, nodes, assignments
        case automaticFailover
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        kind = try container.decodeIfPresent(ModelProxyKind.self, forKey: .kind) ?? .http
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 7897
        selections = try container.decodeIfPresent(
            [ModelProxySelection].self,
            forKey: .selections
        ) ?? []
        subscriptions = try container.decodeIfPresent(
            [ProxySubscription].self,
            forKey: .subscriptions
        ) ?? []
        nodes = try container.decodeIfPresent(
            [ProxySubscriptionNode].self,
            forKey: .nodes
        ) ?? []
        assignments = try container.decodeIfPresent(
            [ModelProxyAssignment].self,
            forKey: .assignments
        ) ?? []
        automaticFailover = try container.decodeIfPresent(
            ModelProxyAutomaticFailoverSettings.self,
            forKey: .automaticFailover
        ) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(kind, forKey: .kind)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(selections, forKey: .selections)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(automaticFailover, forKey: .automaticFailover)
    }

    public var validationMessage: String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "代理主机不能为空" }
        guard (1...65_535).contains(port) else { return "代理端口必须在 1–65535 之间" }
        guard !trimmed.contains("://"),
              !trimmed.contains("@"),
              !trimmed.contains("/"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("\\")
        else {
            return "代理主机只能填写域名或 IP，不得包含协议、路径或凭证"
        }
        guard trimmed.unicodeScalars.allSatisfy({
            CharacterSet.urlHostAllowed.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            return "代理主机包含无效字符"
        }
        guard activeNodeIDs.count <= Self.maximumActiveNodes else {
            return "最多可同时启用 \(Self.maximumActiveNodes) 个不同订阅节点"
        }
        if let message = subscriptions.lazy.compactMap(\.validationMessage).first {
            return message
        }
        return nil
    }

    public var sanitized: ModelProxySettings {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.automaticFailover = automaticFailover.sanitized
        var unique: [String: ModelProxySelection] = [:]
        for selection in selections {
            let normalized = ModelProxySelection(
                providerID: selection.providerID,
                model: selection.model
            )
            guard !normalized.model.isEmpty else { continue }
            unique[normalized.id] = normalized
        }
        copy.selections = unique.values.sorted {
            if $0.providerID == $1.providerID { return $0.model < $1.model }
            return $0.providerID.uuidString < $1.providerID.uuidString
        }
        var uniqueSubscriptions: [UUID: ProxySubscription] = [:]
        for subscription in subscriptions {
            let normalized = subscription.sanitized
            guard normalized.validationMessage == nil else { continue }
            uniqueSubscriptions[normalized.id] = normalized
        }
        copy.subscriptions = uniqueSubscriptions.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let validSubscriptionIDs = Set(copy.subscriptions.map(\.id))
        var uniqueNodes: [String: ProxySubscriptionNode] = [:]
        for node in nodes where validSubscriptionIDs.contains(node.subscriptionID) {
            let normalized = ProxySubscriptionNode(
                subscriptionID: node.subscriptionID,
                name: node.name,
                type: node.type,
                isAlive: node.isAlive
            )
            guard !normalized.name.isEmpty,
                  normalized.name.count <= 512,
                  normalized.type.count <= 80
            else { continue }
            uniqueNodes[normalized.id] = normalized
        }
        copy.nodes = uniqueNodes.values.sorted {
            if $0.subscriptionID == $1.subscriptionID { return $0.name < $1.name }
            return $0.subscriptionID.uuidString < $1.subscriptionID.uuidString
        }
        let validNodeIDs = Set(copy.nodes.map(\.id))
        var uniqueAssignments: [String: ModelProxyAssignment] = [:]
        for assignment in assignments {
            let normalized = ModelProxyAssignment(
                providerID: assignment.providerID,
                model: assignment.model,
                nodeID: assignment.nodeID,
                candidateNodeIDs: assignment.candidateNodeIDs.filter(validNodeIDs.contains)
            )
            guard !normalized.model.isEmpty, validNodeIDs.contains(normalized.nodeID) else { continue }
            uniqueAssignments[normalized.id] = normalized
        }
        copy.assignments = uniqueAssignments.values.sorted {
            if $0.providerID == $1.providerID { return $0.model < $1.model }
            return $0.providerID.uuidString < $1.providerID.uuidString
        }
        return copy
    }

    public var activeNodeIDs: [String] {
        Array(Set(assignments.flatMap(\.orderedNodeIDs))).sorted()
    }

    public var nodePortMap: [String: Int] {
        Dictionary(uniqueKeysWithValues: activeNodeIDs.prefix(Self.maximumActiveNodes)
            .enumerated()
            .map { index, nodeID in (nodeID, Self.firstNodePort + index) })
    }

    public func contains(providerID: UUID, model: String) -> Bool {
        let exact = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return selections.contains { $0.providerID == providerID && $0.model == exact }
    }

    public func endpoint(providerID: UUID, model: String) -> ProviderProxyEndpoint? {
        let settings = sanitized
        guard settings.enabled, settings.validationMessage == nil else { return nil }
        let exact = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assignment = settings.assignments.first(where: {
            $0.providerID == providerID && $0.model == exact
        }), let port = settings.nodePortMap[assignment.nodeID] {
            return ProviderProxyEndpoint(kind: .http, host: "127.0.0.1", port: port)
        }
        guard settings.contains(providerID: providerID, model: model) else { return nil }
        return ProviderProxyEndpoint(kind: settings.kind, host: settings.host, port: settings.port)
    }

    public mutating func setSelected(_ selected: Bool, providerID: UUID, model: String) {
        let selection = ModelProxySelection(providerID: providerID, model: model)
        selections.removeAll { $0.providerID == providerID && $0.model == selection.model }
        if selected, !selection.model.isEmpty { selections.append(selection) }
    }

    public mutating func setAssignedNode(
        _ nodeID: String?,
        providerID: UUID,
        model: String
    ) {
        let assignment = ModelProxyAssignment(
            providerID: providerID,
            model: model,
            nodeID: nodeID ?? ""
        )
        assignments.removeAll { $0.id == assignment.id }
        if !assignment.model.isEmpty,
           !assignment.nodeID.isEmpty,
           nodes.contains(where: { $0.id == assignment.nodeID })
        {
            assignments.append(assignment)
        }
    }

    @discardableResult
    public mutating func setAssignedNode(
        _ nodeID: String?,
        providerID: UUID,
        models: [String],
        enableWhenAssigned: Bool = false
    ) -> Int {
        var seen = Set<String>()
        let normalizedModels = models.compactMap { rawModel -> String? in
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
        for model in normalizedModels {
            setAssignedNode(nodeID, providerID: providerID, model: model)
        }
        if enableWhenAssigned,
           let nodeID = nodeID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nodeID.isEmpty,
           assignments.contains(where: {
               $0.providerID == providerID
                   && normalizedModels.contains($0.model)
                   && $0.nodeID == nodeID
           })
        {
            enabled = true
        }
        return normalizedModels.count
    }
}

/// Immutable hot-path lookup derived from a fully sanitized proxy snapshot.
/// Configuration validation remains centralized in `ModelProxySettings`; each
/// upstream request only pays for a normalized dictionary lookup.
public struct ModelProxyEndpointIndex: Sendable {
    private struct Key: Hashable, Sendable {
        let providerID: UUID
        let model: String
    }

    private let endpoints: [Key: ProviderProxyEndpoint]

    public init(settings rawSettings: ModelProxySettings) {
        let settings = rawSettings.sanitized
        guard settings.enabled, settings.validationMessage == nil else {
            endpoints = [:]
            return
        }

        var indexed: [Key: ProviderProxyEndpoint] = [:]
        indexed.reserveCapacity(settings.selections.count + settings.assignments.count)
        let manualEndpoint = ProviderProxyEndpoint(
            kind: settings.kind,
            host: settings.host,
            port: settings.port
        )
        for selection in settings.selections {
            indexed[Self.key(
                providerID: selection.providerID,
                model: selection.model
            )] = manualEndpoint
        }
        let ports = settings.nodePortMap
        for assignment in settings.assignments {
            guard let port = ports[assignment.nodeID] else { continue }
            indexed[Self.key(
                providerID: assignment.providerID,
                model: assignment.model
            )] = ProviderProxyEndpoint(
                kind: .http,
                host: "127.0.0.1",
                port: port
            )
        }
        endpoints = indexed
    }

    public func endpoint(providerID: UUID, model: String) -> ProviderProxyEndpoint? {
        endpoints[Self.key(providerID: providerID, model: model)]
    }

    private static func key(providerID: UUID, model: String) -> Key {
        Key(
            providerID: providerID,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum ModelProxyFailoverEvent: Hashable, Sendable {
    case succeeded
    case nonTransientFailure
    case transportFailure
    case httpStatus(Int)

    fileprivate var isTransientNodeFailure: Bool {
        switch self {
        case .transportFailure:
            return true
        case .httpStatus(let statusCode):
            return (500...599).contains(statusCode)
        case .succeeded, .nonTransientFailure:
            return false
        }
    }
}

public enum ModelProxyFailoverOutcome: String, Hashable, Sendable {
    case stayed
    case switched
    case exhausted
}

public struct ModelProxyFailoverState: Hashable, Sendable {
    public var providerID: UUID
    public var model: String
    public var activeNodeID: String
    public var consecutiveTransientFailures: Int

    public init(
        providerID: UUID,
        model: String,
        activeNodeID: String,
        consecutiveTransientFailures: Int = 0
    ) {
        self.providerID = providerID
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.activeNodeID = activeNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.consecutiveTransientFailures = max(consecutiveTransientFailures, 0)
    }
}

public struct ModelProxyFailoverTransition: Hashable, Sendable {
    public let state: ModelProxyFailoverState
    public let outcome: ModelProxyFailoverOutcome

    public init(state: ModelProxyFailoverState, outcome: ModelProxyFailoverOutcome) {
        self.state = state
        self.outcome = outcome
    }
}

/// Pure, immutable state machine for explicitly configured proxy candidates.
/// It never synthesizes a direct or manual-proxy fallback when candidates are
/// absent, invalid, disabled, dead, or exhausted.
public struct ModelProxyFailoverIndex: Sendable {
    private struct Key: Hashable, Sendable {
        let providerID: UUID
        let model: String
    }

    private struct Entry: Sendable {
        let nodeIDs: [String]
        let endpointsByNodeID: [String: ProviderProxyEndpoint]
    }

    private let entries: [Key: Entry]
    private let failureThreshold: Int

    public init(settings rawSettings: ModelProxySettings) {
        let settings = rawSettings.sanitized
        let automaticFailover = settings.automaticFailover.sanitized
        failureThreshold = automaticFailover.consecutiveFailureThreshold
        guard settings.enabled,
              automaticFailover.enabled,
              settings.validationMessage == nil
        else {
            entries = [:]
            return
        }

        let enabledSubscriptionIDs = Set(
            settings.subscriptions.lazy.filter(\.enabled).map(\.id)
        )
        let allowedNodeIDs = Set(settings.nodes.lazy.filter {
            $0.isAlive && enabledSubscriptionIDs.contains($0.subscriptionID)
        }.map(\.id))
        let ports = settings.nodePortMap
        var indexed: [Key: Entry] = [:]
        indexed.reserveCapacity(settings.assignments.count)
        for assignment in settings.assignments {
            let nodeIDs = assignment.orderedNodeIDs.filter {
                allowedNodeIDs.contains($0) && ports[$0] != nil
            }
            guard !nodeIDs.isEmpty else { continue }
            let endpoints: [String: ProviderProxyEndpoint] = Dictionary(
                uniqueKeysWithValues: nodeIDs.compactMap { nodeID in
                    guard let port = ports[nodeID] else { return nil }
                    return (nodeID, ProviderProxyEndpoint(
                        kind: .http,
                        host: "127.0.0.1",
                        port: port
                    ))
                }
            )
            indexed[Self.key(
                providerID: assignment.providerID,
                model: assignment.model
            )] = Entry(nodeIDs: nodeIDs, endpointsByNodeID: endpoints)
        }
        entries = indexed
    }

    public func initialState(
        providerID: UUID,
        model: String
    ) -> ModelProxyFailoverState? {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nodeID = entries[Self.key(
            providerID: providerID,
            model: normalizedModel
        )]?.nodeIDs.first else { return nil }
        return ModelProxyFailoverState(
            providerID: providerID,
            model: normalizedModel,
            activeNodeID: nodeID
        )
    }

    public func endpoint(for state: ModelProxyFailoverState) -> ProviderProxyEndpoint? {
        guard let entry = entries[Self.key(
            providerID: state.providerID,
            model: state.model
        )], entry.nodeIDs.contains(state.activeNodeID) else { return nil }
        return entry.endpointsByNodeID[state.activeNodeID]
    }

    public func transition(
        from state: ModelProxyFailoverState,
        event: ModelProxyFailoverEvent
    ) -> ModelProxyFailoverTransition? {
        guard let entry = entries[Self.key(
            providerID: state.providerID,
            model: state.model
        )], let activeIndex = entry.nodeIDs.firstIndex(of: state.activeNodeID)
        else { return nil }

        guard event.isTransientNodeFailure else {
            var resetState = state
            resetState.consecutiveTransientFailures = 0
            return ModelProxyFailoverTransition(state: resetState, outcome: .stayed)
        }

        let failures = min(
            min(state.consecutiveTransientFailures, failureThreshold - 1) + 1,
            failureThreshold
        )
        guard failures >= failureThreshold else {
            var pendingState = state
            pendingState.consecutiveTransientFailures = failures
            return ModelProxyFailoverTransition(state: pendingState, outcome: .stayed)
        }

        let nextIndex = activeIndex + 1
        guard entry.nodeIDs.indices.contains(nextIndex) else {
            var exhaustedState = state
            exhaustedState.consecutiveTransientFailures = failureThreshold
            return ModelProxyFailoverTransition(state: exhaustedState, outcome: .exhausted)
        }

        var switchedState = state
        switchedState.activeNodeID = entry.nodeIDs[nextIndex]
        switchedState.consecutiveTransientFailures = 0
        return ModelProxyFailoverTransition(state: switchedState, outcome: .switched)
    }

    /// Applies feedback only when it belongs to the node that is still active.
    /// This prevents late completions from an older attempt from resetting or
    /// incrementing the failure streak of a node selected in the meantime.
    public func transition(
        from state: ModelProxyFailoverState,
        attemptedNodeID: String,
        event: ModelProxyFailoverEvent
    ) -> ModelProxyFailoverTransition? {
        guard state.activeNodeID == attemptedNodeID else { return nil }
        return transition(from: state, event: event)
    }

    private static func key(providerID: UUID, model: String) -> Key {
        Key(
            providerID: providerID,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct UsageAggregate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var month: String
    public var requestedModel: String
    public var providerID: UUID
    public var providerName: String
    public var model: String
    public var requests: Int
    public var successfulRequests: Int
    public var totalLatencyMilliseconds: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var pricedRequests: Int
    public var estimatedCostUSD: Double
    public var contextCharactersSaved: Int
    public var lastUsedAt: Date
    public var recentLatencyMilliseconds: [Int]?

    public init(
        id: UUID = UUID(),
        month: String,
        requestedModel: String,
        providerID: UUID,
        providerName: String,
        model: String,
        requests: Int = 0,
        successfulRequests: Int = 0,
        totalLatencyMilliseconds: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        pricedRequests: Int = 0,
        estimatedCostUSD: Double = 0,
        contextCharactersSaved: Int = 0,
        lastUsedAt: Date = .now,
        recentLatencyMilliseconds: [Int]? = nil
    ) {
        self.id = id
        self.month = month
        self.requestedModel = requestedModel
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.requests = requests
        self.successfulRequests = successfulRequests
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.pricedRequests = pricedRequests
        self.estimatedCostUSD = estimatedCostUSD
        self.contextCharactersSaved = contextCharactersSaved
        self.lastUsedAt = lastUsedAt
        self.recentLatencyMilliseconds = recentLatencyMilliseconds
    }

    public var averageLatencyMilliseconds: Int {
        requests > 0 ? totalLatencyMilliseconds / requests : 0
    }

    public var p90LatencyMilliseconds: Int? {
        guard let samples = recentLatencyMilliseconds, !samples.isEmpty else {
            return requests > 0 ? averageLatencyMilliseconds : nil
        }
        let ordered = samples.sorted()
        let index = min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.9)) - 1)
        return ordered[max(0, index)]
    }
}

public struct UsageTokenCounts: Equatable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}
