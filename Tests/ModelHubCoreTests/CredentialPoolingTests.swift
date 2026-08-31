import XCTest
@testable import ModelHubCore

final class CredentialPoolingTests: XCTestCase {
    private let policyReviewDate = Date(timeIntervalSince1970: 1_787_788_800)

    private func validGeminiOAuthConfiguration() -> OAuthPKCEConfiguration {
        OAuthPKCEConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: "public-native-client-id",
            billingProjectID: "modelhub-oauth-project",
            redirectURI: URL(string: "http://127.0.0.1:11469/oauth/callback")!,
            scopes: ["https://www.googleapis.com/auth/cloud-platform"],
            codeChallengeMethod: .s256,
            requiresState: true,
            requiresNonce: true,
            evidence: .init(
                officialDocumentationURL: URL(string: "https://ai.google.dev/gemini-api/docs/oauth")!,
                reviewedAt: policyReviewDate.addingTimeInterval(-86_400),
                expiresAt: policyReviewDate.addingTimeInterval(86_400),
                approvedScopes: ["https://www.googleapis.com/auth/cloud-platform"]
            )
        )
    }

    func testCredentialPriorityRejectsOverflowingUntrustedMetadata() throws {
        let providerID = UUID()
        let entry = CredentialPoolEntry(
            providerID: providerID,
            label: "bounded",
            secretKind: .apiKey,
            intendedUse: .developerAPI
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        object["priority"] = Int.max
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(CredentialPoolEntry.self, from: data))
    }

    func testBackupRejectsMoreThanMaximumCredentialEntries() {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )
        let entries = (0...CredentialPoolConfiguration.maximumEntries).map { index in
            CredentialPoolEntry(
                providerID: provider.id,
                label: "key-\(index)",
                secretKind: .apiKey,
                intendedUse: .developerAPI,
                priority: index
            )
        }
        let configuration = AppConfiguration(
            providers: [provider],
            credentialPools: [.init(providerID: provider.id, entries: entries)]
        )

        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(configuration: configuration, appVersion: "test")
        )
    }

    func testBackupRejectsDuplicateCredentialIDsAcrossProviders() {
        let first = ProviderConfig(
            name: "first",
            kind: .unifiedCompatible,
            baseURL: "https://first.example/v1"
        )
        let second = ProviderConfig(
            name: "second",
            kind: .unifiedCompatible,
            baseURL: "https://second.example/v1"
        )
        let duplicateID = UUID()
        let configuration = AppConfiguration(
            providers: [first, second],
            credentialPools: [
                .init(providerID: first.id, entries: [.init(
                    id: duplicateID,
                    providerID: first.id,
                    label: "first",
                    secretKind: .apiKey,
                    intendedUse: .developerAPI
                )]),
                .init(providerID: second.id, entries: [.init(
                    id: duplicateID,
                    providerID: second.id,
                    label: "second",
                    secretKind: .apiKey,
                    intendedUse: .developerAPI
                )])
            ]
        )

        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(configuration: configuration, appVersion: "test")
        )
    }

    func testBackupRejectsProviderMismatchAndInvalidManualSelection() {
        let provider = ProviderConfig(
            name: "provider",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )
        let wrongProviderID = UUID()
        let mismatched = CredentialPoolEntry(
            providerID: wrongProviderID,
            label: "wrong",
            secretKind: .apiKey,
            intendedUse: .developerAPI
        )
        let mismatchedConfiguration = AppConfiguration(
            providers: [provider],
            credentialPools: [.init(providerID: provider.id, entries: [mismatched])]
        )
        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(
                configuration: mismatchedConfiguration,
                appVersion: "test"
            )
        )

        let valid = CredentialPoolEntry(
            providerID: provider.id,
            label: "valid",
            secretKind: .apiKey,
            intendedUse: .developerAPI
        )
        let invalidSelection = AppConfiguration(
            providers: [provider],
            credentialPools: [.init(
                providerID: provider.id,
                mode: .manualOnly,
                entries: [valid],
                manuallySelectedCredentialID: UUID()
            )]
        )
        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(
                configuration: invalidSelection,
                appVersion: "test"
            )
        )
    }

    func testConsumerSubscriptionOAuthIsNeverEligibleForGatewayAutomation() {
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "个人订阅",
            secretKind: .oauthRefreshToken,
            intendedUse: .consumerSubscription
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .anthropic
            ),
            .blocked(.consumerSubscriptionIsNotDeveloperAPI)
        )
    }

    func testOfficialGeminiDeveloperOAuthCanUseFailoverPool() {
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: validGeminiOAuthConfiguration()
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .allowed
        )
    }

    func testGeminiDeveloperOAuthWithoutOwnBillingProjectFailsClosed() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.billingProjectID = nil
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthProviderMetadataNotOfficial)
        )
    }

    func testOAuthWithoutNonSecretPKCEMetadataFailsClosed() {
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthConfigurationMissing)
        )
    }

    func testOAuthAuthorizationAndTokenEndpointsMustUseHTTPS() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.authorizationEndpoint = URL(string: "http://accounts.google.com/o/oauth2/v2/auth")!

        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .insecureAuthorizationEndpoint
        )

        configuration = validGeminiOAuthConfiguration()
        configuration.tokenEndpoint = URL(string: "http://oauth2.googleapis.com/token")!
        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .insecureTokenEndpoint
        )
    }

    func testOAuthRequiresExactLoopbackCallbackAndAllowsPreauthorizationOnly() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.redirectURI = URL(string: "https://example.com/oauth/callback")!
        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .loopbackRedirectRequired
        )

        configuration.redirectURI = URL(string: "http://127.0.0.1/oauth/callback")!
        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .loopbackRedirectRequired
        )

        configuration.redirectURI = URL(string: "http://localhost:11469/oauth/callback")!
        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .loopbackRedirectRequired
        )

        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: validGeminiOAuthConfiguration(),
            requiresReauthorization: true
        )
        XCTAssertEqual(
            CredentialCompliancePolicy.authorizationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .allowed
        )
        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.reauthorizationRequired)
        )
    }

    func testOAuthRequiresS256StateAndNonce() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.codeChallengeMethod = .plain
        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), .pkceS256Required)

        configuration = validGeminiOAuthConfiguration()
        configuration.requiresState = false
        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), .stateRequired)

        configuration = validGeminiOAuthConfiguration()
        configuration.requiresNonce = false
        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), .nonceRequired)
    }

    func testOAuthScopesMustBeNonEmptyAndLimitedToReviewedScopes() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.scopes = []
        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), .scopeRequired)

        configuration = validGeminiOAuthConfiguration()
        configuration.scopes.append("https://www.googleapis.com/auth/generative-language.retriever")
        XCTAssertEqual(
            configuration.validationError(asOf: policyReviewDate),
            .scopeNotApproved("https://www.googleapis.com/auth/generative-language.retriever")
        )
    }

    func testExpiredOAuthEvidenceFailsClosed() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.evidence.expiresAt = policyReviewDate
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), .evidenceExpired)
        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthEvidenceExpired)
        )
    }

    func testOAuthEvidenceMustUseAnOfficialProviderDocumentationHost() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.evidence.officialDocumentationURL = URL(
            string: "https://example.com/copied-oauth-documentation"
        )!
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthEvidenceNotOfficial)
        )
    }

    func testOfficialHostWithUnreviewedDocumentationPathFailsClosed() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.evidence.officialDocumentationURL = URL(
            string: "https://ai.google.dev/unrelated-page"
        )!
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthEvidenceNotOfficial)
        )
    }

    func testHTTPSOAuthEndpointOutsideTheOfficialProviderPolicyFailsClosed() {
        var configuration = validGeminiOAuthConfiguration()
        configuration.tokenEndpoint = URL(string: "https://example.com/token")!
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthProviderMetadataNotOfficial)
        )
    }

    func testSelfDeclaredOAuthEvidenceCannotExpandOfficialScopePolicy() {
        var configuration = validGeminiOAuthConfiguration()
        let unapprovedScope = "https://www.googleapis.com/auth/generative-language.retriever"
        configuration.scopes = [unapprovedScope]
        configuration.evidence.approvedScopes = [unapprovedScope]
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: configuration
        )

        XCTAssertEqual(configuration.validationError(asOf: policyReviewDate), nil)
        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .gemini,
                asOf: policyReviewDate
            ),
            .blocked(.oauthProviderMetadataNotOfficial)
        )
    }

    func testUndocumentedProviderOAuthFailsClosed() {
        let entry = CredentialPoolEntry(
            providerID: UUID(),
            label: "未验证 OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI
        )

        XCTAssertEqual(
            CredentialCompliancePolicy.automationDecision(
                for: entry,
                providerKind: .xAI
            ),
            .blocked(.providerOAuthNotDocumented)
        )
    }

    func testQuotaFailureNeverRotatesCredential() async {
        let providerID = UUID()
        let primary = CredentialPoolEntry(
            providerID: providerID,
            label: "主凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 0
        )
        let fallback = CredentialPoolEntry(
            providerID: providerID,
            label: "备用凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 1
        )
        let selector = CredentialPoolSelector()

        let first = await selector.select(
            providerKind: .gemini,
            configuration: .init(
                providerID: providerID,
                mode: .failoverOnly,
                entries: [primary, fallback]
            )
        )
        await selector.recordFailure(
            credentialID: primary.id,
            providerID: providerID,
            reason: .quotaOrRateLimited
        )
        let afterQuota = await selector.select(
            providerKind: .gemini,
            configuration: .init(
                providerID: providerID,
                mode: .failoverOnly,
                entries: [primary, fallback]
            )
        )

        XCTAssertEqual(first?.id, primary.id)
        XCTAssertEqual(afterQuota?.id, primary.id)
    }

    func testManualPoolRequiresExplicitSelectionAndNeverFailsOver() async {
        let providerID = UUID()
        let selected = CredentialPoolEntry(
            providerID: providerID,
            label: "手动凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 0
        )
        let other = CredentialPoolEntry(
            providerID: providerID,
            label: "其他凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 1
        )
        let selector = CredentialPoolSelector()

        let withoutSelection = await selector.select(
            providerKind: .gemini,
            configuration: .init(
                providerID: providerID,
                mode: .manualOnly,
                entries: [selected, other]
            )
        )
        await selector.recordFailure(
            credentialID: selected.id,
            providerID: providerID,
            reason: .revokedOrInvalid
        )
        let afterRevocation = await selector.select(
            providerKind: .gemini,
            configuration: .init(
                providerID: providerID,
                mode: .manualOnly,
                entries: [selected, other],
                manuallySelectedCredentialID: selected.id
            )
        )

        XCTAssertNil(withoutSelection)
        XCTAssertNil(afterRevocation)
    }

    func testRevokedCredentialFailsOverButDoesNotExposeSecretsInConfiguration() async throws {
        let providerID = UUID()
        let primary = CredentialPoolEntry(
            providerID: providerID,
            label: "主凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 0
        )
        let fallback = CredentialPoolEntry(
            providerID: providerID,
            label: "备用凭证",
            secretKind: .apiKey,
            intendedUse: .developerAPI,
            priority: 1
        )
        let configuration = CredentialPoolConfiguration(
            providerID: providerID,
            mode: .failoverOnly,
            entries: [primary, fallback]
        )
        let selector = CredentialPoolSelector()

        await selector.recordFailure(
            credentialID: primary.id,
            providerID: providerID,
            reason: .revokedOrInvalid
        )
        let selected = await selector.select(
            providerKind: .gemini,
            configuration: configuration
        )
        let encoded = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)

        XCTAssertEqual(selected?.id, fallback.id)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("access_token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("refresh_token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("api_key"))
    }
}
