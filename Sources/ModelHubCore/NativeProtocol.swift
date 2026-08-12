import Foundation

public enum NativeAPIOperation: String, CaseIterable, Codable, Sendable {
    case imageGeneration
    case musicGeneration
    case musicTask
    case videoGeneration
    case videoTask
    case speech
    case transcription
    case embeddings
    case reranking

    public var modelProtocol: ModelNativeProtocol {
        switch self {
        case .imageGeneration: .imageGeneration
        case .musicGeneration, .musicTask: .musicGeneration
        case .videoGeneration, .videoTask: .videoGeneration
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        }
    }
}

public struct NativeGatewayMatch: Equatable, Sendable {
    public let operation: NativeAPIOperation
    public let taskID: String?

    public init(operation: NativeAPIOperation, taskID: String? = nil) {
        self.operation = operation
        self.taskID = taskID
    }
}

/// Single source of truth for ModelHub's additive native-generation routes.
/// Provider-specific URL selection remains separate and always uses an exact
/// saved endpoint or the exact saved Base URL.
public enum NativeGatewayRoute {
    public static func match(method: String, path: String) -> NativeGatewayMatch? {
        switch (method.uppercased(), path) {
        case ("POST", "/v1/images/generations"):
            return NativeGatewayMatch(operation: .imageGeneration)
        case ("POST", "/v1/music/generations"):
            return NativeGatewayMatch(operation: .musicGeneration)
        case ("POST", "/v1/videos/generations"), ("POST", "/v1/videos"):
            return NativeGatewayMatch(operation: .videoGeneration)
        case ("POST", "/v1/audio/speech"):
            return NativeGatewayMatch(operation: .speech)
        case ("POST", "/v1/audio/transcriptions"):
            return NativeGatewayMatch(operation: .transcription)
        case ("POST", "/v1/embeddings"):
            return NativeGatewayMatch(operation: .embeddings)
        case ("POST", "/v1/rerank"):
            return NativeGatewayMatch(operation: .reranking)
        default:
            break
        }

        guard method.caseInsensitiveCompare("GET") == .orderedSame else { return nil }
        if let taskID = taskID(path: path, prefixes: ["/v1/tasks/", "/v1/videos/"]) {
            return NativeGatewayMatch(operation: .videoTask, taskID: taskID)
        }
        if let taskID = taskID(path: path, prefixes: ["/v1/music/"]), taskID != "generations" {
            return NativeGatewayMatch(operation: .musicTask, taskID: taskID)
        }
        return nil
    }

    public static func allowedMethods(for path: String) -> [String]? {
        if match(method: "POST", path: path) != nil { return ["POST", "OPTIONS"] }
        if match(method: "GET", path: path) != nil { return ["GET", "OPTIONS"] }
        return nil
    }

    private static func taskID(path: String, prefixes: [String]) -> String? {
        for prefix in prefixes where path.hasPrefix(prefix) {
            let taskID = String(path.dropFirst(prefix.count))
            if !taskID.isEmpty { return taskID }
        }
        return nil
    }
}
