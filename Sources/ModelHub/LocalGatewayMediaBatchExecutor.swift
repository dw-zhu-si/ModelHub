import Foundation
import ModelHubCore

struct LocalGatewayMediaBatchPayload: Sendable {
    var createURL: URL
    var body: Data
    var modelID: String
}

enum LocalGatewayMediaBatchExecutorError: Error, Equatable {
    case payloadMissing
    case authorizationUnavailable
    case nonHTTPResponse
    case upstreamRejected(statusCode: Int)
    case invalidTaskResponse
    case unsupportedAsyncImageTask
    case responseTooLarge(limit: Int)
}

/// Executes batch jobs through ModelHub's own authenticated local gateway.
/// Request bodies are kept only in memory for the lifetime of a job; gateway
/// tokens are fetched just-in-time and are never stored in the queue metadata.
actor LocalGatewayMediaBatchExecutor: MediaBatchExecuting {
    typealias TokenProvider = @Sendable () async -> String

    private struct RuntimeState: Sendable {
        var payload: LocalGatewayMediaBatchPayload
        var immediateSuccess = false
        var result: MediaBatchResult?
    }

    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let maximumResponseBytes: Int
    private let resultDirectory: URL
    private var states: [UUID: RuntimeState] = [:]

    init(
        session: URLSession = URLSession(configuration: ProviderNetworkSession.directConfiguration()),
        maximumResponseBytes: Int = 4 * 1_024 * 1_024,
        resultDirectory: URL? = nil,
        tokenProvider: @escaping TokenProvider
    ) {
        self.session = session
        self.maximumResponseBytes = min(max(1, maximumResponseBytes), 16 * 1_024 * 1_024)
        self.resultDirectory = resultDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appending(path: "ModelHub/MediaBatchResults", directoryHint: .isDirectory)
            ?? URL(filePath: "/dev/null/ModelHub-MediaBatchResults", directoryHint: .isDirectory)
        self.tokenProvider = tokenProvider
    }

    func register(_ payload: LocalGatewayMediaBatchPayload, for id: UUID) {
        states[id] = RuntimeState(payload: payload)
    }

    func discard(id: UUID) {
        states.removeValue(forKey: id)
    }

    func create(_ metadata: MediaBatchMetadata) async throws -> String {
        guard var state = states[metadata.id] else {
            throw LocalGatewayMediaBatchExecutorError.payloadMissing
        }
        guard Self.isAllowedLocalGatewayURL(state.payload.createURL) else {
            throw LocalGatewayMediaBatchExecutorError.invalidTaskResponse
        }
        let response = try await send(
            url: state.payload.createURL,
            method: "POST",
            body: state.payload.body
        )
        guard (200..<300).contains(response.statusCode) else {
            throw LocalGatewayMediaBatchExecutorError.upstreamRejected(
                statusCode: response.statusCode
            )
        }

        // A synchronous generation may legitimately carry request/asset metadata.
        // A validated artifact is therefore authoritative before task semantics.
        if let result = try validatedResult(
            from: response.data,
            metadata: metadata
        ) {
            state.immediateSuccess = true
            state.result = result
            states[metadata.id] = state
            return "immediate-\(metadata.id.uuidString.lowercased())"
        }
        if let taskID = Self.taskID(from: response.data) {
            // The local gateway currently exposes task-query protocols only for
            // music and video. Accepting an asynchronous image task here would
            // make the queue report success without ever retrieving its image.
            guard metadata.kind != .image else {
                states.removeValue(forKey: metadata.id)
                throw LocalGatewayMediaBatchExecutorError.unsupportedAsyncImageTask
            }
            return taskID
        }
        throw LocalGatewayMediaBatchExecutorError.invalidTaskResponse
    }

    func poll(
        remoteTaskID: String,
        metadata: MediaBatchMetadata
    ) async throws -> MediaBatchRemoteState {
        guard let state = states[metadata.id] else {
            throw LocalGatewayMediaBatchExecutorError.payloadMissing
        }
        if state.immediateSuccess {
            return .succeeded
        }

        let path: String
        switch metadata.kind {
        case .image:
            throw LocalGatewayMediaBatchExecutorError.unsupportedAsyncImageTask
        case .music:
            path = "/v1/music/\(Self.pathComponent(remoteTaskID))"
        case .video:
            path = "/v1/videos/\(Self.pathComponent(remoteTaskID))"
        }
        guard var components = URLComponents(
            url: state.payload.createURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw LocalGatewayMediaBatchExecutorError.invalidTaskResponse
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "model", value: state.payload.modelID)]
        guard let url = components.url else {
            throw LocalGatewayMediaBatchExecutorError.invalidTaskResponse
        }
        let response = try await send(url: url, method: "GET", body: nil)
        guard (200..<300).contains(response.statusCode) else {
            throw LocalGatewayMediaBatchExecutorError.upstreamRejected(
                statusCode: response.statusCode
            )
        }
        if let result = try validatedResult(
            from: response.data,
            metadata: metadata
        ) {
            var updated = state
            updated.result = result
            states[metadata.id] = updated
            return .succeeded
        }
        switch Self.remoteState(from: response.data) {
        case .succeeded:
            // A completed task without a retrievable artifact is not usable.
            throw LocalGatewayMediaBatchExecutorError.invalidTaskResponse
        case .failed:
            states.removeValue(forKey: metadata.id)
            return .failed
        case .pending:
            return .pending
        }
    }

    func result(for metadata: MediaBatchMetadata) async -> MediaBatchResult? {
        defer { states.removeValue(forKey: metadata.id) }
        return states[metadata.id]?.result
    }

    private func send(url: URL, method: String, body: Data?) async throws -> (
        statusCode: Int,
        data: Data
    ) {
        let token = await tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw LocalGatewayMediaBatchExecutorError.authorizationUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalGatewayMediaBatchExecutorError.nonHTTPResponse
        }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw LocalGatewayMediaBatchExecutorError.responseTooLarge(
                limit: maximumResponseBytes
            )
        }
        var data = Data()
        data.reserveCapacity(min(
            maximumResponseBytes,
            max(0, Int(http.expectedContentLength))
        ))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw LocalGatewayMediaBatchExecutorError.responseTooLarge(
                    limit: maximumResponseBytes
                )
            }
            data.append(byte)
        }
        return (http.statusCode, data)
    }

    private func validatedResult(
        from data: Data,
        metadata: MediaBatchMetadata
    ) throws -> MediaBatchResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              !Self.containsTopLevelError(object)
        else { return nil }

        var artifacts: [MediaBatchArtifact] = []
        let remoteURLs = Self.findArtifactURLs(in: object, depth: 0)
        artifacts.append(contentsOf: remoteURLs.prefix(16).map {
            MediaBatchArtifact(remoteURL: $0)
        })

        if artifacts.isEmpty,
           let encoded = Self.findBase64Artifact(in: object, depth: 0),
           let bytes = Data(base64Encoded: encoded.value, options: [.ignoreUnknownCharacters]),
           !bytes.isEmpty,
           bytes.count <= maximumResponseBytes
        {
            let fileURL = try persistArtifact(
                bytes,
                metadata: metadata,
                mimeType: encoded.mimeType
            )
            artifacts.append(MediaBatchArtifact(
                localFileURL: fileURL,
                mimeType: encoded.mimeType,
                byteCount: bytes.count
            ))
        }
        return artifacts.isEmpty ? nil : MediaBatchResult(artifacts: artifacts)
    }

    private func persistArtifact(
        _ data: Data,
        metadata: MediaBatchMetadata,
        mimeType: String?
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: resultDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resultDirectory.path
        )
        let ext: String = switch mimeType?.lowercased() {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "audio/mpeg": "mp3"
        case "audio/wav": "wav"
        case "video/mp4": "mp4"
        default: "bin"
        }
        let url = resultDirectory.appending(
            path: "\(metadata.id.uuidString.lowercased()).\(ext)"
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func taskID(from data: Data) -> String? {
        guard data.count <= 4 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              !containsDeclaredFailure(dictionary)
        else { return nil }
        for container in taskResponseContainers(dictionary) {
            for key in ["task_id", "taskId"] {
                if let taskID = normalizedTaskID(container[key]) { return taskID }
            }
        }
        return nil
    }

    private static func remoteState(from data: Data) -> MediaBatchRemoteState {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return .pending }
        if containsDeclaredFailure(dictionary) { return .failed }
        let status = taskResponseContainers(dictionary).lazy.compactMap { container in
            for key in ["status", "state", "task_status", "taskStatus"] {
                if let value = container[key] as? String {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty { return normalized.lowercased() }
                }
            }
            return nil
        }.first
        guard let status else { return .pending }
        if ["success", "succeeded", "completed", "done", "finished"].contains(status) {
            return .succeeded
        }
        if ["failed", "error", "cancelled", "canceled", "rejected"].contains(status) {
            return .failed
        }
        return .pending
    }

    private static func containsTopLevelError(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else { return false }
        return containsDeclaredFailure(dictionary)
    }

    private static func containsDeclaredFailure(_ dictionary: [String: Any]) -> Bool {
        if let error = dictionary["error"], !(error is NSNull) { return true }
        if let success = dictionary["success"] as? Bool, !success { return true }
        if let baseResponse = dictionary["base_resp"] as? [String: Any],
           let statusCode = numericCode(baseResponse["status_code"]),
           statusCode != 0
        {
            return true
        }
        if let code = numericCode(dictionary["code"]),
           code != 0, !(200..<300).contains(code)
        {
            return true
        }
        return false
    }

    private static func numericCode(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// Only documented task-bearing envelopes are inspected. Generic `id` and
    /// `request_id` values are correlation or artifact identifiers, not tasks.
    private static func taskResponseContainers(
        _ dictionary: [String: Any]
    ) -> [[String: Any]] {
        var containers = [dictionary]
        if let output = dictionary["output"] as? [String: Any] {
            containers.append(output)
        }
        if let data = dictionary["data"] as? [String: Any] {
            containers.append(data)
        } else if let first = (dictionary["data"] as? [[String: Any]])?.first {
            containers.append(first)
        }
        return containers
    }

    private static func normalizedTaskID(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let taskID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty,
              taskID.utf8.count <= 2_000,
              taskID.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return taskID
    }

    private static func findArtifactURLs(in value: Any, depth: Int) -> [URL] {
        guard depth <= 16 else { return [] }
        let keys: Set<String> = [
            "url", "image_url", "imageUrl", "video_url", "videoUrl",
            "audio_url", "audioUrl", "file_url", "fileUrl", "download_url"
        ]
        var found: [URL] = []
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key), let raw = child as? String,
                   let url = URL(string: raw), url.scheme?.lowercased() == "https",
                   url.user == nil, url.password == nil, url.fragment == nil
                {
                    found.append(url)
                } else {
                    found.append(contentsOf: findArtifactURLs(in: child, depth: depth + 1))
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                found.append(contentsOf: findArtifactURLs(in: child, depth: depth + 1))
            }
        }
        return Array(found.prefix(16))
    }

    private static func findBase64Artifact(
        in value: Any,
        depth: Int
    ) -> (value: String, mimeType: String?)? {
        guard depth <= 16 else { return nil }
        if let dictionary = value as? [String: Any] {
            let mimeType = (dictionary["mime_type"] ?? dictionary["mimeType"]) as? String
            for key in ["b64_json", "base64", "base64_data"] {
                if let encoded = dictionary[key] as? String, !encoded.isEmpty {
                    return (encoded, mimeType)
                }
            }
            for child in dictionary.values {
                if let found = findBase64Artifact(in: child, depth: depth + 1) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findBase64Artifact(in: child, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func pathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(
                CharacterSet(charactersIn: "/?#")
            )
        ) ?? raw
    }

    private static func isAllowedLocalGatewayURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? ""),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port != nil
        else { return false }
        return [
            "/v1/images/generations",
            "/v1/music/generations",
            "/v1/videos/generations"
        ].contains(url.path)
    }
}
