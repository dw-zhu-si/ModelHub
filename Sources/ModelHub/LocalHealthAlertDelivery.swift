import Foundation
import ModelHubCore

#if canImport(UserNotifications)
import UserNotifications
#endif

enum LocalHealthNotificationAuthorization: Equatable, Sendable {
    case allowed
    case denied
    case notDetermined
}

struct LocalHealthNotification: Equatable, Sendable {
    var identifier: String
    var title: String
    var message: String
}

protocol LocalHealthNotificationSinking: Sendable {
    func authorizationStatus() async -> LocalHealthNotificationAuthorization
    func deliver(_ notification: LocalHealthNotification) async throws
}

enum LocalHealthAlertDeliveryOutcome: Equatable, Sendable {
    case delivered
    case skippedDisabled
    case skippedUnauthorized(LocalHealthNotificationAuthorization)
}

enum LocalHealthAlertNotificationMapper {
    static func map(_ alert: PassiveHealthAlert) -> LocalHealthNotification {
        let message: String
        switch alert.kind {
        case .failureRate:
            message = "检测到本地模型连接连续失败，请打开 ModelHub 查看详情。"
        case .highLatency:
            message = "检测到本地模型连接响应变慢，请打开 ModelHub 查看详情。"
        case .recovered:
            message = "本地模型连接已恢复，可在 ModelHub 中查看最近状态。"
        }

        return LocalHealthNotification(
            identifier: "modelhub.health.\(alert.id.uuidString)",
            title: "ModelHub 健康提醒",
            message: message
        )
    }
}

actor LocalHealthAlertDeliveryBridge {
    private let sink: any LocalHealthNotificationSinking
    private var isEnabled: Bool

    init(
        sink: any LocalHealthNotificationSinking,
        isEnabled: Bool = false
    ) {
        self.sink = sink
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func deliver(_ alert: PassiveHealthAlert) async throws -> LocalHealthAlertDeliveryOutcome {
        guard isEnabled else {
            return .skippedDisabled
        }

        let authorization = await sink.authorizationStatus()
        guard authorization == .allowed else {
            return .skippedUnauthorized(authorization)
        }

        try await sink.deliver(LocalHealthAlertNotificationMapper.map(alert))
        return .delivered
    }
}

#if canImport(UserNotifications)
final class UNLocalHealthNotificationSink: LocalHealthNotificationSinking, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func authorizationStatus() async -> LocalHealthNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func deliver(_ notification: LocalHealthNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.message
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}
#endif
