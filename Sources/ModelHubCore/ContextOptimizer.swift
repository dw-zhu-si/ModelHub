import Foundation

public struct ContextOptimizationResult: Sendable {
    public let body: Data
    public let charactersSaved: Int

    public init(body: Data, charactersSaved: Int) {
        self.body = body
        self.charactersSaved = charactersSaved
    }
}

public enum ContextOptimizer {
    public static func optimizeChatBody(
        _ body: Data,
        settings: ContextOptimizationSettings
    ) -> ContextOptimizationResult {
        guard settings.mode == .conservative,
              var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = root["messages"] as? [[String: Any]]
        else { return .init(body: body, charactersSaved: 0) }

        let totalCharacters = messages.reduce(0) { partial, message in
            partial + ((message["content"] as? String)?.count ?? 0)
        }
        guard totalCharacters >= max(0, settings.minimumCharacters) else {
            return .init(body: body, charactersSaved: 0)
        }

        var saved = 0
        for index in messages.indices {
            guard let content = messages[index]["content"] as? String,
                  !content.contains("```")
            else { continue }
            let optimized = conservativeText(content)
            saved += max(0, content.count - optimized.count)
            messages[index]["content"] = optimized
        }
        guard saved > 0 else { return .init(body: body, charactersSaved: 0) }
        root["messages"] = messages
        let encoded = (try? JSONSerialization.data(withJSONObject: root)) ?? body
        return .init(body: encoded, charactersSaved: saved)
    }

    private static func conservativeText(_ text: String) -> String {
        let normalizedLines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }
        var output: [String] = []
        var blankCount = 0
        for line in normalizedLines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { output.append(line) }
            } else {
                blankCount = 0
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
