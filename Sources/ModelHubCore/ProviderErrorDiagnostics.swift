import Foundation

public enum ProviderErrorDiagnostics {
    public static let maximumSummaryCharacters = 420
    public static let maximumParsedBodyBytes = 64 * 1_024

    public static func summary(for response: ProviderResponse) -> String {
        var parts = ["HTTP \(response.statusCode)"]
        let boundedBody = response.body.prefix(maximumParsedBodyBytes)
        if let json = try? JSONSerialization.jsonObject(with: Data(boundedBody)),
           let object = json as? [String: Any] {
            if let code = firstString(in: object, paths: [["error", "code"], ["code"]]) {
                parts.append("code=\(sanitize(code, limit: 80))")
            }
            if let message = firstString(
                in: object,
                paths: [["error", "message"], ["message"], ["error_description"]]
            ) {
                parts.append("message=\(sanitize(message, limit: 220))")
            }
            if let requestID = firstString(
                in: object,
                paths: [["request_id"], ["requestId"], ["request", "id"]]
            ) {
                parts.append("request_id=\(sanitize(requestID, limit: 80))")
            }
        }
        if !parts.contains(where: { $0.hasPrefix("request_id=") }),
           let requestID = response.headers.first(where: {
               ["x-request-id", "request-id", "x-dashscope-request-id"]
                   .contains($0.key.lowercased())
           })?.value {
            parts.append("request_id=\(sanitize(requestID, limit: 80))")
        }
        return String(parts.joined(separator: " · ").prefix(maximumSummaryCharacters))
    }

    private static func firstString(
        in object: [String: Any],
        paths: [[String]]
    ) -> String? {
        for path in paths {
            var value: Any = object
            var found = true
            for component in path {
                guard let dictionary = value as? [String: Any],
                      let next = dictionary[component]
                else {
                    found = false
                    break
                }
                value = next
            }
            if found, let string = value as? String, !string.isEmpty { return string }
            if found, let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func sanitize(_ value: String, limit: Int) -> String {
        var text = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let patterns = [
            #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\bsk-[A-Za-z0-9_-]{12,}\b"#,
            #"(?i)(api[_-]?key|token|secret)\s*[:=]\s*[^\s,;]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: "[已脱敏]"
            )
        }
        return String(text.prefix(limit))
    }
}
