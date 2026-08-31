import Foundation
import XCTest
@testable import ModelHubCore

final class ConfigurationPersistenceTests: XCTestCase {
    func testLegacyConfigurationWithoutCredentialPoolsDecodesWithEmptyPoolList() throws {
        let data = Data(#"{"providers":[],"routes":[],"server":{}}"#.utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertTrue(configuration.credentialPools.isEmpty)
    }

    func testCredentialPoolPersistsOnlyNonSecretMetadata() throws {
        let providerID = UUID()
        let credentialID = UUID()
        let sentinelSecret = "secret-value-that-must-never-enter-configuration"
        let entry = CredentialPoolEntry(
            id: credentialID,
            providerID: providerID,
            label: "Google Cloud OAuth",
            secretKind: .oauthRefreshToken,
            intendedUse: .developerAPI,
            oauth: OAuthPKCEConfiguration(
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                clientID: "public-native-client-id",
                billingProjectID: "modelhub-oauth-project",
                redirectURI: URL(string: "com.local.modelhub:/oauth/callback")!,
                scopes: ["https://www.googleapis.com/auth/cloud-platform"],
                codeChallengeMethod: .s256,
                requiresState: true,
                requiresNonce: true,
                evidence: .init(
                    officialDocumentationURL: URL(string: "https://ai.google.dev/gemini-api/docs/oauth")!,
                    reviewedAt: Date(timeIntervalSince1970: 1_787_702_400),
                    expiresAt: Date(timeIntervalSince1970: 1_795_564_800),
                    approvedScopes: ["https://www.googleapis.com/auth/cloud-platform"]
                )
            )
        )
        let configuration = AppConfiguration(
            credentialPools: [.init(providerID: providerID, entries: [entry])]
        )

        let data = try JSONEncoder().encode(configuration)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var pools = try XCTUnwrap(root["credentialPools"] as? [[String: Any]])
        var entries = try XCTUnwrap(pools[0]["entries"] as? [[String: Any]])
        entries[0]["refreshToken"] = sentinelSecret
        pools[0]["entries"] = entries
        root["credentialPools"] = pools
        let contaminatedData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: contaminatedData)
        let sanitizedData = try JSONEncoder().encode(decoded)
        let encoded = String(decoding: sanitizedData, as: UTF8.self)

        XCTAssertEqual(decoded.credentialPools.first?.entries.first?.id, credentialID)
        XCTAssertFalse(encoded.contains(sentinelSecret))
        XCTAssertFalse(encoded.contains("accessToken"))
        XCTAssertFalse(encoded.contains("refreshToken"))
        XCTAssertFalse(encoded.contains("apiKeyValue"))
    }

    func testNewestRevisionWinsEvenWhenAnOlderSnapshotArrivesLater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ModelHubConfigurationPersistenceTests-\(UUID().uuidString)")
        let url = directory.appending(path: "configuration.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = ConfigurationPersistence()
        var newest = AppConfiguration()
        newest.providers = [ProviderConfig(
            name: "newest",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )]
        var stale = AppConfiguration()
        stale.providers = [ProviderConfig(
            name: "stale",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1"
        )]

        let newestResult = try await persistence.persist(newest, revision: 2, to: url)
        let staleResult = try await persistence.persist(stale, revision: 1, to: url)
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(newestResult, .written(revision: 2))
        XCTAssertEqual(staleResult, .skippedStale(revision: 1, latestRevision: 2))
        XCTAssertEqual(decoded.providers.map(\.name), ["newest"])
        let latestRevision = await persistence.latestWrittenRevision()
        XCTAssertEqual(latestRevision, 2)
    }

    func testPersistenceCreatesParentDirectoryAndWritesDecodablePrettyJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ModelHubConfigurationPersistenceTests-\(UUID().uuidString)")
        let url = directory.appending(path: "nested/configuration.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = ConfigurationPersistence()
        let configuration = AppConfiguration(
            providers: [ProviderConfig(
                name: "provider",
                kind: .unifiedCompatible,
                baseURL: "https://example.com/v1"
            )]
        )

        let result = try await persistence.persist(configuration, revision: 1, to: url)
        XCTAssertEqual(result, .written(revision: 1))
        let data = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONDecoder().decode(AppConfiguration.self, from: data))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\n"))
    }
}
