import Foundation

public struct ProviderModelCatalogResult: Sendable, Equatable {
    public let models: [String]
    public let prices: [String: ProviderModelPrice]
    public let capabilityDetails: [String: ModelCapabilityDetails]
    public let endpoint: URL
    public let durationMilliseconds: Int
    public let responseBytes: Int
    public let pageCount: Int

    public init(
        models: [String],
        prices: [String: ProviderModelPrice] = [:],
        capabilityDetails: [String: ModelCapabilityDetails] = [:],
        endpoint: URL,
        durationMilliseconds: Int,
        responseBytes: Int,
        pageCount: Int = 1
    ) {
        self.models = models
        self.prices = prices
        self.capabilityDetails = capabilityDetails
        self.endpoint = endpoint
        self.durationMilliseconds = durationMilliseconds
        self.responseBytes = responseBytes
        self.pageCount = pageCount
    }
}

public struct ProviderModelCatalogParseResult: Sendable, Equatable {
    public let models: [String]
    public let prices: [String: ProviderModelPrice]
    public let capabilityDetails: [String: ModelCapabilityDetails]

    public init(
        models: [String],
        prices: [String: ProviderModelPrice],
        capabilityDetails: [String: ModelCapabilityDetails]
    ) {
        self.models = models
        self.prices = prices
        self.capabilityDetails = capabilityDetails
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
    case credentialMismatch(String)
    case redirectedToDifferentOrigin
    case nonHTTPResponse
    case secureConnectionFailed
    case networkUnavailable
    case timedOut
    case responseTooLarge(maximumBytes: Int)
    case tooManyPages(maximum: Int)
    case tooManyModels(maximum: Int)
    case rejected(statusCode: Int, providerKind: ProviderKind)
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
        case .credentialMismatch(let message):
            message
        case .redirectedToDifferentOrigin:
            "模型名录请求被重定向到其他来源，为防止凭证泄露已拒绝响应"
        case .nonHTTPResponse:
            "供应商返回了非 HTTP 响应"
        case .secureConnectionFailed:
            "TLS 安全连接失败；ModelHub 未绕过证书校验。请检查 VPN/TUN、代理或系统时间后重试"
        case .networkUnavailable:
            "无法连接模型供应商；请检查网络、DNS、VPN/TUN 或代理状态后重试"
        case .timedOut:
            "模型名录请求超时；已停止重试，请稍后再试"
        case .responseTooLarge(let maximumBytes):
            "模型名录响应超过安全上限（\(maximumBytes / 1_048_576) MiB）"
        case .tooManyPages(let maximum):
            "模型名录分页超过安全上限（\(maximum) 页），为避免返回不完整目录已停止导入"
        case .tooManyModels(let maximum):
            "模型名录超过安全上限（\(maximum) 个模型），为避免内存占用异常已停止导入"
        case .rejected(let statusCode, let providerKind):
            rejectionDescription(statusCode: statusCode, providerKind: providerKind)
        case .invalidResponse:
            "模型名录不是可识别的 JSON 格式"
        case .noModels:
            "响应成功，但没有解析到模型名称"
        }
    }

    private func rejectionDescription(
        statusCode: Int,
        providerKind: ProviderKind
    ) -> String {
        guard statusCode == 401 || statusCode == 403 else {
            return "供应商拒绝模型名录请求（HTTP \(statusCode)）"
        }
        switch providerKind {
        case .qwenPersonal:
            return "千问AI平台个人版鉴权失败（HTTP \(statusCode)）：请使用与 Token Plan Base URL 配套、以 sk-sp- 开头的个人版专属 API Key，并确认订阅仍有效。"
        case .qwenEnterprise:
            return "千问AI平台 Token Plan 团队版鉴权失败（HTTP \(statusCode)）：请先分配成员席位，再使用与 Token Plan Base URL 配套、以 sk-sp- 开头的团队版专属 API Key。"
        case .qwen:
            return "千问AI平台按量付费版鉴权失败（HTTP \(statusCode)）：请使用当前地域/默认业务空间对应的按量付费 API Key 与 Base URL，不能混用 sk-sp- 套餐密钥。"
        case .qwenBusiness:
            return "千问AI平台业务空间鉴权失败（HTTP \(statusCode)）：请使用 API Keys 页面生成的按量付费 API Key，并核对页面展示的地域、业务空间和 Base URL；不能混用 sk-sp- 套餐密钥。"
        case .minimax:
            return "MiniMax 国际站鉴权失败（HTTP \(statusCode)）：当前 API Key 不被 api.minimax.io 接受；如果使用中国站账号，请将供应商类型切换为“MiniMax 中国站”。"
        case .minimaxChina:
            return "MiniMax 中国站鉴权失败（HTTP \(statusCode)）：当前 API Key 不被 api.minimaxi.com 接受；请确认密钥来自中国站开放平台，或切换为“MiniMax 国际站”。"
        default:
            return "供应商拒绝模型名录请求（HTTP \(statusCode)）；请检查 API Key、账号权限、区域和订阅状态。"
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
    ) throws -> ProviderModelCatalogParseResult {
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
        var rawDetails: [String: ModelCapabilityDetails] = [:]
        collect(
            from: root,
            depth: 0,
            providerKind: providerKind,
            source: source,
            candidates: &candidates,
            prices: &rawPrices,
            capabilityDetails: &rawDetails
        )

        var seen = Set<String>()
        var result: [String] = []
        var prices: [String: ProviderModelPrice] = [:]
        var capabilityDetails: [String: ModelCapabilityDetails] = [:]
        result.reserveCapacity(min(candidates.count, maximumModelCount))
        for rawName in candidates {
            guard let name = normalized(rawName) else { continue }
            let identity = name.lowercased()
            guard seen.insert(identity).inserted else { continue }
            result.append(name)
            if let price = rawPrices[identity], price.hasKnownPrice {
                prices[name] = price
            }
            let catalog = rawDetails[identity]
            let inferred = providerKind.isBailian
                ? QianwenModelCapabilityRegistry.details(for: name)
                : nil
            if let details = catalog?.mergingFallback(inferred) ?? inferred,
               !details.isEmpty {
                capabilityDetails[name] = details
            }
            if result.count == maximumModelCount { break }
        }
        guard !result.isEmpty else { throw ProviderModelCatalogError.noModels }
        return .init(
            models: result,
            prices: prices,
            capabilityDetails: capabilityDetails
        )
    }

    private static func collect(
        from value: Any,
        depth: Int,
        providerKind: ProviderKind,
        source: String,
        candidates: inout [String],
        prices: inout [String: ProviderModelPrice],
        capabilityDetails: inout [String: ModelCapabilityDetails]
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
                    if let object = item as? [String: Any],
                       let details = parsedCapabilityDetails(
                           from: object,
                           modelName: name,
                           providerKind: providerKind,
                           source: source
                       )
                    {
                        capabilityDetails[
                            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        ] = details
                    }
                } else if item is [Any] || item is [String: Any] {
                    collect(
                        from: item,
                        depth: depth + 1,
                        providerKind: providerKind,
                        source: source,
                        candidates: &candidates,
                        prices: &prices,
                        capabilityDetails: &capabilityDetails
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
                    prices: &prices,
                    capabilityDetails: &capabilityDetails
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
        for key in ["id", "model_id", "modelId", "model", "model_name", "name"] {
            if let string = object[key] as? String { return string }
        }
        return nil
    }

    private static func parsedCapabilityDetails(
        from object: [String: Any],
        modelName: String,
        providerKind: ProviderKind,
        source: String
    ) -> ModelCapabilityDetails? {
        let modality = object["modality"] as? [String: Any]
        let input = modalities(
            modality?["input"] ?? object["input_modalities"] ?? object["inputModalities"]
        )
        let output = modalities(
            modality?["output"] ?? object["output_modalities"] ?? object["outputModalities"]
        )
        let rawParameters = object["supported_parameters"]
            ?? object["supportedParameters"]
            ?? object["parameters"]
        let parameters = parameterConstraints(rawParameters)
        let sizeValues = parameters.first { ["size", "image_size"].contains($0.name) }?
            .allowedValues ?? stringValues(object["supported_sizes"] ?? object["sizes"])
        let ratioValues = parameters.first { ["aspect_ratio", "ratio"].contains($0.name) }?
            .allowedValues ?? stringValues(object["aspect_ratios"])
        let resolutionValues = parameters.first { $0.name == "resolution" }?.allowedValues
            ?? stringValues(object["resolutions"])
        let duration = durationConstraint(
            parameter: parameters.first { ["duration", "duration_seconds"].contains($0.name) },
            raw: object["durations"] ?? object["duration_seconds"]
        )
        let maximumOutputs = parameters.first { ["n", "count"].contains($0.name) }?
            .maximum.map(Int.init)
        let widthPixels = numericConstraint(
            parameter: parameters.first { ["width", "width_pixels"].contains($0.name) },
            minimum: object["minimum_width"] ?? object["min_width"],
            maximum: object["maximum_width"] ?? object["max_width"]
        )
        let heightPixels = numericConstraint(
            parameter: parameters.first { ["height", "height_pixels"].contains($0.name) },
            minimum: object["minimum_height"] ?? object["min_height"],
            maximum: object["maximum_height"] ?? object["max_height"]
        )

        let hasImage = output.contains(.image) || !sizeValues.isEmpty
        let hasVideo = output.contains(.video) || !resolutionValues.isEmpty || duration != nil
        let hasAudio = output.contains(.audio)
        let details = ModelCapabilityDetails(
            inputModalities: input,
            outputModalities: output,
            image: hasImage ? .init(
                sizes: sizeValues,
                aspectRatios: ratioValues,
                widthPixels: widthPixels,
                heightPixels: heightPixels,
                maximumOutputs: maximumOutputs
            ) : nil,
            video: hasVideo ? .init(
                resolutions: resolutionValues,
                aspectRatios: ratioValues,
                durationsSeconds: duration
            ) : nil,
            audio: hasAudio ? .init(
                formats: stringValues(object["audio_formats"] ?? object["formats"]),
                sampleRatesHz: integerValues(object["sample_rates"] ?? object["sample_rates_hz"])
            ) : nil,
            parameters: parameters,
            source: source
        ).mergingFallback(
            providerKind.isBailian
                ? QianwenModelCapabilityRegistry.details(for: modelName)
                : nil
        )
        return details.isEmpty ? nil : details
    }

    private static func modalities(_ value: Any?) -> [ModelModality] {
        stringValues(value).compactMap { raw in
            switch raw.lowercased() {
            case "text", "language": .text
            case "image", "vision": .image
            case "video": .video
            case "audio", "speech", "music": .audio
            case "vector", "embedding", "embeddings": .vector
            default: nil
            }
        }
    }

    private static func parameterConstraints(_ value: Any?) -> [ModelParameterConstraint] {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().compactMap { name in
                guard let definition = dictionary[name] as? [String: Any] else {
                    return ModelParameterConstraint(name: name)
                }
                return parameterConstraint(name: name, definition: definition)
            }
        }
        if let array = value as? [[String: Any]] {
            return array.compactMap { definition in
                guard let name = definition["name"] as? String else { return nil }
                return parameterConstraint(name: name, definition: definition)
            }
        }
        return []
    }

    private static func parameterConstraint(
        name: String,
        definition: [String: Any]
    ) -> ModelParameterConstraint {
        .init(
            name: name,
            valueType: definition["type"] as? String,
            required: (definition["required"] as? Bool) ?? false,
            allowedValues: stringValues(
                definition["enum"] ?? definition["allowed_values"] ?? definition["values"]
            ),
            minimum: number(definition["minimum"] ?? definition["min"]),
            maximum: number(definition["maximum"] ?? definition["max"]),
            step: number(definition["step"]),
            unit: definition["unit"] as? String,
            description: definition["description"] as? String
        )
    }

    private static func durationConstraint(
        parameter: ModelParameterConstraint?,
        raw: Any?
    ) -> ModelNumericConstraint? {
        if let parameter {
            let values = parameter.allowedValues.compactMap(Double.init)
            if !values.isEmpty { return .values(values) }
            if let minimum = parameter.minimum, let maximum = parameter.maximum {
                return .range(minimum: minimum, maximum: maximum, step: parameter.step)
            }
        }
        let values = numericValues(raw)
        return values.isEmpty ? nil : .values(values)
    }

    private static func numericConstraint(
        parameter: ModelParameterConstraint?,
        minimum: Any?,
        maximum: Any?
    ) -> ModelNumericConstraint? {
        if let parameter {
            let values = parameter.allowedValues.compactMap(Double.init)
            if !values.isEmpty { return .values(values) }
            if let minimum = parameter.minimum, let maximum = parameter.maximum {
                return .range(
                    minimum: minimum,
                    maximum: maximum,
                    step: parameter.step
                )
            }
        }
        guard let minimum = number(minimum), let maximum = number(maximum) else {
            return nil
        }
        return .range(minimum: minimum, maximum: maximum, step: nil)
    }

    private static func stringValues(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap {
                if let string = $0 as? String { return string }
                if let number = $0 as? NSNumber { return number.stringValue }
                return nil
            }
        }
        return []
    }

    private static func numericValues(_ value: Any?) -> [Double] {
        if let values = value as? [Any] { return values.compactMap(number) }
        return number(value).map { [$0] } ?? []
    }

    private static func integerValues(_ value: Any?) -> [Int] {
        numericValues(value).map(Int.init)
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
        let importedExactNames = Dictionary(
            imported.compactMap { raw -> (String, String)? in
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return (name.lowercased(), name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        return (existing + imported).compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = name.lowercased()
            guard !name.isEmpty, seen.insert(identity).inserted else { return nil }
            // Catalog IDs are authoritative. This also repairs old entries that
            // accidentally persisted a display name or different ID casing.
            return importedExactNames[identity] ?? name
        }
    }
}

public enum ProviderModelCatalogPagination {
    public static func nextURL(responseBody: Data, currentURL: URL) throws -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: responseBody),
              let rootObject = root as? [String: Any]
        else { return nil }
        let object = paginationObject(in: rootObject)

        if let rawNext = string(
            object["next"] ?? object["next_url"] ?? object["nextUrl"]
        ), !rawNext.isEmpty {
            guard let resolved = URL(string: rawNext, relativeTo: currentURL)?.absoluteURL,
                  sameOrigin(currentURL, resolved)
            else { throw ProviderModelCatalogError.redirectedToDifferentOrigin }
            return resolved
        }

        if let token = string(
            object["next_page_token"] ?? object["nextPageToken"]
        ), !token.isEmpty {
            var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            let existingName = items.first {
                ["page_token", "pageToken", "cursor"].contains($0.name)
            }?.name ?? "page_token"
            items.removeAll { $0.name == existingName }
            items.append(.init(name: existingName, value: token))
            components?.queryItems = items
            return components?.url
        }

        let currentPage = integer(
            object["page_no"] ?? object["pageNo"] ?? object["page"]
        )
        let totalPages = integer(
            object["total_pages"] ?? object["totalPages"] ?? object["pages"]
        )
        guard let currentPage, let totalPages, currentPage < totalPages else { return nil }
        var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        let candidates = ["page_no", "pageNo", "page"]
        let name = items.first { candidates.contains($0.name) }?.name
            ?? (object["page_no"] != nil ? "page_no" : "page")
        items.removeAll { $0.name == name }
        let insertion = items.firstIndex { ["page_size", "pageSize", "limit"].contains($0.name) }
            ?? items.endIndex
        items.insert(.init(name: name, value: String(currentPage + 1)), at: insertion)
        components?.queryItems = items
        return components?.url
    }

    private static func paginationObject(in root: [String: Any]) -> [String: Any] {
        for key in ["pagination", "page_info", "pageInfo", "meta", "response", "result", "output"] {
            if let nested = root[key] as? [String: Any],
               nested.keys.contains(where: {
                   ["next", "next_url", "next_page_token", "page_no", "page", "total_pages"]
                       .contains($0)
               }) {
                return nested.merging(root) { nested, _ in nested }
            }
        }
        return root
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
            && rhs.user == nil && rhs.password == nil
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
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
                "千问AI平台账户可用模型"
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
        case .qwen, .qwenBusiness:
            return fixed(
                "dashscope.aliyuncs.com",
                "https://dashscope.aliyuncs.com/api/v1/models",
                "千问AI平台北京地域账户可用模型"
            )
        case .qwenPersonal, .qwenEnterprise:
            return fixed(
                "token-plan.cn-beijing.maas.aliyuncs.com",
                "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/models",
                "千问AI平台 Token Plan 当前版本可用模型"
            )
        case .moonshot:
            return fixed("api.moonshot.cn", "https://api.moonshot.cn/v1/models", "Moonshot 账户可用模型")
        case .zhipu:
            return fixed("open.bigmodel.cn", "https://open.bigmodel.cn/api/paas/v4/models", "智谱开放平台账户可用模型")
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
        case .volcengine:
            return fixed("ark.cn-beijing.volces.com", "https://ark.cn-beijing.volces.com/api/v3/models", "火山方舟账户可用模型")
        case .baiduQianfan:
            return fixed("qianfan.baidubce.com", "https://qianfan.baidubce.com/v2/models", "百度千帆账户可用模型")
        case .minimax:
            return fixed("api.minimax.io", "https://api.minimax.io/v1/models", "MiniMax 账户可用模型")
        case .minimaxChina:
            return fixed("api.minimaxi.com", "https://api.minimaxi.com/v1/models", "MiniMax 中国站账户可用模型")
        case .apimart, .agnes, .yunwu,
             .unifiedCompatible:
            return nil
        }
    }

    public static func exactURL(for provider: ProviderConfig) -> URL? {
        suggestion(for: provider)?.exactURL
    }
}

