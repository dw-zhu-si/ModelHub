import Foundation

/// A transport-neutral modality used by catalog metadata and the local API.
public enum ModelModality: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case image
    case video
    case audio
    case vector
}

public enum ModelNumericConstraint: Codable, Hashable, Sendable {
    case values([Double])
    case range(minimum: Double, maximum: Double, step: Double?)
}

public struct ModelImageCapabilities: Codable, Hashable, Sendable {
    public var sizes: [String]
    public var aspectRatios: [String]
    public var widthPixels: ModelNumericConstraint?
    public var heightPixels: ModelNumericConstraint?
    public var maximumOutputs: Int?

    public init(
        sizes: [String] = [],
        aspectRatios: [String] = [],
        widthPixels: ModelNumericConstraint? = nil,
        heightPixels: ModelNumericConstraint? = nil,
        maximumOutputs: Int? = nil
    ) {
        self.sizes = Self.normalized(sizes)
        self.aspectRatios = Self.normalized(aspectRatios)
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.maximumOutputs = maximumOutputs
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                return nil
            }
            return trimmed
        }
    }

    fileprivate func mergingFallback(_ fallback: Self?) -> Self {
        guard let fallback else { return self }
        return .init(
            sizes: sizes.isEmpty ? fallback.sizes : sizes,
            aspectRatios: aspectRatios.isEmpty ? fallback.aspectRatios : aspectRatios,
            widthPixels: widthPixels ?? fallback.widthPixels,
            heightPixels: heightPixels ?? fallback.heightPixels,
            maximumOutputs: maximumOutputs ?? fallback.maximumOutputs
        )
    }
}

public struct ModelVideoCapabilities: Codable, Hashable, Sendable {
    public var resolutions: [String]
    public var aspectRatios: [String]
    public var durationsSeconds: ModelNumericConstraint?

    public init(
        resolutions: [String] = [],
        aspectRatios: [String] = [],
        durationsSeconds: ModelNumericConstraint? = nil
    ) {
        self.resolutions = Self.normalized(resolutions)
        self.aspectRatios = Self.normalized(aspectRatios)
        self.durationsSeconds = durationsSeconds
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                return nil
            }
            return trimmed
        }
    }

    fileprivate func mergingFallback(_ fallback: Self?) -> Self {
        guard let fallback else { return self }
        return .init(
            resolutions: resolutions.isEmpty ? fallback.resolutions : resolutions,
            aspectRatios: aspectRatios.isEmpty ? fallback.aspectRatios : aspectRatios,
            durationsSeconds: durationsSeconds ?? fallback.durationsSeconds
        )
    }
}

public struct ModelAudioCapabilities: Codable, Hashable, Sendable {
    public var formats: [String]
    public var sampleRatesHz: [Int]

