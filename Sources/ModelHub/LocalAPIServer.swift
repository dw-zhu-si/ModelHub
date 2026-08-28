import Foundation
@preconcurrency import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let queryItems: [String: String]
    let orderedQueryItems: [HTTPQueryItem]
    let headers: [String: String]
    let body: Data
    let requestID: String

    init(
        method: String,
        path: String,
        queryItems: [String: String],
        orderedQueryItems: [HTTPQueryItem],
        headers: [String: String],
        body: Data,
        requestID: String? = nil
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.orderedQueryItems = orderedQueryItems
        self.headers = headers
        self.body = body
        self.requestID = HTTPRequestIDPolicy.normalized(
            requestID
                ?? headers["x-modelhub-request-id"]
                ?? headers["x-request-id"]
        )
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func queryItem(_ name: String) -> String? {
        queryItems[name.lowercased()]
    }
}

struct HTTPQueryItem: Sendable, Equatable {
    let name: String
    let value: String?
}

private enum HTTPRequestIDPolicy {
    static func normalized(_ candidate: String?) -> String {
        guard let candidate,
              (1...80).contains(candidate.utf8.count),
              candidate.utf8.allSatisfy(isAllowedByte)
        else {
            return UUID().uuidString
        }
        return candidate
    }

    private static func isAllowedByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 46
            || byte == 95
            || byte == 45
    }
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json(statusCode: Int, object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    func addingRequestID(_ requestID: String) -> HTTPResponse {
        var updatedHeaders = headers.filter {
            $0.key.caseInsensitiveCompare("X-ModelHub-Request-ID") != .orderedSame
        }
        updatedHeaders["X-ModelHub-Request-ID"] = HTTPRequestIDPolicy.normalized(requestID)
        return HTTPResponse(statusCode: statusCode, headers: updatedHeaders, body: body)
    }

    func serialized() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-ModelHub-Request-ID, X-Request-ID"
        allHeaders["Access-Control-Expose-Headers"] = "X-ModelHub-Request-ID"
        allHeaders["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"

        var head = "HTTP/1.1 \(statusCode) \(httpReasonPhrase(statusCode))\r\n"
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

struct HTTPStreamResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>

    func addingRequestID(_ requestID: String) -> HTTPStreamResponse {
        var updatedHeaders = headers.filter {
            $0.key.caseInsensitiveCompare("X-ModelHub-Request-ID") != .orderedSame
        }
        updatedHeaders["X-ModelHub-Request-ID"] = HTTPRequestIDPolicy.normalized(requestID)
        return HTTPStreamResponse(statusCode: statusCode, headers: updatedHeaders, body: body)
    }

    func serializedHead() -> Data {
        var allHeaders = headers
        allHeaders["Transfer-Encoding"] = "chunked"
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-cache"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-ModelHub-Request-ID, X-Request-ID"
        allHeaders["Access-Control-Expose-Headers"] = "X-ModelHub-Request-ID"
        var head = "HTTP/1.1 \(statusCode) \(httpReasonPhrase(statusCode))\r\n"
        for (key, value) in allHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }
}

private func httpReasonPhrase(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 202: "Accepted"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 408: "Request Timeout"
    case 409: "Conflict"
    case 411: "Length Required"
    case 413: "Content Too Large"
    case 422: "Unprocessable Entity"
    case 429: "Too Many Requests"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    default: "HTTP Response"
    }
}

struct HTTPServerConnectionPolicy: Sendable, Equatable {
    enum TimeoutReason: Sendable, Equatable {
        case idle
        case absoluteRequestDeadline
        case handlerDeadline
        case streamIdle
        case maximumStreamDuration
    }

    let maximumActiveConnections: Int
    let idleTimeout: TimeInterval
    let absoluteRequestDeadline: TimeInterval
    let handlerDeadline: TimeInterval
    let streamIdleTimeout: TimeInterval
    let maximumStreamDuration: TimeInterval

    init(
        maximumActiveConnections: Int = 128,
        idleTimeout: TimeInterval = 10,
        absoluteRequestDeadline: TimeInterval = 30,
        handlerDeadline: TimeInterval = 660,
        streamIdleTimeout: TimeInterval = 30,
        maximumStreamDuration: TimeInterval = 3_600
    ) {
        self.maximumActiveConnections = max(1, maximumActiveConnections)
        self.idleTimeout = max(0.1, idleTimeout)
        self.absoluteRequestDeadline = max(0.1, absoluteRequestDeadline)
        self.handlerDeadline = max(0.1, handlerDeadline)
        self.streamIdleTimeout = max(0.1, streamIdleTimeout)
        self.maximumStreamDuration = max(0.1, maximumStreamDuration)
    }

