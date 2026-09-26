import CryptoKit
import XCTest
@testable import ModelHubMobileAccess

final class MobilePairingCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPairingSessionIsShortLivedSingleUseAndGrantsViewerOnly() async throws {
        let coordinator = MobilePairingCoordinator(pairingTTL: 120)
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://192.168.1.4:11470")),
            certificateFingerprint: String(repeating: "a", count: 64),
            now: now
        )
        let key = P256.Signing.PrivateKey()
        let request = MobilePairingCompletionRequest(
            sessionID: session.id,
            secret: session.secret,
            deviceName: "iPhone 17 Pro",
            publicKey: key.publicKey.x963Representation.base64EncodedString()
        )

        let credential = try await coordinator.completePairing(request, now: now)

        XCTAssertEqual(credential.permissions, [.viewer])
        XCTAssertEqual(credential.deviceName, "iPhone 17 Pro")
        await XCTAssertThrowsErrorAsync(
            try await coordinator.completePairing(request, now: now)
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .pairingUnavailable)
        }
    }

    func testNetworkPairingRequiresExplicitDesktopApproval() async throws {
        let coordinator = MobilePairingCoordinator(pairingTTL: 120)
        let key = P256.Signing.PrivateKey()
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://192.168.1.4:11470")),
            certificateFingerprint: String(repeating: "f", count: 64),
            now: now
        )
        let completion = MobilePairingCompletionRequest(
            sessionID: session.id,
            secret: session.secret,
            deviceName: "Android Tablet",
            publicKey: key.publicKey.x963Representation.base64EncodedString()
        )

        let pending = try await coordinator.submitPairing(completion, now: now)
        XCTAssertEqual(pending.deviceName, "Android Tablet")
        let beforeApproval = await coordinator.devices()
        XCTAssertEqual(beforeApproval, [])
        let awaitingStatus = try await coordinator.pairingStatus(
            requestID: pending.id,
            secret: session.secret,
            now: now
        )
        XCTAssertEqual(awaitingStatus, .awaitingApproval)

        try await coordinator.approvePairing(requestID: pending.id, now: now)
        guard case .approved(let credential) = try await coordinator.pairingStatus(
            requestID: pending.id,
            secret: session.secret,
            now: now
        ) else {
            return XCTFail("Expected approved credential")
        }
        XCTAssertEqual(credential.deviceName, "Android Tablet")
        XCTAssertEqual(credential.permissions, [.viewer])
        let afterApproval = await coordinator.devices()
        XCTAssertEqual(afterApproval.count, 1)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.submitPairing(completion, now: now)
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .pairingUnavailable)
        }
    }

    func testDesktopCanRejectPendingPairingWithoutCreatingDevice() async throws {
        let coordinator = MobilePairingCoordinator()
        let key = P256.Signing.PrivateKey()
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "1", count: 64),
            now: now
        )
        let pending = try await coordinator.submitPairing(
            MobilePairingCompletionRequest(
                sessionID: session.id,
                secret: session.secret,
                deviceName: "Unknown phone",
                publicKey: key.publicKey.x963Representation.base64EncodedString()
            ),
            now: now
        )

        try await coordinator.rejectPairing(requestID: pending.id, now: now)
        let rejectedStatus = try await coordinator.pairingStatus(
            requestID: pending.id,
            secret: session.secret,
            now: now
        )
        XCTAssertEqual(rejectedStatus, .rejected)
        let devices = await coordinator.devices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testExpiredAndIncorrectPairingSecretsFailClosed() async throws {
        let coordinator = MobilePairingCoordinator(pairingTTL: 30, maximumPairingAttempts: 2)
        let key = P256.Signing.PrivateKey()
        let first = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "b", count: 64),
            now: now
        )
        let wrong = MobilePairingCompletionRequest(
            sessionID: first.id,
            secret: "not-the-secret",
            deviceName: "Pixel Tablet",
            publicKey: key.publicKey.x963Representation.base64EncodedString()
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.completePairing(wrong, now: now)
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .invalidPairingSecret)
        }

        let expired = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "c", count: 64),
            now: now
        )
        let expiredRequest = MobilePairingCompletionRequest(
            sessionID: expired.id,
            secret: expired.secret,
            deviceName: "iPad",
            publicKey: key.publicKey.x963Representation.base64EncodedString()
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.completePairing(
                expiredRequest,
                now: now.addingTimeInterval(31)
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .pairingExpired)
        }
    }

    func testMalformedDeviceInputIsRejected() async throws {
        let coordinator = MobilePairingCoordinator()
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "d", count: 64),
            now: now
        )
        let request = MobilePairingCompletionRequest(
            sessionID: session.id,
            secret: session.secret,
            deviceName: String(repeating: "x", count: 129),
            publicKey: Data("not-a-key".utf8).base64EncodedString()
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.completePairing(request, now: now)
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .invalidDeviceName)
        }
    }

    func testSignedRequestRejectsTamperingStalenessReplayAndRevocation() async throws {
        let coordinator = MobilePairingCoordinator(maximumClockSkew: 90)
        let privateKey = P256.Signing.PrivateKey()
        let credential = try await pair(privateKey: privateKey, with: coordinator)
        let request = MobileRequestDescriptor(
            method: "GET",
            path: "/mobile/v1/bootstrap",
            body: Data()
        )
        let signedProof = try proof(
            for: request,
            credential: credential,
            privateKey: privateKey,
            nonce: "mG-fE4ntS7z8kR4zRBrYvA",
            now: now
        )

        let authorized = try await coordinator.authorize(
            signedProof,
            request: request,
            requiring: .viewer,
            now: now
        )
        XCTAssertEqual(authorized.id, credential.deviceID)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.authorize(
                signedProof,
                request: request,
                requiring: .viewer,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .replayedRequest)
        }

        let changed = MobileRequestDescriptor(
            method: "GET",
            path: "/mobile/v1/providers/health",
            body: Data()
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.authorize(
                signedProof,
                request: changed,
                requiring: .viewer,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .invalidSignature)
        }

        let staleProof = try proof(
            for: request,
            credential: credential,
            privateKey: privateKey,
            nonce: "rT2Nf8A9e_1qJnVPnS6-pQ",
            now: now.addingTimeInterval(-91)
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.authorize(
                staleProof,
                request: request,
                requiring: .viewer,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .staleRequest)
        }

        try await coordinator.revoke(deviceID: credential.deviceID, now: now)
        let revokedProof = try proof(
            for: request,
            credential: credential,
            privateKey: privateKey,
            nonce: "DXMuuvmUD7X3qk0rg31KAw",
            now: now
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.authorize(
                revokedProof,
                request: request,
                requiring: .viewer,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .revokedDevice)
        }
    }

    func testPermissionAndRequestShapeAreEnforced() async throws {
        let coordinator = MobilePairingCoordinator()
        let privateKey = P256.Signing.PrivateKey()
        let credential = try await pair(privateKey: privateKey, with: coordinator)
        let request = MobileRequestDescriptor(
            method: "GET",
            path: "/mobile/v1/bootstrap",
            body: Data()
        )
        let signed = try proof(
            for: request,
            credential: credential,
            privateKey: privateKey,
            nonce: "ccPaMIB3bkobBQYn0LbM8Q",
            now: now
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.authorize(
                signed,
                request: request,
                requiring: .operator,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MobileAccessError, .insufficientPermission)
        }

        let invalidPath = MobileRequestDescriptor(
            method: "GET",
            path: "/v1/providers",
            body: Data()
        )
        XCTAssertThrowsError(try MobileRequestCanonicalizer.canonicalData(
            proof: signed,
            request: invalidPath
        )) { error in
            XCTAssertEqual(error as? MobileAccessError, .invalidRequest)
        }
    }

    private func pair(
        privateKey: P256.Signing.PrivateKey,
        with coordinator: MobilePairingCoordinator
    ) async throws -> MobileDeviceCredential {
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "e", count: 64),
            now: now
        )
        return try await coordinator.completePairing(
            MobilePairingCompletionRequest(
                sessionID: session.id,
                secret: session.secret,
                deviceName: "Test Device",
                publicKey: privateKey.publicKey.x963Representation.base64EncodedString()
            ),
            now: now
        )
    }

    private func proof(
        for request: MobileRequestDescriptor,
        credential: MobileDeviceCredential,
        privateKey: P256.Signing.PrivateKey,
        nonce: String,
        now: Date
    ) throws -> MobileSignedRequestProof {
        let unsigned = MobileSignedRequestProof(
            deviceID: credential.deviceID,
            timestamp: Int64(now.timeIntervalSince1970),
            nonce: nonce,
            signature: ""
        )
        let canonical = try MobileRequestCanonicalizer.canonicalData(
            proof: unsigned,
            request: request
        )
        let signature = try privateKey.signature(for: canonical)
        return MobileSignedRequestProof(
            deviceID: credential.deviceID,
            timestamp: unsigned.timestamp,
            nonce: nonce,
            signature: signature.derRepresentation.base64EncodedString()
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
