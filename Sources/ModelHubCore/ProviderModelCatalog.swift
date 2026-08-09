import Foundation

public struct ProviderModelCatalogResult: Sendable, Equatable {
    public let models: [String]
    public let prices: [String: ProviderModelPrice]
    public let endpoint: URL
    public let durationMilliseconds: Int
    public let responseBytes: Int

    public init(
        models: [String],
        prices: [String: ProviderModelPrice] = [:],
        endpoint: URL,
        durationMilliseconds: Int,
        responseBytes: Int
    ) {
        self.models = models
        self.prices = prices
        self.endpoint = endpoint
        self.durationMilliseconds = durationMilliseconds
        self.responseBytes = responseBytes
    }
}

public struct ProviderModelPrice: Sendable, Equatable {
    public let inputPerMillionTokensUSD: Double?
    public let outputPerMillionTokensUSD: Double?
    public let perRequestUSD: Double?
    public let source: String

    public init(
        inputPerMillionTokensUSD: Double? = nil,
        outputPerMillionTokensUSD: Double? = nil,
        perRequestUSD: Double? = nil,
        source: String
    ) {
        self.inputPerMillionTokensUSD = inputPerMillionTokensUSD
        self.outputPerMillionTokensUSD = outputPerMillionTokensUSD
        self.perRequestUSD = perRequestUSD
        self.source = source
    }

    public var hasKnownPrice: Bool {
        inputPerMillionTokensUSD != nil
            || outputPerMillionTokensUSD != nil
            || perRequestUSD != nil
    }
}

public enum ProviderModelCatalogError: LocalizedError, Equatable {
    case missingEndpoint
    case invalidEndpoint
    case insecureEndpoint
    case credentialInURL
    case missingAPIKey
    case redirectedToDifferentOrigin
    case nonHTTPResponse
    case responseTooLarge(maximumBytes: Int)
    case rejected(statusCode: Int)
    case invalidResponse
    case noModels

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            "请填写精确的模型名录 URL；模型推理 Base URL 不会被当作名录地址"
        case .invalidEndpoint:
            "模型名录 URL 必须是无片段的完整 HTTP(S) 地址"
        case .insecureEndpoint:
            String(localized: "远程模型名录必须使用 HTTPS；HTTP 只允许本机回环地址")
        case .credentialInURL:
            "模型名录 URL 不得包含用户名、密码、API Key 或 Token 查询参数"
        case .missingAPIKey:
            "供应商 API Key 未配置"
        case .redirectedToDifferentOrigin:
            "模型名录请求被重定向到其他来源，为防止凭证泄露已拒绝响应"
        case .nonHTTPResponse:
            "供应商返回了非 HTTP 响应"
        case .responseTooLarge(let maximumBytes):
            "模型名录响应超过安全上限（\(maximumBytes / 1_048_576) MiB）"
        case .rejected(let statusCode):
            "供应商拒绝模型名录请求（HTTP \(statusCode)）"
        case .invalidResponse:
            "模型名录不是可识别的 JSON 格式"
        case .noModels:
            "响应成功，但没有解析到模型名称"
        }
    }
}

public enum ProviderModelCatalogParser {
    public static let maximumResponseBytes = 8 * 1_048_576
    public static let maximumModelCount = 10_000
    public static let maximumModelNameLength = 512

    public static func parse(_ data: Data) throws -> [String] {
        try parseDetailed(data, providerKind: .unifiedCompatible, source: "").models
    }

