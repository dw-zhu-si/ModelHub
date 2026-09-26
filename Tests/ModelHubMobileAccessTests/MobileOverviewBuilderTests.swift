import XCTest
import ModelHubCore
@testable import ModelHubMobileAccess

final class MobileOverviewBuilderTests: XCTestCase {
    func testOverviewSelectsFirstHealthyRouteAndOnlyReturnsAggregates() throws {
        let first = ProviderConfig(
            name: "Primary",
            kind: .unifiedCompatible,
            baseURL: "https://secret-provider.example/v1",
            models: ["unhealthy", "healthy"]
        )
        let second = ProviderConfig(
            name: "Backup",
            kind: .unifiedCompatible,
            baseURL: "https://backup.example/v1",
            models: ["other"]
        )
        let route = RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: first.id, model: "healthy")]
        )
        let configuration = AppConfiguration(
            providers: [first, second],
            routes: [route],
            modelHealth: [
                ModelHealthRecord(providerID: first.id, model: "unhealthy", status: .unavailable),
                ModelHealthRecord(providerID: first.id, model: "healthy", status: .available),
                ModelHealthRecord(providerID: second.id, model: "other", status: .configurationRequired)
            ]
        )

        let overview = MobileOverviewBuilder.make(
            configuration: configuration,
            gatewayVersion: "1.10.0",
            isGatewayRunning: true,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(overview.defaultModel, "smart")
        XCTAssertEqual(overview.enabledProviderCount, 2)
        XCTAssertEqual(overview.modelHealth.available, 1)
        XCTAssertEqual(overview.modelHealth.unavailable, 1)
        XCTAssertEqual(overview.modelHealth.configurationRequired, 1)
        XCTAssertEqual(overview.providers.map(\.name), ["Primary", "Backup"])

        let data = try JSONEncoder().encode(overview)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("secret-provider.example"))
        XCTAssertFalse(json.contains("baseURL"))
        XCTAssertFalse(json.lowercased().contains("api_key"))
    }

    func testOverviewFallsBackToHealthyProviderModelAndNeverDefaultsToQuarantinedModel() {
        let provider = ProviderConfig(
            name: "Provider",
            kind: .unifiedCompatible,
            baseURL: "https://provider.example/v1",
            models: ["bad", "good"]
        )
        let configuration = AppConfiguration(
            providers: [provider],
            modelHealth: [
                ModelHealthRecord(providerID: provider.id, model: "bad", status: .unavailable),
                ModelHealthRecord(providerID: provider.id, model: "good", status: .available)
            ]
        )

        let overview = MobileOverviewBuilder.make(
            configuration: configuration,
            gatewayVersion: "1.10.0",
            isGatewayRunning: true
        )
        XCTAssertEqual(overview.defaultModel, "Provider/good")

        let unavailableOnly = AppConfiguration(
            providers: [provider],
            modelHealth: provider.models.map {
                ModelHealthRecord(providerID: provider.id, model: $0, status: .unavailable)
            }
        )
        XCTAssertNil(MobileOverviewBuilder.make(
            configuration: unavailableOnly,
            gatewayVersion: "1.10.0",
            isGatewayRunning: true
        ).defaultModel)
    }
}