public enum ProviderModelPricingAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public struct ProviderModelPriceRefreshSummary: Sendable, Equatable {
    public let totalProviders: Int
    public let catalogsChecked: Int
    public let catalogsFetched: Int
    public let catalogsWithoutPrices: Int
    public let modelsUpdated: Int
    public let unavailablePriceSources: Int
    public let missingCredentials: Int
    public let failures: Int
    public let referenceModelsApplied: Int
    public let referenceModelsAvailable: Int
    public let modelsStillUnpriced: Int

    public init(
        totalProviders: Int,
        catalogsChecked: Int,
        catalogsFetched: Int,
        catalogsWithoutPrices: Int,
        modelsUpdated: Int,
        unavailablePriceSources: Int,
        missingCredentials: Int,
        failures: Int,
        referenceModelsApplied: Int = 0,
        referenceModelsAvailable: Int = 0,
        modelsStillUnpriced: Int = 0
    ) {
        self.totalProviders = max(0, totalProviders)
        self.catalogsChecked = max(0, catalogsChecked)
        self.catalogsFetched = max(0, catalogsFetched)
        self.catalogsWithoutPrices = max(0, catalogsWithoutPrices)
        self.modelsUpdated = max(0, modelsUpdated)
        self.unavailablePriceSources = max(0, unavailablePriceSources)
        self.missingCredentials = max(0, missingCredentials)
        self.failures = max(0, failures)
        self.referenceModelsApplied = max(0, referenceModelsApplied)
        self.referenceModelsAvailable = max(0, referenceModelsAvailable)
        self.modelsStillUnpriced = max(0, modelsStillUnpriced)
    }

