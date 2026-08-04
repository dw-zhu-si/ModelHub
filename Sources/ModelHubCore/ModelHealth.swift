import Foundation

public enum ModelAvailability: String, Codable, CaseIterable, Sendable {
    case unknown
    case available
    case unavailable
    case configurationRequired
    case unsupported

    public var routingRank: Int {
        switch self {
        case .available: 0
        case .unknown: 1
        case .unavailable: 2
        case .configurationRequired: 3
        case .unsupported: 4
        }
    }

    public var isRoutable: Bool {
        self == .available || self == .unknown
    }

    public var isQuarantined: Bool {
        !isRoutable
    }

    public init(statusCode: Int) {
        switch statusCode {
        case 200..<300:
            self = .available
        case 401, 403:
            self = .configurationRequired
        default:
            self = .unavailable
        }
    }
}

public struct ModelHealthRecord: Codable, Hashable, Identifiable, Sendable {
    public var providerID: UUID
    public var model: String
    public var status: ModelAvailability
    public var checkedAt: Date
    public var latencyMilliseconds: Int?
    public var statusCode: Int?
    public var detail: String

    public var id: String {
        "\(providerID.uuidString.lowercased())/\(model.lowercased())"
    }

    public init(
        providerID: UUID,
        model: String,
        status: ModelAvailability,
        checkedAt: Date = .now,
        latencyMilliseconds: Int? = nil,
        statusCode: Int? = nil,
        detail: String = ""
    ) {
        self.providerID = providerID
        self.model = model
        self.status = status
        self.checkedAt = checkedAt
        self.latencyMilliseconds = latencyMilliseconds
        self.statusCode = statusCode
        self.detail = detail
    }
}

public struct ModelHealthIndex: Sendable {
    private struct Key: Hashable, Sendable {
        let providerID: UUID
        let model: String
    }

    private var recordsByKey: [Key: ModelHealthRecord]

    public init(records: [ModelHealthRecord]) {
        var indexed: [Key: ModelHealthRecord] = [:]
        indexed.reserveCapacity(records.count)
        for record in records {
            let key = Self.key(providerID: record.providerID, model: record.model)
            if let current = indexed[key], current.checkedAt > record.checkedAt {
                continue
            }
            indexed[key] = record
        }
        recordsByKey = indexed
    }

    public func record(providerID: UUID, model: String) -> ModelHealthRecord? {
        recordsByKey[Self.key(providerID: providerID, model: model)]
    }

    public func status(providerID: UUID, model: String) -> ModelAvailability {
        record(providerID: providerID, model: model)?.status ?? .unknown
    }

    public mutating func upsert(_ record: ModelHealthRecord) {
        recordsByKey[Self.key(providerID: record.providerID, model: record.model)] = record
    }

    public func order(models: [String], providerID: UUID) -> [String] {
        models.enumerated()
            .sorted { lhs, rhs in
                let leftRank = status(providerID: providerID, model: lhs.element).routingRank
                let rightRank = status(providerID: providerID, model: rhs.element).routingRank
                if leftRank == rightRank { return lhs.offset < rhs.offset }
                return leftRank < rightRank
            }
            .map(\.element)
    }

    public func order(targets: [RouteTarget]) -> [RouteTarget] {
        targets.enumerated()
            .sorted { lhs, rhs in
                let leftRank = status(
                    providerID: lhs.element.providerID,
                    model: lhs.element.model
                ).routingRank
                let rightRank = status(
                    providerID: rhs.element.providerID,
                    model: rhs.element.model
                ).routingRank
                if leftRank == rightRank { return lhs.offset < rhs.offset }
                return leftRank < rightRank
            }
            .map(\.element)
    }

    private static func key(providerID: UUID, model: String) -> Key {
        Key(
            providerID: providerID,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
