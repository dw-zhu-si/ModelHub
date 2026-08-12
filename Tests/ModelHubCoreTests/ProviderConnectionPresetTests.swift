import XCTest
@testable import ModelHubCore

final class ProviderConnectionPresetTests: XCTestCase {
    func testAPIMartPresetContainsOfficialVideoCreateAndTaskEndpoints() throws {
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .apimart))

        XCTAssertEqual(preset.baseURL, "https://api.apimart.ai/v1")
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)],
            "https://api.apimart.ai/v1/models"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://api.apimart.ai/v1/chat/completions"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoGeneration)],
            "https://api.apimart.ai/v1/videos/generations"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoTask)],
            "https://api.apimart.ai/v1/tasks/{task_id}"
        )
    }

    func testOfficialAPIMartLegacyProviderIsReclassifiedWithoutLosingIdentityOrModels() throws {
        let id = UUID()
        let legacy = ProviderConfig(
            id: id,
            name: "seedance",
            kind: .unifiedCompatible,
            baseURL: "https://api.apimart.ai/v1/videos/generations",
            enabled: true,
            models: ["doubao-seedance-2.0-fast", "claude-fable-5"],
            endpointURLs: [
                ProviderEndpointRecord.key(for: .imageGeneration):
                    "https://custom.example.com/v1/images/generations",
                ProviderEndpointRecord.key(for: .chat, model: "claude-fable-5"):
                    "https://api.apimart.ai/v1/videos/generations",
                ProviderEndpointRecord.key(
                    for: .videoTask,
                    model: "doubao-seedance-2.0-fast"
                ): "https://api.apimart.ai/v1/videos/generations"
            ]
        )

        let migrated = try XCTUnwrap(
            ProviderConnectionPresetMigration.migratedProvider(legacy)
        )

        XCTAssertEqual(migrated.id, id)
        XCTAssertEqual(migrated.name, "seedance")
        XCTAssertEqual(migrated.kind, .apimart)
        XCTAssertEqual(migrated.models, legacy.models)
        XCTAssertEqual(migrated.baseURL, "https://api.apimart.ai/v1")
        XCTAssertEqual(
            migrated.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://api.apimart.ai/v1/chat/completions"
        )
        XCTAssertEqual(
            migrated.endpointURLs[ProviderEndpointRecord.key(for: .videoGeneration)],
            "https://api.apimart.ai/v1/videos/generations"
        )
        XCTAssertEqual(
            migrated.endpointURLs[ProviderEndpointRecord.key(for: .videoTask)],
            "https://api.apimart.ai/v1/tasks/{task_id}"
        )
        XCTAssertEqual(
            migrated.endpointURLs[ProviderEndpointRecord.key(for: .imageGeneration)],
            "https://custom.example.com/v1/images/generations"
        )
        XCTAssertEqual(
            migrated.endpointURLs[
                ProviderEndpointRecord.key(for: .chat, model: "claude-fable-5")
            ],
            "https://api.apimart.ai/v1/chat/completions"
        )
        XCTAssertEqual(
            migrated.endpointURLs[
                ProviderEndpointRecord.key(
                    for: .videoTask,
                    model: "doubao-seedance-2.0-fast"
                )
            ],
            "https://api.apimart.ai/v1/tasks/{task_id}"
        )
    }

    func testAPIMartMigrationDoesNotClaimCustomCompatibleGateways() {
        let custom = ProviderConfig(
            name: "APIMart proxy",
            kind: .unifiedCompatible,
            baseURL: "https://gateway.example.com/v1",
            models: ["doubao-seedance-2.0-fast"]
        )

        XCTAssertNil(ProviderConnectionPresetMigration.migratedProvider(custom))
    }

    func testMiniMaxChinaPresetContainsEveryOfficialFixedEndpoint() throws {
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .minimaxChina))

        XCTAssertEqual(preset.baseURL, "https://api.minimaxi.com/v1")
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)],
            "https://api.minimaxi.com/v1/models"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://api.minimaxi.com/v1/chat/completions"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .imageGeneration)],
            "https://api.minimaxi.com/v1/image_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .musicGeneration)],
            "https://api.minimaxi.com/v1/music_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoGeneration)],
            "https://api.minimaxi.com/v1/video_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoTask)],
            "https://api.minimaxi.com/v1/query/video_generation?task_id={task_id}"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .speech)],
            "https://api.minimaxi.com/v1/t2a_v2"
        )
    }

    func testMiniMaxPresetContainsEveryOfficialFixedEndpoint() throws {
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .minimax))

        XCTAssertEqual(preset.baseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)],
            "https://api.minimax.io/v1/models"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://api.minimax.io/v1/chat/completions"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .imageGeneration)],
            "https://api.minimax.io/v1/image_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .musicGeneration)],
            "https://api.minimax.io/v1/music_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoGeneration)],
            "https://api.minimax.io/v1/video_generation"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .videoTask)],
            "https://api.minimax.io/v1/query/video_generation?task_id={task_id}"
        )
        XCTAssertEqual(
            preset.endpointURLs[ProviderEndpointRecord.key(for: .speech)],
            "https://api.minimax.io/v1/t2a_v2"
        )
    }

    func testEveryBuiltInProviderHasSafeBaseAndChatPreset() throws {
        for kind in ProviderKind.allCases where kind != .unifiedCompatible {
            let preset = try XCTUnwrap(
                ProviderConnectionPresets.preset(for: kind),
                "Missing preset for \(kind.rawValue)"
            )
            let base = try XCTUnwrap(URLComponents(string: preset.baseURL))
            XCTAssertTrue(ProviderEndpointSecurity.isSafeConfigurationURL(base))
            XCTAssertNotNil(
                preset.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
                "Missing chat endpoint for \(kind.rawValue)"
            )
            let editable = ProviderEndpointEditorCodec.text(from: preset.endpointURLs)
            XCTAssertNoThrow(try ProviderEndpointEditorCodec.records(from: editable))
        }
        XCTAssertNil(ProviderConnectionPresets.preset(for: .unifiedCompatible))
    }

    func testEveryBuiltInProviderHasSafeModelCatalogPreset() throws {
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        for kind in ProviderKind.allCases where kind != .unifiedCompatible {
            let preset = try XCTUnwrap(
                ProviderConnectionPresets.preset(for: kind),
                "Missing preset for \(kind.rawValue)"
            )
            let rawCatalog = try XCTUnwrap(
                preset.endpointURLs[catalogKey],
                "Missing model catalog for \(kind.rawValue)"
            )
            let components = try XCTUnwrap(
                URLComponents(string: rawCatalog),
                "Invalid model catalog for \(kind.rawValue)"
            )
            XCTAssertTrue(
                ProviderEndpointSecurity.isSafeConfigurationURL(components),
                "Unsafe model catalog for \(kind.rawValue)"
            )
        }
    }

    func testEveryBuiltInProviderCanBuildItsExactCatalogRequest() throws {
        let catalogKey = ProviderEndpointRecord.key(for: .modelCatalog)
        for kind in ProviderKind.allCases where kind != .unifiedCompatible {
            let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: kind))
            let provider = preset.applying(
                to: ProviderConfig(name: kind.displayName, kind: kind, baseURL: ""),
                mode: .replaceURLs
            )
            let request = try ProviderClient().modelCatalogRequest(
                provider: provider,
                apiKey: kind.needsAPIKey
                    ? (kind.isBailianTokenPlan ? "sk-sp-test-key" : "test-key")
                    : nil
            )
            XCTAssertEqual(
                request.url?.absoluteString,
                preset.endpointURLs[catalogKey],
                kind.rawValue
            )
            XCTAssertEqual(request.httpMethod, "GET", kind.rawValue)
            XCTAssertNil(request.httpBody, kind.rawValue)
        }
    }

    func testPresetCanReplaceVendorURLsOrOnlyFillMissingValues() throws {
        var provider = ProviderConfig(
            name: "MiniMax",
            kind: .minimax,
            baseURL: "",
            models: []
        )
        provider.endpointURLs[ProviderEndpointRecord.key(for: .chat)] =
            "https://custom.example.com/chat"
        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .minimax))

        let filled = preset.applying(to: provider, mode: .fillMissing)
        XCTAssertEqual(filled.baseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(
            filled.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://custom.example.com/chat"
        )
        XCTAssertEqual(
            filled.endpointURLs[ProviderEndpointRecord.key(for: .modelCatalog)],
            "https://api.minimax.io/v1/models"
        )

        let replaced = preset.applying(to: provider, mode: .replaceURLs)
        XCTAssertEqual(replaced.baseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(
            replaced.endpointURLs[ProviderEndpointRecord.key(for: .chat)],
            "https://api.minimax.io/v1/chat/completions"
        )
    }

    func testModelTemplateIsRestrictedAndSubstitutedWithoutPathInjection() throws {
        let template = "chat = https://generativelanguage.googleapis.com/v1beta/{model}:generateContent"
        XCTAssertNoThrow(try ProviderEndpointEditorCodec.records(from: template))
        XCTAssertThrowsError(
            try ProviderEndpointEditorCodec.records(
                from: "imageGeneration = https://example.com/{model}/image"
            )
        )

        let preset = try XCTUnwrap(ProviderConnectionPresets.preset(for: .gemini))
        let provider = preset.applying(
            to: ProviderConfig(
                name: "Gemini",
                kind: .gemini,
                baseURL: "",
                models: []
            ),
            mode: .replaceURLs
        )
        XCTAssertEqual(
            try ProviderClient().endpoint(for: provider, model: "models/gemini-2.5-pro")
                .absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent"
        )
        XCTAssertEqual(
            try ProviderClient().endpoint(for: provider, model: "../escape").absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/..%2Fescape:generateContent"
        )
    }
}
