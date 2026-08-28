import Foundation
import XCTest
@testable import ModelHubCore

final class ConfigurationPersistenceTests: XCTestCase {
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
