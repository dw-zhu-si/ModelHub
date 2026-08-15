import Foundation

/// MiniMax's media and speech APIs are provider-native protocols rather than
/// OpenAI-compatible request bodies. Keep their exact model identifiers and
/// parameter translations in one place so chat and other providers remain
/// untouched.
public enum MiniMaxNativeAdapter {
    private static let legacyModelIDAliases: [String: String] = [
        "minimax music 3.0": "music-3.0",
        "minimax music-2.6": "music-2.6"
    ]
    public static let videoModelIDs: Set<String> = [
        "MiniMax-Hailuo-2.3", "MiniMax-Hailuo-02", "T2V-01-Director", "T2V-01"
    ]
    public static let imageModelIDs: Set<String> = ["image-01", "image-01-live"]
    public static let musicModelIDs: Set<String> = [
        "music-3.0", "music-2.6", "music-cover",
        "music-3.0-free", "music-2.6-free", "music-cover-free"
    ]
    public static let speechModelIDs: Set<String> = [
        "speech-2.8-hd", "speech-2.8-turbo", "speech-2.6-hd", "speech-2.6-turbo",
        "speech-02-hd", "speech-02-turbo", "speech-01-hd", "speech-01-turbo"
    ]

    public static func isMiniMax(_ provider: ProviderConfig) -> Bool {
        if provider.kind == .minimax || provider.kind == .minimaxChina { return true }
        let host = URL(string: provider.baseURL)?.host?.lowercased()
        return host == "api.minimax.io" || host == "api.minimaxi.com"
    }

    public static func nativeProtocol(forExactModelID model: String) -> ModelNativeProtocol? {
        if videoModelIDs.contains(model) { return .videoGeneration }
        if imageModelIDs.contains(model) { return .imageGeneration }
        if musicModelIDs.contains(model) { return .musicGeneration }
        if speechModelIDs.contains(model) { return .speech }
        return nil
    }

    /// Repairs only aliases emitted by older ModelHub versions. Arbitrary
    /// case-insensitive or fuzzy matches remain rejected so typos cannot be
    /// routed to a different billable model.
    public static func canonicalModelID(forStoredModelID model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyModelIDAliases[trimmed.lowercased()] ?? trimmed
    }

    public static func resemblesNativeModelID(_ model: String) -> Bool {
        let value = model.lowercased()
        return ["hailuo", "t2v-", "image-", "music-", "speech-"].contains {
            value.contains($0)
        }
    }

    public static func normalizedRequest(
        _ original: [String: Any],
        model: String,
        operation: NativeAPIOperation
    ) throws -> [String: Any] {
        let exactModel = canonicalModelID(forStoredModelID: model)
        try validateExactModelID(exactModel, operation: operation)
        var json = original
        json["model"] = exactModel

        switch operation {
        case .videoGeneration:
            try normalizeVideo(&json, model: exactModel)
        case .imageGeneration:
            try normalizeImage(&json, model: exactModel)
        case .musicGeneration:
            try normalizeMusic(&json, model: exactModel)
        case .speech:
            try normalizeSpeech(&json)
        case .videoTask, .musicTask, .transcription, .embeddings, .reranking:
            break
        }
        return json
    }

    public static func validateExactModelID(
        _ model: String,
        operation: NativeAPIOperation
    ) throws {
        let supported: Set<String>
        switch operation {
        case .videoGeneration, .videoTask: supported = videoModelIDs
        case .imageGeneration: supported = imageModelIDs
        case .musicGeneration, .musicTask: supported = musicModelIDs
        case .speech: supported = speechModelIDs
        case .transcription, .embeddings, .reranking: return
        }
        guard supported.contains(model) else {
            let values = supported.sorted().joined(separator: "、")
            throw ProviderClientError.invalidRequest(
                "MiniMax \(operation.modelProtocol.displayName)必须使用官方精确模型 ID：\(values)"
            )
        }
    }

    private static func normalizeVideo(
        _ json: inout [String: Any],
        model: String
    ) throws {
        moveValue(in: &json, from: "watermark", to: "aigc_watermark")
        json.removeValue(forKey: "size")
        json.removeValue(forKey: "generate_audio")
        json.removeValue(forKey: "quality")

        let hailuo = model == "MiniMax-Hailuo-2.3" || model == "MiniMax-Hailuo-02"
        let duration = integer(json["duration"]) ?? 6
        let normalizedDuration = duration == 5 ? 6 : duration
        guard normalizedDuration == 6 || (hailuo && normalizedDuration == 10) else {
            throw ProviderClientError.invalidRequest(
                hailuo ? "MiniMax Hailuo 视频时长只支持 6 或 10 秒" : "该 MiniMax 视频模型只支持 6 秒"
            )
        }
        json["duration"] = normalizedDuration

        let defaultResolution = hailuo ? "768P" : "720P"
        let rawResolution = (json["resolution"] as? String)?.uppercased() ?? defaultResolution
        let resolution = rawResolution == "480P" ? defaultResolution : rawResolution
        let allowed = hailuo
            ? (normalizedDuration == 10 ? Set(["768P"]) : Set(["768P", "1080P"]))
            : Set(["720P", "1080P"])
        guard allowed.contains(resolution) else {
            throw ProviderClientError.invalidRequest(
                "MiniMax 模型 \(model) 在 \(normalizedDuration) 秒下不支持分辨率 \(resolution)"
            )
        }
        json["resolution"] = resolution

        if json["fast_pretreatment"] != nil && !hailuo {
            throw ProviderClientError.invalidRequest(
                "fast_pretreatment 仅支持 MiniMax-Hailuo-2.3 和 MiniMax-Hailuo-02"
            )
        }
    }

