import Foundation
import ModelHubCore
import XCTest
@testable import ModelHub

@MainActor
final class ReviewDemoTests: XCTestCase {
    func testDemoFixtureCoversCoreProductAreasWithoutRealEndpoints() {
        let configuration = AppModel.reviewDemoConfiguration(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(configuration.providers.count, 2)
        XCTAssertEqual(configuration.routes.count, 3)
        XCTAssertFalse(configuration.usage.isEmpty)
        XCTAssertTrue(configuration.modelHealth.contains { $0.status == .available })
        XCTAssertEqual(
            configuration.modelHealth.filter(ModelHealthRecoveryPolicy.isRecoverable).count,
            1
        )
        XCTAssertEqual(configuration.modelHealthActivities.count, 1)
        XCTAssertEqual(configuration.modelHealthActivities.first?.circuitSkipped, 4)
        XCTAssertTrue(configuration.providers.allSatisfy {
            URL(string: $0.baseURL)?.host?.hasSuffix(".invalid") == true
        })

        let categories = configuration.providers
            .flatMap { provider in
                provider.models.flatMap { model in
                    ModelCategory.infer(
                        model: model,
                        capabilities: provider.modelProfiles?[model]?.capabilities ?? []
                    )
                }
            }
        XCTAssertTrue(Set(categories).isSuperset(of: [.reasoning, .text, .image, .music, .video]))
    }

    func testEnteringAndExitingDemoRestoresOriginalInMemoryState() {
        let model = AppModel()
        let originalProvider = ProviderConfig(
            name: "Original",
            kind: .ollama,
            baseURL: "http://127.0.0.1:11434",
            models: ["local-model"]
        )
        model.configuration = AppConfiguration(providers: [originalProvider])
        model.totalRequests = 7
        model.successfulRequests = 6

        model.enterReviewDemoMode()
        XCTAssertTrue(model.isReviewDemoMode)
        XCTAssertNotEqual(model.providers, [originalProvider])

        model.exitReviewDemoMode()
        XCTAssertFalse(model.isReviewDemoMode)
        XCTAssertEqual(model.providers, [originalProvider])
        XCTAssertEqual(model.totalRequests, 7)
        XCTAssertEqual(model.successfulRequests, 6)
    }

    func testTransientRecoveryActionKeepsSyntheticModelQuarantinedAndAddsActivity() throws {
        let model = AppModel()
        model.enterReviewDemoMode()
        let providerID = try XCTUnwrap(model.providers.first?.id)

        XCTAssertEqual(model.recoverableTransientHealthCount(providerID: providerID), 1)

        let recoveredCount = model.recoverTransientNetworkHealth(providerID: providerID)

        XCTAssertEqual(recoveredCount, 1)
        XCTAssertEqual(model.recoverableTransientHealthCount(providerID: providerID), 0)
        XCTAssertEqual(
            model.healthRecord(providerID: providerID, model: "review-text-1")?.status,
            .unknown
        )
        XCTAssertEqual(model.recentModelHealthActivities().first?.kind, .transientRecovery)
        XCTAssertEqual(model.recentModelHealthActivities().first?.recoveredToUnknown, 1)
    }

    func testDemoConsoleProducesLocalDisclosureAndLog() async {
        let model = AppModel()
        model.enterReviewDemoMode()

        await model.runConsole(model: "smart", prompt: "review")

        XCTAssertTrue(model.consoleOutput.contains("REVIEW DEMO"))
        XCTAssertTrue(model.consoleOutput.contains("不会产生费用"))
        XCTAssertEqual(model.logs.first?.provider, "Review Demo")
        XCTAssertEqual(model.logs.first?.statusCode, 200)
    }

    func testDemoMusicConsoleUsesSyntheticProtocolResponseWithoutUpstream() async {
        let model = AppModel()
        model.enterReviewDemoMode()

        await model.runConsole(
            model: "review-music-1",
            prompt: "温暖的钢琴曲",
            operation: .musicGeneration
        )

        XCTAssertTrue(model.consoleOutput.contains("REVIEW DEMO"))
        XCTAssertTrue(model.consoleOutput.contains("music.generation"))
        XCTAssertTrue(model.consoleOutput.contains("未访问上游"))
        XCTAssertEqual(model.logs.first?.provider, "Review Demo")
    }

    func testConsoleModelPickerOnlyIncludesCurrentlyRoutableModels() {
        let model = AppModel()
        model.enterReviewDemoMode()

        let modelIDs = model.availableModelIDsForConsole(operation: .chat)

        XCTAssertTrue(modelIDs.contains("smart"))
        XCTAssertFalse(modelIDs.contains("Review Cloud/review-text-1"))
        XCTAssertTrue(modelIDs.contains("Review Edge/review-text-1"))
        XCTAssertFalse(modelIDs.contains("creative-media"))
        XCTAssertFalse(modelIDs.contains("Review Cloud/review-music-1"))

        let musicModelIDs = model.availableModelIDsForConsole(operation: .musicGeneration)
        XCTAssertTrue(musicModelIDs.contains("creative-media"))
        XCTAssertTrue(musicModelIDs.contains("Review Cloud/review-music-1"))
        XCTAssertFalse(musicModelIDs.contains("smart"))
    }
}
