import XCTest
@testable import ModelHubCore

final class ReferenceModelPricingTests: XCTestCase {
    func testRegistryReturnsCurrentUpstreamReferencesAndConvertsCNYToUSD() throws {
        let rates = CurrencyDisplaySettings(
            currency: .cny,
            unitsPerUSD: ["USD": 1, "CNY": 7]
        )

        let openAI = try XCTUnwrap(
            ReferenceModelPricingRegistry.price(
                for: "gpt-5.6-terra-2026-07-09",
                currency: rates
            )
        )
        XCTAssertEqual(openAI.inputPerMillionTokensUSD, 2)
        XCTAssertEqual(openAI.outputPerMillionTokensUSD, 12)
        XCTAssertTrue(ReferenceModelPricingRegistry.isReferenceSource(openAI.source))

        let qwen = try XCTUnwrap(
            ReferenceModelPricingRegistry.price(
                for: "qwen3.8-max",
                currency: rates
            )
        )
        XCTAssertEqual(try XCTUnwrap(qwen.inputPerMillionTokensUSD), 12 / 7, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(qwen.outputPerMillionTokensUSD), 36 / 7, accuracy: 0.000_001)
        XCTAssertTrue(qwen.source.contains("非当前渠道结算价"))
    }

    func testRegistryRejectsAmbiguousVariantsAndCNYQuotesWithoutExchangeRate() {
        XCTAssertNil(
            ReferenceModelPricingRegistry.price(
                for: "gpt-5.6-sol-ultra",
                currency: CurrencyDisplaySettings()
            )
        )
        XCTAssertNil(
            ReferenceModelPricingRegistry.price(
                for: "qwen3.8-max",
                currency: CurrencyDisplaySettings()
            )
        )
        XCTAssertNil(
            ReferenceModelPricingRegistry.price(
                for: "made-up-model",
                currency: CurrencyDisplaySettings()
            )
        )
    }

    func testReferenceUpdaterNeverOverwritesManualOrCatalogPrices() throws {
        let providerID = UUID()
        var provider = ProviderConfig(
            id: providerID,
            name: "Compatible",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["gpt-5.6-sol", "gemini-2.5-flash"],
            modelProfiles: [
                "gpt-5.6-sol": TargetProfile(
                    inputCostPerMillionTokens: 99,
                    outputCostPerMillionTokens: 199,
                    pricingSource: "手动配置"
                )
            ]
        )
        var routes = [RouteConfig(
            alias: "smart",
            targets: [RouteTarget(providerID: providerID, model: "gpt-5.6-sol")]
        )]
        let prices = ReferenceModelPricingRegistry.prices(
            for: provider.models,
            currency: CurrencyDisplaySettings()
        )

        let count = ProviderModelReferencePricingUpdater.apply(
            prices: prices,
            to: &provider,
            routes: &routes,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(provider.modelProfiles?["gpt-5.6-sol"]?.inputCostPerMillionTokens, 99)
        XCTAssertEqual(provider.modelProfiles?["gpt-5.6-sol"]?.pricingSource, "手动配置")
        XCTAssertEqual(provider.modelProfiles?["gemini-2.5-flash"]?.inputCostPerMillionTokens, 0.30)
        XCTAssertNil(routes[0].targets[0].profile)
    }

    func testReferenceUpdaterRepricesOnlyItsOwnPriorReference() throws {
        var provider = ProviderConfig(
            name: "MiniMax",
            kind: .minimaxChina,
            baseURL: "https://api.minimaxi.com/v1",
            models: ["MiniMax-M2.7"]
        )
        var routes: [RouteConfig] = []
        let firstRates = CurrencyDisplaySettings(
            unitsPerUSD: ["USD": 1, "CNY": 7]
        )
        let firstPrices = ReferenceModelPricingRegistry.prices(
            for: provider.models,
            currency: firstRates
        )
        XCTAssertEqual(
            ProviderModelReferencePricingUpdater.apply(
                prices: firstPrices,
                to: &provider,
                routes: &routes
            ),
            1
        )
        XCTAssertEqual(
            ProviderModelReferencePricingUpdater.apply(
                prices: firstPrices,
                to: &provider,
                routes: &routes
            ),
            0
        )
        let first = try XCTUnwrap(
            provider.modelProfiles?["MiniMax-M2.7"]?.inputCostPerMillionTokens
        )

        let secondRates = CurrencyDisplaySettings(
            unitsPerUSD: ["USD": 1, "CNY": 7.2]
        )
        let secondPrices = ReferenceModelPricingRegistry.prices(
            for: provider.models,
            currency: secondRates
        )
        XCTAssertEqual(
            ProviderModelReferencePricingUpdater.apply(
                prices: secondPrices,
                to: &provider,
                routes: &routes
            ),
            1
        )
        let second = try XCTUnwrap(
            provider.modelProfiles?["MiniMax-M2.7"]?.inputCostPerMillionTokens
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, 2.1 / 7.2, accuracy: 0.000_001)
    }
}
