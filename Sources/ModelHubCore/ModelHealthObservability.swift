import Foundation

public struct ModelHealthRecoveryResult: Sendable, Equatable {
    public let records: [ModelHealthRecord]
    public let recoveredCount: Int

    public init(records: [ModelHealthRecord], recoveredCount: Int) {
        self.records = records
        self.recoveredCount = recoveredCount
    }
}

/// Safely withdraws legacy quarantines that were created by an explicit,
/// retryable URL transport error. Recovery never marks a model routable; it
/// returns the record to `unknown` until a successful probe or explicit local
/// trust decision provides new evidence.
public enum ModelHealthRecoveryPolicy {
    private static let recoveredDetailPrefix = "已撤销瞬态网络故障造成的隔离"
    private static let restoredDetail = "已根据健康活动恢复瞬态网络故障隔离，等待重新验证"
    private static let recoverableTransportCodes: Set<Int> = [
        URLError.timedOut.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.dnsLookupFailed.rawValue,
        URLError.notConnectedToInternet.rawValue,
        URLError.secureConnectionFailed.rawValue,
    ]

    public static func recoverableErrorCode(in record: ModelHealthRecord) -> Int? {
        guard record.status == .unavailable, record.statusCode == nil else { return nil }
        let normalized = record.detail.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard normalized.contains("网络错误")
                || normalized.contains("network error")
                || normalized.contains("nsurlerrordomain")
        else { return nil }

        return recoverableTransportCodes.sorted().first { code in
            normalized.contains("（\(code)）")
                || normalized.contains("(\(code))")
                || normalized.contains("code=\(code)")
                || normalized.contains(" \(code)")
        }
    }

    public static func isRecoverable(_ record: ModelHealthRecord) -> Bool {
        recoverableErrorCode(in: record) != nil
    }

    public static func isRecoveredPendingVerification(_ record: ModelHealthRecord) -> Bool {
        record.status == .unknown
            && (record.detail.hasPrefix(recoveredDetailPrefix)
                || record.detail == restoredDetail)
    }

    public static func isDeferredNativePendingVerification(
        _ record: ModelHealthRecord
    ) -> Bool {
        record.status == .unknown
            && record.detail.contains("尚未通过真实协议验证")
            && record.detail.contains("未自动发起可能计费")
    }

    public static func recovering(
        records: [ModelHealthRecord],
        providerID: UUID? = nil,
        at recoveredAt: Date = .now
    ) -> ModelHealthRecoveryResult {
        var recoveredCount = 0
        let recoveredRecords = records.map { record -> ModelHealthRecord in
            guard providerID == nil || record.providerID == providerID,
                  let errorCode = recoverableErrorCode(in: record)
            else { return record }

            recoveredCount += 1
            return ModelHealthRecord(
                providerID: record.providerID,
                model: record.model,
                status: .unknown,
                checkedAt: recoveredAt,
                latencyMilliseconds: nil,
                statusCode: nil,
                detail: "\(recoveredDetailPrefix)，等待重新验证（原错误 \(errorCode)）"
            )
        }
        return ModelHealthRecoveryResult(
            records: recoveredRecords,
            recoveredCount: recoveredCount
        )
    }

    /// Repairs records written by early recovery builds whose generic health
    /// migration converted `unknown` back to `unavailable` on restart. The
    /// activity timestamp and provider scope identify the exact recovered
    /// records without storing model IDs or raw errors in observability data.
    public static func restoringRecordedRecoveries(
        records: [ModelHealthRecord],
        activities: [ModelHealthActivity]
    ) -> [ModelHealthRecord] {
        var recoveries = activities.compactMap { activity -> RecordedRecovery? in
            guard activity.kind == .transientRecovery,
                  activity.recoveredToUnknown > 0
            else { return nil }
            return RecordedRecovery(
                providerID: activity.providerID,
                recoveredAt: activity.startedAt,
                remainingCount: activity.recoveredToUnknown
            )
        }
        guard !recoveries.isEmpty else { return records }

        return records.map { record in
            guard record.status == .unavailable, record.statusCode == nil else {
                return record
            }
            guard let recoveryIndex = recoveries.firstIndex(where: { recovery in
                recovery.remainingCount > 0
                    && recovery.recoveredAt == record.checkedAt
                    && (recovery.providerID == nil || recovery.providerID == record.providerID)
            }) else { return record }

            recoveries[recoveryIndex].remainingCount -= 1
            return ModelHealthRecord(
                providerID: record.providerID,
                model: record.model,
                status: .unknown,
                checkedAt: record.checkedAt,
                latencyMilliseconds: nil,
                statusCode: nil,
                detail: restoredDetail
            )
        }
    }

