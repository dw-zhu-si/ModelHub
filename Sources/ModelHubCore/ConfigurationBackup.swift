import Foundation

public struct ConfigurationBackupEnvelope: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let appVersion: String
    public let configuration: AppConfiguration

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = .now,
        appVersion: String,
        configuration: AppConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.configuration = configuration
    }
}

public struct ConfigurationBackupPreview: Equatable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let appVersion: String
    public let providerCount: Int
    public let routeCount: Int
    public let healthRecordCount: Int
    public let usageAggregateCount: Int
}

public enum ConfigurationBackupError: LocalizedError {
    case tooLarge
    case unsupportedVersion(Int)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "备份文件超过 10 MiB 上限"
        case .unsupportedVersion(let version): "不支持的备份版本：\(version)"
        case .invalidData: "备份文件无效或已损坏"
        }
    }
}

public enum ConfigurationBackup {
    public static let maximumBytes = 10 * 1_024 * 1_024

    public static func exportData(
        configuration: AppConfiguration,
        appVersion: String
    ) throws -> Data {
        let envelope = ConfigurationBackupEnvelope(
            appVersion: appVersion,
            configuration: configuration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumBytes else { throw ConfigurationBackupError.tooLarge }
        return data
    }

    public static func preview(_ data: Data) throws -> ConfigurationBackupPreview {
        let envelope = try decode(data)
        return ConfigurationBackupPreview(
            schemaVersion: envelope.schemaVersion,
            exportedAt: envelope.exportedAt,
            appVersion: envelope.appVersion,
            providerCount: envelope.configuration.providers.count,
            routeCount: envelope.configuration.routes.count,
            healthRecordCount: envelope.configuration.modelHealth.count,
            usageAggregateCount: envelope.configuration.usage.count
        )
    }

    public static func configuration(from data: Data) throws -> AppConfiguration {
        try decode(data).configuration
    }

    private static func decode(_ data: Data) throws -> ConfigurationBackupEnvelope {
        guard data.count <= maximumBytes else { throw ConfigurationBackupError.tooLarge }
        guard let envelope = try? JSONDecoder().decode(ConfigurationBackupEnvelope.self, from: data)
        else { throw ConfigurationBackupError.invalidData }
        guard envelope.schemaVersion == 1 else {
            throw ConfigurationBackupError.unsupportedVersion(envelope.schemaVersion)
        }
        return envelope
    }
}
