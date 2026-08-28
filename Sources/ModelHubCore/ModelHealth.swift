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
        self == .available
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

/// A stable, presentation-independent classification of why a model is not
/// routable. The UI can localize this value without exposing raw upstream
/// response bodies or credentials.
public enum ModelQuarantineCause: String, Codable, CaseIterable, Sendable {
    case notVerified
    case missingCredential
    case invalidCredential
    case insufficientPermission
    case invalidRequest
    case endpointOrModelNotFound
    case modelAccessNotConfigured
    case requestTimedOut
    case rateLimitedOrOutOfQuota
    case upstreamFailure
    case networkFailure
    case nativeVerificationRequired
    case unsupportedProtocol
    case unknownFailure
}

/// Describes only the age of the latest persisted verification. Freshness is
/// intentionally independent from availability so an old successful check can
/// be presented as a warning without silently removing a model from routing.
public enum ModelHealthFreshness: String, Codable, CaseIterable, Sendable {
    case fresh
    case stale
    case never
}

public struct ModelHealthFreshnessPolicy: Codable, Hashable, Sendable {
    /// Default warning window. Consumers may supply a different policy without
    /// changing the persisted availability or routing behavior.
    public static let defaultFreshWindow: TimeInterval = 24 * 60 * 60

    public var freshWindow: TimeInterval

    public init(freshWindow: TimeInterval = Self.defaultFreshWindow) {
        if freshWindow.isFinite {
            self.freshWindow = max(freshWindow, 0)
        } else {
            self.freshWindow = Self.defaultFreshWindow
        }
    }

    public func freshness(checkedAt: Date?, at now: Date) -> ModelHealthFreshness {
        guard let checkedAt else { return .never }
        return now.timeIntervalSince(checkedAt) <= freshWindow ? .fresh : .stale
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

    public var quarantineCause: ModelQuarantineCause? {
        guard status.isQuarantined else { return nil }

        switch status {
        case .available:
            return nil
        case .unknown:
            return .notVerified
        case .configurationRequired:
            if statusCode == 401 { return .invalidCredential }
            if statusCode == 403 { return .insufficientPermission }
            if statusCode == 404 { return .modelAccessNotConfigured }
            return .missingCredential
        case .unsupported:
            return .unsupportedProtocol
        case .unavailable:
            break
        }

        let normalizedDetail = detail.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if normalizedDetail.contains("model_not_found")
            || normalizedDetail.contains("modelnotfound")
            || normalizedDetail.contains("invalid_api_type")
            || normalizedDetail.contains("unsupported_model")
            || normalizedDetail.contains("unsupported model")
        {
            return .endpointOrModelNotFound
        }
        if normalizedDetail.contains("access_denied")
            || normalizedDetail.contains("permission_denied")
            || normalizedDetail.contains("insufficient permission")
        {
            return .insufficientPermission
        }
        if normalizedDetail.contains("get_channel_failed")
            || normalizedDetail.contains("video_queue_full")
            || normalizedDetail.contains("model_price_error")
            || normalizedDetail.contains("upstream_service")
        {
            return .upstreamFailure
        }
        if normalizedDetail.contains("invalid_parameter")
            || normalizedDetail.contains("invalid_request")
            || normalizedDetail.contains("parameter_error")
        {
            return .invalidRequest
        }
        if normalizedDetail.contains("invalid_api_key")
            || normalizedDetail.contains("authentication")
        {
            return .invalidCredential
        }
        if normalizedDetail.contains("rate_limit")
            || normalizedDetail.contains("quota")
            || normalizedDetail.contains("arrearage")
        {
            return .rateLimitedOrOutOfQuota
        }

        if let statusCode {
            switch statusCode {
            case 400, 409, 413, 422:
                return .invalidRequest
            case 401:
                return .invalidCredential
            case 403:
                return .insufficientPermission
            case 404, 410:
                return .endpointOrModelNotFound
            case 408, 504:
                return .requestTimedOut
            case 429:
                return .rateLimitedOrOutOfQuota
            case 500...599:
                return .upstreamFailure
            default:
                break
            }
        }

        if normalizedDetail.contains("api key") || normalizedDetail.contains("密钥") {
            return .missingCredential
        }
        if normalizedDetail.contains("尚未通过真实协议验证")
            || normalizedDetail.contains("未自动发起可能计费")
            || normalizedDetail.contains("native verification")
        {
            return .nativeVerificationRequired
        }
        if normalizedDetail.contains("timeout") || normalizedDetail.contains("timed out")
            || normalizedDetail.contains("超时")
        {
            return .requestTimedOut
        }
        if normalizedDetail.contains("network") || normalizedDetail.contains("网络")
            || normalizedDetail.contains("offline")
        {
            return .networkFailure
        }
        if normalizedDetail.contains("未测试") || normalizedDetail.contains("待验证")
            || normalizedDetail.contains("尚未完成真实验证")
        {
            return .notVerified
        }
        return .unknownFailure
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
        record(providerID: providerID, model: model)?.status ?? .unavailable
    }

    public func freshness(
        providerID: UUID,
        model: String,
        at now: Date,
        policy: ModelHealthFreshnessPolicy = .init()
    ) -> ModelHealthFreshness {
        policy.freshness(
            checkedAt: record(providerID: providerID, model: model)?.checkedAt,
            at: now
        )
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

/// Decides whether a normal gateway request has enough evidence to replace a
/// previously verified health record. Request-specific failures and transient
/// transport failures belong to resilience/fallback telemetry, not permanent
/// model quarantine.
public enum RuntimeHealthUpdatePolicy {
    public static func shouldPreserve(
        existing: ModelHealthRecord?,
        proposedStatus: ModelAvailability,
        statusCode: Int?,
        detail: String = "",
        isTransportFailure: Bool
    ) -> Bool {
        guard existing?.status == .available,
              proposedStatus != .available,
              proposedStatus != .configurationRequired
        else { return false }

        let proposedCause = ModelHealthRecord(
            providerID: existing?.providerID ?? UUID(),
            model: existing?.model ?? "runtime-update",
            status: proposedStatus,
            statusCode: statusCode,
            detail: detail
        ).quarantineCause
        if proposedCause == .endpointOrModelNotFound
            || proposedCause == .unsupportedProtocol
        {
            return false
        }
        if isTransportFailure { return true }
        guard let statusCode else { return false }
        switch statusCode {
        case 400, 408, 409, 413, 422, 429, 500...599:
            return true
        default:
            return false
        }
    }
}