    public var didUpdatePrices: Bool { modelsUpdated > 0 || referenceModelsApplied > 0 }

    public func message(trigger: String) -> String {
        if referenceModelsApplied > 0 {
            return "\(trigger)：从供应商机器目录更新 \(modelsUpdated) 个模型，并为 \(referenceModelsApplied) 个缺价模型填入 ModelHub 内置上游公开参考价；仍有 \(modelsStillUnpriced) 个模型无可靠参考价。参考价不代表当前渠道结算价，供应商目录、CSV 和手动价始终优先。目录情况：检查 \(catalogsChecked) 个，成功读取 \(catalogsFetched) 个，\(catalogsWithoutPrices) 个无明确价格，\(unavailablePriceSources) 个无机器价格源，\(missingCredentials) 个缺少凭证，\(failures) 个失败。"
        }
        if modelsUpdated == 0 && referenceModelsAvailable > 0 {
            return "\(trigger)：未发现需要改写的价格。当前 \(referenceModelsAvailable) 个模型已有 ModelHub 内置上游公开参考价，仍有 \(modelsStillUnpriced) 个模型无可靠参考价。参考价不代表当前渠道结算价，供应商目录、CSV 和手动价始终优先。目录情况：检查 \(catalogsChecked) 个，成功读取 \(catalogsFetched) 个，\(catalogsWithoutPrices) 个无明确价格，\(unavailablePriceSources) 个无机器价格源，\(missingCredentials) 个缺少凭证，\(failures) 个失败。"
        }
        if !didUpdatePrices {
            return "\(trigger)：未写入任何价格。\(totalProviders) 个已启用供应商中：\(unavailablePriceSources) 个模型目录不提供带明确币种和单位的机器可读价格，\(missingCredentials) 个缺少可用凭证，\(catalogsWithoutPrices) 个目录已响应但没有明确价格，\(failures) 个请求失败。未修改现有费用；可在供应商编辑页导入其官方价格 CSV。"
        }
        return "\(trigger)：检查 \(catalogsChecked) 个价格目录，成功读取 \(catalogsFetched) 个，更新 \(modelsUpdated) 个模型价格；\(catalogsWithoutPrices) 个目录未返回明确价格，\(unavailablePriceSources) 个供应商无机器可读价格源，\(missingCredentials) 个缺少凭证，\(failures) 个失败。"
    }
}

