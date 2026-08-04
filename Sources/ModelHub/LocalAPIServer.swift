import Foundation
@preconcurrency import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let queryItems: [String: String]
    let orderedQueryItems: [HTTPQueryItem]
    let headers: [String: String]
    let body: Data

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

    func serialized() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
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

    func serializedHead() -> Data {
        var allHeaders = headers
        allHeaders["Transfer-Encoding"] = "chunked"
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-cache"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
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
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes
                ? .failure(errorResponse(431, "请求头超过 64 KiB", "request_headers_too_large"))
                : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else {
            return .failure(errorResponse(431, "请求头超过 64 KiB", "request_headers_too_large"))
        }
        guard let headerText = String(
            data: data[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
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
        let unambiguousHeaders = Set(["authorization", "content-length", "host", "transfer-encoding"])
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

        guard !(contentLengths.isEmpty == false && transferEncodings.isEmpty == false) else {
            return .failure(errorResponse(400, "Content-Length 与 Transfer-Encoding 不能同时出现", "ambiguous_request_body"))
        }
        guard contentLengths.count <= 1 else {
            return .failure(errorResponse(400, "Content-Length 不能重复", "ambiguous_content_length"))
        }

        let bodyResult: BodyParseResult
        if let transferEncoding = transferEncodings.first {
            guard transferEncodings.count == 1,
                  transferEncoding
                    .split(separator: ",")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    == ["chunked"]
            else {
                return .failure(errorResponse(501, "仅支持 chunked Transfer-Encoding", "unsupported_transfer_encoding"))
            }
            bodyResult = parseChunkedBody(Data(data[headerRange.upperBound...]))
        } else if let contentLengthText = contentLengths.first {
            guard let contentLength = Int(contentLengthText), contentLength >= 0 else {
                return .failure(errorResponse(400, "Content-Length 必须是非负整数", "invalid_content_length"))
            }
            guard contentLength <= maximumBodyBytes else {
                return .failure(errorResponse(413, "请求体超过 32 MiB", "request_too_large"))
            }
            let bodyStart = headerRange.upperBound
            guard data.count >= bodyStart + contentLength else { return .incomplete }
            bodyResult = .body(data.subdata(in: bodyStart..<(bodyStart + contentLength)))
        } else {
            bodyResult = .body(Data())
        }

        switch bodyResult {
        case .incomplete:
            return .incomplete
        case .failure(let response):
            return .failure(response)
        case .body(let body):
            return makeRequest(
                method: parts[0].uppercased(),
                target: parts[1],
                headers: headers,
                body: body
            )
        }
    }

    private func parseChunkedBody(_ encoded: Data) -> BodyParseResult {
        let lineSeparator = Data("\r\n".utf8)
        let trailerSeparator = Data("\r\n\r\n".utf8)
        var cursor = encoded.startIndex
        var decoded = Data()

        while true {
            guard let sizeLineRange = encoded.range(
                of: lineSeparator,
                in: cursor..<encoded.endIndex
            ) else { return .incomplete }
            guard let rawSizeLine = String(
                data: encoded[cursor..<sizeLineRange.lowerBound],
                encoding: .ascii
            ) else {
                return .failure(errorResponse(400, "Chunk 大小行无效", "invalid_chunked_body"))
            }
            let sizeText = rawSizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sizeText.isEmpty, let chunkSize = Int(sizeText, radix: 16), chunkSize >= 0 else {
                return .failure(errorResponse(400, "Chunk 大小无效", "invalid_chunked_body"))
            }
            cursor = sizeLineRange.upperBound

            if chunkSize == 0 {
                guard encoded.count >= cursor + lineSeparator.count else { return .incomplete }
                if encoded[cursor..<(cursor + lineSeparator.count)] == lineSeparator {
                    return .body(decoded)
                }
                guard encoded.range(of: trailerSeparator, in: cursor..<encoded.endIndex) != nil else {
                    return .incomplete
                }
                return .body(decoded)
            }

            guard decoded.count <= maximumBodyBytes - chunkSize else {
                return .failure(errorResponse(413, "请求体超过 32 MiB", "request_too_large"))
            }
            guard encoded.count >= cursor + chunkSize + lineSeparator.count else {
                return .incomplete
            }
            let chunkEnd = cursor + chunkSize
            guard encoded[chunkEnd..<(chunkEnd + lineSeparator.count)] == lineSeparator else {
                return .failure(errorResponse(400, "Chunk 结尾无效", "invalid_chunked_body"))
            }
            decoded.append(encoded[cursor..<chunkEnd])
            cursor = chunkEnd + lineSeparator.count
        }
    }

    private func makeRequest(
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

    private func errorResponse(_ statusCode: Int, _ message: String, _ code: String) -> HTTPResponse {
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

    private enum BodyParseResult {
        case incomplete
        case body(Data)
        case failure(HTTPResponse)
    }
}

final class LocalAPIServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    typealias StreamHandler = @Sendable (HTTPRequest) async -> HTTPStreamResponse?

    private let queue = DispatchQueue(label: "com.local.modelhub.http-server")
    private let handler: Handler
    private let streamHandler: StreamHandler?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let requestParser = HTTPRequestParser()
    private let maximumBufferedBytes = 33 * 1_024 * 1_024
    private let requestTimeout: TimeInterval = 30

    init(handler: @escaping Handler, streamHandler: StreamHandler? = nil) {
        self.handler = handler
        self.streamHandler = streamHandler
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
            connectionTimeouts.values.forEach { $0.cancel() }
            connectionTimeouts.removeAll()
            connectionTasks.values.forEach { $0.cancel() }
            connectionTasks.removeAll()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        refreshTimeout(for: connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.removeConnection(identifier)
            } else if case .cancelled = state {
                self?.removeConnection(identifier)
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func refreshTimeout(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: identifier)?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            connection?.cancel()
            self?.removeConnection(identifier)
        }
        connectionTimeouts[identifier] = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var updated = buffer
            if let data, !data.isEmpty {
                updated.append(data)
                self.refreshTimeout(for: connection)
            }
            guard updated.count <= self.maximumBufferedBytes else {
                let response = HTTPResponse.json(
                    statusCode: 413,
                    object: ["error": ["message": "请求体超过 32 MiB", "type": "request_too_large"]]
                )
                self.send(response, on: connection)
                return
            }

            switch self.requestParser.parse(updated) {
            case .request(let request):
                self.cancelTimeout(for: connection)
                let identifier = ObjectIdentifier(connection)
                let task = Task { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    if let streamHandler = self.streamHandler,
                       let response = await streamHandler(request)
                    {
                        await self.send(response, on: connection)
                    } else {
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                }
                self.connectionTasks[identifier] = task
                return
            case .failure(let response):
                self.cancelTimeout(for: connection)
                self.send(response, on: connection)
                return
            case .incomplete:
                break
            }

            if error != nil {
                connection.cancel()
                return
            }
            if isComplete {
                self.cancelTimeout(for: connection)
                self.send(
                    .json(
                        statusCode: 400,
                        object: ["error": ["message": "请求数据不完整", "type": "incomplete_request"]]
                    ),
                    on: connection
                )
                return
            }
            self.receive(on: connection, buffer: updated)
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
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func cancelTimeout(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: identifier)?.cancel()
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        connectionTimeouts.removeValue(forKey: identifier)?.cancel()
        connectionTasks.removeValue(forKey: identifier)?.cancel()
        connections.removeValue(forKey: identifier)
    }
}
