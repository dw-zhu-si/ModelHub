import Foundation

public enum ModelNativeProtocol: String, Codable, Equatable, Sendable {
    case imageGeneration
    case videoGeneration
    case speech
    case transcription
    case embeddings
    case reranking
    case providerNative

    public var displayName: String {
        switch self {
        case .imageGeneration: "图像生成"
        case .videoGeneration: "视频生成"
        case .speech: "语音合成"
        case .transcription: "语音转录"
        case .embeddings: "向量"
        case .reranking: "重排"
        case .providerNative: "供应商专用"
        }
    }
}

public enum ModelProbeDisposition: Equatable, Sendable {
    case readyForChatProbe
    case configurationRequired
    case readyForNativeProtocol(ModelNativeProtocol)
}

public enum ModelProbePolicy {
    public static func disposition(
        provider: ProviderConfig,
        model: String,
        hasAPIKey: Bool
    ) -> ModelProbeDisposition {
        if provider.kind.needsAPIKey && !hasAPIKey {
            return .configurationRequired
        }
        if let nativeProtocol = nativeProtocol(provider: provider, model: model) {
            return .readyForNativeProtocol(nativeProtocol)
        }
        return .readyForChatProbe
    }

    public static func nativeProtocol(
        provider: ProviderConfig,
        model: String
    ) -> ModelNativeProtocol? {
        let providerName = provider.name.lowercased()
        let name = model.lowercased()

        if isProviderNativeModel(provider: provider, name: name) {
            return .providerNative
        }
        if providerName.contains("tts") {
            return .speech
        }
        if name.contains("rerank") {
            return .reranking
        }
        if name.contains("embedding") {
            return .embeddings
        }
        if name.contains("whisper") || name.contains("transcrib") {
            return .transcription
        }
        if isSpeechModel(name) {
            return .speech
        }
        if isImageModel(name) {
            return .imageGeneration
        }
        if isVideoModel(name) {
            return .videoGeneration
        }
        return nil
    }

    private static func isProviderNativeModel(
        provider: ProviderConfig,
        name: String
    ) -> Bool {
        let providerName = provider.name.lowercased()
        let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        let isYunwu = providerName.contains("云雾") || hostname.contains("yunwu.ai")
        let isBailian = providerName.contains("百炼")
            || hostname.contains("dashscope.aliyuncs.com")

        if isYunwu {
            let exactPrefixes = [
                "mj_", "suno_", "kling-", "pixverse-", "happyhorse-",
                "hailuo-", "vidu", "wan2."
            ]
            let actionMarkers = [
                "-i2v", "-t2v", "-r2v", "lipsync", "sound-effect",
                "voice-design", "music-open"
            ]
            if exactPrefixes.contains(where: { name.hasPrefix($0) })
                || actionMarkers.contains(where: { name.contains($0) })
            {
                return true
            }
        }

        if isBailian {
            return name.contains("voice-design")
                || name.contains("voice-clone")
                || name.contains("realtime")
        }
        return false
    }

    private static func isSpeechModel(_ name: String) -> Bool {
        let markers = [
            "tts", "speech-", "/speech"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func isImageModel(_ name: String) -> Bool {
        let markers = [
            "image", "seedream", "flux", "dall-e", "z-image"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func isVideoModel(_ name: String) -> Bool {
        let markers = [
            "seedance", "video", "sora", "veo"
        ]
        if markers.contains(where: { name.contains($0) }) {
            return true
        }
        return false
    }
}

public enum ModelHealthMigration {
    public static func normalize(
        records: [ModelHealthRecord],
        providers: [ProviderConfig]
    ) -> [ModelHealthRecord] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var normalized = records.map { original in
            guard let provider = providersByID[original.providerID] else {
                guard original.status == .unknown else { return original }
                var record = original
                record.status = .unavailable
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "旧版待验证记录已隔离"
                return record
            }

            var record = original
            if original.detail == "未配置 API Key"
                || original.statusCode == 401
                || original.statusCode == 403
            {
                record.status = .configurationRequired
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "需要配置或更新 API Key（旧结果已纠正）"
                return record
            }

            if let nativeProtocol = ModelProbePolicy.nativeProtocol(
                provider: provider,
                model: original.model
            ) {
                if original.status == .available
                    || original.status == .configurationRequired
                    || original.status == .unsupported
                    || original.detail.hasPrefix("原生")
                {
                    return original
                }
                record.status = .unavailable
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "\(nativeProtocol.displayName)尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
                return record
            }

            if original.status == .unknown {
                record.status = .unavailable
                record.latencyMilliseconds = nil
                record.statusCode = nil
                record.detail = "尚未完成在线验证，已隔离"
            }
            return record
        }

        var recordedKeys = Set(normalized.map {
            healthKey(providerID: $0.providerID, model: $0.model)
        })
        for provider in providers {
            for model in provider.models {
                let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedModel.isEmpty else { continue }
                let key = healthKey(providerID: provider.id, model: trimmedModel)
                guard recordedKeys.insert(key).inserted else { continue }

                let detail: String
                if let nativeProtocol = ModelProbePolicy.nativeProtocol(
                    provider: provider,
                    model: trimmedModel
                ) {
                    detail = "\(nativeProtocol.displayName)尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
                } else {
                    detail = "尚未完成在线验证，已隔离"
                }
                normalized.append(
                    ModelHealthRecord(
                        providerID: provider.id,
                        model: trimmedModel,
                        status: .unavailable,
                        detail: detail
                    )
                )
            }
        }
        return normalized
    }

    private static func healthKey(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString.lowercased())/\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}
