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
        case .videoGeneration: "视频生成"
        }
    }
}

public struct TargetProfile: Codable, Hashable, Sendable {
    public var contextWindow: Int?
    public var inputCostPerMillionTokens: Double?
    public var outputCostPerMillionTokens: Double?
    public var capabilities: Set<ModelCapability>
    public var pricingSource: String
    public var pricingUpdatedAt: Date?
    public var monthlyTokenLimit: Int?

    public init(
        contextWindow: Int? = nil,
        inputCostPerMillionTokens: Double? = nil,
        outputCostPerMillionTokens: Double? = nil,
        capabilities: Set<ModelCapability> = [],
        pricingSource: String = "",
        pricingUpdatedAt: Date? = nil,
        monthlyTokenLimit: Int? = nil
    ) {
        self.contextWindow = contextWindow
        self.inputCostPerMillionTokens = inputCostPerMillionTokens
        self.outputCostPerMillionTokens = outputCostPerMillionTokens
        self.capabilities = capabilities
        self.pricingSource = pricingSource
        self.pricingUpdatedAt = pricingUpdatedAt
        self.monthlyTokenLimit = monthlyTokenLimit
    }

    public var hasKnownPrice: Bool {
        inputCostPerMillionTokens != nil || outputCostPerMillionTokens != nil
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

    public init(
        mcpEnabled: Bool = true,
        a2aEnabled: Bool = true,
        acpManifestEnabled: Bool = true
    ) {
        self.mcpEnabled = mcpEnabled
        self.a2aEnabled = a2aEnabled
        self.acpManifestEnabled = acpManifestEnabled
    }
}

public struct OperationalSettings: Codable, Hashable, Sendable {
    public var resilience: ResilienceSettings
    public var budget: BudgetSettings
    public var contextOptimization: ContextOptimizationSettings
    public var agentProtocols: AgentProtocolSettings
    public var analyticsRetentionMonths: Int

    public init(
        resilience: ResilienceSettings = .init(),
        budget: BudgetSettings = .init(),
        contextOptimization: ContextOptimizationSettings = .init(),
        agentProtocols: AgentProtocolSettings = .init(),
        analyticsRetentionMonths: Int = 12
    ) {
        self.resilience = resilience
        self.budget = budget
        self.contextOptimization = contextOptimization
        self.agentProtocols = agentProtocols
        self.analyticsRetentionMonths = analyticsRetentionMonths
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
        lastUsedAt: Date = .now
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
    }

    public var averageLatencyMilliseconds: Int {
        requests > 0 ? totalLatencyMilliseconds / requests : 0
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
