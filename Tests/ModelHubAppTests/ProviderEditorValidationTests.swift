import XCTest
@testable import ModelHub
import ModelHubCore

final class ProviderEditorValidationTests: XCTestCase {
    func testProviderCanBeSavedBeforeAnyModelsAreAdded() {
        let provider = ProviderConfig(
            name: "MiniMax",
            kind: .minimax,
            baseURL: "https://api.minimax.io/v1",
            models: []
        )

        XCTAssertTrue(
            ProviderEditorValidation.isSavable(
                provider: provider,
                endpointsText: "",
                requiresBailianReplacementKey: false
            )
        )
    }

    func testProviderStillRejectsInvalidBaseURLAndEndpointText() {
        let provider = ProviderConfig(
            name: "MiniMax",
            kind: .minimax,
            baseURL: "not-a-url",
            models: []
        )

        XCTAssertFalse(
            ProviderEditorValidation.isSavable(
                provider: provider,
                endpointsText: "",
                requiresBailianReplacementKey: false
            )
        )

        var validProvider = provider
        validProvider.baseURL = "https://api.minimax.io/v1"
        XCTAssertFalse(
            ProviderEditorValidation.isSavable(
                provider: validProvider,
                endpointsText: "chat = /relative/path",
                requiresBailianReplacementKey: false
            )
        )
    }

    func testProviderRejectsKnownCredentialFamilyMismatch() {
        let provider = ProviderConfig(
            name: "阿里云百炼 Token Plan 团队版",
            kind: .qwenEnterprise,
            baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        )

        XCTAssertFalse(
            ProviderEditorValidation.isSavable(
                provider: provider,
                endpointsText: "",
                requiresBailianReplacementKey: true
            )
        )
    }
}
