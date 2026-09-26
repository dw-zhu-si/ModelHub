import CryptoKit
import XCTest
import ModelHubCore
@testable import ModelHubMobileAccess

final class MobileAccessRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPairingSubmissionRequiresApprovalAndNeverReturnsSecret() async throws {
        let coordinator = MobilePairingCoordinator()
        let router = MobileAccessRouter(
            coordinator: coordinator,
            overviewProvider: { Self.overview }
        )
        let key = P256.Signing.PrivateKey()
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://192.168.1.4:11470")),
            certificateFingerprint: String(repeating: "a", count: 64),
            now: now
        )
        let body = try JSONEncoder.mobile.encode(MobilePairingCompletionRequest(
            sessionID: session.id,
            secret: session.secret,
            deviceName: "iPhone",
            publicKey: key.publicKey.x963Representation.base64EncodedString()
        ))

        let response = await router.handle(
            MobileAccessHTTPRequest(
                method: "POST",
                path: "/mobile/v1/pairing/complete",
                headers: ["content-type": "application/json"],
                body: body
            ),
            now: now
        )

        XCTAssertEqual(response.statusCode, 202)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(session.secret))
        let receipt = try JSONDecoder.mobile.decode(
            MobilePairingSubmissionResponse.self,
            from: response.body
        )
        XCTAssertEqual(receipt.state, .awaitingApproval)
        let pendingRequests = await coordinator.pendingPairingRequests()
        XCTAssertEqual(pendingRequests.count, 1)
    }

    func testBootstrapRejectsUnsignedRequestAndReturnsMinimizedOverviewForSignedViewer() async throws {
        let coordinator = MobilePairingCoordinator()
        let router = MobileAccessRouter(
            coordinator: coordinator,
            overviewProvider: { Self.overview }
        )
        let unsigned = await router.handle(
            MobileAccessHTTPRequest(
                method: "GET",
                path: "/mobile/v1/bootstrap",
                headers: [:],
                body: Data()
            ),
            now: now
        )
        XCTAssertEqual(unsigned.statusCode, 401)

        let key = P256.Signing.PrivateKey()
        let credential = try await pair(key: key, coordinator: coordinator)
        let descriptor = MobileRequestDescriptor(
            method: "GET",
            path: "/mobile/v1/bootstrap",
            body: Data()
        )
        let proof = try signedProof(
            descriptor: descriptor,
            credential: credential,
            key: key,
            nonce: "06m2aK2dVGt2TqJHtZ4jxQ"
        )
        let signed = await router.handle(
            MobileAccessHTTPRequest(
                method: descriptor.method,
                path: descriptor.path,
                headers: [
                    "x-modelhub-device-id": proof.deviceID.uuidString,
                    "x-modelhub-timestamp": String(proof.timestamp),
                    "x-modelhub-nonce": proof.nonce,
                    "x-modelhub-signature": proof.signature
                ],
                body: descriptor.body
            ),
            now: now
        )

        XCTAssertEqual(signed.statusCode, 200)
        XCTAssertEqual(signed.headers["Cache-Control"], "no-store")
        let bootstrap = try JSONDecoder.mobile.decode(
            MobileBootstrapResponse.self,
            from: signed.body
        )
        XCTAssertEqual(bootstrap.overview.defaultModel, "smart")
        XCTAssertFalse(String(decoding: signed.body, as: UTF8.self).contains("base_url"))
    }

    func testRouterHasStrictAllowlistAndBodyLimit() async {
        let router = MobileAccessRouter(
            coordinator: MobilePairingCoordinator(),
            overviewProvider: { Self.overview }
        )
        let forbidden = await router.handle(
            MobileAccessHTTPRequest(
                method: "GET",
                path: "/v1/providers",
                headers: [:],
                body: Data()
            ),
            now: now
        )
        XCTAssertEqual(forbidden.statusCode, 404)

        let oversized = await router.handle(
            MobileAccessHTTPRequest(
                method: "POST",
                path: "/mobile/v1/pairing/complete",
                headers: ["content-type": "application/json"],
                body: Data(repeating: 0, count: 16_385)
            ),
            now: now
        )
        XCTAssertEqual(oversized.statusCode, 413)
    }

    func testPairingAndAuthenticatedActivityUseSeparateCallbacks() async throws {
        actor CallbackRecorder {
            var pairingCount = 0
            var activityCount = 0

            func recordPairing() { pairingCount += 1 }
            func recordActivity() { activityCount += 1 }
            func counts() -> (Int, Int) { (pairingCount, activityCount) }
        }

        let coordinator = MobilePairingCoordinator()
        let recorder = CallbackRecorder()
        let router = MobileAccessRouter(
            coordinator: coordinator,
            overviewProvider: { Self.overview },
            pairingSubmitted: { await recorder.recordPairing() },
            deviceActivityObserved: { await recorder.recordActivity() }
        )
        let pendingKey = P256.Signing.PrivateKey()
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://192.168.1.4:11470")),
            certificateFingerprint: String(repeating: "a", count: 64),
            now: now
        )
        let pairingBody = try JSONEncoder.mobile.encode(MobilePairingCompletionRequest(
            sessionID: session.id,
            secret: session.secret,
            deviceName: "Pending iPhone",
            publicKey: pendingKey.publicKey.x963Representation.base64EncodedString()
        ))
        let pairingResponse = await router.handle(
            MobileAccessHTTPRequest(
                method: "POST",
                path: "/mobile/v1/pairing/complete",
                headers: ["content-type": "application/json"],
                body: pairingBody
            ),
            now: now
        )
        XCTAssertEqual(pairingResponse.statusCode, 202)

        let approvedKey = P256.Signing.PrivateKey()
        let credential = try await pair(key: approvedKey, coordinator: coordinator)
        let descriptor = MobileRequestDescriptor(
            method: "GET",
            path: "/mobile/v1/bootstrap",
            body: Data()
        )
        let proof = try signedProof(
            descriptor: descriptor,
            credential: credential,
            key: approvedKey,
            nonce: "callbackSeparationNonce_1"
        )
        let bootstrapResponse = await router.handle(
            MobileAccessHTTPRequest(
                method: descriptor.method,
                path: descriptor.path,
                headers: [
                    "x-modelhub-device-id": proof.deviceID.uuidString,
                    "x-modelhub-timestamp": String(proof.timestamp),
                    "x-modelhub-nonce": proof.nonce,
                    "x-modelhub-signature": proof.signature
                ],
                body: descriptor.body
            ),
            now: now
        )
        XCTAssertEqual(bootstrapResponse.statusCode, 200)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    private func pair(
        key: P256.Signing.PrivateKey,
        coordinator: MobilePairingCoordinator
    ) async throws -> MobileDeviceCredential {
        let session = try await coordinator.createPairingSession(
            serviceURL: try XCTUnwrap(URL(string: "https://modelhub.local:11470")),
            certificateFingerprint: String(repeating: "b", count: 64),
            now: now
        )
        return try await coordinator.completePairing(
            MobilePairingCompletionRequest(
                sessionID: session.id,
                secret: session.secret,
                deviceName: "Test Device",
                publicKey: key.publicKey.x963Representation.base64EncodedString()
            ),
            now: now
        )
    }

    private func signedProof(
        descriptor: MobileRequestDescriptor,
        credential: MobileDeviceCredential,
        key: P256.Signing.PrivateKey,
        nonce: String
    ) throws -> MobileSignedRequestProof {
        let unsigned = MobileSignedRequestProof(
            deviceID: credential.deviceID,
            timestamp: Int64(now.timeIntervalSince1970),
            nonce: nonce,
            signature: ""
        )
        let canonical = try MobileRequestCanonicalizer.canonicalData(
            proof: unsigned,
            request: descriptor
        )
        return MobileSignedRequestProof(
            deviceID: credential.deviceID,
            timestamp: unsigned.timestamp,
            nonce: unsigned.nonce,
            signature: try key.signature(for: canonical).derRepresentation.base64EncodedString()
        )
    }

    private static let overview = MobileGatewayOverview(
        protocolVersion: "1.0",
        gatewayVersion: "1.10.0",
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        isGatewayRunning: true,
        defaultModel: "smart",
        enabledProviderCount: 2,
        enabledRouteCount: 1,
        modelHealth: MobileModelHealthSummary(
            total: 10,
            available: 8,
            unavailable: 1,
            unknown: 0,
            configurationRequired: 1,
            unsupported: 0
        ),
        providers: []
    )
}
