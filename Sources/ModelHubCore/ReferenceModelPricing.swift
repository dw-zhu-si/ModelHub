import Foundation

/// Curated upstream list-price references bundled with ModelHub. These values
/// are an estimation fallback only: a reseller, region, long-context tier,
/// priority tier, promotion, cache mode or private contract can bill a
/// different amount. Provider catalogs, imported CSV data and manual prices
/// always take precedence.
public enum ReferenceModelPricingRegistry {
    public static let revision = "2026-08-31"
    public static let sourcePrefix = "ModelHub 内置上游公开参考价"

    private struct Quote {
        let input: Double
        let output: Double
        let currency: DisplayCurrency
        let publisher: String
        let qualifier: String
    }

    public static func isReferenceSource(_ source: String) -> Bool {
        source.hasPrefix(sourcePrefix)
    }

    public static func prices(
        for models: [String],
        currency: CurrencyDisplaySettings
    ) -> [String: ProviderModelPrice] {
        var result: [String: ProviderModelPrice] = [:]
        result.reserveCapacity(models.count)
        for model in models {
            if let price = price(for: model, currency: currency) {
                result[model] = price
            }
        }
        return result
    }

    public static func price(
        for model: String,
        currency rawCurrency: CurrencyDisplaySettings
    ) -> ProviderModelPrice? {
        let identity = normalizedIdentity(model)
        guard !identity.isEmpty, let quote = quote(for: identity) else { return nil }
        let currency = rawCurrency.sanitized
        let divisor: Double
        switch quote.currency {
        case .usd:
            divisor = 1
        default:
            guard let rate = currency.unitsPerUSD[quote.currency.rawValue],
                  rate.isFinite, rate > 0
            else { return nil }
            divisor = rate
        }

        let qualifier = quote.qualifier.isEmpty ? "" : " · \(quote.qualifier)"
        return ProviderModelPrice(
            inputPerMillionTokensUSD: quote.input / divisor,
            outputPerMillionTokensUSD: quote.output / divisor,
            source: "\(sourcePrefix) · \(quote.publisher) · \(revision)\(qualifier) · 非当前渠道结算价"
        )
    }