public enum ProviderModelCatalogPricingPolicy {
    private static let builtInMachinePriceKinds: Set<ProviderKind> = [
        .xAI, .openRouter, .togetherAI,
    ]

    /// Avoids scheduled requests to built-in model catalogs that are known not
    /// to publish machine-readable prices. A user-supplied custom catalog stays
    /// eligible because its response contract is controlled by that provider.
    public static func shouldFetch(provider: ProviderConfig, endpoint: URL) -> Bool {
        availability(provider: provider, endpoint: endpoint) == .available
    }

    public static func availability(
        provider: ProviderConfig,
        endpoint: URL
    ) -> ProviderModelPricingAvailability {
        if let suggestion = ProviderModelCatalogSuggestions.suggestion(for: provider),
           suggestion.exactURL == endpoint
        {
            guard suggestion.canReturnTokenPrices else {
                return .unavailable(reason: unavailableReason(for: provider.kind))
            }
            return .available
        }

        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        if let presetCatalog = ProviderConnectionPresets.preset(for: provider.kind)?
            .endpointURLs[catalogKey],
           URL(string: presetCatalog) == endpoint
        {
            guard builtInMachinePriceKinds.contains(provider.kind) else {
                return .unavailable(reason: unavailableReason(for: provider.kind))
            }
            return .available
        }
        return .available
    }