    public init(formats: [String] = [], sampleRatesHz: [Int] = []) {
        self.formats = Array(Set(formats.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
        self.sampleRatesHz = Array(Set(sampleRatesHz.filter { $0 > 0 })).sorted()
    }


    fileprivate func mergingFallback(_ fallback: Self?) -> Self {
        guard let fallback else { return self }
        return .init(
            formats: formats.isEmpty ? fallback.formats : formats,
            sampleRatesHz: sampleRatesHz.isEmpty ? fallback.sampleRatesHz : sampleRatesHz
        )
    }
}

public struct ModelParameterConstraint: Codable, Hashable, Sendable {
    public var name: String
    public var valueType: String?
    public var required: Bool
    public var allowedValues: [String]
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var unit: String?
    public var description: String?

    public init(
        name: String,
        valueType: String? = nil,
        required: Bool = false,
        allowedValues: [String] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        step: Double? = nil,
        unit: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.valueType = valueType
        self.required = required
        self.allowedValues = allowedValues
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.unit = unit
        self.description = description
    }
}

public struct ModelCapabilityDetails: Codable, Hashable, Sendable {
    public var inputModalities: [ModelModality]
    public var outputModalities: [ModelModality]
    public var image: ModelImageCapabilities?
    public var video: ModelVideoCapabilities?
    public var audio: ModelAudioCapabilities?
    public var parameters: [ModelParameterConstraint]
    public var source: String
    public var updatedAt: Date?

    public init(
        inputModalities: [ModelModality] = [],
        outputModalities: [ModelModality] = [],
        image: ModelImageCapabilities? = nil,
        video: ModelVideoCapabilities? = nil,
        audio: ModelAudioCapabilities? = nil,
        parameters: [ModelParameterConstraint] = [],
        source: String = "",
        updatedAt: Date? = nil
    ) {
        self.inputModalities = Self.unique(inputModalities)
        self.outputModalities = Self.unique(outputModalities)
        self.image = image
        self.video = video
        self.audio = audio
        self.parameters = parameters
        self.source = source
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        inputModalities.isEmpty && outputModalities.isEmpty
            && image == nil && video == nil && audio == nil && parameters.isEmpty
    }

    public func mergingFallback(_ fallback: ModelCapabilityDetails?) -> Self {
        guard let fallback else { return self }
        return .init(
            inputModalities: inputModalities.isEmpty ? fallback.inputModalities : inputModalities,
            outputModalities: outputModalities.isEmpty ? fallback.outputModalities : outputModalities,
            image: image?.mergingFallback(fallback.image) ?? fallback.image,
            video: video?.mergingFallback(fallback.video) ?? fallback.video,
            audio: audio?.mergingFallback(fallback.audio) ?? fallback.audio,
            parameters: parameters.isEmpty ? fallback.parameters : parameters,
            source: source.isEmpty ? fallback.source : source,
            updatedAt: updatedAt ?? fallback.updatedAt
        )
    }

    private static func unique(_ values: [ModelModality]) -> [ModelModality] {
        var seen = Set<ModelModality>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Provider-owned constraints which are not exposed by the inference model list.
/// The values intentionally cover only documented, model-family-specific facts.
public enum QianwenModelCapabilityRegistry {
    public static func details(for model: String) -> ModelCapabilityDetails? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let imageSource = "https://platform.qianwenai.com/docs/developer-guides/image-generation/text-to-image"
        let videoSource = "https://platform.qianwenai.com/docs/api-reference/video-generation/wan27-text-to-video/create-task"

        if name == "qwen-image-3.0-pro" {
            return .init(
                inputModalities: [.text, .image],
                outputModalities: [.image],
                image: .init(
                    aspectRatios: ["1:8–8:1"],
                    widthPixels: .range(minimum: 512, maximum: 2048, step: nil),
                    heightPixels: .range(minimum: 512, maximum: 2048, step: nil),
                    maximumOutputs: 6
                ),
                parameters: [
                    .init(
                        name: "size",
                        valueType: "string",
                        description: "宽*高；单边 512–2048 像素，宽高比 1:8–8:1"
                    ),
                    .init(name: "n", valueType: "integer", minimum: 1, maximum: 6),
                    .init(name: "prompt_extend", valueType: "boolean"),
                    .init(
                        name: "prompt_extend_mode",
                        valueType: "string",
                        allowedValues: ["direct", "agent"]
                    )
                ],
                source: imageSource
            )
        }
        if name.hasPrefix("qwen-image-2") {
            return .init(
                inputModalities: [.text, .image],
                outputModalities: [.image],
                image: .init(
                    widthPixels: .range(minimum: 512, maximum: 2048, step: nil),
                    heightPixels: .range(minimum: 512, maximum: 2048, step: nil),
                    maximumOutputs: 6
                ),
                parameters: [
                    .init(
                        name: "size",
                        valueType: "string",
                        description: "宽*高；单边 512–2048 像素"
                    ),
                    .init(name: "n", valueType: "integer", minimum: 1, maximum: 6)
                ],
                source: imageSource
            )
        }
        if name.hasPrefix("wan2.7-image") {
            let sizes = name.contains("pro") ? ["1K", "2K", "4K"] : ["1K", "2K"]
            let maximumPixels: Double = name.contains("pro") ? 4096 : 2048
            return .init(
                inputModalities: [.text, .image],
                outputModalities: [.image],
                image: .init(
                    sizes: sizes,
                    aspectRatios: ["1:8–8:1"],
                    widthPixels: .range(minimum: 768, maximum: maximumPixels, step: nil),
                    heightPixels: .range(minimum: 768, maximum: maximumPixels, step: nil),
                    maximumOutputs: 12
                ),
                parameters: [
                    .init(name: "size", valueType: "string", allowedValues: sizes),
                    .init(
                        name: "n",
                        valueType: "integer",
                        minimum: 1,
                        maximum: 12,
                        description: "启用连续图集时最多 12；普通生成最多 4"
                    )
                ],
                source: imageSource
            )
        }
        if name.contains("wan2.7"),
           ["t2v", "i2v", "r2v", "video"].contains(where: name.contains) {
            return .init(
                inputModalities: name.contains("t2v") ? [.text] : [.text, .image],
                outputModalities: [.video],
                video: .init(
                    resolutions: ["720P", "1080P"],
                    aspectRatios: ["16:9", "9:16", "1:1", "4:3", "3:4"],
                    durationsSeconds: .range(minimum: 2, maximum: 15, step: 1)
                ),
                parameters: [
                    .init(name: "resolution", valueType: "string", allowedValues: ["720P", "1080P"]),
                    .init(name: "ratio", valueType: "string", allowedValues: ["16:9", "9:16", "1:1", "4:3", "3:4"]),
                    .init(name: "duration", valueType: "integer", minimum: 2, maximum: 15, step: 1, unit: "seconds")
                ],
                source: videoSource
            )
        }
        return nil
    }
}

public enum ProviderModelCapabilityUpdater {
    @discardableResult
    public static func apply(
        details: [String: ModelCapabilityDetails],
        to provider: inout ProviderConfig,
        updatedAt: Date = .now
    ) -> Int {
        let indexed = Dictionary(uniqueKeysWithValues: details.map {
            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.value)
        })
        var profiles = provider.modelProfiles ?? [:]
        var count = 0
        for model in provider.models {
            let identity = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let catalog = indexed[identity]
            var inferred = provider.kind.isBailian
                ? QianwenModelCapabilityRegistry.details(for: model)
                : nil
            if catalog == nil, var value = inferred {
                if value.updatedAt == nil { value.updatedAt = updatedAt }
                inferred = value
            }
            guard let resolved = catalog ?? inferred else { continue }
            let existingKey = profiles.keys.first { $0.lowercased() == identity }
            var profile = existingKey.flatMap { profiles[$0] } ?? TargetProfile()
            profile.capabilityDetails = resolved
            profile.capabilities.formUnion(capabilitySet(for: resolved))
            if let existingKey, existingKey != model { profiles.removeValue(forKey: existingKey) }
            profiles[model] = profile
            count += 1
        }
        provider.modelProfiles = profiles.isEmpty ? nil : profiles
        return count
    }

    private static func capabilitySet(
        for details: ModelCapabilityDetails
    ) -> Set<ModelCapability> {
        var result: Set<ModelCapability> = []
        if details.outputModalities.contains(.image) { result.insert(.imageGeneration) }
        if details.outputModalities.contains(.video) { result.insert(.videoGeneration) }
        if details.outputModalities.contains(.audio) { result.insert(.audio) }
        if details.outputModalities.contains(.text) { result.insert(.chat) }
        return result
    }
}
