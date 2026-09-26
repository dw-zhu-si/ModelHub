import CryptoKit
import Foundation

public enum MobileRequestCanonicalizer {
    public static func canonicalData(
        proof: MobileSignedRequestProof,
        request: MobileRequestDescriptor
    ) throws -> Data {
        let method = request.method.uppercased()
        guard request.method == method,
              ["GET", "POST", "PATCH", "DELETE"].contains(method),
              request.path.hasPrefix("/mobile/v1/"),
              request.path.utf8.count <= 2_048,
              !request.path.contains("?"),
              !request.path.contains("#"),
              !request.path.contains("\0"),
              request.body.count <= 1_048_576,
              proof.timestamp > 0,
              isValidNonce(proof.nonce)
        else {
            throw MobileAccessError.invalidRequest
        }

        let bodyDigest = SHA256.hash(data: request.body)
            .map { String(format: "%02x", $0) }
            .joined()
        let canonical = [
            "MODELHUB-MOBILE-V1",
            proof.deviceID.uuidString.lowercased(),
            String(proof.timestamp),
            proof.nonce,
            method,
            request.path,
            bodyDigest
        ].joined(separator: "\n")
        return Data(canonical.utf8)
    }

    private static func isValidNonce(_ nonce: String) -> Bool {
        (16...128).contains(nonce.utf8.count) && nonce.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }
}

