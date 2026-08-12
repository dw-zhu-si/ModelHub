import Foundation

public struct ProviderModelCSVImport: Sendable, Equatable {
    public let models: [String]
    public let prices: [String: ProviderModelPrice]
    public let endpointURLs: [String: String]
    public let duplicateCount: Int

    public init(
        models: [String],
        prices: [String: ProviderModelPrice],
        endpointURLs: [String: String],
        duplicateCount: Int
    ) {
        self.models = models
        self.prices = prices
        self.endpointURLs = endpointURLs
        self.duplicateCount = duplicateCount
    }
}

public enum ProviderModelCSVError: LocalizedError, Equatable {
    case fileTooLarge(maximumBytes: Int)
    case invalidEncoding
    case malformedCSV(row: Int)
    case missingHeader
    case missingModelColumn
    case missingModels
    case tooManyRows(maximum: Int)
    case invalidModel(row: Int)
    case invalidPrice(row: Int, column: String)
    case invalidEndpoint(row: Int, column: String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maximumBytes):
            "CSV 文件超过安全上限（\(maximumBytes / 1_048_576) MiB）"
        case .invalidEncoding:
            "CSV 文件必须使用 UTF-8 或 UTF-16 编码"
        case .malformedCSV(let row):
            "CSV 第 \(row) 行的引号格式不完整"
        case .missingHeader:
            "CSV 文件缺少表头"
        case .missingModelColumn:
            "CSV 表头必须包含 model 或 模型名称 列"
        case .missingModels:
            "CSV 文件中没有可导入的模型"
        case .tooManyRows(let maximum):
            "CSV 模型数量超过安全上限（\(maximum)）"
        case .invalidModel(let row):
            "CSV 第 \(row) 行的模型名称为空、过长或包含控制字符"
        case .invalidPrice(let row, let column):
            "CSV 第 \(row) 行的 \(column) 必须是大于或等于 0 的数字"
        case .invalidEndpoint(let row, let column):
            "CSV 第 \(row) 行的 \(column) 必须是无凭证的完整 HTTP(S) URL"
        }
    }
}

public enum ProviderModelCSVImporter {
    public static let maximumFileBytes = 8 * 1_048_576
    public static let maximumRows = 10_000
    public static let maximumModelNameLength = 512

    private static let modelHeaders = [
        "model", "model_id", "model_name", "模型", "模型_id", "模型名称", "模型标识"
    ]
    private static let inputPriceHeaders = [
        "input_price", "input_price_usd_per_million_tokens",
        "input_price_usd_per_1m_tokens", "input_cost_per_million_tokens",
        "prompt_price", "输入价格", "输入单价"
    ]
    private static let outputPriceHeaders = [
        "output_price", "output_price_usd_per_million_tokens",
        "output_price_usd_per_1m_tokens", "output_cost_per_million_tokens",
        "completion_price", "输出价格", "输出单价"
    ]
    private static let requestPriceHeaders = [
        "request_price", "price_per_request_usd", "request_price_usd",
        "cost_per_request_usd", "每次调用价格", "单次价格"
    ]
    private static let priceSourceHeaders = ["price_source", "价格来源"]
    private static let endpointColumns: [(headers: [String], kind: ProviderEndpointKind)] = [
        (["endpoint", "chat_endpoint", "聊天端点"], .chat),
        (["responses_endpoint", "responses端点"], .responses),
        (["image_endpoint", "image_generation_endpoint", "图片端点"], .imageGeneration),
        (["music_endpoint", "music_generation_endpoint", "音乐端点"], .musicGeneration),
        (["music_task_endpoint", "音乐任务端点"], .musicTask),
        (["video_endpoint", "video_generation_endpoint", "视频端点"], .videoGeneration),
        (["video_task_endpoint", "视频任务端点"], .videoTask),
        (["speech_endpoint", "语音端点"], .speech),
        (["transcription_endpoint", "转录端点"], .transcription),
        (["embeddings_endpoint", "向量端点"], .embeddings),
        (["reranking_endpoint", "重排端点"], .reranking),
    ]

