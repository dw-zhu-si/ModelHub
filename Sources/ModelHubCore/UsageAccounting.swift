import Foundation

public struct UsageMonth: Hashable, Comparable, Sendable {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let ordinal: Int

    public init(date: Date) {
        let components = Self.calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 1
        ordinal = year * 12 + month - 1
    }

    private init(ordinal: Int) {
        self.ordinal = ordinal
    }

    public var key: String {
        let year = ordinal >= 0 ? ordinal / 12 : (ordinal - 11) / 12
        let month = ordinal - (year * 12) + 1
        return String(format: "%04d-%02d", year, month)
    }

    public func adding(months: Int) -> UsageMonth {
        UsageMonth(ordinal: ordinal + months)
    }

    public static func < (lhs: UsageMonth, rhs: UsageMonth) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

public enum UsageAccounting {
    public static func tokenCounts(from responseBody: Data) -> UsageTokenCounts {
        guard let root = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { return .init() }

        return UsageTokenCounts(
            input: integer(usage["input_tokens"]) ?? integer(usage["prompt_tokens"]) ?? 0,
            output: integer(usage["output_tokens"]) ?? integer(usage["completion_tokens"]) ?? 0
        )
    }

    public static func tokenCounts(fromEventStream data: Data) -> UsageTokenCounts {
        let text = String(decoding: data, as: UTF8.self)
        var maximum = UsageTokenCounts()
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let eventData = payload.data(using: .utf8) else {
                continue
            }
            var counts = tokenCounts(from: eventData)
            if counts == UsageTokenCounts(),
               let root = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
               let response = root["response"] as? [String: Any],
               let nested = try? JSONSerialization.data(withJSONObject: response)
            {
                counts = tokenCounts(from: nested)
            }
            maximum.input = max(maximum.input, counts.input)
            maximum.output = max(maximum.output, counts.output)
        }
        return maximum
    }

    public static func estimatedCostUSD(
        tokens: UsageTokenCounts,
        profile: TargetProfile?
    ) -> Double? {
        guard let profile else { return nil }
        if tokens.input > 0 && profile.inputCostPerMillionTokens == nil {
            return nil
        }
        if tokens.output > 0 && profile.outputCostPerMillionTokens == nil {
            return nil
        }
        guard profile.hasKnownPrice else { return nil }
        let input = Double(tokens.input) * (profile.inputCostPerMillionTokens ?? 0) / 1_000_000
        let output = Double(tokens.output) * (profile.outputCostPerMillionTokens ?? 0) / 1_000_000
        return input + output + (profile.requestCostUSD ?? 0)
    }

    public static func monthKey(for date: Date = .now) -> String {
        UsageMonth(date: date).key
    }

    public static func recording(
        aggregates: consuming [UsageAggregate],
        requestedModel: String,
        providerID: UUID,
        providerName: String,
        model: String,
        statusCode: Int,
        latencyMilliseconds: Int,
        tokens: UsageTokenCounts,
        estimatedCostUSD: Double?,
        contextCharactersSaved: Int,
        date: Date = .now,
        retentionMonths: Int = 12
    ) -> [UsageAggregate] {
        let currentMonth = UsageMonth(date: date)
        let month = currentMonth.key
        let months = max(1, retentionMonths)
        let cutoffMonth = currentMonth.adding(months: -(months - 1)).key
        var result = aggregates
        result.removeAll { $0.month < cutoffMonth }

        func matches(_ aggregate: UsageAggregate) -> Bool {
            aggregate.month == month
                && aggregate.requestedModel == requestedModel
                && aggregate.providerID == providerID
                && aggregate.model == model
        }
        // Usage is naturally bursty. Keep the most recently updated aggregate
        // at the tail and inspect a bounded hot window before falling back to a
        // full scan. This preserves the persisted array schema while making a
        // rotating working set independent of the full history size.
        let hotWindowSize = 64
        let hotWindowStart = max(result.startIndex, result.endIndex - hotWindowSize)
        let index = result.indices[hotWindowStart...].reversed().first {
            matches(result[$0])
        } ?? result.indices[..<hotWindowStart].first {
            matches(result[$0])
        }
        if let index {
            var aggregate = result[index]
            aggregate.requests += 1
            aggregate.successfulRequests += (200..<300).contains(statusCode) ? 1 : 0
            aggregate.totalLatencyMilliseconds += max(0, latencyMilliseconds)
            aggregate.inputTokens += max(0, tokens.input)
            aggregate.outputTokens += max(0, tokens.output)
            if let estimatedCostUSD {
                aggregate.pricedRequests += 1
                aggregate.estimatedCostUSD += max(0, estimatedCostUSD)
            }
            aggregate.contextCharactersSaved += max(0, contextCharactersSaved)
            aggregate.lastUsedAt = date
            var samples = aggregate.recentLatencyMilliseconds ?? []
            samples.append(max(0, latencyMilliseconds))
            if samples.count > 100 { samples.removeFirst(samples.count - 100) }
            aggregate.recentLatencyMilliseconds = samples
            if index == result.indices.last {
                result[index] = aggregate
            } else {
                result.remove(at: index)
                result.append(aggregate)
            }
        } else {
            result.append(UsageAggregate(
                month: month,
                requestedModel: requestedModel,
                providerID: providerID,
                providerName: providerName,
                model: model,
                requests: 1,
                successfulRequests: (200..<300).contains(statusCode) ? 1 : 0,
                totalLatencyMilliseconds: max(0, latencyMilliseconds),
                inputTokens: max(0, tokens.input),
                outputTokens: max(0, tokens.output),
                pricedRequests: estimatedCostUSD == nil ? 0 : 1,
                estimatedCostUSD: max(0, estimatedCostUSD ?? 0),
                contextCharactersSaved: max(0, contextCharactersSaved),
                lastUsedAt: date,
                recentLatencyMilliseconds: [max(0, latencyMilliseconds)]
            ))
        }

        return result
    }

    public static func currentMonthCost(
        in aggregates: [UsageAggregate],
        date: Date = .now
    ) -> Double {
        let month = monthKey(for: date)
        return aggregates.lazy.filter { $0.month == month }.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    public static func currentMonthTokens(
        in aggregates: [UsageAggregate],
        providerID: UUID,
        model: String,
        date: Date = .now
    ) -> Int {
        let month = monthKey(for: date)
        return aggregates.lazy.filter {
            $0.month == month
                && $0.providerID == providerID
                && $0.model == model
        }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
