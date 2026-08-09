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

public enum ProviderEndpointKind: String, Codable, Sendable {
    case modelCatalog
    case chat
    case chatStream
    case responses
    case imageGeneration
    case videoGeneration
    case videoTask
    case speech
    case transcription
    case embeddings
    case reranking
}

public enum ProviderEndpointRecord {
    public static func key(for kind: ProviderEndpointKind, model: String? = nil) -> String {
        guard let model, !model.isEmpty else { return kind.rawValue }
        return "\(kind.rawValue)|\(model.lowercased())"
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
    public var endpointURLs: [String: String]
    public var privacyProfile: ProviderPrivacyProfile?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        enabled: Bool = true,
        models: [String] = [],
        apiVersion: String = "",
        modelProfiles: [String: TargetProfile]? = nil,
        endpointURLs: [String: String] = [:],
        privacyProfile: ProviderPrivacyProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.enabled = enabled
        self.models = models
        self.apiVersion = apiVersion
        self.modelProfiles = modelProfiles
        self.endpointURLs = endpointURLs
        self.privacyProfile = privacyProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, enabled, models, apiVersion, modelProfiles, endpointURLs, privacyProfile
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
            endpointURLs = [:]
            privacyProfile = nil
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
            endpointURLs = try container.decodeIfPresent(
                [String: String].self,
                forKey: .endpointURLs
            ) ?? [:]
            privacyProfile = try container.decodeIfPresent(
                ProviderPrivacyProfile.self,
                forKey: .privacyProfile
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
        if !endpointURLs.isEmpty {
            try container.encode(endpointURLs, forKey: .endpointURLs)
        }
        try container.encodeIfPresent(privacyProfile, forKey: .privacyProfile)
    }

    private static func legacyIdentifier(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0xA5 }, as: UTF8.self)
    }
}

/// Converts legacy host/version-root records into explicit request endpoints once.
/// Request execution itself never derives or appends an endpoint path.
public enum ProviderBaseURLMigration {
    public static func migratedProvider(_ provider: ProviderConfig) -> ProviderConfig? {
        guard provider.endpointURLs.isEmpty, !provider.models.isEmpty else { return nil }
        var migrated = provider
        var records: [String: String] = [:]

        for model in provider.models {
            var singleModelProvider = provider
            singleModelProvider.models = [model]
            if let nativeProtocol = ModelProbePolicy.nativeProtocol(
                provider: provider,
                model: model
            ), let operation = ModelProbePolicy.nativeOperation(for: nativeProtocol) {
                let kind = endpointKind(for: operation)
                records[ProviderEndpointRecord.key(for: kind, model: model)] =
                    completedLegacyURL(for: singleModelProvider) ?? provider.baseURL
                if operation == .videoGeneration,
                   let taskTemplate = legacyVideoTaskTemplate(for: provider)
                {
                    records[
                        ProviderEndpointRecord.key(for: .videoTask, model: model)
                    ] = taskTemplate
                }
            } else {
                records[ProviderEndpointRecord.key(for: .chat, model: model)] =
                    completedLegacyURL(for: singleModelProvider) ?? provider.baseURL
                if provider.kind == .gemini,
                   let streamURL = legacyGeminiStreamURL(for: provider, model: model)
                {
                    records[
                        ProviderEndpointRecord.key(for: .chatStream, model: model)
                    ] = streamURL
                }
            }
        }

        guard !records.isEmpty else { return nil }
        migrated.endpointURLs = records
        if let firstModel = provider.models.first {
            let nativeKind = ModelProbePolicy.nativeProtocol(provider: provider, model: firstModel)
                .flatMap(ModelProbePolicy.nativeOperation(for:))
                .map(endpointKind(for:))
            let firstKind = nativeKind ?? .chat
            if let explicitURL = records[
                ProviderEndpointRecord.key(for: firstKind, model: firstModel)
            ] {
                migrated.baseURL = explicitURL
            }
        }
        return migrated
    }

