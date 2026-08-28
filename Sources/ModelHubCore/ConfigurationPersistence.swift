import Foundation

public enum ConfigurationPersistenceResult: Equatable, Sendable {
    case written(revision: UInt64)
    case skippedStale(revision: UInt64, latestRevision: UInt64)
}

/// Serializes configuration encoding and atomic filesystem writes away from
/// the UI actor. Revisions make late-arriving snapshots harmless: an older
/// snapshot can never overwrite a configuration that was already accepted.
public actor ConfigurationPersistence {
    private var latestRevision: UInt64 = 0

    public init() {}

    @discardableResult
    public func persist(
        _ configuration: AppConfiguration,
        revision: UInt64,
        to url: URL
    ) throws -> ConfigurationPersistenceResult {
        guard revision >= latestRevision else {
            return .skippedStale(revision: revision, latestRevision: latestRevision)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        latestRevision = revision
        return .written(revision: revision)
    }

    public func latestWrittenRevision() -> UInt64 {
        latestRevision
    }
}
