import Darwin
import Foundation
@preconcurrency import Network
import XCTest
@testable import ModelHub
import ModelHubCore

final class OAuthTokenManagerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testKeychainValueRoundTripsWithoutMakingSecretGenerallyCodable() throws {
        let entry = validEntry()
        let secret = OAuthTokenSecret(
            accessToken: "access-value",
            refreshToken: "refresh-value",
            expiresAt: now.addingTimeInterval(3_600),
            providerID: entry.providerID,
            providerKind: .gemini,
            canonicalOrigin: "https://generativelanguage.googleapis.com"
        )

        let storedValue = try secret.keychainValue()
        let decoded = try OAuthTokenSecret(keychainValue: storedValue)

        XCTAssertEqual(decoded, secret)
    }

    func testLegacyUnboundOAuthSecretFailsClosedInsteadOfMigratingSilently() {
        let legacy = #"{"accessToken":"access","expiresAt":1788003600000,"refreshToken":"refresh"}"#

        XCTAssertThrowsError(try OAuthTokenSecret(keychainValue: legacy))
    }

    func testOAuthSecretBindingMismatchRequiresReauthorizationBeforeTransport() async throws {
        let entry = validEntry()
        let mismatchedSecrets = [
            OAuthTokenSecret(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: now.addingTimeInterval(3_600),
                providerID: UUID(),
                providerKind: .gemini,
                canonicalOrigin: "https://generativelanguage.googleapis.com"
            ),
            OAuthTokenSecret(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: now.addingTimeInterval(3_600),
                providerID: entry.providerID,
                providerKind: .anthropic,
                canonicalOrigin: "https://generativelanguage.googleapis.com"
            ),
            OAuthTokenSecret(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: now.addingTimeInterval(3_600),
                providerID: entry.providerID,
                providerKind: .gemini,
                canonicalOrigin: "https://example.com"
            )
        ]

        for secret in mismatchedSecrets {
            let storage = FakeOAuthTokenSecretStorage(
                initial: [entry.id: try secret.keychainValue()]
            )
            let transport = FakeOAuthTokenRefreshTransport()
            let manager = OAuthTokenManager(storage: storage, transport: transport)

            do {
                _ = try await manager.accessToken(
                    for: entry,
                    providerKind: .gemini,
                    asOf: now
                )
                XCTFail("mismatched OAuth secret binding must fail closed")
            } catch {
                XCTAssertEqual(error as? OAuthTokenManagerError, .secretBindingMismatch)
            }
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testFreshAccessTokenDoesNotRefresh() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try boundSecret(
                    entry: entry,
                    accessToken: "still-fresh",
                    refreshToken: "refresh-value",
                    expiresAt: now.addingTimeInterval(61)
                ).keychainValue()
            ]
        )
        let transport = FakeOAuthTokenRefreshTransport()
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        let token = try await manager.accessToken(
            for: entry,
            providerKind: .gemini,
            asOf: now
        )

        let requestCount = await transport.requestCount()
        XCTAssertEqual(token, "still-fresh")
        XCTAssertEqual(requestCount, 0)
    }

    func testExpiringTokenUsesOfficialFormEncodedRefreshWithoutClientSecret() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try boundSecret(
                    entry: entry,
                    accessToken: "expiring",
                    refreshToken: "refresh value/+",
                    expiresAt: now.addingTimeInterval(60)
                ).keychainValue()
            ]
        )
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(
                #"{"access_token":"new-access","expires_in":3600}"#
            )
        )
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        let token = try await manager.accessToken(
            for: entry,
            providerKind: .gemini,
            asOf: now
        )
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let fields = formFields(request.formData)

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.endpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["client_id"], "public-native-client-id")
        XCTAssertEqual(fields["refresh_token"], "refresh value/+")
        XCTAssertNil(fields["client_secret"])
    }

    func testConcurrentRefreshIsSingleFlightPerCredential() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try expiredSecret(
                    entry: entry,
                    refreshToken: "refresh-value"
                ).keychainValue()
            ]
        )
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(
                #"{"access_token":"single-flight","expires_in":3600}"#
            ),
            delayNanoseconds: 20_000_000
        )
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        let requestDate = now
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await manager.accessToken(
                        for: entry,
                        providerKind: .gemini,
                        asOf: requestDate
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        let requestCount = await transport.requestCount()
        XCTAssertEqual(Set(tokens), Set(["single-flight"]))
        XCTAssertEqual(requestCount, 1)
    }

    func testUnauthorizedFreshAccessTokenForcesOneRefresh() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try boundSecret(
                    entry: entry,
                    accessToken: "rejected-access",
                    refreshToken: "refresh-value",
                    expiresAt: now.addingTimeInterval(3_600)
                ).keychainValue()
            ]
        )
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(#"{"access_token":"fresh-after-401","expires_in":3600}"#)
        )
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        let refreshed = try await manager.accessTokenAfterUnauthorized(
            rejectedAccessToken: "rejected-access",
            for: entry,
            providerKind: .gemini,
            asOf: now
        )

        XCTAssertEqual(refreshed, "fresh-after-401")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testConcurrentUnauthorizedRefreshIsSingleFlightAndDoesNotRefreshNewerToken() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try boundSecret(
                    entry: entry,
                    accessToken: "rejected-access",
                    refreshToken: "refresh-value",
                    expiresAt: now.addingTimeInterval(3_600)
                ).keychainValue()
            ]
        )
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(#"{"access_token":"single-flight-401","expires_in":3600}"#),
            delayNanoseconds: 20_000_000
        )
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        let requestDate = now
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await manager.accessTokenAfterUnauthorized(
                        rejectedAccessToken: "rejected-access",
                        for: entry,
                        providerKind: .gemini,
                        asOf: requestDate
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(tokens), Set(["single-flight-401"]))
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)

        let alreadyRecovered = try await manager.accessTokenAfterUnauthorized(
            rejectedAccessToken: "rejected-access",
            for: entry,
            providerKind: .gemini,
            asOf: now
        )
        XCTAssertEqual(alreadyRecovered, "single-flight-401")
        let finalRequestCount = await transport.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testOnlyExplicitInvalidGrantIsClassifiedAsIrrecoverableAuthorization() async throws {
        let entry = validEntry()
        let storedValue = try expiredSecret(
            entry: entry,
            refreshToken: "refresh-value"
        ).keychainValue()

        let invalidGrantManager = OAuthTokenManager(
            storage: FakeOAuthTokenSecretStorage(initial: [entry.id: storedValue]),
            transport: FakeOAuthTokenRefreshTransport(
                response: OAuthTokenRefreshResponse(
                    statusCode: 400,
                    data: Data(#"{"error":"invalid_grant","error_description":"revoked"}"#.utf8)
                )
            )
        )
        do {
            _ = try await invalidGrantManager.accessToken(
                for: entry,
                providerKind: .gemini,
                asOf: now
            )
            XCTFail("invalid_grant must be classified as unrecoverable")
        } catch {
            XCTAssertEqual(
                error as? OAuthTokenManagerError,
                .authorizationIrrecoverable(errorCode: "invalid_grant")
            )
        }

        let invalidScopeManager = OAuthTokenManager(
            storage: FakeOAuthTokenSecretStorage(initial: [entry.id: storedValue]),
            transport: FakeOAuthTokenRefreshTransport(
                response: OAuthTokenRefreshResponse(
                    statusCode: 400,
                    data: Data(#"{"error":"invalid_scope"}"#.utf8)
                )
            )
        )
        do {
            _ = try await invalidScopeManager.accessToken(
                for: entry,
                providerKind: .gemini,
                asOf: now
            )
            XCTFail("other refresh errors must remain recoverable server rejections")
        } catch {
            XCTAssertEqual(error as? OAuthTokenManagerError, .serverRejected(statusCode: 400))
        }
    }

    func testOAuthTransportStopsAtConfiguredByteLimit() async throws {
        let transport = URLSessionOAuthTokenRefreshTransport(
            protocolClasses: [BoundedOAuthResponseURLProtocol.self],
            maximumResponseBytes: 16
        )

        do {
            _ = try await transport.send(OAuthTokenRefreshRequest(
                endpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                formData: Data("grant_type=refresh_token".utf8)
            ))
            XCTFail("oversized OAuth response must fail during transport")
        } catch {
            XCTAssertEqual(error as? OAuthTokenManagerError, .responseTooLarge(limit: 16))
        }
        XCTAssertLessThanOrEqual(BoundedOAuthResponseURLProtocol.deliveredBytes, 24)
    }

    func testRefreshTokenIsAtomicallyReplacedOnlyWhenResponseProvidesOne() async throws {
        let firstEntry = validEntry()
        let firstStorage = FakeOAuthTokenSecretStorage(
            initial: [
                firstEntry.id: try expiredSecret(
                    entry: firstEntry,
                    refreshToken: "old-refresh"
                ).keychainValue()
            ]
        )
        let firstManager = OAuthTokenManager(
            storage: firstStorage,
            transport: FakeOAuthTokenRefreshTransport(
                response: jsonResponse(
                    #"{"access_token":"access-a","refresh_token":"new-refresh","expires_in":3600}"#
                )
            )
        )
        _ = try await firstManager.accessToken(
            for: firstEntry,
            providerKind: .gemini,
            asOf: now
        )
        let firstStoredValue = await firstStorage.value(for: firstEntry.id)
        let replaced = try OAuthTokenSecret(keychainValue: XCTUnwrap(firstStoredValue))
        XCTAssertEqual(replaced.refreshToken, "new-refresh")

        let secondEntry = validEntry()
        let secondStorage = FakeOAuthTokenSecretStorage(
            initial: [
                secondEntry.id: try expiredSecret(
                    entry: secondEntry,
                    refreshToken: "keep-refresh"
                ).keychainValue()
            ]
        )
        let secondManager = OAuthTokenManager(
            storage: secondStorage,
            transport: FakeOAuthTokenRefreshTransport(
                response: jsonResponse(
                    #"{"access_token":"access-b","expires_in":3600}"#
                )
            )
        )
        _ = try await secondManager.accessToken(
            for: secondEntry,
            providerKind: .gemini,
            asOf: now
        )
        let secondStoredValue = await secondStorage.value(for: secondEntry.id)
        let preserved = try OAuthTokenSecret(keychainValue: XCTUnwrap(secondStoredValue))
        XCTAssertEqual(preserved.refreshToken, "keep-refresh")
    }

    func testConsumerAndInvalidOAuthConfigurationsFailBeforeStorageOrTransport() async {
        var consumer = validEntry()
        consumer.intendedUse = .consumerSubscription
        var invalid = validEntry()
        invalid.oauth?.tokenEndpoint = URL(string: "http://oauth2.googleapis.com/token")!
        let storage = FakeOAuthTokenSecretStorage(initial: [:])
        let transport = FakeOAuthTokenRefreshTransport()
        let manager = OAuthTokenManager(storage: storage, transport: transport)

        do {
            _ = try await manager.accessToken(
                for: consumer,
                providerKind: .gemini,
                asOf: now
            )
            XCTFail("consumer subscription must fail closed")
        } catch {
            XCTAssertEqual(
                error as? OAuthTokenManagerError,
                .complianceBlocked(.consumerSubscriptionIsNotDeveloperAPI)
            )
        }

        do {
            _ = try await manager.accessToken(
                for: invalid,
                providerKind: .gemini,
                asOf: now
            )
            XCTFail("insecure endpoint must fail closed")
        } catch {
            XCTAssertEqual(
                error as? OAuthTokenManagerError,
                .configurationInvalid(.insecureTokenEndpoint)
            )
        }

        let readCount = await storage.readCount()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(requestCount, 0)
    }

    func testTransportErrorIsStructuredAndNeverIncludesSecretValues() async throws {
        let entry = validEntry()
        let accessMarker = "ACCESS-SECRET-MARKER"
        let refreshMarker = "REFRESH-SECRET-MARKER"
        let storage = FakeOAuthTokenSecretStorage(
            initial: [
                entry.id: try boundSecret(
                    entry: entry,
                    accessToken: accessMarker,
                    refreshToken: refreshMarker,
                    expiresAt: now.addingTimeInterval(-1)
                ).keychainValue()
            ]
        )
        let manager = OAuthTokenManager(
            storage: storage,
            transport: FakeOAuthTokenRefreshTransport(error: FakeOAuthTransportError.failed)
        )

        do {
            _ = try await manager.accessToken(
                for: entry,
                providerKind: .gemini,
                asOf: now
            )
            XCTFail("transport failure expected")
        } catch {
            XCTAssertEqual(error as? OAuthTokenManagerError, .transportFailure)
            let rendered = String(describing: error)
            XCTAssertFalse(rendered.contains(accessMarker))
            XCTAssertFalse(rendered.contains(refreshMarker))
        }
    }

    @MainActor
    func testAuthorizationFlowBuildsOfficialGeminiPKCERequestAndStoresBoundSecret() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(initial: [:])
        let browser = FakeOAuthAuthorizationSession()
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(
                #"{"access_token":"issued-access","refresh_token":"issued-refresh","expires_in":3600,"scope":"https://www.googleapis.com/auth/cloud-platform"}"#
            )
        )
        let proof = OAuthPKCEProof(
            verifier: String(repeating: "v", count: 64),
            state: "state-marker",
            nonce: "nonce-marker"
        )
        await browser.setCallbackBuilder { requestURL in
            let query = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            XCTAssertEqual(query?.first(where: { $0.name == "state" })?.value, proof.state)
            XCTAssertEqual(query?.first(where: { $0.name == "nonce" })?.value, proof.nonce)
            XCTAssertEqual(query?.first(where: { $0.name == "scope" })?.value,
                           "https://www.googleapis.com/auth/cloud-platform")
            XCTAssertEqual(requestURL.host, "accounts.google.com")
            return URL(string: "http://127.0.0.1:11469/oauth/callback?code=auth-code&state=state-marker")!
        }
        let flow = OAuthAuthorizationFlow(
            storage: storage,
            transport: transport,
            authorizationSession: browser,
            proofFactory: { proof }
        )

        try await flow.authorize(
            entry: entry,
            providerKind: .gemini,
            asOf: now
        )

        let requests = await transport.requests()
        let exchange = try XCTUnwrap(requests.first)
        let fields = formFields(exchange.formData)
        XCTAssertEqual(exchange.endpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "auth-code")
        XCTAssertEqual(fields["code_verifier"], proof.verifier)
        XCTAssertEqual(fields["client_id"], "public-native-client-id")
        XCTAssertNil(fields["client_secret"])

        let storedValue = await storage.value(for: entry.id)
        let stored = try OAuthTokenSecret(keychainValue: XCTUnwrap(storedValue))
        XCTAssertEqual(stored.accessToken, "issued-access")
        XCTAssertEqual(stored.refreshToken, "issued-refresh")
        XCTAssertEqual(stored.providerID, entry.providerID)
        XCTAssertEqual(stored.providerKind, .gemini)
        XCTAssertEqual(stored.canonicalOrigin,
                       "https://generativelanguage.googleapis.com")
    }

    @MainActor
    func testAuthorizationFlowRejectsStateMismatchWithoutTokenExchangeOrStorage() async throws {
        let entry = validEntry()
        let storage = FakeOAuthTokenSecretStorage(initial: [:])
        let browser = FakeOAuthAuthorizationSession(
            callback: URL(
                string: "http://127.0.0.1:11469/oauth/callback?code=auth-code&state=attacker"
            )!
        )
        let transport = FakeOAuthTokenRefreshTransport()
        let flow = OAuthAuthorizationFlow(
            storage: storage,
            transport: transport,
            authorizationSession: browser,
            proofFactory: {
                OAuthPKCEProof(
                    verifier: String(repeating: "v", count: 64),
                    state: "expected",
                    nonce: "nonce"
                )
            }
        )

        do {
            try await flow.authorize(entry: entry, providerKind: .gemini, asOf: now)
            XCTFail("state mismatch must fail closed")
        } catch {
            XCTAssertEqual(error as? OAuthAuthorizationFlowError, .stateMismatch)
        }
        let requestCount = await transport.requestCount()
        let storedValue = await storage.value(for: entry.id)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(storedValue)
    }

    @MainActor
    func testAuthorizationFlowRejectsConsumerSubscriptionBeforeOpeningBrowser() async throws {
        var entry = validEntry()
        entry.intendedUse = .consumerSubscription
        let browser = FakeOAuthAuthorizationSession()
        let transport = FakeOAuthTokenRefreshTransport()
        let storage = FakeOAuthTokenSecretStorage(initial: [:])
        let flow = OAuthAuthorizationFlow(
            storage: storage,
            transport: transport,
            authorizationSession: browser
        )

        do {
            try await flow.authorize(entry: entry, providerKind: .gemini, asOf: now)
            XCTFail("consumer subscription OAuth must not open")
        } catch {
            XCTAssertEqual(
                error as? OAuthAuthorizationFlowError,
                .complianceBlocked(.consumerSubscriptionIsNotDeveloperAPI)
            )
        }
        let requestCount = await transport.requestCount()
        let browserStartCount = await browser.startCount()
        XCTAssertEqual(browserStartCount, 0)
        XCTAssertEqual(requestCount, 0)
    }

    func testPKCEProofUsesHighEntropyURLSafeValuesAndS256Challenge() throws {
        let proof = try OAuthPKCEProof.secureRandom()
        XCTAssertGreaterThanOrEqual(proof.verifier.count, 43)
        XCTAssertGreaterThanOrEqual(proof.state.count, 32)
        XCTAssertGreaterThanOrEqual(proof.nonce.count, 32)
        XCTAssertFalse(proof.verifier.contains("="))
        XCTAssertFalse(proof.codeChallenge.contains("="))
        XCTAssertNotEqual(proof.codeChallenge, proof.verifier)
    }

    func testLoopbackAuthorizationSessionReceivesOnlyExactCallbackAndReturnsNoSecrets() async throws {
        let loopbackLock = try OAuthLoopbackTestLock()
        defer { loopbackLock.unlock() }
        let opener = FakeOAuthBrowserOpener()
        let session = LoopbackOAuthAuthorizationSession(browserOpener: opener)
        let authorizationURL = URL(
            string: "https://accounts.google.com/o/oauth2/v2/auth?state=browser-state"
        )!
        let authentication = Task {
            try await session.authenticate(
                at: authorizationURL,
                callbackURL: URL(
                    string: "http://127.0.0.1:11469/oauth/callback"
                )!,
                timeoutNanoseconds: 2_000_000_000
            )
        }

        let openedURL = try await waitForBrowserOpen(opener)
        XCTAssertEqual(openedURL, authorizationURL)

        let wrongPath = URL(
            string: "http://127.0.0.1:11469/not-the-callback?code=path-secret"
        )!
        let (wrongBody, wrongResponse) = try await loopbackURLSession().data(from: wrongPath)
        XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(String(decoding: wrongBody, as: UTF8.self).contains("path-secret"))

        var oversizedRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:11469/oauth/callback")!
        )
        oversizedRequest.setValue(
            String(repeating: "a", count: LoopbackOAuthAuthorizationSession.maximumHeaderBytes),
            forHTTPHeaderField: "X-Oversized"
        )
        let (oversizedBody, oversizedResponse) = try await loopbackURLSession()
            .data(for: oversizedRequest)
        XCTAssertEqual((oversizedResponse as? HTTPURLResponse)?.statusCode, 431)
        XCTAssertFalse(String(decoding: oversizedBody, as: UTF8.self).contains("aaaa"))

        let callbackURL = URL(
            string: "http://127.0.0.1:11469/oauth/callback?code=callback-secret&state=expected-state"
        )!
        let (successBody, successResponse) = try await loopbackURLSession().data(from: callbackURL)
        XCTAssertEqual((successResponse as? HTTPURLResponse)?.statusCode, 200)
        let rendered = String(decoding: successBody, as: UTF8.self)
        XCTAssertFalse(rendered.contains("callback-secret"))
        XCTAssertFalse(rendered.contains("expected-state"))
        let receivedCallbackURL = try await authentication.value
        XCTAssertEqual(receivedCallbackURL, callbackURL)
    }

    func testAADedicatedLoopbackPortOccupationFailsClosedBeforeBrowserOpen() async throws {
        let loopbackLock = try OAuthLoopbackTestLock()
        defer { loopbackLock.unlock() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(
                rawValue: LoopbackOAuthAuthorizationSession.port
            )!
        )
        let blocker = try NWListener(using: parameters)
        let ready = expectation(description: "blocking listener ready")
        blocker.newConnectionHandler = { connection in connection.cancel() }
        blocker.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        blocker.start(queue: DispatchQueue(label: "oauth-loopback-port-blocker"))
        await fulfillment(of: [ready], timeout: 2)
        defer { blocker.cancel() }

        let opener = FakeOAuthBrowserOpener()
        let session = LoopbackOAuthAuthorizationSession(browserOpener: opener)
        do {
            _ = try await session.authenticate(
                at: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                callbackURL: URL(
                    string: "http://127.0.0.1:11469/oauth/callback"
                )!,
                timeoutNanoseconds: 1_000_000_000
            )
            XCTFail("an occupied dedicated callback port must fail closed")
        } catch {
            XCTAssertEqual(
                error as? OAuthAuthorizationFlowError,
                .loopbackListenerUnavailable
            )
        }
        let openedCount = await opener.openedCount()
        XCTAssertEqual(openedCount, 0)
    }

    func testLoopbackAuthorizationDropsSlowHeaderConnectionAndAcceptsRealCallback() async throws {
        let loopbackLock = try OAuthLoopbackTestLock()
        defer { loopbackLock.unlock() }
        let opener = FakeOAuthBrowserOpener()
        let session = LoopbackOAuthAuthorizationSession(
            browserOpener: opener,
            connectionHeaderTimeoutSeconds: 0.1
        )
        let authentication = Task {
            try await session.authenticate(
                at: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                callbackURL: URL(
                    string: "http://127.0.0.1:11469/oauth/callback"
                )!,
                timeoutNanoseconds: 2_000_000_000
            )
        }

        _ = try await waitForBrowserOpen(opener)
        let slowConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: LoopbackOAuthAuthorizationSession.port)!,
            using: .tcp
        )
        let connected = expectation(description: "slow callback connection accepted")
        slowConnection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        slowConnection.start(queue: DispatchQueue(label: "oauth-slow-header-test"))
        await fulfillment(of: [connected], timeout: 1)
        try await Task.sleep(nanoseconds: 250_000_000)

        let callbackURL = URL(
            string: "http://127.0.0.1:11469/oauth/callback?code=real-code&state=expected"
        )!
        let (_, response) = try await loopbackURLSession().data(from: callbackURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await authentication.value
        XCTAssertEqual(received, callbackURL)
        slowConnection.cancel()
    }

    func testZZCancellingLoopbackAuthorizationClosesPendingSession() async throws {
        let loopbackLock = try OAuthLoopbackTestLock()
        defer { loopbackLock.unlock() }
        let opener = FakeOAuthBrowserOpener()
        let session = LoopbackOAuthAuthorizationSession(browserOpener: opener)
        let authentication = Task {
            try await session.authenticate(
                at: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                callbackURL: URL(
                    string: "http://127.0.0.1:11469/oauth/callback"
                )!,
                timeoutNanoseconds: 2_000_000_000
            )
        }

        _ = try await waitForBrowserOpen(opener)
        await session.cancel()
        do {
            _ = try await authentication.value
            XCTFail("cancelled callback listener must not complete successfully")
        } catch {
            XCTAssertEqual(error as? OAuthAuthorizationFlowError, .cancelled)
        }
    }

    @MainActor
    func testAuthorizationFlowTimesOutAndDoesNotExchangeOrStoreTokens() async throws {
        let entry = validEntry()
        let browser = FakeOAuthAuthorizationSession(delayNanoseconds: 1_000_000_000)
        let transport = FakeOAuthTokenRefreshTransport()
        let storage = FakeOAuthTokenSecretStorage(initial: [:])
        let flow = OAuthAuthorizationFlow(
            storage: storage,
            transport: transport,
            authorizationSession: browser,
            authorizationTimeoutNanoseconds: 1_000_000
        )

        do {
            try await flow.authorize(entry: entry, providerKind: .gemini, asOf: now)
            XCTFail("authorization must time out")
        } catch {
            XCTAssertEqual(error as? OAuthAuthorizationFlowError, .timedOut)
        }
        let requestCount = await transport.requestCount()
        let storedValue = await storage.value(for: entry.id)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(storedValue)
    }

    @MainActor
    func testAuthorizationFlowRejectsMissingGrantedScopeAndLocalRevocationDeletesSecret() async throws {
        let entry = validEntry()
        let initial = try boundSecret(
            entry: entry,
            accessToken: "existing",
            refreshToken: "existing-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        ).keychainValue()
        let storage = FakeOAuthTokenSecretStorage(initial: [entry.id: initial])
        let browser = FakeOAuthAuthorizationSession(
            callback: URL(
                string: "http://127.0.0.1:11469/oauth/callback?code=auth-code&state=expected"
            )!
        )
        let transport = FakeOAuthTokenRefreshTransport(
            response: jsonResponse(
                #"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600,"scope":"openid"}"#
            )
        )
        let flow = OAuthAuthorizationFlow(
            storage: storage,
            transport: transport,
            authorizationSession: browser,
            proofFactory: {
                OAuthPKCEProof(
                    verifier: String(repeating: "v", count: 64),
                    state: "expected",
                    nonce: "nonce"
                )
            }
        )

        do {
            try await flow.authorize(entry: entry, providerKind: .gemini, asOf: now)
            XCTFail("missing granted scope must fail closed")
        } catch {
            XCTAssertEqual(error as? OAuthAuthorizationFlowError, .invalidTokenResponse)
        }
        let preserved = await storage.value(for: entry.id)
        XCTAssertEqual(preserved, initial)

        try await flow.revokeLocalAuthorization(for: entry.id)
        let revoked = await storage.value(for: entry.id)
        XCTAssertNil(revoked)
    }

    private func validEntry() -> CredentialPoolEntry {
        CredentialPoolEntry(
            providerID: UUID(),
            label: "Google developer OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: OAuthPKCEConfiguration(
                authorizationEndpoint: URL(
                    string: "https://accounts.google.com/o/oauth2/v2/auth"
                )!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                clientID: "public-native-client-id",
                billingProjectID: "modelhub-oauth-project",
                redirectURI: URL(string: "http://127.0.0.1:11469/oauth/callback")!,
                scopes: ["https://www.googleapis.com/auth/cloud-platform"],
                evidence: OAuthAuthorizationEvidence(
                    officialDocumentationURL: URL(
                        string: "https://ai.google.dev/gemini-api/docs/oauth"
                    )!,
                    reviewedAt: now.addingTimeInterval(-86_400),
                    expiresAt: now.addingTimeInterval(86_400),
                    approvedScopes: [
                        "https://www.googleapis.com/auth/cloud-platform"
                    ]
                )
            )
        )
    }

    private func expiredSecret(
        entry: CredentialPoolEntry,
        refreshToken: String
    ) -> OAuthTokenSecret {
        boundSecret(
            entry: entry,
            accessToken: "expired",
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(-1)
        )
    }

    private func boundSecret(
        entry: CredentialPoolEntry,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date
    ) -> OAuthTokenSecret {
        OAuthTokenSecret(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            providerID: entry.providerID,
            providerKind: .gemini,
            canonicalOrigin: "https://generativelanguage.googleapis.com"
        )
    }

    private func jsonResponse(_ json: String) -> OAuthTokenRefreshResponse {
        OAuthTokenRefreshResponse(statusCode: 200, data: Data(json.utf8))
    }

    private func formFields(_ data: Data) -> [String: String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "&")
            .reduce(into: [:]) { result, item in
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return }
                result[pair[0].removingPercentEncoding ?? pair[0]] = pair[1]
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? pair[1]
            }
    }

    private func loopbackURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }

    private func waitForBrowserOpen(
        _ opener: FakeOAuthBrowserOpener
    ) async throws -> URL {
        for _ in 0..<200 {
            if let openedURL = await opener.firstOpenedURL() { return openedURL }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw OAuthAuthorizationFlowError.timedOut
    }
}