    public static func parse(_ data: Data, source: String = "CSV") throws -> ProviderModelCSVImport {
        guard data.count <= maximumFileBytes else {
            throw ProviderModelCSVError.fileTooLarge(maximumBytes: maximumFileBytes)
        }
        guard var text = decodedText(from: data) else {
            throw ProviderModelCSVError.invalidEncoding
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        // Swift treats CRLF as one extended grapheme. Normalize line endings so
        // the state machine sees a single, predictable record delimiter.
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let prepared = preparedSource(text)
        let rows = try parseRows(prepared.text, delimiter: prepared.delimiter)
        guard let rawHeader = rows.first, !rawHeader.isEmpty else {
            throw ProviderModelCSVError.missingHeader
        }
        let header = rawHeader.map(normalizedHeader)
        guard let modelColumn = firstIndex(of: modelHeaders, in: header) else {
            throw ProviderModelCSVError.missingModelColumn
        }
        let inputPriceColumn = firstIndex(of: inputPriceHeaders, in: header)
        let outputPriceColumn = firstIndex(of: outputPriceHeaders, in: header)
        let requestPriceColumn = firstIndex(of: requestPriceHeaders, in: header)
        let priceSourceColumn = firstIndex(of: priceSourceHeaders, in: header)
        let endpointColumnIndexes = endpointColumns.compactMap { definition in
            firstIndex(of: definition.headers, in: header).map { ($0, definition.kind) }
        }

        let contentRows = rows.dropFirst().filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard contentRows.count <= maximumRows else {
            throw ProviderModelCSVError.tooManyRows(maximum: maximumRows)
        }

        var models: [String] = []
        var prices: [String: ProviderModelPrice] = [:]
        var endpointURLs: [String: String] = [:]
        var identities = Set<String>()
        var duplicateCount = 0

        for (offset, row) in contentRows.enumerated() {
            let rowNumber = offset + 2
            let model = value(at: modelColumn, in: row)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidModel(model) else {
                throw ProviderModelCSVError.invalidModel(row: rowNumber)
            }
            let identity = model.lowercased()
            guard identities.insert(identity).inserted else {
                duplicateCount += 1
                continue
            }
            models.append(model)

            let inputPrice = try parsePrice(
                column: inputPriceColumn,
                header: header,
                row: row,
                rowNumber: rowNumber
            )
            let outputPrice = try parsePrice(
                column: outputPriceColumn,
                header: header,
                row: row,
                rowNumber: rowNumber
            )
            let requestPrice = try parsePrice(
                column: requestPriceColumn,
                header: header,
                row: row,
                rowNumber: rowNumber
            )
            if inputPrice != nil || outputPrice != nil || requestPrice != nil {
                let configuredSource = priceSourceColumn
                    .map { value(at: $0, in: row) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                prices[model] = ProviderModelPrice(
                    inputPerMillionTokensUSD: inputPrice,
                    outputPerMillionTokensUSD: outputPrice,
                    perRequestUSD: requestPrice,
                    source: configuredSource?.isEmpty == false ? configuredSource! : source
                )
            }

            for (column, kind) in endpointColumnIndexes {
                let endpoint = value(at: column, in: row)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !endpoint.isEmpty else { continue }
                guard isValidEndpoint(endpoint) else {
                    throw ProviderModelCSVError.invalidEndpoint(
                        row: rowNumber,
                        column: rawHeader[column]
                    )
                }
                endpointURLs[ProviderEndpointRecord.key(for: kind, model: model)] = endpoint
            }
        }

        guard !models.isEmpty else { throw ProviderModelCSVError.missingModels }
        return ProviderModelCSVImport(
            models: models,
            prices: prices,
            endpointURLs: endpointURLs,
            duplicateCount: duplicateCount
        )
    }

    private static func decodedText(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes == [0xFE, 0xFF] {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    private static func preparedSource(_ source: String) -> (text: String, delimiter: Character) {
        let firstLineEnd = source.firstIndex(of: "\n") ?? source.endIndex
        let firstLine = source[..<firstLineEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLine.lowercased().hasPrefix("sep="), firstLine.count == 5 {
            let delimiter = firstLine.last!
            if [",", ";", "\t"].contains(delimiter) {
                let contentStart = firstLineEnd < source.endIndex
                    ? source.index(after: firstLineEnd)
                    : source.endIndex
                return (String(source[contentStart...]), delimiter)
            }
        }

        let supported: [Character] = [",", ";", "\t"]
        let delimiter = supported.max { lhs, rhs in
            firstLine.filter { $0 == lhs }.count < firstLine.filter { $0 == rhs }.count
        } ?? ","
        return (source, delimiter)
    }

    private static func parseRows(
        _ source: String,
        delimiter: Character
    ) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if insideQuotes {
                if character == "\"" {
                    let next = source.index(after: index)
                    if next < source.endIndex, source[next] == "\"" {
                        field.append("\"")
                        index = source.index(after: next)
                        continue
                    }
                    insideQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    insideQuotes = true
                case delimiter:
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    rows.append(row)
                    row = []
                    field = ""
                default:
                    field.append(character)
                }
            }
            index = source.index(after: index)
        }
        guard !insideQuotes else {
            throw ProviderModelCSVError.malformedCSV(row: rows.count + 1)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            rows.append(row)
        }
        return rows
    }

    private static func firstIndex(of aliases: [String], in header: [String]) -> Int? {
        let normalizedAliases = Set(aliases.map(normalizedHeader))
        return header.firstIndex(where: normalizedAliases.contains)
    }

    private static func normalizedHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func value(at index: Int, in row: [String]) -> String {
        index < row.count ? row[index] : ""
    }

    private static func parsePrice(
        column: Int?,
        header: [String],
        row: [String],
        rowNumber: Int
    ) throws -> Double? {
        guard let column else { return nil }
        let raw = value(at: column, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let price = Double(raw), price.isFinite, price >= 0 else {
            throw ProviderModelCSVError.invalidPrice(row: rowNumber, column: header[column])
        }
        return price
    }

    private static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty
            && model.count <= maximumModelNameLength
            && !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidEndpoint(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              ProviderEndpointSecurity.isSafeConfigurationURL(components)
        else { return false }
        return true
    }
}
