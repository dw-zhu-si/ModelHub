import Foundation

public enum NativeAPIOperation: String, CaseIterable, Codable, Sendable {
    case imageGeneration
    case videoGeneration
    case videoTask
    case speech
    case transcription
    case embeddings
    case reranking

    public var modelProtocol: ModelNativeProtocol {
        switch self {
        case .imageGeneration: .imageGeneration
        case .videoGeneration, .videoTask: .videoGeneration
        case .speech: .speech
        case .transcription: .transcription
        case .embeddings: .embeddings
        case .reranking: .reranking
        }
    }
}