    private static func normalizeImage(
        _ json: inout [String: Any],
        model: String
    ) throws {
        moveValue(in: &json, from: "watermark", to: "aigc_watermark")
        json.removeValue(forKey: "quality")

        guard let size = json.removeValue(forKey: "size") as? String else { return }
        let mappedRatios = [
            "1024x1024": "1:1", "1280x720": "16:9", "1152x864": "4:3",
            "1248x832": "3:2", "832x1248": "2:3", "864x1152": "3:4",
            "720x1280": "9:16", "1344x576": "21:9"
        ]
        if let ratio = mappedRatios[size], model == "image-01-live" {
            guard ratio != "21:9" else {
                throw ProviderClientError.invalidRequest("image-01-live 不支持 21:9")
            }
            if json["aspect_ratio"] == nil { json["aspect_ratio"] = ratio }
            return
        }

        let parts = size.lowercased().split(separator: "x", maxSplits: 1)
        guard model == "image-01", parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              (512...2048).contains(width), (512...2048).contains(height),
              width.isMultiple(of: 8), height.isMultiple(of: 8)
        else {
            throw ProviderClientError.invalidRequest(
                "MiniMax 图片 size 必须是 512～2048 范围内且为 8 的倍数；image-01-live 请使用官方宽高比"
            )
        }
        if json["aspect_ratio"] == nil {
            json["width"] = width
            json["height"] = height
        }
    }

    private static func normalizeMusic(
        _ json: inout [String: Any],
        model: String
    ) throws {
        moveValue(in: &json, from: "instrumental", to: "is_instrumental")
        moveValue(in: &json, from: "watermark", to: "aigc_watermark")
        json.removeValue(forKey: "duration")

        var audio = json["audio_setting"] as? [String: Any] ?? [:]
        if let responseFormat = json.removeValue(forKey: "response_format") as? String {
            if ["url", "hex"].contains(responseFormat) {
                if json["output_format"] == nil { json["output_format"] = responseFormat }
            } else if ["mp3", "wav", "pcm"].contains(responseFormat) {
                if audio["format"] == nil { audio["format"] = responseFormat }
            } else {
                throw ProviderClientError.invalidRequest(
                    "MiniMax 音乐 response_format 只支持 url、hex、mp3、wav 或 pcm"
                )
            }
        }
        for key in ["sample_rate", "bitrate", "format"] {
            if audio[key] == nil, let value = json.removeValue(forKey: key) {
                audio[key] = value
            }
        }
        if !audio.isEmpty { json["audio_setting"] = audio }

        if let format = json["output_format"] as? String,
           !["url", "hex"].contains(format) {
            throw ProviderClientError.invalidRequest("MiniMax 音乐 output_format 只支持 url 或 hex")
        }
        let isCover = model == "music-cover" || model == "music-cover-free"
        if isCover {
            let sources = ["audio_url", "audio_base64", "cover_feature_id"]
                .filter { json[$0] != nil }
            guard sources.count == 1 else {
                throw ProviderClientError.invalidRequest(
                    "MiniMax 翻唱模型必须且只能提供 audio_url、audio_base64 或 cover_feature_id 之一"
                )
            }
        }
    }

    private static func normalizeSpeech(_ json: inout [String: Any]) throws {
        if json["text"] == nil, let input = json.removeValue(forKey: "input") as? String {
            json["text"] = input
        }
        guard let text = json["text"] as? String, !text.isEmpty else {
            throw ProviderClientError.invalidRequest("MiniMax 语音合成需要非空 text 或 input")
        }

        var voice = json["voice_setting"] as? [String: Any] ?? [:]
        if voice["voice_id"] == nil, let voiceID = json.removeValue(forKey: "voice") {
            voice["voice_id"] = voiceID
        }
        for key in ["speed", "vol", "pitch", "emotion"] {
            if voice[key] == nil, let value = json.removeValue(forKey: key) {
                voice[key] = value
            }
        }
        if !voice.isEmpty { json["voice_setting"] = voice }

        var audio = json["audio_setting"] as? [String: Any] ?? [:]
        if audio["format"] == nil, let format = json.removeValue(forKey: "response_format") {
            audio["format"] = format
        }
        for key in ["sample_rate", "bitrate", "channel"] {
            if audio[key] == nil, let value = json.removeValue(forKey: key) {
                audio[key] = value
            }
        }
        if !audio.isEmpty { json["audio_setting"] = audio }
    }

    private static func moveValue(
        in json: inout [String: Any],
        from source: String,
        to destination: String
    ) {
        guard let value = json.removeValue(forKey: source), json[destination] == nil else { return }
        json[destination] = value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
