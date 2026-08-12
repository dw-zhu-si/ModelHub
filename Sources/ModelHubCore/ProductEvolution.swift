import CryptoKit
import Foundation

public enum ProviderDataRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case mainlandChina
    case global
    case localDevice
    case custom

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .unknown: "未核实"
        case .mainlandChina: "中国大陆"
        case .global: "全球/境外"
        case .localDevice: "仅本机"
        case .custom: "自定义"
        }
    }
}

public struct ProviderPrivacyProfile: Codable, Hashable, Sendable {
    public var dataRegion: ProviderDataRegion
    public var zeroDataRetention: Bool
    public var mayUseForTraining: Bool?
    public var retentionDays: Int?
    public var policySource: String
    public var verifiedAt: Date?

    public init(
        dataRegion: ProviderDataRegion = .unknown,
        zeroDataRetention: Bool = false,
        mayUseForTraining: Bool? = nil,
        retentionDays: Int? = nil,
        policySource: String = "",
        verifiedAt: Date? = nil
    ) {
        self.dataRegion = dataRegion
        self.zeroDataRetention = zeroDataRetention
        self.mayUseForTraining = mayUseForTraining
        self.retentionDays = retentionDays
        self.policySource = policySource
        self.verifiedAt = verifiedAt
    }
}

public struct RouteConstraints: Codable, Hashable, Sendable {
    public var maximumCombinedCostPerMillionTokens: Double?
    public var maximumP90LatencyMilliseconds: Int?
    public var minimumContextWindow: Int?
    public var requireKnownPrice: Bool
    public var requireOfficialProvider: Bool
    public var requiredCapabilities: Set<ModelCapability>

    public init(
        maximumCombinedCostPerMillionTokens: Double? = nil,
        maximumP90LatencyMilliseconds: Int? = nil,
        minimumContextWindow: Int? = nil,
        requireKnownPrice: Bool = false,
        requireOfficialProvider: Bool = false,
        requiredCapabilities: Set<ModelCapability> = []
    ) {
        self.maximumCombinedCostPerMillionTokens = maximumCombinedCostPerMillionTokens
        self.maximumP90LatencyMilliseconds = maximumP90LatencyMilliseconds
        self.minimumContextWindow = minimumContextWindow
        self.requireKnownPrice = requireKnownPrice
        self.requireOfficialProvider = requireOfficialProvider
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct WorkspacePrivacyPolicy: Codable, Hashable, Sendable {
    public var allowedRegions: Set<ProviderDataRegion>
    public var requireZeroDataRetention: Bool
    public var forbidTrainingUse: Bool
    public var maximumRetentionDays: Int?

    public init(
        allowedRegions: Set<ProviderDataRegion> = [],
        requireZeroDataRetention: Bool = false,
        forbidTrainingUse: Bool = false,
        maximumRetentionDays: Int? = nil
    ) {
        self.allowedRegions = allowedRegions
        self.requireZeroDataRetention = requireZeroDataRetention
        self.forbidTrainingUse = forbidTrainingUse
        self.maximumRetentionDays = maximumRetentionDays
    }
}

public struct WorkspaceConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var allowedProviderIDs: Set<UUID>
    public var allowedModels: Set<String>
    public var monthlyBudgetUSD: Double?
    public var privacy: WorkspacePrivacyPolicy

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        allowedProviderIDs: Set<UUID> = [],
        allowedModels: Set<String> = [],
        monthlyBudgetUSD: Double? = nil,
        privacy: WorkspacePrivacyPolicy = .init()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.allowedProviderIDs = allowedProviderIDs
        self.allowedModels = allowedModels
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.privacy = privacy
    }
}

