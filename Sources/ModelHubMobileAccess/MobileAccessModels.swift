import Foundation

public enum MobilePermissionScope: String, Codable, CaseIterable, Hashable, Sendable {
    case viewer
    case chat
    case `operator`
}

public enum MobileAccessError: Error, Equatable, Sendable {
    case invalidServiceURL
    case invalidCertificateFingerprint
    case pairingCapacityExceeded
    case pairingUnavailable
    case pairingExpired
    case invalidPairingSecret
    case invalidDeviceName
    case invalidPublicKey
    case deviceAlreadyPaired
    case deviceCapacityExceeded
    case unknownDevice
    case revokedDevice
    case staleRequest
    case replayedRequest
    case invalidSignature
    case insufficientPermission
    case invalidRequest
    case requestRateLimited
}

extension MobileAccessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServiceURL: "移动访问地址无效"
        case .invalidCertificateFingerprint: "TLS 证书指纹无效"
        case .pairingCapacityExceeded: "当前配对会话已满"
        case .pairingUnavailable: "配对会话不存在或已被使用"
        case .pairingExpired: "配对会话已过期"
        case .invalidPairingSecret: "配对凭据无效"
        case .invalidDeviceName: "设备名称无效"
        case .invalidPublicKey: "设备公钥无效"
        case .deviceAlreadyPaired: "该设备已经配对"
        case .deviceCapacityExceeded: "已配对设备数量达到上限"
        case .unknownDevice: "设备未配对"
        case .revokedDevice: "设备授权已撤销"
        case .staleRequest: "请求时间已过期"
        case .replayedRequest: "请求 nonce 已被使用"
        case .invalidSignature: "设备签名无效"
        case .insufficientPermission: "设备权限不足"
        case .invalidRequest: "移动请求无效"
        case .requestRateLimited: "设备请求过于频繁"
        }
    }
}

public struct MobilePairingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let serviceURL: URL
    public let certificateFingerprint: String
    public let secret: String
    public let expiresAt: Date

    public init(
        id: UUID,
        serviceURL: URL,
        certificateFingerprint: String,
        secret: String,
        expiresAt: Date
    ) {
        self.id = id
        self.serviceURL = serviceURL
        self.certificateFingerprint = certificateFingerprint
        self.secret = secret
        self.expiresAt = expiresAt
    }
}

public struct MobilePairingCompletionRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let secret: String
    public let deviceName: String
    public let publicKey: String

    public init(
        sessionID: UUID,
        secret: String,
        deviceName: String,
        publicKey: String
    ) {
        self.sessionID = sessionID
        self.secret = secret
        self.deviceName = deviceName
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case secret
        case deviceName = "device_name"
        case publicKey = "public_key"
    }
}

public struct MobileDeviceCredential: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let deviceName: String
    public let permissions: Set<MobilePermissionScope>
    public let pairedAt: Date

    public init(
        deviceID: UUID,
        deviceName: String,
        permissions: Set<MobilePermissionScope>,
        pairedAt: Date
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.permissions = permissions
        self.pairedAt = pairedAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case permissions
        case pairedAt = "paired_at"
    }
}

public struct MobilePendingPairingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deviceName: String
    public let publicKeyFingerprint: String
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID,
        deviceName: String,
        publicKeyFingerprint: String,
        requestedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.deviceName = deviceName
        self.publicKeyFingerprint = publicKeyFingerprint
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

public enum MobilePairingStatus: Codable, Equatable, Sendable {
    case awaitingApproval
    case approved(MobileDeviceCredential)
    case rejected
}

public struct MobilePairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let publicKey: String
    public var permissions: Set<MobilePermissionScope>
    public let pairedAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }

    public init(
        id: UUID,
        name: String,
        publicKey: String,
        permissions: Set<MobilePermissionScope>,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.permissions = permissions
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

public struct MobileRequestDescriptor: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: Data

    public init(method: String, path: String, body: Data) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct MobileSignedRequestProof: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let timestamp: Int64
    public let nonce: String
    public let signature: String

    public init(deviceID: UUID, timestamp: Int64, nonce: String, signature: String) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.nonce = nonce
        self.signature = signature
    }
}
