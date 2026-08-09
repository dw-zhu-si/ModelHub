import XCTest
@testable import ModelHub
@testable import ModelHubCore

final class ModelTestingTests: XCTestCase {
    func testModelPriceRefreshProgressIsBoundedAndReportsCompletion() {
        var progress = ModelPriceRefreshProgress(
            total: 4,
            completed: 1
        )
        XCTAssertEqual(progress.fractionCompleted, 0.25)

        progress.completed = 4
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(
            ModelPriceRefreshProgress(
                total: 0,
                completed: 0
            ).fractionCompleted,
            0
        )
    }

    func testManualTestPlanIncludesQuarantinedChatAndNativeModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "image-model"]
        )
        let health = ModelHealthIndex(records: [
            ModelHealthRecord(
                providerID: provider.id,
                model: "chat-model",
                status: .unavailable
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "image-model",
                status: .unavailable
            )
        ])

        let plan = AppModel.makeManualModelTestPlan(
            providers: [provider],
            health: health
        )

        XCTAssertEqual(plan.candidates.map(\.model), ["chat-model", "image-model"])
        XCTAssertEqual(plan.preflightSkipped, 0)
    }

    func testManualTestPlanDeduplicatesModelsWithoutFilteringHealthyCandidates() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "chat-model"]
        )

        let plan = AppModel.makeManualModelTestPlan(
            providers: [provider],
            health: ModelHealthIndex(records: [])
        )

        XCTAssertEqual(plan.candidates.map(\.model), ["chat-model"])
        XCTAssertEqual(plan.preflightSkipped, 0)
    }
}