    func admits(activeConnectionCount: Int) -> Bool {
        activeConnectionCount < maximumActiveConnections
    }

    func timeoutReason(requestAge: TimeInterval, idleAge: TimeInterval) -> TimeoutReason? {
        if requestAge >= absoluteRequestDeadline {
            return .absoluteRequestDeadline
        }
        if idleAge >= idleTimeout {
            return .idle
        }
        return nil
    }
}

enum HTTPRequestParseResult {
    case incomplete
    case request(HTTPRequest)
    case failure(HTTPResponse)
}

struct HTTPRequestParser {
    let maximumBodyBytes: Int
    let maximumHeaderBytes: Int

    init(
        maximumBodyBytes: Int = 32 * 1_024 * 1_024,
        maximumHeaderBytes: Int = 64 * 1_024
    ) {
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    func parse(_ data: Data) -> HTTPRequestParseResult {
        makeStreamParser().append(data)
    }

    func makeStreamParser() -> HTTPRequestStreamParser {
        HTTPRequestStreamParser(parser: self)
    }

    fileprivate func parseHead(_ data: Data) -> HTTPRequestHeadParseResult {
        guard let headerText = String(data: data, encoding: .utf8) else {
            return .failure(errorResponse(400, "请求头不是有效 UTF-8", "invalid_request_headers"))
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(errorResponse(400, "缺少请求行", "invalid_request_line"))
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]),
              isHTTPToken(parts[0])
        else {
            return .failure(errorResponse(400, "请求行无效", "invalid_request_line"))
        }

        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        var transferEncodings: [String] = []
        let unambiguousHeaders = Set([
            "authorization",
            "content-length",
            "host",
            "transfer-encoding",
            "x-modelhub-request-id",
            "x-request-id"
        ])
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(errorResponse(400, "请求头格式无效", "invalid_request_headers"))
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard isHTTPToken(name) else {
                return .failure(errorResponse(400, "请求头名称无效", "invalid_request_headers"))
            }
            let normalizedName = name.lowercased()
            if let existingValue = headers[normalizedName] {
                guard !unambiguousHeaders.contains(normalizedName) else {
                    return .failure(errorResponse(400, name + " 不能重复", "ambiguous_request_headers"))
                }
                headers[normalizedName] = existingValue + ", " + value
            } else {
                headers[normalizedName] = value
            }
            switch normalizedName {
            case "content-length": contentLengths.append(value)
            case "transfer-encoding": transferEncodings.append(value)
            default: break
            }
        }

        guard headers["x-modelhub-request-id"] == nil || headers["x-request-id"] == nil else {
            return .failure(errorResponse(
                400,
                "X-ModelHub-Request-ID 与 X-Request-ID 不能同时出现",
                "ambiguous_request_id"
            ))
        }

        guard !(contentLengths.isEmpty == false && transferEncodings.isEmpty == false) else {
            return .failure(errorResponse(400, "Content-Length 与 Transfer-Encoding 不能同时出现", "ambiguous_request_body"))
        }
        guard contentLengths.count <= 1 else {
            return .failure(errorResponse(400, "Content-Length 不能重复", "ambiguous_content_length"))
        }

        let bodyMode: HTTPParsedRequestHead.BodyMode
        if let transferEncoding = transferEncodings.first {
            guard transferEncodings.count == 1,
                  transferEncoding
                    .split(separator: ",")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    == ["chunked"]
            else {
                return .failure(errorResponse(501, "仅支持 chunked Transfer-Encoding", "unsupported_transfer_encoding"))
            }
            bodyMode = .chunked
        } else if let contentLengthText = contentLengths.first {
            guard let contentLength = Int(contentLengthText), contentLength >= 0 else {
                return .failure(errorResponse(400, "Content-Length 必须是非负整数", "invalid_content_length"))
            }
            guard contentLength <= maximumBodyBytes else {
                return .failure(errorResponse(413, "请求体超过 32 MiB", "request_too_large"))
            }
            bodyMode = .contentLength(contentLength)
        } else {
            bodyMode = .none
        }