    public static func parseDetailed(
        _ data: Data,
        providerKind: ProviderKind,
        source: String
    ) throws -> (models: [String], prices: [String: ProviderModelPrice]) {
        guard data.count <= maximumResponseBytes else {
            throw ProviderModelCatalogError.responseTooLarge(
                maximumBytes: maximumResponseBytes
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderModelCatalogError.invalidResponse
        }

        var candidates: [String] = []
        var rawPrices: [String: ProviderModelPrice] = [:]
        collect(
            from: root,
            depth: 0,
            providerKind: providerKind,
            source: source,
            candidates: &candidates,
            prices: &rawPrices
        )

        var seen = Set<String>()
        var result: [String] = []
        var prices: [String: ProviderModelPrice] = [:]
        result.reserveCapacity(min(candidates.count, maximumModelCount))
        for rawName in candidates {
            guard let name = normalized(rawName) else { continue }
            let identity = name.lowercased()
            guard seen.insert(identity).inserted else { continue }
            result.append(name)
            if let price = rawPrices[identity], price.hasKnownPrice {
                prices[name] = price
            }
            if result.count == maximumModelCount { break }
        }
        guard !result.isEmpty else { throw ProviderModelCatalogError.noModels }
        return (result, prices)
    }

    private static func collect(
        from value: Any,
        depth: Int,
        providerKind: ProviderKind,
        source: String,
        candidates: inout [String],
        prices: inout [String: ProviderModelPrice]
    ) {
        guard depth <= 4, candidates.count < maximumModelCount else { return }
        if let array = value as? [Any] {
            for item in array where candidates.count < maximumModelCount {
                if let name = modelName(from: item) {
                    candidates.append(name)
                    if let object = item as? [String: Any],
                       let price = tokenPrice(
                           from: object,
                           providerKind: providerKind,
                           source: source
                       )
                    {
                        prices[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = price
                    }
                } else if item is [Any] || item is [String: Any] {
                    collect(
                        from: item,
                        depth: depth + 1,
                        providerKind: providerKind,
                        source: source,
                        candidates: &candidates,
                        prices: &prices
                    )
                }
            }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let collectionKeys = [
            "data", "models", "items", "results", "model_list", "modelList",
            "response", "result", "output"
        ]
        for key in collectionKeys {
            if let nested = object[key] {
                collect(
                    from: nested,
                    depth: depth + 1,
                    providerKind: providerKind,
                    source: source,
                    candidates: &candidates,
                    prices: &prices
                )
            }
        }
    }

    private static func tokenPrice(
        from object: [String: Any],
        providerKind: ProviderKind,
        source: String
    ) -> ProviderModelPrice? {
        let input: Double?
        let output: Double?
        let perRequest = validPrice(number(
            object["price_per_request_usd"]
                ?? object["request_price_usd"]
                ?? object["cost_per_request_usd"]
        ))

        switch providerKind {
        case .openRouter:
            let pricing = object["pricing"] as? [String: Any]
            input = validPrice(number(pricing?["prompt"]).map { $0 * 1_000_000 })
            output = validPrice(number(pricing?["completion"]).map { $0 * 1_000_000 })
        case .xAI:
            // xAI publishes these integers as USD cents per 100 million tokens.
            input = validPrice(number(object["prompt_text_token_price"]).map { $0 / 10_000 })
            output = validPrice(number(object["completion_text_token_price"]).map { $0 / 10_000 })
        case .togetherAI:
            // Together's model catalog documents input/output as USD per 1M tokens.
            if let type = (object["type"] as? String)?.lowercased(),
               !["chat", "language", "code", "embedding", "rerank", "moderation"]
                .contains(type)
            {
                return nil
            }
            let pricing = object["pricing"] as? [String: Any]
            input = validPrice(number(pricing?["input"]))
            output = validPrice(number(pricing?["output"]))
        default:
            // Only accept fields whose names carry an explicit per-million unit.
            input = validPrice(number(
                object["input_cost_per_million_tokens"]
                    ?? object["input_price_per_million_tokens"]
            ))
            output = validPrice(number(
                object["output_cost_per_million_tokens"]
                    ?? object["output_price_per_million_tokens"]
            ))
        }

        guard input != nil || output != nil || perRequest != nil else { return nil }
        return ProviderModelPrice(
            inputPerMillionTokensUSD: input,
            outputPerMillionTokensUSD: output,
            perRequestUSD: perRequest,
            source: source
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func validPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000 else { return nil }
        return value
    }

    private static func modelName(from value: Any) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["id", "name", "model", "model_id", "modelId", "model_name"] {
            if let string = object[key] as? String { return string }
        }
        return nil
    }

    private static func normalized(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= maximumModelNameLength,
              name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return name
    }
}

public enum ProviderModelCatalogImporter {
    public static func merging(existing: [String], imported: [String]) -> [String] {
        var seen = Set<String>()
        return (existing + imported).compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }
}

public struct ProviderModelCatalogHotUpdateSummary: Sendable, Equatable {
    public let catalogModelCount: Int
    public let addedModelCount: Int
    public let retainedModelCount: Int

    public init(
        catalogModelCount: Int,
        addedModelCount: Int,
        retainedModelCount: Int
    ) {
        self.catalogModelCount = catalogModelCount
        self.addedModelCount = addedModelCount
        self.retainedModelCount = retainedModelCount
    }
}

/// Applies a catalog refresh without replacing locally maintained state.
/// Existing models keep their order and health records. Newly discovered
/// models are appended and normalized into a quarantined state until a real
/// provider probe succeeds.
public enum ProviderModelCatalogHotUpdater {
    @discardableResult
    public static func apply(
        importedModels: [String],
        to provider: inout ProviderConfig,
        healthRecords: inout [ModelHealthRecord]
    ) -> ProviderModelCatalogHotUpdateSummary {
        let existingCount = provider.models.count
        let merged = ProviderModelCatalogImporter.merging(
            existing: provider.models,
            imported: importedModels
        )
        provider.models = merged
        let unrelatedHealth = healthRecords.filter { $0.providerID != provider.id }
        let providerHealth = ModelHealthMigration.normalize(
            records: healthRecords.filter { $0.providerID == provider.id },
            providers: [provider]
        )
        healthRecords = unrelatedHealth + providerHealth
        return ProviderModelCatalogHotUpdateSummary(
            catalogModelCount: importedModels.count,
            addedModelCount: max(0, merged.count - existingCount),
            retainedModelCount: existingCount
        )
    }
}

public enum ProviderModelPricingUpdater {
    @discardableResult
    public static func apply(
        prices: [String: ProviderModelPrice],
        to provider: inout ProviderConfig,
        routes: inout [RouteConfig],
        updatedAt: Date = .now
    ) -> Int {
        var indexedPrices: [String: ProviderModelPrice] = [:]
        for (model, price) in prices {
            indexedPrices[
                model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ] = price
        }
        var modelProfiles = provider.modelProfiles ?? [:]
        var updatedModels = Set<String>()

        for model in provider.models {
            let identity = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let price = indexedPrices[identity], price.hasKnownPrice else { continue }
            let existingKey = modelProfiles.keys.first {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity
            }
            var profile = existingKey.flatMap { modelProfiles[$0] } ?? TargetProfile()
            if let input = price.inputPerMillionTokensUSD {
                profile.inputCostPerMillionTokens = input
            }
            if let output = price.outputPerMillionTokensUSD {
                profile.outputCostPerMillionTokens = output
            }
            if let request = price.perRequestUSD {
                profile.requestCostUSD = request
            }
            profile.pricingSource = price.source
            profile.pricingUpdatedAt = updatedAt
            if let existingKey, existingKey != model {
                modelProfiles.removeValue(forKey: existingKey)
            }
            modelProfiles[model] = profile
            updatedModels.insert(identity)
        }
        provider.modelProfiles = modelProfiles.isEmpty ? nil : modelProfiles

        for routeIndex in routes.indices {
            for targetIndex in routes[routeIndex].targets.indices {
                guard routes[routeIndex].targets[targetIndex].providerID == provider.id else {
                    continue
                }
                let model = routes[routeIndex].targets[targetIndex].model
                let identity = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let price = indexedPrices[identity], price.hasKnownPrice else { continue }
                var profile = routes[routeIndex].targets[targetIndex].profile
                    ?? modelProfiles[model]
                    ?? TargetProfile()
                if let input = price.inputPerMillionTokensUSD {
                    profile.inputCostPerMillionTokens = input
                }
                if let output = price.outputPerMillionTokensUSD {
                    profile.outputCostPerMillionTokens = output
                }
                if let request = price.perRequestUSD {
                    profile.requestCostUSD = request
                }
                profile.pricingSource = price.source
                profile.pricingUpdatedAt = updatedAt
                routes[routeIndex].targets[targetIndex].profile = profile
            }
        }
        return updatedModels.count
    }
}

public enum ProviderModelCatalogImportBehavior: String, Sendable, Equatable {
    case directlyCallable
    case deploymentReferenceOnly
}

public struct ProviderModelCatalogSuggestion: Sendable, Equatable {
    public let exactURL: URL
    public let scope: String
    public let canReturnTokenPrices: Bool
    public let importBehavior: ProviderModelCatalogImportBehavior

    public init(
        exactURL: URL,
        scope: String,
        canReturnTokenPrices: Bool = false,
        importBehavior: ProviderModelCatalogImportBehavior = .directlyCallable
    ) {
        self.exactURL = exactURL
        self.scope = scope
        self.canReturnTokenPrices = canReturnTokenPrices
        self.importBehavior = importBehavior
    }
}

public enum ProviderModelCatalogMergePolicy {
    public static func shouldAutomaticallyMerge(
        provider: ProviderConfig,
        endpoint: URL
    ) -> Bool {
        guard let suggestion = ProviderModelCatalogSuggestions.suggestion(for: provider),
              suggestion.exactURL == endpoint
        else { return false }
        return suggestion.importBehavior == .directlyCallable
    }

    /// Existing providers may hot-update from an explicitly saved catalog or
    /// an exact provider-owned catalog in the verified suggestion registry.
    /// Verified provider-owned reference catalogs are also safe here because
    /// hot updates quarantine every newly discovered model until a real probe
    /// succeeds. This is intentionally less permissive than automatic test
    /// preparation, which must never probe deployment references as chat IDs.
    public static func shouldHotUpdate(
        provider: ProviderConfig,
        endpoint: URL
    ) -> Bool {
        if let suggestion = ProviderModelCatalogSuggestions.suggestion(for: provider),
           suggestion.exactURL == endpoint
        {
            return true
        }
        let key = ProviderEndpointRecord.key(for: .modelCatalog)
        guard let configured = provider.endpointURLs[key],
              let configuredURL = URL(string: configured),
              configuredURL == endpoint
        else { return false }
        return true
    }
}

public enum ProviderModelCatalogSuggestions {
    /// Registry of provider-owned exact endpoints verified by official material
    /// and/or a successful account-authenticated live request. Nothing is
    /// appended to or persisted into the inference Base URL.
    public static func suggestion(for provider: ProviderConfig) -> ProviderModelCatalogSuggestion? {
        guard let components = URLComponents(string: provider.baseURL),
              let host = components.host?.lowercased()
        else { return nil }

        func fixed(
            _ expectedHost: String,
            _ url: String,
            _ scope: String,
            prices: Bool = false,
            importBehavior: ProviderModelCatalogImportBehavior = .directlyCallable
        ) -> ProviderModelCatalogSuggestion? {
            guard host == expectedHost, let exactURL = URL(string: url) else { return nil }
            return .init(
                exactURL: exactURL,
                scope: scope,
                canReturnTokenPrices: prices,
                importBehavior: importBehavior
            )
        }

        // Legacy configurations may have been saved as the generic compatible
        // kind before these provider-specific kinds were introduced. Match only
        // exact provider-owned hosts; never derive a path from Base URL.
        switch host {
        case "api.apimart.ai":
            return fixed(
                "api.apimart.ai",
                "https://api.apimart.ai/v1/models",
                "APIMart 账户可用模型"
            )
        case "dashscope.aliyuncs.com":
            return fixed(
                "dashscope.aliyuncs.com",
                "https://dashscope.aliyuncs.com/api/v1/models",
                "阿里云百炼账户可用模型"
            )
        case "apihub.agnes-ai.com":
            return fixed(
                "apihub.agnes-ai.com",
                "https://apihub.agnes-ai.com/v1/models",
                "Agnes AI 账户可用模型"
            )
        case "apihub.agnes-ai.cn":
            return fixed(
                "apihub.agnes-ai.cn",
                "https://apihub.agnes-ai.cn/v1/models",
                "Agnes AI 中国站账户可用模型"
            )
        case "yunwu.ai":
            return fixed(
                "yunwu.ai",
                "https://yunwu.ai/v1/models",
                "云雾 API 账户可用模型"
            )
        case "api.euno-ai.com":
            return fixed(
                "api.euno-ai.com",
                "https://api.euno-ai.com/v1/models",
                "Euno AI 账户可用模型"
            )
        case "godai.cloud":
            return fixed(
                "godai.cloud",
                "https://godai.cloud/v1/models",
                "GodAI 账户可用模型"
            )
        default:
            break
        }

        switch provider.kind {
        case .anthropic:
            return fixed("api.anthropic.com", "https://api.anthropic.com/v1/models?limit=1000", "Anthropic 账户可用模型")
        case .gemini:
            return fixed("generativelanguage.googleapis.com", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", "Gemini API 可用模型")
        case .deepSeek:
            return fixed("api.deepseek.com", "https://api.deepseek.com/models", "DeepSeek API 可用模型")
        case .qwen:
            return fixed(
                "dashscope.aliyuncs.com",
                "https://dashscope.aliyuncs.com/api/v1/deployments/models?page_no=1&page_size=100&version=v1.0&model_source=base",
                "百炼北京地域可部署的基础模型；不代表全部按量付费或语音模型",
                importBehavior: .deploymentReferenceOnly
            )
        case .xAI:
            return fixed("api.x.ai", "https://api.x.ai/v1/models", "xAI 可用模型及其公开 Token 价格", prices: true)
        case .groq:
            return fixed("api.groq.com", "https://api.groq.com/openai/v1/models", "Groq 账户可用模型")
        case .mistral:
            return fixed("api.mistral.ai", "https://api.mistral.ai/v1/models", "Mistral 账户可用模型")
        case .ollama:
            guard ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
            var local = URLComponents()
            local.scheme = components.scheme
            local.host = components.host
            local.port = components.port
            local.path = "/api/tags"
            guard let exactURL = local.url else { return nil }
            return .init(exactURL: exactURL, scope: "本机 Ollama 已安装模型")
        case .openRouter:
            return fixed("openrouter.ai", "https://openrouter.ai/api/v1/models", "OpenRouter 模型及公开 Token 价格", prices: true)
        case .togetherAI:
            return fixed("api.together.xyz", "https://api.together.xyz/v1/models", "Together AI 模型及公开 Token 价格", prices: true)
        case .fireworksAI:
            return fixed("api.fireworks.ai", "https://api.fireworks.ai/inference/v1/models", "Fireworks 账户可用模型")
        case .perplexity:
            return fixed("api.perplexity.ai", "https://api.perplexity.ai/v1/models", "Perplexity 账户可用模型")
        case .cohere:
            return fixed("api.cohere.ai", "https://api.cohere.ai/v1/models", "Cohere 账户可用模型")
        case .siliconFlow:
            return fixed("api.siliconflow.cn", "https://api.siliconflow.cn/v1/models", "SiliconFlow 账户可用模型")
        case .baiduQianfan:
            return fixed("qianfan.baidubce.com", "https://qianfan.baidubce.com/v2/models", "百度千帆账户可用模型")
        case .moonshot, .zhipu, .volcengine, .minimax, .apimart, .agnes, .yunwu,
             .unifiedCompatible:
            return nil
        }
    }

    public static func exactURL(for provider: ProviderConfig) -> URL? {
        suggestion(for: provider)?.exactURL
    }
}

public enum ProviderModelCatalogMigration {
    /// Persists only exact endpoints from the verified host registry. This does
    /// not modify Base URL and deliberately leaves arbitrary compatible hosts
    /// untouched.
    public static func migratedProvider(_ provider: ProviderConfig) -> ProviderConfig? {
        let key = ProviderEndpointRecord.key(for: .modelCatalog)
        guard provider.endpointURLs[key]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty != false,
              let suggestion = ProviderModelCatalogSuggestions.suggestion(for: provider)
        else { return nil }
        var migrated = provider
        migrated.endpointURLs[key] = suggestion.exactURL.absoluteString
        return migrated
    }
}

extension ProviderClient {
    public func modelCatalogRequest(
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 20
    ) throws -> URLRequest {
        if provider.kind.needsAPIKey && apiKey?.isEmpty != false {
            throw ProviderModelCatalogError.missingAPIKey
        }
        let configured = provider.endpointURLs[
            ProviderEndpointRecord.key(for: .modelCatalog)
        ]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty else { throw ProviderModelCatalogError.missingEndpoint }
        guard let components = URLComponents(string: configured),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { throw ProviderModelCatalogError.invalidEndpoint }

        if scheme == "http" {
            let host = components.host?.lowercased() ?? ""
            guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
                throw ProviderModelCatalogError.insecureEndpoint
            }
        }

        let sensitiveQueryNames = Set(["key", "api_key", "apikey", "token", "access_token"])
        if components.queryItems?.contains(where: {
            sensitiveQueryNames.contains($0.name.lowercased())
        }) == true {
            throw ProviderModelCatalogError.credentialInURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(max(timeoutInterval, 5), 60)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            switch provider.kind {
            case .anthropic:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(
                    provider.apiVersion.isEmpty ? "2023-06-01" : provider.apiVersion,
                    forHTTPHeaderField: "anthropic-version"
                )
            case .gemini:
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            default:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    public func fetchModelCatalog(
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 20
    ) async throws -> ProviderModelCatalogResult {
        let request = try modelCatalogRequest(
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let startedAt = ContinuousClock.now
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: RejectModelCatalogRedirects()
        )
        guard let http = response as? HTTPURLResponse else {
            throw ProviderModelCatalogError.nonHTTPResponse
        }
        guard sameOrigin(request.url, http.url) else {
            throw ProviderModelCatalogError.redirectedToDifferentOrigin
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderModelCatalogError.rejected(statusCode: http.statusCode)
        }

        var body = Data()
        body.reserveCapacity(min(http.expectedContentLength > 0
            ? Int(http.expectedContentLength)
            : 64 * 1024, ProviderModelCatalogParser.maximumResponseBytes))
        for try await byte in bytes {
            guard body.count < ProviderModelCatalogParser.maximumResponseBytes else {
                throw ProviderModelCatalogError.responseTooLarge(
                    maximumBytes: ProviderModelCatalogParser.maximumResponseBytes
                )
            }
            body.append(byte)
        }
        let parsed = try ProviderModelCatalogParser.parseDetailed(
            body,
            providerKind: provider.kind,
            source: request.url!.absoluteString
        )
        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return ProviderModelCatalogResult(
            models: parsed.models,
            prices: parsed.prices,
            endpoint: request.url!,
            durationMilliseconds: milliseconds,
            responseBytes: body.count
        )
    }

    private func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}

private final class RejectModelCatalogRedirects: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
