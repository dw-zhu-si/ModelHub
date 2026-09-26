import CryptoKit
import Foundation
import XCTest
import ModelHubMobileAccess
@testable import ModelHub

final class MobileAccessServiceTests: XCTestCase {
    func testServiceNegotiatesPinnedTLSAndExposesOnlyMobileRoutes() async throws {
        let identity = try MobileTLSCertificateFactory.makeIdentity(
            privateKey: MobileTLSCertificateFactory.makeEphemeralPrivateKey()
        )
        let coordinator = MobilePairingCoordinator()
        let router = MobileAccessRouter(
            coordinator: coordinator,
            overviewProvider: {
                MobileGatewayOverview(
                    protocolVersion: "1.0",
                    gatewayVersion: "test",
                    generatedAt: .now,
                    isGatewayRunning: true,
                    defaultModel: nil,
                    enabledProviderCount: 0,
                    enabledRouteCount: 0,
                    modelHealth: .init(
                        total: 0,
                        available: 0,
                        unavailable: 0,
                        unknown: 0,
                        configurationRequired: 0,
                        unsupported: 0
                    ),
                    providers: []
                )
            }
        )
        let service = MobileAccessService(router: router, identity: identity)
        defer { service.stop() }
        try await start(service)

        let delegate = PinnedCertificateDelegate(fingerprint: identity.fingerprint)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(
            string: "https://127.0.0.1:\(MobileAccessService.fixedPort)/v1/providers"
        ))
        let (_, response) = try await session.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(delegate.didValidatePinnedCertificate)
    }

    private func start(_ service: MobileAccessService) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            do {
                try service.start { result in
                    continuation.resume(with: result.map { _ in () })
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String
    private let lock = NSLock()
    private var validated = false

    var didValidatePinnedCertificate: Bool {
        lock.withLock { validated }
    }

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.withLock { validated = true }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
