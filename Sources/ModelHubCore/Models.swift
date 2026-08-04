import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini
    case azureOpenAI
    case deepSeek
    case qwen
    case moonshot
    case zhipu
    case xAI
    case groq
    case mistral
    case ollama
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .azureOpenAI: "Azure OpenAI"
        case .deepSeek: "DeepSeek"
        case .qwen: "阿里云百炼 / Qwen"
        case .moonshot: "Moonshot / Kimi"
        case .zhipu: "智谱 GLM"
        case .xAI: "xAI Grok"
        case .groq: "Groq"
        case .mistral: "Mistral AI"
        case .ollama: "Ollama（本地）"
        case .openAICompatible: "通用 OpenAI 兼容"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .azureOpenAI: "https://YOUR-RESOURCE.openai.azure.com"
        case .deepSeek: "https://api.deepseek.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode"
        case .moonshot: "https://api.moonshot.cn"
        case .zhipu: "https://open.bigmodel.cn/api/paas"
        case .xAI: "https://api.x.ai"
        case .groq: "https://api.groq.com/openai"
        case .mistral: "https://api.mistral.ai"
        case .ollama: "http://127.0.0.1:11434"
        case .openAICompatible: "https://"
        }
    }

    public var usesOpenAIProtocol: Bool {
        switch self {
        case .anthropic, .gemini: false
        default: true
        }
    }

    public var needsAPIKey: Bool {
        self != .ollama
    }
}

public struct ProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var enabled: Bool
    public var models: [String]
    public var apiVersion: String
    public var modelProfiles: [String: TargetProfile]?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        enabled: Bool = true,
        models: [String] = [],
        apiVersion: String = "",
        modelProfiles: [String: TargetProfile]? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.enabled = enabled
        self.models = models
        self.apiVersion = apiVersion
        self.modelProfiles = modelProfiles
    }
}

public enum RouteStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case priority
    case roundRobin
    case weightedRandom
    case lowestLatency
    case highestStability
    case lowestCost
    case largestContext
    case balanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .priority: "优先级故障转移"
        case .roundRobin: "轮询"
        case .weightedRandom: "权重随机"
        case .lowestLatency: "最低延迟"
        case .highestStability: "最高稳定性"
        case .lowestCost: "最低成本"
        case .largestContext: "最大上下文"
        case .balanced: "综合评分"
        }
    }
}

public struct RouteTarget: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var providerID: UUID
    public var model: String
    public var weight: Int
    public var priority: Int
    public var profile: TargetProfile?

    public init(
        id: UUID = UUID(),
        providerID: UUID,
        model: String,
        weight: Int = 1,
        priority: Int = 0,
        profile: TargetProfile? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.model = model
        self.weight = weight
        self.priority = priority
        self.profile = profile
    }
}

public struct RouteConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var alias: String
    public var enabled: Bool
    public var strategy: RouteStrategy
    public var targets: [RouteTarget]

    public init(
        id: UUID = UUID(),
        alias: String,
        enabled: Bool = true,
        strategy: RouteStrategy = .priority,
        targets: [RouteTarget] = []
    ) {
        self.id = id
        self.alias = alias
        self.enabled = enabled
        self.strategy = strategy
        self.targets = targets
    }
}

public struct ServerSettings: Codable, Hashable, Sendable {
    public static let fixedPort: UInt16 = 11_435

    public var port: UInt16 { Self.fixedPort }
    public var requireAuthentication: Bool
    public var startAutomatically: Bool

    public init(
        requireAuthentication: Bool = true,
        startAutomatically: Bool = true
    ) {
        self.requireAuthentication = requireAuthentication
        self.startAutomatically = startAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case port, requireAuthentication, startAutomatically
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requireAuthentication = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireAuthentication
        ) ?? true
        startAutomatically = try container.decodeIfPresent(
            Bool.self,
            forKey: .startAutomatically
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.fixedPort, forKey: .port)
        try container.encode(requireAuthentication, forKey: .requireAuthentication)
        try container.encode(startAutomatically, forKey: .startAutomatically)
    }
}

public struct AppConfiguration: Codable, Sendable {
    public var providers: [ProviderConfig]
    public var routes: [RouteConfig]
    public var server: ServerSettings
    public var modelHealth: [ModelHealthRecord]
    public var operational: OperationalSettings
    public var usage: [UsageAggregate]

    public init(
        providers: [ProviderConfig] = [],
        routes: [RouteConfig] = [],
        server: ServerSettings = .init(),
        modelHealth: [ModelHealthRecord] = [],
        operational: OperationalSettings = .init(),
        usage: [UsageAggregate] = []
    ) {
        self.providers = providers
        self.routes = routes
        self.server = server
        self.modelHealth = modelHealth
        self.operational = operational
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case providers, routes, server, modelHealth, operational, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        routes = try container.decodeIfPresent([RouteConfig].self, forKey: .routes) ?? []
        server = try container.decodeIfPresent(ServerSettings.self, forKey: .server) ?? .init()
        modelHealth = try container.decodeIfPresent([ModelHealthRecord].self, forKey: .modelHealth) ?? []
        operational = try container.decodeIfPresent(
            OperationalSettings.self,
            forKey: .operational
        ) ?? .init()
        usage = try container.decodeIfPresent([UsageAggregate].self, forKey: .usage) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(routes, forKey: .routes)
        try container.encode(server, forKey: .server)
        try container.encode(modelHealth, forKey: .modelHealth)
        try container.encode(operational, forKey: .operational)
        try container.encode(usage, forKey: .usage)
    }
}

public struct ChatRequestEnvelope: Codable, Sendable {
    public var model: String
    public var messages: [ChatMessage]?
    public var stream: Bool?
    public var temperature: Double?
    public var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
}

public struct ModelRequestEnvelope: Codable, Sendable {
    public var model: String
    public var stream: Bool?

    public init(model: String, stream: Bool? = nil) {
        self.model = model
        self.stream = stream
    }
}

public struct ChatMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct GatewayLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let model: String
    public let provider: String
    public let statusCode: Int
    public let latencyMilliseconds: Int
    public let detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        model: String,
        provider: String,
        statusCode: Int,
        latencyMilliseconds: Int,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.provider = provider
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.detail = detail
    }
}