public struct VirtualAccessKey: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tokenDigest: String
    public var workspaceID: UUID?
    public var enabled: Bool
    public var allowedModels: Set<String>
    public var requestsPerMinute: Int
    public var monthlyBudgetUSD: Double?
    public var createdAt: Date
    public var expiresAt: Date?
    public var lastUsedAt: Date?
    public var usageMonth: String
    public var requestsThisMonth: Int
    public var estimatedCostThisMonth: Double

    public init(
        id: UUID = UUID(),
        name: String,
        tokenDigest: String,
        workspaceID: UUID? = nil,
        enabled: Bool = true,
        allowedModels: Set<String> = [],
        requestsPerMinute: Int = 120,
        monthlyBudgetUSD: Double? = nil,
        createdAt: Date = .now,
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil,
        usageMonth: String = UsageAccounting.monthKey(),
        requestsThisMonth: Int = 0,
        estimatedCostThisMonth: Double = 0
    ) {
        self.id = id
        self.name = name
        self.tokenDigest = tokenDigest
        self.workspaceID = workspaceID
        self.enabled = enabled
        self.allowedModels = allowedModels
        self.requestsPerMinute = requestsPerMinute
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.usageMonth = usageMonth
        self.requestsThisMonth = requestsThisMonth
        self.estimatedCostThisMonth = estimatedCostThisMonth
    }

    public func isUsable(at date: Date = .now) -> Bool {
        enabled && (expiresAt == nil || expiresAt! > date)
    }
}

public enum AccessTokenHasher {
    public static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ token: String, digest expected: String) -> Bool {
        let actual = Array(digest(token).utf8)
        let expectedBytes = Array(expected.lowercased().utf8)
        guard actual.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for index in actual.indices { difference |= actual[index] ^ expectedBytes[index] }
        return difference == 0
    }
}

public struct RoutingAccessPolicy: Hashable, Sendable {
    public var allowedProviderIDs: Set<UUID>
    public var allowedModels: Set<String>
    public var privacy: WorkspacePrivacyPolicy

    public init(
        allowedProviderIDs: Set<UUID> = [],
        allowedModels: Set<String> = [],
        privacy: WorkspacePrivacyPolicy = .init()
    ) {
        self.allowedProviderIDs = allowedProviderIDs
        self.allowedModels = allowedModels
        self.privacy = privacy
    }

    public static let unrestricted = RoutingAccessPolicy()
}

public enum RoutingPolicyEvaluator {
    public static func exclusionReasons(
        target: RouteTarget,
        provider: ProviderConfig,
        health: ModelHealthIndex,
        usage: [UsageAggregate],
        requiredCapabilities: Set<ModelCapability>,
        constraints: RouteConstraints?,
        access: RoutingAccessPolicy
    ) -> [String] {
        var reasons: [String] = []
        if !provider.enabled { reasons.append("供应商已停用") }
        if !health.status(providerID: provider.id, model: target.model).isRoutable {
            reasons.append("模型未通过验真或已隔离")
        }
        if !access.allowedProviderIDs.isEmpty, !access.allowedProviderIDs.contains(provider.id) {
            reasons.append("工作区未授权此供应商")
        }
        if !access.allowedModels.isEmpty,
           !access.allowedModels.contains(where: {
               $0.caseInsensitiveCompare(target.model) == .orderedSame
           })
        {
            reasons.append("工作区未授权此模型")
        }
        let profile = target.profile ?? provider.modelProfiles?[target.model]
        let capabilities = requiredCapabilities.union(constraints?.requiredCapabilities ?? [])
        if !capabilities.isEmpty, let profile, !profile.capabilities.isEmpty,
           !capabilities.isSubset(of: profile.capabilities)
        {
            reasons.append("能力不匹配")
        }
        if constraints?.requireKnownPrice == true, profile?.hasKnownPrice != true {
            reasons.append("缺少已核实价格")
        }
        if let maximum = constraints?.maximumCombinedCostPerMillionTokens,
           let profile, profile.hasKnownPrice,
           profile.configuredUnitCostUSD > maximum
        {
            reasons.append("价格超过路由上限")
        }
        if let minimum = constraints?.minimumContextWindow,
           (profile?.contextWindow ?? 0) < minimum
        {
            reasons.append("上下文窗口不足")
        }
        if constraints?.requireOfficialProvider == true,
           !provider.kind.isOfficialProvider(for: target.model)
        {
            reasons.append("不是模型官方供应商")
        }
        if let maximum = constraints?.maximumP90LatencyMilliseconds {
            let p90 = usage.filter { $0.providerID == provider.id && $0.model == target.model }
                .compactMap(\.p90LatencyMilliseconds).max()
            if p90 == nil || p90! > maximum { reasons.append("P90 延迟未知或超过上限") }
        }
        let privacy = provider.privacyProfile ?? .init()
        if !access.privacy.allowedRegions.isEmpty,
           !access.privacy.allowedRegions.contains(privacy.dataRegion)
        {
            reasons.append("数据地区不符合工作区策略")
        }
        if access.privacy.requireZeroDataRetention, !privacy.zeroDataRetention {
            reasons.append("未核实零数据留存")
        }
        if access.privacy.forbidTrainingUse, privacy.mayUseForTraining != false {
            reasons.append("未核实禁止训练使用")
        }
        if let maximum = access.privacy.maximumRetentionDays,
           (privacy.retentionDays ?? .max) > maximum
        {
            reasons.append("数据留存期限未知或超限")
        }
        return reasons
    }
}