        return .head(
            HTTPParsedRequestHead(
                method: parts[0].uppercased(),
                target: parts[1],
                headers: headers,
                bodyMode: bodyMode
            )
        )
    }

    fileprivate func makeRequest(
        method: String,
        target: String,
        headers: [String: String],
        body: Data
    ) -> HTTPRequestParseResult {
        guard let components = URLComponents(string: target),
              components.scheme == nil,
              components.host == nil,
              components.fragment == nil,
              target.hasPrefix("/")
        else {
            return .failure(errorResponse(400, "请求目标必须是本机绝对路径", "invalid_request_target"))
        }
        guard let orderedQueryItems = parseQueryItems(components.percentEncodedQuery) else {
            return .failure(errorResponse(400, "查询参数编码无效", "invalid_query_string"))
        }
        let queryItems = Dictionary(
            orderedQueryItems.map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        return .request(
            HTTPRequest(
                method: method,
                path: components.path,
                queryItems: queryItems,
                orderedQueryItems: orderedQueryItems,
                headers: headers,
                body: body
            )
        )
    }

    private func parseQueryItems(_ percentEncodedQuery: String?) -> [HTTPQueryItem]? {
        guard let percentEncodedQuery, !percentEncodedQuery.isEmpty else { return [] }
        var items: [HTTPQueryItem] = []
        for pair in percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = String(parts[0]).removingPercentEncoding else { return nil }
            let value: String?
            if parts.count == 2 {
                guard let decodedValue = String(parts[1]).removingPercentEncoding else { return nil }
                value = decodedValue
            } else {
                value = nil
            }
            items.append(HTTPQueryItem(name: name, value: value))
        }
        return items
    }

    fileprivate func errorResponse(_ statusCode: Int, _ message: String, _ code: String) -> HTTPResponse {
        .json(
            statusCode: statusCode,
            object: ["error": ["message": message, "type": code, "code": code]]
        )
    }

    private func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value > 31 && $0.value != 127 && !separators.contains($0)
        }
    }

}

private struct HTTPParsedRequestHead {
    enum BodyMode {
        case none
        case contentLength(Int)
        case chunked
    }

    let method: String
    let target: String
    let headers: [String: String]
    let bodyMode: BodyMode
}

private enum HTTPRequestHeadParseResult {
    case head(HTTPParsedRequestHead)
    case failure(HTTPResponse)
}

final class HTTPRequestStreamParser: @unchecked Sendable {
    private let parser: HTTPRequestParser
    private let headerSeparator = Data("\r\n\r\n".utf8)
    private let lineSeparator = Data("\r\n".utf8)
    private let trailerSeparator = Data("\r\n\r\n".utf8)
    private var buffer = Data()
    private var headerSearchOffset = 0
    private var head: HTTPParsedRequestHead?
    private var terminalResult: HTTPRequestParseResult?

    private var decodedChunkedBody = Data()
    private var chunkCursor = 0
    private var chunkSizeSearchOffset = 0
    private var pendingChunkSize: Int?
    private var readingTrailers = false
    private var trailerSearchOffset = 0

    private(set) var parsedHeaderCount = 0

    init(parser: HTTPRequestParser) {
        self.parser = parser
    }

    var bufferedByteCount: Int {
        guard let head else { return buffer.count }
        switch head.bodyMode {
        case .none:
            return 0
        case .contentLength:
            return buffer.count
        case .chunked:
            return decodedChunkedBody.count + max(0, buffer.count - chunkCursor)
        }
    }

    func append(_ fragment: Data) -> HTTPRequestParseResult {
        if let terminalResult { return terminalResult }
        if !fragment.isEmpty { buffer.append(fragment) }

        if head == nil {
            return parseHeaderIfPossible()
        }
        return parseBodyIfPossible()
    }

    private func parseHeaderIfPossible() -> HTTPRequestParseResult {
        let searchStart = min(headerSearchOffset, buffer.endIndex)
        guard let headerRange = buffer.range(
            of: headerSeparator,
            in: searchStart..<buffer.endIndex
        ) else {
            if buffer.count > parser.maximumHeaderBytes {
                return finish(.failure(parser.errorResponse(
                    431,
                    "请求头超过 64 KiB",
                    "request_headers_too_large"
                )))
            }
            headerSearchOffset = max(buffer.startIndex, buffer.endIndex - (headerSeparator.count - 1))
            return .incomplete
        }
        guard headerRange.lowerBound <= parser.maximumHeaderBytes else {
            return finish(.failure(parser.errorResponse(
                431,
                "请求头超过 64 KiB",
                "request_headers_too_large"
            )))
        }

        parsedHeaderCount += 1
        switch parser.parseHead(Data(buffer[..<headerRange.lowerBound])) {
        case .failure(let response):
            return finish(.failure(response))
        case .head(let parsedHead):
            head = parsedHead
            buffer = Data(buffer[headerRange.upperBound...])
            headerSearchOffset = 0
            return parseBodyIfPossible()
        }
    }