    private static func unavailableReason(for kind: ProviderKind) -> String {
        switch kind {
        case .qwenPersonal, .qwenEnterprise:
            return "千问AI平台 Token Plan 的模型目录不提供美元单价；套餐按 Credits 与动态抵扣系数计量，请以平台控制台为准。现有费用不会被覆盖。"
        case .qwen, .qwenBusiness:
            return "千问AI平台按量付费模型目录不提供带明确币种与单位的机器可读价格；请以平台控制台价格页为准，现有费用不会被覆盖。"
        case .minimax, .minimaxChina:
            return "MiniMax 模型目录只返回模型信息，不提供机器可读价格；当前不能从该目录自动同步金额，现有费用不会被覆盖。"
        case .apimart, .yunwu:
            return "该供应商的模型目录没有返回带明确币种和单位的机器可读价格；为避免猜价，现有费用不会被覆盖。"
        default:
            return "该供应商的官方模型目录没有机器可读价格字段；为避免猜价，现有费用不会被覆盖。"
        }
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
    private static var maximumCatalogPageCount: Int { 100 }
    private static var maximumCatalogTotalBytes: Int { 16 * 1_048_576 }

    public func modelCatalogRequest(
        provider: ProviderConfig,
        apiKey: String?,
        timeoutInterval: TimeInterval = 20
    ) throws -> URLRequest {
        if provider.kind.needsAPIKey && apiKey?.isEmpty != false {
            throw ProviderModelCatalogError.missingAPIKey
        }
        if let apiKey,
           let message = ProviderCredentialPolicy.validationMessage(
               for: provider.kind,
               apiKey: apiKey
           )
        {
            throw ProviderModelCatalogError.credentialMismatch(message)
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
        timeoutInterval: TimeInterval = 20,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) async throws -> ProviderModelCatalogResult {
        var request = try modelCatalogRequest(
            provider: provider,
            apiKey: apiKey,
            timeoutInterval: timeoutInterval
        )
        let firstEndpoint = request.url!
        var models: [String] = []
        var prices: [String: ProviderModelPrice] = [:]
        var capabilities: [String: ModelCapabilityDetails] = [:]
        var totalDuration = 0
        var totalBytes = 0
        var pageCount = 0

        var nextURL: URL?
        while pageCount < Self.maximumCatalogPageCount {
            let page = try await fetchModelCatalogPage(
                request,
                providerKind: provider.kind,
                retryDelayNanoseconds: retryDelayNanoseconds
            )
            pageCount += 1
            totalDuration += page.result.durationMilliseconds
            totalBytes += page.result.responseBytes
            guard totalBytes <= Self.maximumCatalogTotalBytes else {
                throw ProviderModelCatalogError.responseTooLarge(
                    maximumBytes: Self.maximumCatalogTotalBytes
                )
            }
            let mergedModels = ProviderModelCatalogImporter.merging(
                existing: models,
                imported: page.result.models
            )
            guard mergedModels.count <= ProviderModelCatalogParser.maximumModelCount else {
                throw ProviderModelCatalogError.tooManyModels(
                    maximum: ProviderModelCatalogParser.maximumModelCount
                )
            }
            models = mergedModels
            for (model, price) in page.result.prices { prices[model] = price }
            for (model, details) in page.result.capabilityDetails {
                capabilities[model] = details
            }
            nextURL = page.nextURL
            guard let nextURL else { break }
            request.url = nextURL
        }
        if pageCount == Self.maximumCatalogPageCount, nextURL != nil {
            throw ProviderModelCatalogError.tooManyPages(
                maximum: Self.maximumCatalogPageCount
            )
        }
        return .init(
            models: models,
            prices: prices,
            capabilityDetails: capabilities,
            endpoint: firstEndpoint,
            durationMilliseconds: totalDuration,
            responseBytes: totalBytes,
            pageCount: pageCount
        )
    }

    private struct ProviderModelCatalogPage {
        let result: ProviderModelCatalogResult
        let nextURL: URL?
    }

    private func fetchModelCatalogPage(
        _ request: URLRequest,
        providerKind: ProviderKind,
        retryDelayNanoseconds: UInt64
    ) async throws -> ProviderModelCatalogPage {
        var requestSession = session
        var recoverySession: URLSession?
        defer { recoverySession?.finishTasksAndInvalidate() }
        var retryCount = 0
        while true {
            do {
                return try await performModelCatalogRequest(
                    request,
                    providerKind: providerKind,
                    session: requestSession
                )
            } catch let error as URLError {
                if retryCount == 0,
                   shouldReestablishCatalogSession(after: error),
                   let factory = catalogRecoverySessionFactory
                {
                    retryCount += 1
                    let freshSession = factory()
                    recoverySession = freshSession
                    requestSession = freshSession
                    if retryDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    }
                    continue
                }
                if retryCount == 0, shouldRetryCatalogRequest(after: error) {
                    retryCount += 1
                    if retryDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    }
                    continue
                }
                throw mappedCatalogNetworkError(error)
            }
        }
    }