public enum SecurityAuditAction: String, Codable, Sendable {
    case virtualKeyCreated
    case virtualKeyRevoked
    case accessDenied
    case policyChanged
    case cacheCleared
    case taskSubmitted
    case taskCancelled
}

public struct SecurityAuditEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var action: SecurityAuditAction
    public var actor: String
    public var outcome: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        action: SecurityAuditAction,
        actor: String,
        outcome: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.actor = actor
        self.outcome = outcome
        self.detail = detail
    }
}

public enum ScopedAdmission: Equatable, Sendable {
    case allowed
    case rateLimited(retryAfterSeconds: Int)
}

public actor ScopedRateLimiter {
    private var requestDates: [UUID: [Date]] = [:]

    public init() {}

    public func admit(keyID: UUID, requestsPerMinute: Int, now: Date = .now) -> ScopedAdmission {
        let cutoff = now.addingTimeInterval(-60)
        var dates = requestDates[keyID, default: []]
        dates.removeAll { $0 <= cutoff }
        guard dates.count < max(1, requestsPerMinute) else {
            requestDates[keyID] = dates
            let retry = dates.first.map {
                max(1, Int(ceil($0.addingTimeInterval(60).timeIntervalSince(now))))
            } ?? 1
            return .rateLimited(retryAfterSeconds: retry)
        }
        dates.append(now)
        requestDates[keyID] = dates
        return .allowed
    }
}

public enum EndpointEditorError: Error, Equatable, LocalizedError {
    case invalidLine(Int)
    case invalidKey(Int)
    case duplicateKey(String)
    case invalidURL(Int)
    case unsupportedTemplate(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLine(let line): "第 \(line) 行必须使用“端点键 = 完整 URL”。"
        case .invalidKey(let line): "第 \(line) 行的端点键无效。"
        case .duplicateKey(let key): "端点键重复：\(key)"
        case .invalidURL(let line): "第 \(line) 行不是完整的 HTTP(S) URL。"
        case .unsupportedTemplate(let line): "第 \(line) 行只允许聊天端点使用 {model}，视频或音乐任务端点使用 {task_id}。"
        }
    }
}

/// 面向界面的显式端点编解码器。运行时不会借此推导或补全路径。
public enum ProviderEndpointEditorCodec {
    public static func text(from records: [String: String]) -> String {
        records.keys.sorted().compactMap { key in
            guard let value = records[key] else { return nil }
            return "\(key) = \(value)"
        }.joined(separator: "\n")
    }

