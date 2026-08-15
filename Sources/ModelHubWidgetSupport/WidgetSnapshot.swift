import Foundation

public struct ModelHubWidgetSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var isServerRunning: Bool
    public var endpoint: String
    public var providerCount: Int
    public var routeCount: Int
    public var availableModelCount: Int
    public var totalRequests: Int
    public var successfulRequests: Int

    public init(
        updatedAt: Date = Date(),
        isServerRunning: Bool,
        endpoint: String,
        providerCount: Int,
        routeCount: Int,
        availableModelCount: Int,
        totalRequests: Int,
        successfulRequests: Int
    ) {
        self.updatedAt = updatedAt
        self.isServerRunning = isServerRunning
        self.endpoint = endpoint
        self.providerCount = providerCount
        self.routeCount = routeCount
        self.availableModelCount = availableModelCount
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
    }

    public var successRate: Int? {
        guard totalRequests > 0 else { return nil }
        return Int((Double(successfulRequests) / Double(totalRequests)) * 100)
    }

    public static let placeholder = ModelHubWidgetSnapshot(
        updatedAt: Date(),
        isServerRunning: true,
        endpoint: "127.0.0.1:11435/v1",
        providerCount: 3,
        routeCount: 2,
        availableModelCount: 12,
        totalRequests: 128,
        successfulRequests: 124
    )
}

public enum ModelHubWidgetSnapshotStore {
    public static let appGroupIdentifier = "L4G2HAQ5B5.com.local.modelhub"
    public static let widgetKind = "ModelHubStatusWidget"
    public static let filename = "widget-status.json"

    public static func load(fileManager: FileManager = .default) -> ModelHubWidgetSnapshot? {
        guard let url = snapshotURL(fileManager: fileManager) else { return nil }
        return try? load(from: url)
    }

    @discardableResult
    public static func save(
        _ snapshot: ModelHubWidgetSnapshot,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = snapshotURL(fileManager: fileManager) else { return false }
        do {
            try save(snapshot, to: url, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    static func load(from url: URL) throws -> ModelHubWidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ModelHubWidgetSnapshot.self, from: Data(contentsOf: url))
    }

    static func save(
        _ snapshot: ModelHubWidgetSnapshot,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // This status file is disposable and rebuilt by the host app. A plain
        // write avoids Foundation's protected atomic-temp-file path, which can
        // block indefinitely in an App Group container on some macOS systems.
        try encoder.encode(snapshot).write(to: url)
    }

    private static func snapshotURL(fileManager: FileManager) -> URL? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.appendingPathComponent(filename, isDirectory: false)
    }
}
