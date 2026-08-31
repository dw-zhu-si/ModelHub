import Foundation

public enum DisplayCurrency: String, Codable, CaseIterable, Identifiable, Sendable {
    case usd = "USD"
    case cny = "CNY"
    case hkd = "HKD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case krw = "KRW"
    case sgd = "SGD"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .usd: "美元（USD）"
        case .cny: "人民币（CNY）"
        case .hkd: "港币（HKD）"
        case .eur: "欧元（EUR）"
        case .gbp: "英镑（GBP）"
        case .jpy: "日元（JPY）"
        case .krw: "韩元（KRW）"
        case .sgd: "新加坡元（SGD）"
        }
    }
}

public struct CurrencyDisplaySettings: Codable, Hashable, Sendable {
    public var currency: DisplayCurrency
    public var unitsPerUSD: [String: Double]
    /// Time when ModelHub last received and parsed a valid rate document.
    public var rateUpdatedAt: Date?
    public var rateSource: String?
    /// Effective business date published by the reference-rate provider.
    public var rateEffectiveDate: String?
    /// Time of the last bounded network attempt, successful or otherwise.
    public var rateLastAttemptAt: Date?
    /// Sanitized local diagnostic for the latest failed attempt.
    public var rateLastError: String?

    public init(
        currency: DisplayCurrency = .usd,
        unitsPerUSD: [String: Double] = [DisplayCurrency.usd.rawValue: 1],
        rateUpdatedAt: Date? = nil,
        rateSource: String? = nil,
        rateEffectiveDate: String? = nil,
        rateLastAttemptAt: Date? = nil,
        rateLastError: String? = nil
    ) {
        self.currency = currency
        self.unitsPerUSD = unitsPerUSD
        self.rateUpdatedAt = rateUpdatedAt
        self.rateSource = rateSource
        self.rateEffectiveDate = rateEffectiveDate
        self.rateLastAttemptAt = rateLastAttemptAt
        self.rateLastError = rateLastError
    }

    public var sanitized: CurrencyDisplaySettings {
        let supported = Set(DisplayCurrency.allCases.map(\.rawValue))
        var rates = unitsPerUSD.filter {
            supported.contains($0.key) && $0.value.isFinite && $0.value > 0
        }
        rates[DisplayCurrency.usd.rawValue] = 1
        let selected = rates[currency.rawValue] == nil ? DisplayCurrency.usd : currency
        return CurrencyDisplaySettings(
            currency: selected,
            unitsPerUSD: rates,
            rateUpdatedAt: rateUpdatedAt,
            rateSource: rateSource.map { String($0.prefix(200)) },
            rateEffectiveDate: rateEffectiveDate.map { String($0.prefix(32)) },
            rateLastAttemptAt: rateLastAttemptAt,
            rateLastError: rateLastError.map { String($0.prefix(300)) }
        )
    }

    public func convertedFromUSD(_ value: Double) -> Double {
        value * (unitsPerUSD[currency.rawValue] ?? 1)
    }

    public func formattedUSD(
        _ value: Double,
        minimumFractionDigits: Int = 4,
        maximumFractionDigits: Int = 4
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: convertedFromUSD(value)))
            ?? "\(currency.rawValue) \(convertedFromUSD(value))"
    }
}

/// Keeps the ECB reference-rate cache current without creating a tight retry
/// loop. ECB publishes once per working day, so a six-hour success interval
/// catches the next publication while the 30-minute failure interval limits
/// repeated traffic during outages.
public enum CurrencyRateRefreshPolicy {
    public static let successInterval: TimeInterval = 6 * 60 * 60
    public static let failureRetryInterval: TimeInterval = 30 * 60

    public static func shouldRefresh(
        _ settings: CurrencyDisplaySettings,
        at date: Date = .now
    ) -> Bool {
        nextRefreshDate(for: settings, at: date) <= date
    }

