import Foundation

struct TargetLanguage {
    let catalogCode: String
    let translationCode: String
}

let targetLanguages = [
    TargetLanguage(catalogCode: "en", translationCode: "en"),
    TargetLanguage(catalogCode: "ja", translationCode: "ja"),
    TargetLanguage(catalogCode: "ko", translationCode: "ko"),
    TargetLanguage(catalogCode: "es", translationCode: "es"),
    TargetLanguage(catalogCode: "fr", translationCode: "fr"),
    TargetLanguage(catalogCode: "de", translationCode: "de"),
    TargetLanguage(catalogCode: "pt-BR", translationCode: "pt"),
    TargetLanguage(catalogCode: "ru", translationCode: "ru"),
    TargetLanguage(catalogCode: "ar", translationCode: "ar"),
]

enum GeneratorError: LocalizedError {
    case usage
    case invalidCatalog
    case invalidResponse(String)
    case translationFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: generate_localization_catalog.swift <Localizable.xcstrings>"
        case .invalidCatalog:
            return "The input file is not a valid string catalog."
        case let .invalidResponse(language):
            return "The translation service returned an invalid response for \(language)."
        case let .translationFailed(statusCode, body):
            return "Translation request failed with HTTP \(statusCode): \(body.prefix(300))"
        }
    }
}

func containsHan(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        (0x3400...0x4DBF).contains(Int(scalar.value)) ||
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }
}

func traditionalChinese(_ value: String) -> String {
    let mutable = NSMutableString(string: value)
    CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
    return mutable as String
}

func formEncoded(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

func translatedBatch(_ sourceTexts: [String], target: TargetLanguage) async throws -> [String] {
    guard !sourceTexts.isEmpty else { return [] }
    let boundary = "__MODELHUB_STRING_BOUNDARY_48291__"
    let joined = sourceTexts.joined(separator: "\n\(boundary)\n")
    var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("ModelHub localization generator", forHTTPHeaderField: "User-Agent")
    request.httpBody = formEncoded([
        "client": "gtx",
        "sl": "zh-CN",
        "tl": target.translationCode,
        "dt": "t",
        "q": joined,
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw GeneratorError.translationFailed(status, String(data: data, encoding: .utf8) ?? "")
    }
    guard
        let payload = try JSONSerialization.jsonObject(with: data) as? [Any],
        let chunks = payload.first as? [Any]
    else {
        throw GeneratorError.invalidResponse(target.catalogCode)
    }
    let translated = chunks.compactMap { chunk -> String? in
        guard let fields = chunk as? [Any], let text = fields.first as? String else { return nil }
        return text
    }.joined()
    let values = translated
        .components(separatedBy: boundary)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard values.count == sourceTexts.count else {
        throw GeneratorError.invalidResponse(target.catalogCode)
    }
    return values
}

func stringUnit(_ value: String) -> [String: Any] {
    ["stringUnit": ["state": "translated", "value": value]]
}

func sourceValue(for key: String) -> String {
    let components = key.components(separatedBy: "%arg")
    guard components.count > 1 else { return key }
    var result = components[0]
    for index in 1..<components.count {
        result += "%\(index)$arg"
        result += components[index]
    }
    return result
}

func existingTranslation(
    for language: String,
    entry: [String: Any]
) -> String? {
    guard
        let localizations = entry["localizations"] as? [String: Any],
        let localization = localizations[language] as? [String: Any],
        let unit = localization["stringUnit"] as? [String: Any],
        let value = unit["value"] as? String,
        !value.isEmpty
    else {
        return nil
    }
    if language == "en", containsHan(value) {
        return nil
    }
    return value
}

@main
struct LocalizationCatalogGenerator {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw GeneratorError.usage }
            let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let data = try Data(contentsOf: catalogURL)
            guard
                var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                var strings = root["strings"] as? [String: Any]
            else {
                throw GeneratorError.invalidCatalog
            }

            let keys = strings.keys.filter(containsHan).sorted()
            var sources: [String: String] = [:]
            for key in keys {
                sources[key] = sourceValue(for: key)
            }

            var translations: [String: [String: String]] = [:]
            for target in targetLanguages {
                var languageValues: [String: String] = [:]
                var missingKeys: [String] = []
                for key in keys {
                    let entry = strings[key] as? [String: Any] ?? [:]
                    if let existing = existingTranslation(for: target.catalogCode, entry: entry) {
                        languageValues[key] = existing
                    } else {
                        missingKeys.append(key)
                    }
                }
                for start in stride(from: 0, to: missingKeys.count, by: 24) {
                    let batchKeys = Array(missingKeys[start..<min(start + 24, missingKeys.count)])
                    let batchSources = batchKeys.map { sources[$0] ?? $0 }
                    let batchValues = try await translatedBatch(batchSources, target: target)
                    for (key, value) in zip(batchKeys, batchValues) {
                        languageValues[key] = value
                    }
                }
                translations[target.catalogCode] = languageValues
                FileHandle.standardError.write(Data("ready \(target.catalogCode): \(languageValues.count), new \(missingKeys.count)\n".utf8))
            }

            for key in keys {
                var entry = strings[key] as? [String: Any] ?? [:]
                var localizations = entry["localizations"] as? [String: Any] ?? [:]
                let source = sources[key] ?? key
                localizations["zh-Hans"] = stringUnit(source)
                localizations["zh-Hant"] = stringUnit(traditionalChinese(source))
                for target in targetLanguages {
                    guard let value = translations[target.catalogCode]?[key] else {
                        throw GeneratorError.invalidResponse(target.catalogCode)
                    }
                    localizations[target.catalogCode] = stringUnit(value)
                }
                entry["localizations"] = localizations
                strings[key] = entry
            }

            root["sourceLanguage"] = "zh-Hans"
            root["strings"] = strings
            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try output.write(to: catalogURL, options: .atomic)
            FileHandle.standardOutput.write(Data("updated \(catalogURL.path): \(keys.count) source strings, 11 languages\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