    public static func records(from text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw EndpointEditorError.invalidLine(lineNumber)
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard validKey(key) else { throw EndpointEditorError.invalidKey(lineNumber) }
            guard result[key] == nil else { throw EndpointEditorError.duplicateKey(key) }
            guard let components = URLComponents(string: value),
                  ProviderEndpointSecurity.isSafeConfigurationURL(components)
            else { throw EndpointEditorError.invalidURL(lineNumber) }

            let endpointKind = key.split(separator: "|", maxSplits: 1).first.map(String.init)
            if value.contains("{") || value.contains("}") {
                let template: String? = switch endpointKind {
                case ProviderEndpointKind.videoTask.rawValue,
                     ProviderEndpointKind.musicTask.rawValue:
                    "{task_id}"
                case ProviderEndpointKind.chat.rawValue,
                     ProviderEndpointKind.chatStream.rawValue:
                    "{model}"
                default:
                    nil
                }
                guard let template,
                      value.components(separatedBy: template).count == 2,
                      value.replacingOccurrences(of: template, with: "").contains("{") == false,
                      value.replacingOccurrences(of: template, with: "").contains("}") == false
                else { throw EndpointEditorError.unsupportedTemplate(lineNumber) }
            }
            result[key] = value
        }
        return result
    }

    private static func validKey(_ key: String) -> Bool {
        let components = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawKind = components.first,
              ProviderEndpointKind(rawValue: String(rawKind)) != nil
        else { return false }
        return components.count == 1 || !components[1]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ModelVerificationEvidence: Identifiable, Hashable, Sendable {
    public let providerID: UUID
    public let providerName: String
    public let model: String
    public let status: ModelAvailability
    public let checkedAt: Date?
    public let latencyMilliseconds: Int?
    public let statusCode: Int?
    public let capabilities: Set<ModelCapability>
    public let protocolName: String
    public let detail: String

    public var id: String { "\(providerID.uuidString.lowercased())/\(model.lowercased())" }
    public var isLiveVerified: Bool {
        status == .available && statusCode.map { (200..<300).contains($0) } == true
    }

    public init(provider: ProviderConfig, model: String, health: ModelHealthRecord?) {
        providerID = provider.id
        providerName = provider.name
        self.model = model
        status = health?.status ?? .unavailable
        checkedAt = health?.checkedAt
        latencyMilliseconds = health?.latencyMilliseconds
        statusCode = health?.statusCode
        detail = health?.detail ?? "尚无在线验证证据，保持隔离"
        let profile = provider.modelProfiles?[model]
        capabilities = profile?.capabilities ?? []
        protocolName = ModelProbePolicy.nativeProtocol(provider: provider, model: model)?
            .displayName ?? "聊天"
    }
}

public enum RouteDecisionState: String, Codable, Sendable {
    case selected
    case eligible
    case excluded
}

public struct RouteDecisionCandidate: Identifiable, Hashable, Sendable {
    public let target: RouteTarget
    public let providerName: String
    public let state: RouteDecisionState
    public let rank: Int?
    public let reasons: [String]
    public let endpoint: String
    public let availability: ModelAvailability
    public let latencyMilliseconds: Int?
    public let estimatedCostPerMillionTokens: Double?

    public var id: UUID { target.id }
}

public struct RouteDecisionReport: Hashable, Sendable {
    public let requestedModel: String
    public let routeAlias: String?
    public let strategy: RouteStrategy?
    public let generatedAt: Date
    public let candidates: [RouteDecisionCandidate]

    public var selected: RouteDecisionCandidate? {
        candidates.first { $0.state == .selected }
    }
}

extension RoutingEngine {
    /// 只读模拟，不增加轮询计数、不调用供应商，也不改变健康或用量记录。
    public func explain(
        requestedModel: String,
        routes: [RouteConfig],
        providers: [ProviderConfig],
        healthRecords: [ModelHealthRecord],
        usage: [UsageAggregate] = [],
        requiredCapabilities: Set<ModelCapability> = [],
        defaultRule: DefaultRoutingRule = .sameModelLowestCost
    ) -> RouteDecisionReport {
        let health = ModelHealthIndex(records: healthRecords)
        let route = routes.first {
            $0.enabled && $0.alias.caseInsensitiveCompare(requestedModel) == .orderedSame
        }
        let rawTargets: [RouteTarget]
        if let route {
            rawTargets = route.targets
        } else {
            rawTargets = providers.flatMap { provider in
                provider.models.compactMap { model in
                    let names = [model, "\(provider.name)/\(model)", "\(provider.id.uuidString)/\(model)"]
                    guard names.contains(where: {
                        $0.caseInsensitiveCompare(requestedModel) == .orderedSame
                    }) else { return nil }
                    return RouteTarget(
                        providerID: provider.id,
                        model: model,
                        profile: provider.modelProfiles?[model]
                    )
                }
            }
        }

        let providerIndex = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let eligible = explainableOrder(
            rawTargets.compactMap { raw -> RouteTarget? in
                guard let provider = providerIndex[raw.providerID], provider.enabled,
                      !raw.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      health.status(providerID: raw.providerID, model: raw.model).isRoutable
                else { return nil }
                let profile = raw.profile ?? provider.modelProfiles?[raw.model]
                guard requiredCapabilities.isEmpty
                        || profile?.capabilities.isEmpty != false
                        || requiredCapabilities.isSubset(of: profile?.capabilities ?? [])
                else { return nil }
                var target = raw
                target.profile = profile
                return target
            },
            route: route,
            providers: providers,
            health: health,
            usage: usage,
            defaultRule: defaultRule
        )
        let ranks = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($0.element.id, $0.offset) })

        let decisions = rawTargets.map { raw -> RouteDecisionCandidate in
            let provider = providerIndex[raw.providerID]
            let profile = raw.profile ?? provider?.modelProfiles?[raw.model]
            var reasons: [String] = []
            if provider == nil { reasons.append("供应商不存在") }
            if provider?.enabled == false { reasons.append("供应商已停用") }
            if raw.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("模型名称为空")
            }
            let availability = health.status(providerID: raw.providerID, model: raw.model)
            if !availability.isRoutable { reasons.append("模型状态为 \(availability.rawValue)，已隔离") }
            if !requiredCapabilities.isEmpty,
               let profile,
               !profile.capabilities.isEmpty,
               !requiredCapabilities.isSubset(of: profile.capabilities)
            {
                reasons.append("不满足请求能力：\(requiredCapabilities.map(\.displayName).sorted().joined(separator: "、"))")
            }
            let rank = ranks[raw.id]
            let state: RouteDecisionState = reasons.isEmpty
                ? (rank == 0 ? .selected : .eligible)
                : .excluded
            if reasons.isEmpty {
                reasons.append(rank == 0 ? "按当前规则排名第一" : "可用候选，排名 \((rank ?? 0) + 1)")
            }
            let endpoint = endpointURL(provider: provider, model: raw.model)
            let estimatedCost = profile?.hasKnownPrice == true
                ? (profile?.configuredUnitCostUSD ?? 0)
                : nil
            return RouteDecisionCandidate(
                target: raw,
                providerName: provider?.name ?? "未知供应商",
                state: state,
                rank: rank.map { $0 + 1 },
                reasons: reasons,
                endpoint: endpoint,
                availability: availability,
                latencyMilliseconds: health.record(providerID: raw.providerID, model: raw.model)?.latencyMilliseconds,
                estimatedCostPerMillionTokens: estimatedCost
            )
        }.sorted {
            switch ($0.rank, $1.rank) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.providerName < $1.providerName
            }
        }
        return RouteDecisionReport(
            requestedModel: requestedModel,
            routeAlias: route?.alias,
            strategy: route?.strategy,
            generatedAt: .now,
            candidates: decisions
        )
    }

    private func explainableOrder(
        _ targets: [RouteTarget],
        route: RouteConfig?,
        providers: [ProviderConfig],
        health: ModelHealthIndex,
        usage: [UsageAggregate],
        defaultRule: DefaultRoutingRule
    ) -> [RouteTarget] {
        guard let route else {
            return targets.sorted { lhs, rhs in
                let leftModel = lhs.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let rightModel = rhs.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard leftModel == rightModel else { return lhs.id.uuidString < rhs.id.uuidString }
                return compareForExplanation(lhs, rhs, providers: providers, health: health, defaultRule: defaultRule)
            }
        }
        switch route.strategy {
        case .priority, .roundRobin, .weightedRandom:
            return targets.sorted {
                if $0.priority == $1.priority { return $0.weight > $1.weight }
                return $0.priority < $1.priority
            }
        case .lowestLatency:
            return targets.sorted { latencyForExplanation($0, health: health) < latencyForExplanation($1, health: health) }
        case .highestStability:
            return targets.sorted { stabilityForExplanation($0, usage: usage) > stabilityForExplanation($1, usage: usage) }
        case .lowestCost:
            return targets.sorted { costForExplanation($0) < costForExplanation($1) }
        case .largestContext:
            return targets.sorted { ($0.profile?.contextWindow ?? -1) > ($1.profile?.contextWindow ?? -1) }
        case .balanced:
            return targets.sorted {
                let left = Double(min(latencyForExplanation($0, health: health), 60_000)) / 1_000
                    + min(costForExplanation($0), 100)
                let right = Double(min(latencyForExplanation($1, health: health), 60_000)) / 1_000
                    + min(costForExplanation($1), 100)
                return left < right
            }
        }
    }

    private func compareForExplanation(
        _ lhs: RouteTarget,
        _ rhs: RouteTarget,
        providers: [ProviderConfig],
        health: ModelHealthIndex,
        defaultRule: DefaultRoutingRule
    ) -> Bool {
        switch defaultRule {
        case .sameModelLowestCost:
            let left = costForExplanation(lhs), right = costForExplanation(rhs)
            if left != right { return left < right }
        case .sameModelLowestLatency:
            let left = latencyForExplanation(lhs, health: health)
            let right = latencyForExplanation(rhs, health: health)
            if left != right { return left < right }
        case .sameModelOfficial:
            let left = providers.first { $0.id == lhs.providerID }?.kind.isOfficialProvider(for: lhs.model) == true
            let right = providers.first { $0.id == rhs.providerID }?.kind.isOfficialProvider(for: rhs.model) == true
            if left != right { return left && !right }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func endpointURL(provider: ProviderConfig?, model: String) -> String {
        guard let provider else { return "" }
        let kind: ProviderEndpointKind
        if let native = ModelProbePolicy.nativeProtocol(provider: provider, model: model),
           let operation = ModelProbePolicy.nativeOperation(for: native)
        {
            kind = switch operation {
            case .imageGeneration: .imageGeneration
            case .musicGeneration: .musicGeneration
            case .musicTask: .musicTask
            case .videoGeneration: .videoGeneration
            case .videoTask: .videoTask
            case .speech: .speech
            case .transcription: .transcription
            case .embeddings: .embeddings
            case .reranking: .reranking
            }
        } else {
            kind = .chat
        }
        return provider.endpointURLs[ProviderEndpointRecord.key(for: kind, model: model)]
            ?? provider.endpointURLs[ProviderEndpointRecord.key(for: kind)]
            ?? provider.baseURL
    }

    private func latencyForExplanation(_ target: RouteTarget, health: ModelHealthIndex) -> Int {
        health.record(providerID: target.providerID, model: target.model)?.latencyMilliseconds
            .flatMap { $0 > 0 ? $0 : nil } ?? .max
    }

    private func costForExplanation(_ target: RouteTarget) -> Double {
        guard target.profile?.hasKnownPrice == true else { return .greatestFiniteMagnitude }
        return target.profile?.configuredUnitCostUSD ?? .greatestFiniteMagnitude
    }

    private func stabilityForExplanation(_ target: RouteTarget, usage: [UsageAggregate]) -> Double {
        let matching = usage.filter { $0.providerID == target.providerID && $0.model == target.model }
        let requests = matching.reduce(0) { $0 + $1.requests }
        guard requests > 0 else { return -1 }
        return Double(matching.reduce(0) { $0 + $1.successfulRequests }) / Double(requests)
    }
}