public actor MobilePairingCoordinator {
    private struct PendingSession: Sendable {
        let session: MobilePairingSession
        var failedAttempts: Int
    }

    private struct PendingApproval: Sendable {
        enum State: Sendable {
            case awaitingApproval
            case approved(MobileDeviceCredential)
            case rejected
        }

        let summary: MobilePendingPairingRequest
        let secretDigest: Data
        let publicKey: String
        var failedStatusAttempts: Int
        var state: State
    }

    private let pairingTTL: TimeInterval
    private let maximumPairingAttempts: Int
    private let maximumPairingSessions: Int
    private let maximumDevices: Int
    private let maximumClockSkew: TimeInterval
    private let replayWindow: TimeInterval
    private let maximumNoncesPerDevice: Int
    private let approvalTTL: TimeInterval

    private var sessions: [UUID: PendingSession] = [:]
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    private var pairedDevices: [UUID: MobilePairedDevice]
    private var seenNonces: [UUID: [String: Date]] = [:]

    public init(
        pairingTTL: TimeInterval = 120,
        maximumPairingAttempts: Int = 5,
        maximumPairingSessions: Int = 8,
        maximumDevices: Int = 64,
        maximumClockSkew: TimeInterval = 90,
        replayWindow: TimeInterval = 180,
        maximumNoncesPerDevice: Int = 512,
        approvalTTL: TimeInterval = 300,
        persistedDevices: [MobilePairedDevice] = []
    ) {
        self.pairingTTL = min(max(pairingTTL, 30), 300)
        self.maximumPairingAttempts = min(max(maximumPairingAttempts, 1), 10)
        self.maximumPairingSessions = min(max(maximumPairingSessions, 1), 32)
        self.maximumDevices = min(max(maximumDevices, 1), 256)
        self.maximumClockSkew = min(max(maximumClockSkew, 30), 300)
        self.replayWindow = max(replayWindow, maximumClockSkew * 2)
        self.maximumNoncesPerDevice = min(max(maximumNoncesPerDevice, 32), 4_096)
        self.approvalTTL = min(max(approvalTTL, 60), 600)
        self.pairedDevices = Dictionary(
            persistedDevices.prefix(self.maximumDevices).map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.pairedAt >= second.pairedAt ? first : second
            }
        )
    }

    public func createPairingSession(
        serviceURL: URL,
        certificateFingerprint: String,
        now: Date = .now
    ) throws -> MobilePairingSession {
        removeExpiredSessions(at: now)
        guard sessions.count < maximumPairingSessions else {
            throw MobileAccessError.pairingCapacityExceeded
        }
        guard serviceURL.scheme?.lowercased() == "https",
              serviceURL.host != nil,
              serviceURL.user == nil,
              serviceURL.password == nil,
              serviceURL.query == nil,
              serviceURL.fragment == nil
        else {
            throw MobileAccessError.invalidServiceURL
        }
        let fingerprint = certificateFingerprint.lowercased()
        guard fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              })
        else {
            throw MobileAccessError.invalidCertificateFingerprint
        }

        let session = MobilePairingSession(
            id: UUID(),
            serviceURL: serviceURL,
            certificateFingerprint: fingerprint,
            secret: Self.randomSecret(byteCount: 32),
            expiresAt: now.addingTimeInterval(pairingTTL)
        )
        sessions[session.id] = PendingSession(session: session, failedAttempts: 0)
        return session
    }

    public func completePairing(
        _ request: MobilePairingCompletionRequest,
        now: Date = .now
    ) throws -> MobileDeviceCredential {
        let pending = try submitPairing(request, now: now)
        try approvePairing(requestID: pending.id, now: now)
        guard case .approved(let credential) = try pairingStatus(
            requestID: pending.id,
            secret: request.secret,
            now: now
        ) else {
            throw MobileAccessError.pairingUnavailable
        }
        return credential
    }

    public func submitPairing(
        _ request: MobilePairingCompletionRequest,
        now: Date = .now
    ) throws -> MobilePendingPairingRequest {
        removeExpiredApprovals(at: now)
        guard var pending = sessions[request.sessionID] else {
            throw MobileAccessError.pairingUnavailable
        }
        guard pending.session.expiresAt >= now else {
            sessions.removeValue(forKey: request.sessionID)
            throw MobileAccessError.pairingExpired
        }
        guard Self.constantTimeEqual(pending.session.secret, request.secret) else {
            pending.failedAttempts += 1
            if pending.failedAttempts >= maximumPairingAttempts {
                sessions.removeValue(forKey: request.sessionID)
            } else {
                sessions[request.sessionID] = pending
            }
            throw MobileAccessError.invalidPairingSecret
        }

        let name = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.utf8.count),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MobileAccessError.invalidDeviceName
        }
        guard let keyData = Data(base64Encoded: request.publicKey),
              keyData.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: keyData)) != nil
        else {
            throw MobileAccessError.invalidPublicKey
        }
        let normalizedPublicKey = keyData.base64EncodedString()
        guard !pairedDevices.values.contains(where: {
            !$0.isRevoked && $0.publicKey == normalizedPublicKey
        }) else {
            throw MobileAccessError.deviceAlreadyPaired
        }

        let requestID = UUID()
        let keyFingerprint = SHA256.hash(data: keyData)
            .map { String(format: "%02x", $0) }
            .joined()
        let summary = MobilePendingPairingRequest(
            id: requestID,
            deviceName: name,
            publicKeyFingerprint: keyFingerprint,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(approvalTTL)
        )
        sessions.removeValue(forKey: request.sessionID)
        pendingApprovals[requestID] = PendingApproval(
            summary: summary,
            secretDigest: Self.digest(request.secret),
            publicKey: normalizedPublicKey,
            failedStatusAttempts: 0,
            state: .awaitingApproval
        )
        return summary
    }

    public func pendingPairingRequests(now: Date = .now) -> [MobilePendingPairingRequest] {
        removeExpiredApprovals(at: now)
        return pendingApprovals.values.compactMap { pending in
            guard case .awaitingApproval = pending.state else { return nil }
            return pending.summary
        }.sorted { $0.requestedAt < $1.requestedAt }
    }

    public func approvePairing(requestID: UUID, now: Date = .now) throws {
        removeExpiredApprovals(at: now)
        guard var pending = pendingApprovals[requestID] else {
            throw MobileAccessError.pairingUnavailable
        }
        guard case .awaitingApproval = pending.state else {
            throw MobileAccessError.pairingUnavailable
        }
        guard pairedDevices.values.lazy.filter({ !$0.isRevoked }).count < maximumDevices else {
            throw MobileAccessError.deviceCapacityExceeded
        }
        guard !pairedDevices.values.contains(where: {
            !$0.isRevoked && $0.publicKey == pending.publicKey
        }) else {
            throw MobileAccessError.deviceAlreadyPaired
        }
        let deviceID = UUID()
        let permissions: Set<MobilePermissionScope> = [.viewer]
        let credential = MobileDeviceCredential(
            deviceID: deviceID,
            deviceName: pending.summary.deviceName,
            permissions: permissions,
            pairedAt: now
        )
        pairedDevices[deviceID] = MobilePairedDevice(
            id: deviceID,
            name: pending.summary.deviceName,
            publicKey: pending.publicKey,
            permissions: permissions,
            pairedAt: now
        )
        pending.state = .approved(credential)
        pendingApprovals[requestID] = pending
    }

    public func rejectPairing(requestID: UUID, now: Date = .now) throws {
        removeExpiredApprovals(at: now)
        guard var pending = pendingApprovals[requestID] else {
            throw MobileAccessError.pairingUnavailable
        }
        guard case .awaitingApproval = pending.state else {
            throw MobileAccessError.pairingUnavailable
        }
        pending.state = .rejected
        pendingApprovals[requestID] = pending
    }

    public func pairingStatus(
        requestID: UUID,
        secret: String,
        now: Date = .now
    ) throws -> MobilePairingStatus {
        removeExpiredApprovals(at: now)
        guard var pending = pendingApprovals[requestID] else {
            throw MobileAccessError.pairingUnavailable
        }
        guard Self.constantTimeEqual(pending.secretDigest, Self.digest(secret)) else {
            pending.failedStatusAttempts += 1
            if pending.failedStatusAttempts >= maximumPairingAttempts {
                pendingApprovals.removeValue(forKey: requestID)
            } else {
                pendingApprovals[requestID] = pending
            }
            throw MobileAccessError.invalidPairingSecret
        }
        switch pending.state {
        case .awaitingApproval: return .awaitingApproval
        case .approved(let credential): return .approved(credential)
        case .rejected: return .rejected
        }
    }

    @discardableResult
    public func authorize(
        _ proof: MobileSignedRequestProof,
        request: MobileRequestDescriptor,
        requiring permission: MobilePermissionScope,
        now: Date = .now
    ) throws -> MobilePairedDevice {
        let canonical = try MobileRequestCanonicalizer.canonicalData(
            proof: proof,
            request: request
        )
        guard abs(now.timeIntervalSince1970 - Double(proof.timestamp)) <= maximumClockSkew else {
            throw MobileAccessError.staleRequest
        }
        guard var device = pairedDevices[proof.deviceID] else {
            throw MobileAccessError.unknownDevice
        }
        guard !device.isRevoked else {
            throw MobileAccessError.revokedDevice
        }
        guard device.permissions.contains(permission) else {
            throw MobileAccessError.insufficientPermission
        }
        guard let publicKeyData = Data(base64Encoded: device.publicKey),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              let signatureData = Data(base64Encoded: proof.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: canonical)
        else {
            throw MobileAccessError.invalidSignature
        }

        var nonces = seenNonces[proof.deviceID] ?? [:]
        let replayCutoff = now.addingTimeInterval(-replayWindow)
        nonces = nonces.filter { $0.value >= replayCutoff }
        guard nonces[proof.nonce] == nil else {
            throw MobileAccessError.replayedRequest
        }
        guard nonces.count < maximumNoncesPerDevice else {
            throw MobileAccessError.requestRateLimited
        }
        nonces[proof.nonce] = now
        seenNonces[proof.deviceID] = nonces
        device.lastSeenAt = now
        pairedDevices[proof.deviceID] = device
        return device
    }

    public func revoke(deviceID: UUID, now: Date = .now) throws {
        guard var device = pairedDevices[deviceID] else {
            throw MobileAccessError.unknownDevice
        }
        device.revokedAt = now
        pairedDevices[deviceID] = device
        seenNonces.removeValue(forKey: deviceID)
    }

    public func replacePermissions(
        deviceID: UUID,
        permissions: Set<MobilePermissionScope>
    ) throws {
        guard var device = pairedDevices[deviceID] else {
            throw MobileAccessError.unknownDevice
        }
        guard !device.isRevoked else {
            throw MobileAccessError.revokedDevice
        }
        device.permissions = permissions
        pairedDevices[deviceID] = device
    }

    public func devices() -> [MobilePairedDevice] {
        pairedDevices.values.sorted { lhs, rhs in
            if lhs.isRevoked != rhs.isRevoked { return !lhs.isRevoked }
            return lhs.pairedAt > rhs.pairedAt
        }
    }

    public func invalidatePairingSessions() {
        sessions.removeAll(keepingCapacity: true)
        pendingApprovals.removeAll(keepingCapacity: true)
    }

    private func removeExpiredSessions(at now: Date) {
        sessions = sessions.filter { $0.value.session.expiresAt >= now }
    }

    private func removeExpiredApprovals(at now: Date) {
        pendingApprovals = pendingApprovals.filter { $0.value.summary.expiresAt >= now }
    }

    private static func digest(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private static func randomSecret(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            difference |= Int(index < left.count ? left[index] : 0)
                ^ Int(index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}