    private func performModelCatalogRequest(
        _ request: URLRequest,
        providerKind: ProviderKind,
        session: URLSession
    ) async throws -> ProviderModelCatalogPage {
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
            throw ProviderModelCatalogError.rejected(
                statusCode: http.statusCode,
                providerKind: providerKind
            )
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
        let source = sanitizedCatalogSource(request.url!)
        let parsed = try ProviderModelCatalogParser.parseDetailed(
            body,
            providerKind: providerKind,
            source: source
        )
        let fetchedAt = Date()
        let capabilityDetails = parsed.capabilityDetails.mapValues { details in
            var stamped = details
            stamped.updatedAt = fetchedAt
            return stamped
        }
        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let result = ProviderModelCatalogResult(
            models: parsed.models,
            prices: parsed.prices,
            capabilityDetails: capabilityDetails,
            endpoint: request.url!,
            durationMilliseconds: milliseconds,
            responseBytes: body.count
        )
        return .init(
            result: result,
            nextURL: try ProviderModelCatalogPagination.nextURL(
                responseBody: body,
                currentURL: request.url!
            )
        )
    }

    private func sanitizedCatalogSource(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return "provider-catalog" }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "provider-catalog"
    }

    private func shouldRetryCatalogRequest(after error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private func shouldReestablishCatalogSession(after error: URLError) -> Bool {
        switch error.code {
        case .serverCertificateUntrusted, .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private func mappedCatalogNetworkError(
        _ error: URLError
    ) -> ProviderModelCatalogError {
        switch error.code {
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .secureConnectionFailed:
            .secureConnectionFailed
        case .timedOut:
            .timedOut
        default:
            .networkUnavailable
        }
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