    public static func completedLegacyURL(for provider: ProviderConfig) -> String? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "/")
        )
        let base = provider.baseURL.trimmingCharacters(in: trimSet)
        guard var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil,
              components.query == nil,
              components.fragment == nil,
              isLegacyBasePath(components.path)
        else {
            return nil
        }

        if let model = provider.models.first,
           let nativeProtocol = ModelProbePolicy.nativeProtocol(provider: provider, model: model)
        {
            guard let operation = ModelProbePolicy.nativeOperation(for: nativeProtocol) else {
                return nil
            }
            return legacyNativeEndpoint(
                provider: provider,
                model: model,
                operation: operation,
                components: &components
            )
        }

        switch provider.kind {
        case .anthropic:
            return append("/v1/messages", to: base)
        case .gemini:
            guard let model = provider.models.first, !model.isEmpty else { return nil }
            let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            return append("/v1beta/models/\(encoded):generateContent", to: base)
        default:
            let suffix = ["/v1", "/v2", "/v3"].contains(where: base.hasSuffix)
                ? "/chat/completions"
                : "/v1/chat/completions"
            return append(suffix, to: base)
        }
    }

    private static func endpointKind(for operation: NativeAPIOperation) -> ProviderEndpointKind {
        switch operation {
        case .imageGeneration: .imageGeneration
        case .videoGeneration: .videoGeneration
        case .videoTask: .videoTask
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        }
    }

    private static func legacyGeminiStreamURL(
        for provider: ProviderConfig,
        model: String
    ) -> String? {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil,
              isLegacyBasePath(components.path)
        else {
            return provider.baseURL
        }
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        return append("/v1beta/models/\(encoded):streamGenerateContent", to: base)
    }

    private static func legacyVideoTaskTemplate(for provider: ProviderConfig) -> String? {
        guard var components = URLComponents(string: provider.baseURL),
              components.scheme != nil,
              components.host != nil
        else {
            return nil
        }
        let hostname = components.host?.lowercased() ?? ""
        let providerName = provider.name.lowercased()
        let isAPIMart = hostname.contains("apimart.ai") || providerName.contains("apimart")
        let isAgnes = hostname.contains("agnes-ai.com")
            || hostname.contains("agnes-ai.cn")
            || providerName.contains("agnes")
        let knownCreationPaths = ["/v1/videos/generations", "/v1/videos"]
        if let creationPath = knownCreationPaths.first(where: components.path.hasSuffix) {
            components.path.removeLast(creationPath.count)
        } else if components.path.hasSuffix("/v1") {
            components.path.removeLast(3)
        } else if !components.path.isEmpty && components.path != "/" {
            return provider.baseURL
        }
        components.query = nil
        components.fragment = nil
        guard let root = components.url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) else {
            return nil
        }
        let suffix = isAPIMart
            ? "/v1/tasks/{task_id}"
            : isAgnes ? "/v1/videos/{task_id}" : "/v1/videos/{task_id}"
        return root + suffix
    }

    private static func isLegacyBasePath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty || [
            "v1", "v2", "v3", "api/v1", "api/v2", "api/v3",
            "api/paas", "api/paas/v4", "compatible-mode",
            "compatibility/v1", "inference/v1"
        ].contains(normalized)
    }

    private static func legacyNativeEndpoint(
        provider: ProviderConfig,
        model: String,
        operation: NativeAPIOperation,
        components: inout URLComponents
    ) -> String? {
        let providerName = provider.name.lowercased()
        let hostname = components.host?.lowercased() ?? ""
        let isAgnes = hostname.contains("agnes-ai.com")
            || hostname.contains("agnes-ai.cn")
            || providerName.contains("agnes")
        let isBailian = hostname.contains("dashscope.aliyuncs.com")
            || providerName.contains("百炼")

        let suffix: String
        switch operation {
        case .imageGeneration:
            suffix = isBailian && model.lowercased() == "wanx-v1"
                ? "/api/v1/services/aigc/text2image/image-synthesis"
                : "/v1/images/generations"
        case .videoGeneration:
            suffix = isAgnes ? "/v1/videos" : "/v1/videos/generations"
        case .speech:
            if isBailian {
                let lowered = model.lowercased()
                suffix = lowered.hasPrefix("cosyvoice") || lowered.hasPrefix("qwen-audio-")
                    ? "/api/v1/services/audio/tts/SpeechSynthesizer"
                    : "/api/v1/services/aigc/multimodal-generation/generation"
            } else {
                suffix = "/v1/audio/speech"
            }
        case .transcription:
            suffix = "/v1/audio/transcriptions"
        case .embeddings:
            suffix = "/v1/embeddings"
        case .reranking:
            suffix = "/v1/rerank"
        case .videoTask:
            return nil
        }

        if isBailian {
            components.path = ""
        } else if components.path.hasSuffix("/v1") && suffix.hasPrefix("/v1/") {
            components.path.removeLast(3)
        }
        guard let root = components.url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) else {
            return nil
        }
        return append(suffix, to: root)
    }

    private static func append(_ suffix: String, to base: String) -> String? {
        URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix)?
            .absoluteString
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
    public var constraints: RouteConstraints?

    public init(
        id: UUID = UUID(),
        alias: String,
        enabled: Bool = true,
        strategy: RouteStrategy = .priority,
        targets: [RouteTarget] = [],
        constraints: RouteConstraints? = nil
    ) {
        self.id = id
        self.alias = alias
        self.enabled = enabled
        self.strategy = strategy
        self.targets = targets
        self.constraints = constraints
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
    public var workspaces: [WorkspaceConfig]
    public var virtualKeys: [VirtualAccessKey]
    public var securityAudit: [SecurityAuditEvent]

    public init(
        providers: [ProviderConfig] = [],
        routes: [RouteConfig] = [],
        routing: RoutingRuleSettings = .init(),
        server: ServerSettings = .init(),
        modelHealth: [ModelHealthRecord] = [],
        operational: OperationalSettings = .init(),
        usage: [UsageAggregate] = [],
        workspaces: [WorkspaceConfig] = [],
        virtualKeys: [VirtualAccessKey] = [],
        securityAudit: [SecurityAuditEvent] = []
    ) {
        self.providers = providers
        self.routes = routes
        self.routing = routing
        self.server = server
        self.modelHealth = modelHealth
        self.operational = operational
        self.usage = usage
        self.workspaces = workspaces
        self.virtualKeys = virtualKeys
        self.securityAudit = securityAudit
    }

    enum CodingKeys: String, CodingKey {
        case providers, routes, routing, server, modelHealth, operational, usage,
             workspaces, virtualKeys, securityAudit
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
        workspaces = try container.decodeIfPresent([WorkspaceConfig].self, forKey: .workspaces) ?? []
        virtualKeys = try container.decodeIfPresent([VirtualAccessKey].self, forKey: .virtualKeys) ?? []
        securityAudit = try container.decodeIfPresent([SecurityAuditEvent].self, forKey: .securityAudit) ?? []
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
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(virtualKeys, forKey: .virtualKeys)
        try container.encode(securityAudit, forKey: .securityAudit)
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