    private static func normalizedIdentity(_ model: String) -> String {
        var value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let tail = value.split(separator: "/").last {
            value = String(tail)
        }
        for suffix in ["-thinking", "-nothinking", "-official"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }

    private static func isSnapshot(_ identity: String, of base: String) -> Bool {
        identity == base || identity.hasPrefix("\(base)-20")
    }

    private static func quote(for identity: String) -> Quote? {
        // OpenAI standard processing, short-context tier where the publisher
        // documents a separate long-context multiplier.
        if isSnapshot(identity, of: "gpt-5.6-sol") {
            return .init(input: 4, output: 20, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.6-terra") {
            return .init(input: 2, output: 12, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.6-luna") {
            return .init(input: 0.2, output: 1.2, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.5-pro") {
            return .init(input: 30, output: 180, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.5") {
            return .init(input: 5, output: 30, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.4-pro") {
            return .init(input: 30, output: 180, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5.4-mini") {
            return .init(input: 0.75, output: 4.5, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理")
        }
        if isSnapshot(identity, of: "gpt-5.4-nano") {
            return .init(input: 0.2, output: 1.25, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理")
        }
        if isSnapshot(identity, of: "gpt-5.4") {
            return .init(input: 2.5, output: 15, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理短上下文")
        }
        if isSnapshot(identity, of: "gpt-5-mini") {
            return .init(input: 0.25, output: 2, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理")
        }
        if isSnapshot(identity, of: "gpt-5-nano") {
            return .init(input: 0.05, output: 0.4, currency: .usd, publisher: "OpenAI API", qualifier: "标准处理")
        }

        // Google Gemini paid Standard tier. For tiered Pro pricing, the first
        // documented prompt-size tier is used and called out in the source.
        if identity == "gemini-3.7-flash" || identity.hasPrefix("gemini-3.7-flash-") {
            return .init(input: 0.75, output: 3.75, currency: .usd, publisher: "Google Gemini API", qualifier: "限时公开价至 2026-12-31")
        }
        if identity == "gemini-3.5-flash-lite" {
            return .init(input: 0.3, output: 2.5, currency: .usd, publisher: "Google Gemini API", qualifier: "付费 Standard")
        }
        if identity == "gemini-3.5-flash" {
            return .init(input: 1.5, output: 9, currency: .usd, publisher: "Google Gemini API", qualifier: "付费 Standard")
        }
        if identity.hasPrefix("gemini-3.1-pro-preview") {
            return .init(input: 2, output: 12, currency: .usd, publisher: "Google Gemini API", qualifier: "Standard ≤200K 输入")
        }
        if identity == "gemini-3.1-flash-lite" || identity.hasPrefix("gemini-3.1-flash-lite-preview") {
            return .init(input: 0.25, output: 1.5, currency: .usd, publisher: "Google Gemini API", qualifier: "付费 Standard 文本/图像/视频输入")
        }
        if identity == "gemini-2.5-pro" {
            return .init(input: 1.25, output: 10, currency: .usd, publisher: "Google Gemini API", qualifier: "Standard ≤200K 输入")
        }
        if identity == "gemini-2.5-flash" {
            return .init(input: 0.3, output: 2.5, currency: .usd, publisher: "Google Gemini API", qualifier: "付费 Standard 文本/图像/视频输入")
        }
        if identity == "gemini-2.5-flash-lite" || identity.hasPrefix("gemini-2.5-flash-lite-preview") {
            return .init(input: 0.1, output: 0.4, currency: .usd, publisher: "Google Gemini API", qualifier: "付费 Standard 文本/图像/视频输入")
        }

        // DeepSeek now varies by peak/off-peak period. Store the documented
        // peak rate as a conservative default; cache discounts are excluded.
        if ["deepseek-v4-flash", "deepseek-v4-flash-0731", "deepseek-chat", "deepseek-reasoner"].contains(identity) {
            return .init(input: 0.44, output: 1.32, currency: .usd, publisher: "DeepSeek API", qualifier: "峰值时段保守参考价")
        }
        if ["deepseek-v4-pro", "deepseek-v4-pro-0813"].contains(identity) {
            return .init(input: 1.32, output: 3.96, currency: .usd, publisher: "DeepSeek API", qualifier: "峰值时段保守参考价")
        }

        // Alibaba Model Studio, mainland list prices. Tiered models use the
        // first public tier; the qualifier makes that limitation explicit.
        if identity == "qwen3.8-max" {
            return .init(input: 12, output: 36, currency: .cny, publisher: "阿里云百炼", qualifier: "华北 2 公开原价")
        }
        if identity == "qwen3.8-flash" {
            return .init(input: 0.8, output: 2.7, currency: .cny, publisher: "阿里云百炼", qualifier: "华北 2 公开价")
        }
        if identity == "qwen3.7-max" || identity.hasPrefix("qwen3.7-max-2026-") {
            return .init(input: 12, output: 36, currency: .cny, publisher: "阿里云百炼", qualifier: "公开原价未计限时折扣")
        }
        if identity == "qwen3.7-plus" || identity.hasPrefix("qwen3.7-plus-2026-") {
            return .init(input: 2, output: 8, currency: .cny, publisher: "阿里云百炼", qualifier: "首档 ≤256K 公开原价")
        }
        if identity == "qwen3.7-flash" || identity.hasPrefix("qwen3.7-flash-2026-") {
            return .init(input: 0.2, output: 0.8, currency: .cny, publisher: "阿里云百炼", qualifier: "首档 ≤32K 公开价")
        }
        if identity == "qwen-max" || identity == "qwen-max-latest" {
            return .init(input: 2.4, output: 9.6, currency: .cny, publisher: "阿里云百炼", qualifier: "华北 2 公开价")
        }
        if identity == "qwen-plus" || identity == "qwen-plus-latest" || identity.hasPrefix("qwen-plus-20") {
            return .init(input: 0.8, output: 8, currency: .cny, publisher: "阿里云百炼", qualifier: "首档 ≤128K 保守输出价")
        }
        if identity == "qwen-flash" || identity.hasPrefix("qwen-flash-20") {
            return .init(input: 0.15, output: 1.5, currency: .cny, publisher: "阿里云百炼", qualifier: "首档 ≤128K 公开价")
        }

        // MiniMax China pay-as-you-go text pricing.
        if ["minimax-m2.7-highspeed", "minimax-m2.5-highspeed", "minimax-m2.1-highspeed"].contains(identity) {
            return .init(input: 4.2, output: 16.8, currency: .cny, publisher: "MiniMax 中国站", qualifier: "按量付费")
        }
        if ["minimax-m2.7", "minimax-m2.5", "minimax-m2.1", "minimax-m2"].contains(identity) {
            return .init(input: 2.1, output: 8.4, currency: .cny, publisher: "MiniMax 中国站", qualifier: "按量付费")
        }
        return nil
    }
}

/// Applies only bundled fallback prices. Explicit/manual values are never
/// changed. A previous bundled reference may be recalculated when its native
/// currency exchange rate or bundled revision changes.
public enum ProviderModelReferencePricingUpdater {
    @discardableResult
    public static func apply(
        prices: [String: ProviderModelPrice],
        to provider: inout ProviderConfig,
        routes: inout [RouteConfig],
        updatedAt: Date = .now
    ) -> Int {
        let indexed = Dictionary(uniqueKeysWithValues: prices.map {
            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.value)
        })
        var profiles = provider.modelProfiles ?? [:]
        var updated = Set<String>()

        for model in provider.models {
            let identity = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let price = indexed[identity], price.hasKnownPrice else { continue }
            let existingKey = profiles.keys.first {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity
            }
            var profile = existingKey.flatMap { profiles[$0] } ?? TargetProfile()
            guard !profile.hasKnownPrice
                    || ReferenceModelPricingRegistry.isReferenceSource(profile.pricingSource)
            else { continue }
            if profile.inputCostPerMillionTokens == price.inputPerMillionTokensUSD,
               profile.outputCostPerMillionTokens == price.outputPerMillionTokensUSD,
               profile.requestCostUSD == price.perRequestUSD,
               profile.pricingSource == price.source
            {
                continue
            }

            profile.inputCostPerMillionTokens = price.inputPerMillionTokensUSD
            profile.outputCostPerMillionTokens = price.outputPerMillionTokensUSD
            profile.requestCostUSD = price.perRequestUSD
            profile.pricingSource = price.source
            profile.pricingUpdatedAt = updatedAt
            if let existingKey, existingKey != model {
                profiles.removeValue(forKey: existingKey)
            }
            profiles[model] = profile
            updated.insert(identity)
        }
        provider.modelProfiles = profiles.isEmpty ? nil : profiles

        for routeIndex in routes.indices {
            for targetIndex in routes[routeIndex].targets.indices {
                guard routes[routeIndex].targets[targetIndex].providerID == provider.id,
                      var profile = routes[routeIndex].targets[targetIndex].profile
                else { continue }
                let model = routes[routeIndex].targets[targetIndex].model
                let identity = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let price = indexed[identity], price.hasKnownPrice,
                      !profile.hasKnownPrice
                        || ReferenceModelPricingRegistry.isReferenceSource(profile.pricingSource)
                else { continue }
                if profile.inputCostPerMillionTokens == price.inputPerMillionTokensUSD,
                   profile.outputCostPerMillionTokens == price.outputPerMillionTokensUSD,
                   profile.requestCostUSD == price.perRequestUSD,
                   profile.pricingSource == price.source
                {
                    continue
                }
                profile.inputCostPerMillionTokens = price.inputPerMillionTokensUSD
                profile.outputCostPerMillionTokens = price.outputPerMillionTokensUSD
                profile.requestCostUSD = price.perRequestUSD
                profile.pricingSource = price.source
                profile.pricingUpdatedAt = updatedAt
                routes[routeIndex].targets[targetIndex].profile = profile
                updated.insert(identity)
            }
        }
        return updated.count
    }
}