    private func parseBodyIfPossible() -> HTTPRequestParseResult {
        guard let head else { return .incomplete }
        switch head.bodyMode {
        case .none:
            return complete(head: head, body: Data())
        case .contentLength(let contentLength):
            guard buffer.count >= contentLength else { return .incomplete }
            return complete(head: head, body: Data(buffer.prefix(contentLength)))
        case .chunked:
            return parseChunkedBody(head: head)
        }
    }

    private func parseChunkedBody(head: HTTPParsedRequestHead) -> HTTPRequestParseResult {
        while true {
            if readingTrailers {
                guard buffer.count >= chunkCursor + lineSeparator.count else { return .incomplete }
                if buffer[chunkCursor..<(chunkCursor + lineSeparator.count)] == lineSeparator {
                    return complete(head: head, body: decodedChunkedBody)
                }
                let searchStart = min(max(chunkCursor, trailerSearchOffset), buffer.endIndex)
                guard buffer.range(
                    of: trailerSeparator,
                    in: searchStart..<buffer.endIndex
                ) != nil else {
                    trailerSearchOffset = max(chunkCursor, buffer.endIndex - (trailerSeparator.count - 1))
                    return .incomplete
                }
                return complete(head: head, body: decodedChunkedBody)
            }

            if pendingChunkSize == nil {
                let searchStart = min(max(chunkCursor, chunkSizeSearchOffset), buffer.endIndex)
                guard let sizeLineRange = buffer.range(
                    of: lineSeparator,
                    in: searchStart..<buffer.endIndex
                ) else {
                    chunkSizeSearchOffset = max(chunkCursor, buffer.endIndex - (lineSeparator.count - 1))
                    return .incomplete
                }
                guard let rawSizeLine = String(
                    data: buffer[chunkCursor..<sizeLineRange.lowerBound],
                    encoding: .ascii
                ) else {
                    return finish(.failure(parser.errorResponse(
                        400,
                        "Chunk 大小行无效",
                        "invalid_chunked_body"
                    )))
                }
                let sizeText = rawSizeLine
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sizeText.isEmpty,
                      let chunkSize = Int(sizeText, radix: 16),
                      chunkSize >= 0
                else {
                    return finish(.failure(parser.errorResponse(
                        400,
                        "Chunk 大小无效",
                        "invalid_chunked_body"
                    )))
                }
                guard chunkSize <= parser.maximumBodyBytes - decodedChunkedBody.count else {
                    return finish(.failure(parser.errorResponse(
                        413,
                        "请求体超过 32 MiB",
                        "request_too_large"
                    )))
                }

                chunkCursor = sizeLineRange.upperBound
                chunkSizeSearchOffset = chunkCursor
                if chunkSize == 0 {
                    readingTrailers = true
                    trailerSearchOffset = chunkCursor
                    continue
                }
                pendingChunkSize = chunkSize
            }

            guard let chunkSize = pendingChunkSize,
                  buffer.count >= chunkCursor + chunkSize + lineSeparator.count
            else {
                return .incomplete
            }
            let chunkEnd = chunkCursor + chunkSize
            guard buffer[chunkEnd..<(chunkEnd + lineSeparator.count)] == lineSeparator else {
                return finish(.failure(parser.errorResponse(
                    400,
                    "Chunk 结尾无效",
                    "invalid_chunked_body"
                )))
            }
            decodedChunkedBody.append(buffer[chunkCursor..<chunkEnd])
            chunkCursor = chunkEnd + lineSeparator.count
            chunkSizeSearchOffset = chunkCursor
            pendingChunkSize = nil
            compactChunkBufferIfNeeded()
        }
    }

    private func compactChunkBufferIfNeeded() {
        guard chunkCursor >= 64 * 1_024,
              chunkCursor >= buffer.count / 2
        else { return }
        buffer = Data(buffer[chunkCursor...])
        chunkCursor = 0
        chunkSizeSearchOffset = 0
    }

