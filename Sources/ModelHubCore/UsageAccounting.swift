import Foundation

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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    public static func recording(
        aggregates: [UsageAggregate],
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
        let month = monthKey(for: date)
        var result = aggregates
        if let index = result.firstIndex(where: {
            $0.month == month
                && $0.requestedModel == requestedModel
                && $0.providerID == providerID
                && $0.model == model
        }) {
            result[index].requests += 1
            result[index].successfulRequests += (200..<300).contains(statusCode) ? 1 : 0
            result[index].totalLatencyMilliseconds += max(0, latencyMilliseconds)
            result[index].inputTokens += max(0, tokens.input)
            result[index].outputTokens += max(0, tokens.output)
            if let estimatedCostUSD {
                result[index].pricedRequests += 1
                result[index].estimatedCostUSD += max(0, estimatedCostUSD)
            }
            result[index].contextCharactersSaved += max(0, contextCharactersSaved)
            result[index].lastUsedAt = date
            var samples = result[index].recentLatencyMilliseconds ?? []
            samples.append(max(0, latencyMilliseconds))
            if samples.count > 100 { samples.removeFirst(samples.count - 100) }
            result[index].recentLatencyMilliseconds = samples
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

        let months = max(1, retentionMonths)
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .month, value: -(months - 1), to: date) ?? date
        let cutoffMonth = monthKey(for: cutoff)
        return result.filter { $0.month >= cutoffMonth }
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
            $0.month == month && $0.providerID == providerID && $0.model == model
        }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
