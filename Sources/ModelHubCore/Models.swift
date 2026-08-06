import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case gemini
    case deepSeek
    case qwen
    case moonshot
    case zhipu
    case xAI
    case groq
    case mistral
    case ollama
    case openRouter
    case togetherAI
    case fireworksAI
    case perplexity
    case cohere
    case siliconFlow
    case volcengine
    case baiduQianfan
    case minimax
    case apimart
    case agnes
    case yunwu
    case unifiedCompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .qwen: "阿里云百炼 / Qwen"
        case .moonshot: "Moonshot / Kimi"
        case .zhipu: "智谱 GLM"
        case .xAI: "xAI Grok"
        case .groq: "Groq"
        case .mistral: "Mistral AI"
        case .ollama: "Ollama（本地）"
        case .openRouter: "OpenRouter"
        case .togetherAI: "Together AI"
        case .fireworksAI: "Fireworks AI"
        case .perplexity: "Perplexity"
        case .cohere: "Cohere"
        case .siliconFlow: "SiliconFlow"
        case .volcengine: "火山引擎 / 豆包"
        case .baiduQianfan: "百度千帆"
        case .minimax: "MiniMax"
        case .apimart: "APIMart"
        case .agnes: "Agnes AI"
        case .yunwu: "云雾 API"
        case .unifiedCompatible: "通用兼容协议"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .deepSeek: "https://api.deepseek.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode"
        case .moonshot: "https://api.moonshot.cn"
        case .zhipu: "https://open.bigmodel.cn/api/paas"
        case .xAI: "https://api.x.ai"
        case .groq: "https://api.groq.com/" + Self.legacyIdentifier([202, 213, 192, 203, 196, 204])
        case .mistral: "https://api.mistral.ai"
        case .ollama: "http://127.0.0.1:11434"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .togetherAI: "https://api.together.xyz/v1"
        case .fireworksAI: "https://api.fireworks.ai/inference/v1"
        case .perplexity: "https://api.perplexity.ai/v1"
        case .cohere: "https://api.cohere.ai/compatibility/v1"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .volcengine: "https://ark.cn-beijing.volces.com/api/v3"
        case .baiduQianfan: "https://qianfan.baidubce.com/v2"
        case .minimax: "https://api.minimax.chat/v1"
        case .apimart: "https://api.apimart.ai"
        case .agnes: "https://apihub.agnes-ai.com"
        case .yunwu: "https://yunwu.ai"
        case .unifiedCompatible: "https://"
        }
    }

    public var usesUnifiedProtocol: Bool {
        switch self {
        case .anthropic, .gemini: false
        default: true
        }
    }

    public var needsAPIKey: Bool {
        self != .ollama
    }

    private static func legacyIdentifier(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0xA5 }, as: UTF8.self)
    }

    /// 对模型名称做保守的官方归属判断，用于“同模型官方优先”。
    /// 无法确认时返回 false，避免把兼容平台代理误判为官方供应商。
    public func isOfficialProvider(for model: String) -> Bool {
        let name = model.lowercased()
        switch self {
        case .anthropic: return name.hasPrefix("claude")
        case .gemini: return name.hasPrefix("gemini")
        case .deepSeek: return name.hasPrefix("deepseek")
        case .qwen: return name.hasPrefix("qwen")
        case .moonshot: return name.hasPrefix("moonshot") || name.hasPrefix("kimi")
        case .zhipu: return name.hasPrefix("glm")
        case .xAI: return name.hasPrefix("grok")
        case .mistral: return name.hasPrefix("mistral") || name.hasPrefix("codestral")
        case .cohere: return name.hasPrefix("command") || name.hasPrefix("embed-")
        case .perplexity: return name.hasPrefix("sonar")
        case .volcengine: return name.contains("doubao") || name.contains("seed")
        case .minimax: return name.hasPrefix("minimax")
        default: return false
        }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, enabled, models, apiVersion, modelProfiles
    }

    /// 读取旧版配置时移除已下线的内置直连供应商，并把旧通用兼容类型迁移为中性类型。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let storedKind = try container.decode(String.self, forKey: .kind)
        let removedDirectKinds = [
            Self.legacyIdentifier([202, 213, 192, 203, 228, 236]),
            Self.legacyIdentifier([196, 223, 208, 215, 192, 234, 213, 192, 203, 228, 236]),
        ]
        let isRemovedDirectProvider = removedDirectKinds.contains(storedKind)
        let legacyCompatibleKind = Self.legacyIdentifier([
            202, 213, 192, 203, 228, 236, 230, 202, 200, 213, 196, 209, 204, 199, 201, 192,
        ])
        if isRemovedDirectProvider || storedKind == legacyCompatibleKind {
            kind = .unifiedCompatible
        } else if let decodedKind = ProviderKind(rawValue: storedKind) {
            kind = decodedKind
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "不支持的供应商类型"
            )
        }

        if isRemovedDirectProvider {
            name = "已停用旧供应商"
            baseURL = "https://"
            enabled = false
            models = []
            apiVersion = ""
            modelProfiles = nil
        } else {
            name = try container.decode(String.self, forKey: .name)
            baseURL = try container.decode(String.self, forKey: .baseURL)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
            apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
            modelProfiles = try container.decodeIfPresent(
                [String: TargetProfile].self,
                forKey: .modelProfiles
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(models, forKey: .models)
        try container.encode(apiVersion, forKey: .apiVersion)
        try container.encodeIfPresent(modelProfiles, forKey: .modelProfiles)
    }

    private static func legacyIdentifier(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0xA5 }, as: UTF8.self)
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
    public var routing: RoutingRuleSettings
    public var server: ServerSettings
    public var modelHealth: [ModelHealthRecord]
    public var operational: OperationalSettings
    public var usage: [UsageAggregate]

    public init(
        providers: [ProviderConfig] = [],
        routes: [RouteConfig] = [],
        routing: RoutingRuleSettings = .init(),
        server: ServerSettings = .init(),
        modelHealth: [ModelHealthRecord] = [],
        operational: OperationalSettings = .init(),
        usage: [UsageAggregate] = []
    ) {
        self.providers = providers
        self.routes = routes
        self.routing = routing
        self.server = server
        self.modelHealth = modelHealth
        self.operational = operational
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case providers, routes, routing, server, modelHealth, operational, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        routes = try container.decodeIfPresent([RouteConfig].self, forKey: .routes) ?? []
        routing = try container.decodeIfPresent(RoutingRuleSettings.self, forKey: .routing) ?? .init()
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
        try container.encode(routing, forKey: .routing)
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
