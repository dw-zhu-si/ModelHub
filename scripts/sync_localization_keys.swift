import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: sync_localization_keys.swift <Localizable.xcstrings> <source-dir>...\n", stderr)
    exit(2)
}

let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: catalogURL),
      var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var strings = root["strings"] as? [String: Any]
else {
    fputs("Invalid string catalog.\n", stderr)
    exit(3)
}

func containsHan(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        (0x3400...0x4DBF).contains(Int(scalar.value))
            || (0x4E00...0x9FFF).contains(Int(scalar.value))
    }
}

let literalPattern = try NSRegularExpression(pattern: #"\"(?:\\.|[^\"\\])*\""#)
let manager = FileManager.default
var discovered = Set<String>()

for sourcePath in CommandLine.arguments.dropFirst(2) {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard let enumerator = manager.enumerator(
        at: sourceURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { continue }
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in literalPattern.matches(in: source, range: range) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            var literal = String(source[matchRange].dropFirst().dropLast())
            guard !literal.contains(#"\("#), containsHan(literal) else { continue }
            literal = literal
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !literal.isEmpty, literal.count <= 2_000 else { continue }
            discovered.insert(literal)
        }
    }
}

let missing = discovered.filter { strings[$0] == nil }.sorted()
for key in missing {
    strings[key] = ["extractionState": "manual"]
}
root["strings"] = strings
let output = try JSONSerialization.data(
    withJSONObject: root,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
try output.write(to: catalogURL, options: .atomic)
print("Added \(missing.count) localization keys; catalog now has \(strings.count) keys.")