private final class OAuthLoopbackTestLock {
    private var descriptor: Int32

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelhub-oauth-loopback-tests.lock")
            .path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            descriptor = -1
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}

private final class BoundedOAuthResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _deliveredBytes = 0
    private let stateLock = NSLock()
    private var stopped = false

    static var deliveredBytes: Int {
        lock.withLock { _deliveredBytes }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._deliveredBytes = 0 }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.002)
                guard !self.stateLock.withLock({ self.stopped }) else { return }
                let chunk = Data(repeating: 0x61, count: 8)
                Self.lock.withLock { Self._deliveredBytes += chunk.count }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

private enum FakeOAuthTransportError: Error {
    case failed
}

private actor FakeOAuthBrowserOpener: OAuthBrowserOpening {
    private var openedURLs: [URL] = []

    func open(_ url: URL) async throws {
        openedURLs.append(url)
    }

    func firstOpenedURL() -> URL? {
        openedURLs.first
    }

    func openedCount() -> Int {
        openedURLs.count
    }
}

private actor FakeOAuthAuthorizationSession: OAuthAuthorizationSessioning {
    private var callback: URL?
    private var callbackBuilder: (@Sendable (URL) -> URL)?
    private var starts = 0
    private let delayNanoseconds: UInt64

    init(callback: URL? = nil, delayNanoseconds: UInt64 = 0) {
        self.callback = callback
        self.delayNanoseconds = delayNanoseconds
    }

    func setCallbackBuilder(_ builder: @escaping @Sendable (URL) -> URL) {
        callbackBuilder = builder
    }

    func authenticate(
        at authorizationURL: URL,
        callbackURL: URL,
        timeoutNanoseconds: UInt64
    ) async throws -> URL {
        starts += 1
        if delayNanoseconds > 0 {
            if delayNanoseconds > timeoutNanoseconds {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw OAuthAuthorizationFlowError.timedOut
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let callbackBuilder { return callbackBuilder(authorizationURL) }
        if let callback { return callback }
        throw OAuthAuthorizationFlowError.cancelled
    }

    func cancel() async {}

    func startCount() -> Int { starts }
}

private actor FakeOAuthTokenSecretStorage: OAuthTokenSecretStoring {
    private var values: [UUID: String]
    private var reads = 0

    init(initial: [UUID: String]) {
        values = initial
    }

    func readValue(for credentialID: UUID) async throws -> String? {
        reads += 1
        return values[credentialID]
    }

    func replaceValue(_ value: String, for credentialID: UUID) async throws {
        values[credentialID] = value
    }

    func deleteValue(for credentialID: UUID) async throws {
        values.removeValue(forKey: credentialID)
    }

    func value(for credentialID: UUID) -> String? {
        values[credentialID]
    }

    func readCount() -> Int {
        reads
    }
}

private actor FakeOAuthTokenRefreshTransport: OAuthTokenRefreshTransporting {
    private let response: OAuthTokenRefreshResponse
    private let error: Error?
    private let delayNanoseconds: UInt64
    private var sent: [OAuthTokenRefreshRequest] = []

    init(
        response: OAuthTokenRefreshResponse = OAuthTokenRefreshResponse(
            statusCode: 500,
            data: Data()
        ),
        error: Error? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.response = response
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func send(_ request: OAuthTokenRefreshRequest) async throws -> OAuthTokenRefreshResponse {
        sent.append(request)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        return response
    }

    func requests() -> [OAuthTokenRefreshRequest] {
        sent
    }

    func requestCount() -> Int {
        sent.count
    }
}