    public static func nextRefreshDate(
        for rawSettings: CurrencyDisplaySettings,
        at date: Date = .now
    ) -> Date {
        let settings = rawSettings.sanitized
        let nextSuccess = settings.rateUpdatedAt?.addingTimeInterval(successInterval) ?? date
        guard let lastAttempt = settings.rateLastAttemptAt else {
            return max(date, nextSuccess)
        }

        let attemptFailedAfterLastSuccess: Bool
        if let updatedAt = settings.rateUpdatedAt {
            attemptFailedAfterLastSuccess = settings.rateLastError != nil
                && lastAttempt >= updatedAt
        } else {
            attemptFailedAfterLastSuccess = settings.rateLastError != nil
        }
        let nextAttempt = attemptFailedAfterLastSuccess
            ? lastAttempt.addingTimeInterval(failureRetryInterval)
            : nextSuccess
        return max(date, nextAttempt)
    }

    public static func isStale(
        _ settings: CurrencyDisplaySettings,
        at date: Date = .now
    ) -> Bool {
        guard let updatedAt = settings.rateUpdatedAt else { return true }
        return date.timeIntervalSince(updatedAt) >= successInterval
    }
}

public struct CurrencyRateSnapshot: Equatable, Sendable {
    public let unitsPerUSD: [String: Double]
    public let effectiveDate: String?
    public let source: String

    public init(unitsPerUSD: [String: Double], effectiveDate: String?, source: String) {
        self.unitsPerUSD = unitsPerUSD
        self.effectiveDate = effectiveDate
        self.source = source
    }
}

public enum CurrencyRateError: LocalizedError, Equatable {
    case invalidResponse
    case responseTooLarge
    case invalidDocument
    case missingUSDRate

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "汇率服务返回了无效响应。")
        case .responseTooLarge: String(localized: "汇率响应超过安全大小限制。")
        case .invalidDocument: String(localized: "无法解析官方汇率文档。")
        case .missingUSDRate: String(localized: "官方汇率文档没有包含美元基准。")
        }
    }
}

public final class CurrencyRateClient: @unchecked Sendable {
    public static let endpoint = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
    )!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(timeoutInterval: TimeInterval = 15) async throws -> CurrencyRateSnapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme == Self.endpoint.scheme,
              http.url?.host == Self.endpoint.host
        else { throw CurrencyRateError.invalidResponse }
        guard data.count <= 512 * 1_024 else { throw CurrencyRateError.responseTooLarge }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> CurrencyRateSnapshot {
        let delegate = EuropeanCentralBankRateParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw CurrencyRateError.invalidDocument }
        guard let usdPerEUR = delegate.ratesPerEUR[DisplayCurrency.usd.rawValue],
              usdPerEUR.isFinite, usdPerEUR > 0
        else { throw CurrencyRateError.missingUSDRate }

        var unitsPerUSD = [DisplayCurrency.usd.rawValue: 1.0]
        unitsPerUSD[DisplayCurrency.eur.rawValue] = 1 / usdPerEUR
        for currency in DisplayCurrency.allCases where currency != .usd && currency != .eur {
            guard let unitsPerEUR = delegate.ratesPerEUR[currency.rawValue],
                  unitsPerEUR.isFinite, unitsPerEUR > 0
            else { continue }
            unitsPerUSD[currency.rawValue] = unitsPerEUR / usdPerEUR
        }
        return CurrencyRateSnapshot(
            unitsPerUSD: unitsPerUSD,
            effectiveDate: delegate.effectiveDate,
            source: "European Central Bank"
        )
    }
}

private final class EuropeanCentralBankRateParser: NSObject, XMLParserDelegate {
    var ratesPerEUR: [String: Double] = [:]
    var effectiveDate: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Cube" else { return }
        if let time = attributeDict["time"] {
            effectiveDate = time
        }
        guard let currency = attributeDict["currency"],
              let rawRate = attributeDict["rate"],
              let rate = Double(rawRate), rate.isFinite, rate > 0
        else { return }
        ratesPerEUR[currency] = rate
    }
}