    private struct RecordedRecovery {
        let providerID: UUID?
        let recoveredAt: Date
        var remainingCount: Int
    }
}

public enum ModelHealthActivityKind: String, Codable, Sendable {
    case probe
    case transientRecovery
}

/// A bounded, secret-free activity summary. It deliberately stores counts and
/// provider UUIDs only: no API keys, URLs, request bodies, model output, or raw
/// upstream error messages are persisted.
public struct ModelHealthActivity: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ModelHealthActivityKind
    public var startedAt: Date
    public var completedAt: Date
    public var providerID: UUID?
    public var total: Int
    public var completed: Int
    public var available: Int
    public var unavailable: Int
    public var skipped: Int
    public var preservedAvailable: Int
    public var transientFailures: Int
    public var retryAttempts: Int
    public var circuitOpenedProviderIDs: [UUID]
    public var circuitSkipped: Int
    public var recoveredToUnknown: Int
    public var cancelled: Bool

    public init(
        id: UUID = UUID(),
        kind: ModelHealthActivityKind,
        startedAt: Date,
        completedAt: Date,
        providerID: UUID? = nil,
        total: Int = 0,
        completed: Int = 0,
        available: Int = 0,
        unavailable: Int = 0,
        skipped: Int = 0,
        preservedAvailable: Int = 0,
        transientFailures: Int = 0,
        retryAttempts: Int = 0,
        circuitOpenedProviderIDs: [UUID] = [],
        circuitSkipped: Int = 0,
        recoveredToUnknown: Int = 0,
        cancelled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.completedAt = max(startedAt, completedAt)
        self.providerID = providerID
        self.total = max(0, total)
        self.completed = max(0, completed)
        self.available = max(0, available)
        self.unavailable = max(0, unavailable)
        self.skipped = max(0, skipped)
        self.preservedAvailable = max(0, preservedAvailable)
        self.transientFailures = max(0, transientFailures)
        self.retryAttempts = max(0, retryAttempts)
        self.circuitOpenedProviderIDs = Array(
            Set(circuitOpenedProviderIDs)
                .sorted { $0.uuidString < $1.uuidString }
                .prefix(32)
        )
        self.circuitSkipped = max(0, circuitSkipped)
        self.recoveredToUnknown = max(0, recoveredToUnknown)
        self.cancelled = cancelled
    }
}

public enum ModelHealthActivityStore {
    public static let maximumCount = 50

    public static func appending(
        _ activity: ModelHealthActivity,
        to history: [ModelHealthActivity]
    ) -> [ModelHealthActivity] {
        normalized([activity] + history)
    }

    public static func normalized(
        _ history: [ModelHealthActivity]
    ) -> [ModelHealthActivity] {
        var seen = Set<UUID>()
        return Array(
            history
                .map(Self.sanitized)
                .sorted {
                    if $0.completedAt == $1.completedAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.completedAt > $1.completedAt
                }
                .filter { seen.insert($0.id).inserted }
                .prefix(maximumCount)
        )
    }

    private static func sanitized(_ activity: ModelHealthActivity) -> ModelHealthActivity {
        ModelHealthActivity(
            id: activity.id,
            kind: activity.kind,
            startedAt: activity.startedAt,
            completedAt: activity.completedAt,
            providerID: activity.providerID,
            total: activity.total,
            completed: activity.completed,
            available: activity.available,
            unavailable: activity.unavailable,
            skipped: activity.skipped,
            preservedAvailable: activity.preservedAvailable,
            transientFailures: activity.transientFailures,
            retryAttempts: activity.retryAttempts,
            circuitOpenedProviderIDs: activity.circuitOpenedProviderIDs,
            circuitSkipped: activity.circuitSkipped,
            recoveredToUnknown: activity.recoveredToUnknown,
            cancelled: activity.cancelled
        )
    }
}
