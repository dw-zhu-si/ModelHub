import Foundation

public enum ModelNativeProtocol: String, Codable, Equatable, Sendable {
    case imageGeneration
    case musicGeneration
    case videoGeneration
    case speech
    case transcription
    case embeddings
    case reranking
    case providerNative

    public var displayName: String {
        switch self {
        case .imageGeneration: "图像生成"
        case .musicGeneration: "音乐生成"
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

public struct ModelProbePayload: Equatable, Sendable {
    public let body: Data
    public let contentType: String

    public init(body: Data, contentType: String) {
        self.body = body
        self.contentType = contentType
    }
}

public enum ModelProbeRetryDecision: Equatable, Sendable {
    case stop
    case retry(after: TimeInterval)
}

public enum ModelProbeRetryPolicy {
    public static let maximumAttempts = 2

    public static func decision(
        statusCode: Int,
        headers: [String: String],
        attempt: Int
    ) -> ModelProbeRetryDecision {
        guard attempt < maximumAttempts,
              statusCode == 429 || (500...599).contains(statusCode)
        else { return .stop }
        if statusCode == 429,
           let raw = headers.first(where: {
               $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
           })?.value,
           let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .retry(after: min(max(seconds, 0.25), 30))
        }
        return .retry(after: statusCode == 429 ? 2 : 1)
    }

    public static func shouldRetryNetworkError(_ error: URLError, attempt: Int) -> Bool {
        guard attempt < maximumAttempts else { return false }
        return [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .dnsLookupFailed, .notConnectedToInternet
        ].contains(error.code)
    }
}

public enum ModelTestBatchPolicy {
    public static let maximumSize = 3

    public static func nextSize(current: Int, statusCodes: [Int]) -> Int {
        if statusCodes.contains(429) { return 1 }
        let allSuccessful = statusCodes.count >= 3
            && statusCodes.allSatisfy { (200..<300).contains($0) }
        if allSuccessful { return min(maximumSize, current + 1) }
        return min(max(current, 1), maximumSize)
    }
}

public enum ModelProbePolicy {
    public static func nativeOperation(for nativeProtocol: ModelNativeProtocol) -> NativeAPIOperation? {
        switch nativeProtocol {
        case .imageGeneration: .imageGeneration
        case .musicGeneration: .musicGeneration
        case .videoGeneration: .videoGeneration
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        case .providerNative: nil
        }
    }

    public static func shouldSkipNativeProbe(
        status: ModelAvailability?,
        nativeProtocol: ModelNativeProtocol,
        allowNativeProbe: Bool
    ) -> Bool {
        status?.isQuarantined == true && !allowNativeProbe
    }

    public static func nativeProbeBody(
        for nativeProtocol: ModelNativeProtocol,
        model: String
    ) -> Data? {
        nativeProbePayload(for: nativeProtocol, model: model)?.body
    }

    public static func nativeProbePayload(
        for nativeProtocol: ModelNativeProtocol,
        model: String
    ) -> ModelProbePayload? {
        let object: [String: Any]
        switch nativeProtocol {
        case .imageGeneration:
            object = ["prompt": "ModelHub connection test", "n": 1]
        case .musicGeneration:
            // This minimal body is sent only after explicit confirmation that
            // the provider may bill a real protocol probe.
            object = [
                "prompt": "ModelHub connection test",
                "duration": 5,
                "instrumental": true
            ]
        case .videoGeneration:
            // Use the documented Seedance 2.0 minimum that is accepted across the
            // standard and fast variants. Keep resolution and audio at their
            // lowest-cost settings because this probe can create a billable task.
            object = [
                "prompt": "ModelHub connection test",
                "duration": 5,
                "resolution": "480p",
                "size": "16:9",
                "generate_audio": false
            ]
        case .speech:
            object = ["input": "ModelHub connection test", "voice": "alloy"]
        case .embeddings:
            object = ["input": "ModelHub connection test"]
        case .reranking:
            object = [
                "query": "ModelHub connection test",
                "documents": ["ModelHub connection test"]
            ]
        case .transcription:
            return transcriptionProbePayload(model: model)
        case .providerNative:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return ModelProbePayload(body: data, contentType: "application/json")
    }

    public static func nativeProbeUnavailableReason(
        provider: ProviderConfig,
        model _: String,
        nativeProtocol: ModelNativeProtocol
    ) -> String {
        if nativeProtocol == .providerNative {
            let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
            let isBailian = provider.kind.isBailian
                && (hostname == BailianEndpointPolicy.payAsYouGoHost
                    || hostname == BailianEndpointPolicy.tokenPlanHost
                    || provider.name.contains("百炼"))
            if isBailian {
                return "百炼部署/工作流模型需要部署代码、素材或专用参数；不会作为聊天模型请求，请在 API 调试中按供应商文档验证。"
            }
            return "供应商专用模型需要素材或专用参数；不会作为聊天模型请求，请在 API 调试中按供应商文档验证。"
        }
        return "\(nativeProtocol.displayName)尚未通过真实协议验证，已隔离（未自动发起可能计费的请求）"
    }

    public static func videoTaskID(in response: ProviderResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: response.body)
        else { return nil }

        let candidates: [Any?]
        if let object = root as? [String: Any] {
            if let businessCode = object["code"] as? NSNumber,
               !(200..<300).contains(businessCode.intValue) {
                return nil
            }
            let dataObject = object["data"] as? [String: Any]
            let firstDataObject = (object["data"] as? [[String: Any]])?.first
            candidates = [
                object["task_id"], object["taskId"], object["id"],
                dataObject?["task_id"], dataObject?["taskId"], dataObject?["id"],
                firstDataObject?["task_id"], firstDataObject?["taskId"], firstDataObject?["id"]
            ]
        } else {
            return nil
        }

        return candidates.compactMap { value -> String? in
            guard let taskID = value as? String,
                  !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return taskID
        }.first
    }

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

        // Token Plan exposes its own product-scoped model capabilities. Never
        // derive a pay-as-you-go DashScope native endpoint for it. Models that
        // look like native generation models stay quarantined until the user
        // configures and verifies the provider-specific endpoint explicitly.
        if provider.kind.isBailianTokenPlan,
           isLikelyNativeGenerationModel(name)
        {
            return .providerNative
        }

        let musicEndpointKeys = [
            ProviderEndpointRecord.key(for: .musicGeneration, model: model),
            ProviderEndpointRecord.key(for: .musicGeneration)
        ]
        if isMusicModel(name),
           musicEndpointKeys.contains(where: { provider.endpointURLs[$0]?.isEmpty == false })
        {
            return .musicGeneration
        }

        if isBailian(provider), name == "wanx-v1" {
            return .imageGeneration
        }
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
        if isMusicModel(name) {
            return .musicGeneration
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
        let isBailian = provider.kind.isBailian
            || providerName.contains("百炼")
            || hostname == BailianEndpointPolicy.payAsYouGoHost
            || hostname == BailianEndpointPolicy.tokenPlanHost

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
                || name.hasPrefix("wanx-")
                || name.hasPrefix("emo")
                || name.hasPrefix("animate-anyone")
        }
        return false
    }

    private static func isBailian(_ provider: ProviderConfig) -> Bool {
        let hostname = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        return provider.kind.isBailian && (
            provider.name.lowercased().contains("百炼")
                || hostname == BailianEndpointPolicy.payAsYouGoHost
                || hostname == BailianEndpointPolicy.tokenPlanHost
        )
    }

    private static func isLikelyNativeGenerationModel(_ name: String) -> Bool {
        isSpeechModel(name)
            || isImageModel(name)
            || isVideoModel(name)
            || isMusicModel(name)
            || name.contains("embedding")
            || name.contains("rerank")
            || name.contains("whisper")
            || name.contains("transcrib")
            || name.contains("voice-design")
            || name.contains("voice-clone")
            || name.contains("realtime")
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

    private static func isMusicModel(_ name: String) -> Bool {
        let markers = [
            "music", "suno", "udio", "song", "musicgen", "ace-step",
            "audio-generation"
        ]
        return markers.contains { name.contains($0) }
    }

    private static func transcriptionProbePayload(model: String) -> ModelProbePayload {
        let boundary = "ModelHubProbeBoundary"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(model)\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"modelhub-probe.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(silentWAV())
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return ModelProbePayload(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

public enum ModelHealthMigration {
    public static func normalize(
        records: [ModelHealthRecord],
        providers: [ProviderConfig]
    ) -> [ModelHealthRecord] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var normalized = records.compactMap { original -> ModelHealthRecord? in
            guard let provider = providersByID[original.providerID],
                  provider.models.contains(where: {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines)
                          .caseInsensitiveCompare(original.model.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          )) == .orderedSame
                  })
            else { return nil }

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
                record.detail = ModelProbePolicy.nativeProbeUnavailableReason(
                    provider: provider,
                    model: original.model,
                    nativeProtocol: nativeProtocol
                )
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
                    detail = ModelProbePolicy.nativeProbeUnavailableReason(
                        provider: provider,
                        model: trimmedModel,
                        nativeProtocol: nativeProtocol
                    )
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