    private func complete(head: HTTPParsedRequestHead, body: Data) -> HTTPRequestParseResult {
        finish(parser.makeRequest(
            method: head.method,
            target: head.target,
            headers: head.headers,
            body: body
        ))
    }

    private func finish(_ result: HTTPRequestParseResult) -> HTTPRequestParseResult {
        terminalResult = result
        return result
    }
}

final class LocalAPIServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    typealias StreamHandler = @Sendable (HTTPRequest) async -> HTTPStreamResponse?

    private let queue = DispatchQueue(label: "com.local.modelhub.http-server")
    private let handler: Handler
    private let streamHandler: StreamHandler?
    private let connectionPolicy: HTTPServerConnectionPolicy
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var idleTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var absoluteRequestTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let requestParser = HTTPRequestParser()
    private let maximumBufferedBytes = 33 * 1_024 * 1_024

    init(
        handler: @escaping Handler,
        streamHandler: StreamHandler? = nil,
        connectionPolicy: HTTPServerConnectionPolicy = HTTPServerConnectionPolicy()
    ) {
        self.handler = handler
        self.streamHandler = streamHandler
        self.connectionPolicy = connectionPolicy
    }

    func start(port: UInt16, stateChanged: @escaping @Sendable (Result<UInt16, Error>) -> Void) throws {
        stop()
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpointPort
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let actualPort: UInt16
                if let readyPort = listener.port {
                    actualPort = readyPort.rawValue
                } else {
                    actualPort = port
                }
                stateChanged(.success(actualPort))
            case .failed(let error):
                stateChanged(.failure(error))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            idleTimeouts.values.forEach { $0.cancel() }
            idleTimeouts.removeAll()
            absoluteRequestTimeouts.values.forEach { $0.cancel() }
            absoluteRequestTimeouts.removeAll()
            connectionTasks.values.forEach { $0.cancel() }
            connectionTasks.removeAll()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connectionPolicy.admits(activeConnectionCount: connections.count) else {
            connection.start(queue: queue)
            send(
                HTTPResponse.json(
                    statusCode: 503,
                    object: [
                        "error": [
                            "message": "活动连接已达上限",
                            "type": "connection_limit_exceeded",
                            "code": "connection_limit_exceeded"
                        ]
                    ]
                ).addingRequestID(UUID().uuidString),
                on: connection
            )
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        scheduleAbsoluteTimeout(
            for: connection,
            after: connectionPolicy.absoluteRequestDeadline,
            reason: .absoluteRequestDeadline
        )
        refreshIdleTimeout(for: connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.removeConnection(identifier)
            } else if case .cancelled = state {
                self?.removeConnection(identifier)
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: requestParser.makeStreamParser())
    }

    private func scheduleAbsoluteTimeout(
        for connection: NWConnection,
        after deadline: TimeInterval,
        reason: HTTPServerConnectionPolicy.TimeoutReason
    ) {
        let identifier = ObjectIdentifier(connection)
        absoluteRequestTimeouts.removeValue(forKey: identifier)?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.expireRequest(
                identifier: identifier,
                connection: connection,
                reason: reason
            )
        }
        absoluteRequestTimeouts[identifier] = timeout
        queue.asyncAfter(
            deadline: .now() + deadline,
            execute: timeout
        )
    }

    private func refreshIdleTimeout(
        for connection: NWConnection,
        after deadline: TimeInterval? = nil,
        reason: HTTPServerConnectionPolicy.TimeoutReason = .idle
    ) {
        let identifier = ObjectIdentifier(connection)
        idleTimeouts.removeValue(forKey: identifier)?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.expireRequest(identifier: identifier, connection: connection, reason: reason)
        }
        idleTimeouts[identifier] = timeout
        queue.asyncAfter(
            deadline: .now() + (deadline ?? connectionPolicy.idleTimeout),
            execute: timeout
        )
    }

    private func expireRequest(
        identifier: ObjectIdentifier,
        connection: NWConnection,
        reason _: HTTPServerConnectionPolicy.TimeoutReason
    ) {
        guard connections[identifier] != nil else { return }
        removeConnection(identifier)
        connection.cancel()
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestStreamParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            let identifier = ObjectIdentifier(connection)
            guard self.connections[identifier] != nil else { return }
            if let data, !data.isEmpty {
                self.refreshIdleTimeout(for: connection)
            }
            let parseResult = parser.append(data ?? Data())
            guard parser.bufferedByteCount <= self.maximumBufferedBytes else {
                let response = HTTPResponse.json(
                    statusCode: 413,
                    object: ["error": ["message": "请求体超过 32 MiB", "type": "request_too_large"]]
                ).addingRequestID(UUID().uuidString)
                self.cancelRequestTimeouts(for: connection)
                self.send(response, on: connection)
                return
            }

            switch parseResult {
            case .request(let request):
                self.cancelRequestTimeouts(for: connection)
                self.scheduleAbsoluteTimeout(
                    for: connection,
                    after: self.connectionPolicy.handlerDeadline,
                    reason: .handlerDeadline
                )
                let identifier = ObjectIdentifier(connection)
                let task = Task { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    if let streamHandler = self.streamHandler,
                       let response = await streamHandler(request)
                    {
                        guard await self.transitionToStreaming(connection) else { return }
                        await self.send(response.addingRequestID(request.requestID), on: connection)
                    } else {
                        let response = await self.handler(request)
                        guard !Task.isCancelled else { return }
                        self.queue.async { [weak self, weak connection] in
                            guard let self, let connection,
                                  self.connections[identifier] != nil
                            else { return }
                            self.cancelRequestTimeouts(for: connection)
                            self.send(response.addingRequestID(request.requestID), on: connection)
                        }
                    }
                }
                self.connectionTasks[identifier] = task
                return
            case .failure(let response):
                self.cancelRequestTimeouts(for: connection)
                self.send(response.addingRequestID(UUID().uuidString), on: connection)
                return
            case .incomplete:
                break
            }

            if error != nil {
                connection.cancel()
                return
            }
            if isComplete {
                self.cancelRequestTimeouts(for: connection)
                self.send(
                    .json(
                        statusCode: 400,
                        object: ["error": ["message": "请求数据不完整", "type": "incomplete_request"]]
                    ).addingRequestID(UUID().uuidString),
                    on: connection
                )
                return
            }
            self.receive(on: connection, parser: parser)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ response: HTTPStreamResponse, on connection: NWConnection) async {
        do {
            try await sendData(response.serializedHead(), on: connection)
            for try await bodyChunk in response.body {
                try Task.checkCancellation()
                guard !bodyChunk.isEmpty else { continue }
                var framed = Data(String(bodyChunk.count, radix: 16).utf8)
                framed.append(Data("\r\n".utf8))
                framed.append(bodyChunk)
                framed.append(Data("\r\n".utf8))
                try await sendData(framed, on: connection)
            }
            try await sendData(Data("0\r\n\r\n".utf8), on: connection)
        } catch {
            // Once headers are sent, cancellation/transport errors end the stream without a second response.
        }
        connection.cancel()
    }

    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    if let self, let connection {
                        self.refreshIdleTimeout(
                            for: connection,
                            after: self.connectionPolicy.streamIdleTimeout,
                            reason: .streamIdle
                        )
                    }
                    continuation.resume()
                }
            })
        }
    }

    private func transitionToStreaming(_ connection: NWConnection) async -> Bool {
        let identifier = ObjectIdentifier(connection)
        return await withCheckedContinuation { continuation in
            queue.async { [weak self, weak connection] in
                guard let self, let connection,
                      self.connections[identifier] != nil
                else {
                    continuation.resume(returning: false)
                    return
                }
                self.cancelRequestTimeouts(for: connection)
                self.scheduleAbsoluteTimeout(
                    for: connection,
                    after: self.connectionPolicy.maximumStreamDuration,
                    reason: .maximumStreamDuration
                )
                self.refreshIdleTimeout(
                    for: connection,
                    after: self.connectionPolicy.streamIdleTimeout,
                    reason: .streamIdle
                )
                continuation.resume(returning: true)
            }
        }
    }

    private func cancelRequestTimeouts(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        idleTimeouts.removeValue(forKey: identifier)?.cancel()
        absoluteRequestTimeouts.removeValue(forKey: identifier)?.cancel()
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        idleTimeouts.removeValue(forKey: identifier)?.cancel()
        absoluteRequestTimeouts.removeValue(forKey: identifier)?.cancel()
        connectionTasks.removeValue(forKey: identifier)?.cancel()
        connections.removeValue(forKey: identifier)
    }
}
