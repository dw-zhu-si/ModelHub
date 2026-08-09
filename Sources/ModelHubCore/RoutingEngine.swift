import Foundation

public actor RoutingEngine {
    private var roundRobinCounters: [UUID: Int] = [:]

    public init() {}

    public func candidates(
        for requestedModel: String,
        routes: [RouteConfig],
        providers: [ProviderConfig],
        healthRecords: [ModelHealthRecord] = [],
        usage: [UsageAggregate] = [],
        requiredCapabilities: Set<ModelCapability> = [],
        defaultRule: DefaultRoutingRule = .sameModelLowestCost,
        accessPolicy: RoutingAccessPolicy = .unrestricted
    ) -> [RouteTarget] {
        candidates(
            for: requestedModel,
            routes: routes,
            providers: providers,
            health: ModelHealthIndex(records: healthRecords),
            usage: usage,
            requiredCapabilities: requiredCapabilities,
            defaultRule: defaultRule,
            accessPolicy: accessPolicy
        )
    }

    public func candidates(
        for requestedModel: String,
        routes: [RouteConfig],
        providers: [ProviderConfig],
        health: ModelHealthIndex,
        usage: [UsageAggregate] = [],
        requiredCapabilities: Set<ModelCapability> = [],
        defaultRule: DefaultRoutingRule = .sameModelLowestCost,
        accessPolicy: RoutingAccessPolicy = .unrestricted
    ) -> [RouteTarget] {
        let enabledProviders = Set(providers.filter(\.enabled).map(\.id))

        if let route = routes.first(where: {
            $0.enabled && $0.alias.caseInsensitiveCompare(requestedModel) == .orderedSame
        }) {
            let providerIndex = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
            let targets = route.targets.map { target in
                guard target.profile == nil,
                      let inherited = providerIndex[target.providerID]?.modelProfiles?[target.model]
                else { return target }
                var enriched = target
                enriched.profile = inherited
                return enriched
            }.filter { target in
                guard enabledProviders.contains(target.providerID),
                      !target.model.trimmingCharacters(in: .whitespaces).isEmpty,
                      let provider = providerIndex[target.providerID]
                else { return false }
                return RoutingPolicyEvaluator.exclusionReasons(
                    target: target,
                    provider: provider,
                    health: health,
                    usage: usage,
                    requiredCapabilities: requiredCapabilities,
                    constraints: route.constraints,
                    access: accessPolicy
                ).isEmpty
            }
            return orderedTargets(
                targets,
                route: route,
                providers: providers,
                health: health,
                usage: usage,
                defaultRule: defaultRule
            )
        }

        let directMatches = providers
            .filter(\.enabled)
            .flatMap { provider in
                provider.models.compactMap { model -> RouteTarget? in
                    let names = [
                        model,
                        "\(provider.name)/\(model)",
                        "\(provider.id.uuidString)/\(model)"
                    ]
                    guard names.contains(where: {
                        $0.caseInsensitiveCompare(requestedModel) == .orderedSame
                    }) else { return nil }
                    let target = RouteTarget(
                        providerID: provider.id,
                        model: model,
                        profile: provider.modelProfiles?[model]
                    )
                    guard RoutingPolicyEvaluator.exclusionReasons(
                        target: target,
                        provider: provider,
                        health: health,
                        usage: usage,
                        requiredCapabilities: requiredCapabilities,
                        constraints: nil,
                        access: accessPolicy
                    ).isEmpty else { return nil }
                    return target
                }
            }
        let healthOrdered = health.order(targets: directMatches)
        let originalOrder = Dictionary(uniqueKeysWithValues: healthOrdered.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = healthOrdered
            .sorted {
                let leftCapability = capabilityRank($0.profile, required: requiredCapabilities)
                let rightCapability = capabilityRank($1.profile, required: requiredCapabilities)
                if leftCapability != rightCapability { return leftCapability < rightCapability }
                let leftModel = $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let rightModel = $1.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard leftModel == rightModel else {
                    return (originalOrder[$0.id] ?? .max) < (originalOrder[$1.id] ?? .max)
                }
                return compare(
                    $0,
                    $1,
                    providers: providers,
                    health: health,
                    usage: usage,
                    defaultRule: defaultRule
                )
            }
        return ordered
    }

    private func supports(
        _ required: Set<ModelCapability>,
        profile: TargetProfile?
    ) -> Bool {
        guard !required.isEmpty, let profile, !profile.capabilities.isEmpty else { return true }
        return required.isSubset(of: profile.capabilities)
    }

    private func capabilityRank(
        _ profile: TargetProfile?,
        required: Set<ModelCapability>
    ) -> Int {
        guard !required.isEmpty else { return 0 }
        guard let profile, !profile.capabilities.isEmpty else { return 1 }
        return required.isSubset(of: profile.capabilities) ? 0 : 2
    }

    private func orderedTargets(
        _ targets: [RouteTarget],
        route: RouteConfig,
        providers: [ProviderConfig],
        health: ModelHealthIndex,
        usage: [UsageAggregate],
        defaultRule: DefaultRoutingRule
    ) -> [RouteTarget] {
        guard !targets.isEmpty else { return [] }

        let tiers = ModelAvailability.allCases
            .sorted { $0.routingRank < $1.routingRank }
            .map { status in
                targets.filter {
                    health.status(providerID: $0.providerID, model: $0.model) == status
                }
            }
            .filter { !$0.isEmpty }

        switch route.strategy {
        case .priority:
            return tiers.flatMap { tier in
                tier.sorted {
                    if $0.priority == $1.priority { return $0.weight > $1.weight }
                    return $0.priority < $1.priority
                }
            }
        case .roundRobin:
            let counter = roundRobinCounters[route.id, default: 0]
            roundRobinCounters[route.id] = counter + 1
            return tiers.flatMap { tier in
                let offset = counter % tier.count
                return Array(tier[offset...] + tier[..<offset])
            }
        case .weightedRandom:
            return tiers.flatMap { tier in
                let weighted = tier.flatMap { target in
                    Array(repeating: target, count: max(1, min(target.weight, 100)))
                }
                guard let first = weighted.randomElement() else { return tier }
                return [first] + tier.filter { $0.id != first.id }
            }
        case .lowestLatency:
            return tiers.flatMap { tier in
                tier.sorted {
                    latency(for: $0, health: health, usage: usage)
                        < latency(for: $1, health: health, usage: usage)
                }
            }
        case .highestStability:
            return tiers.flatMap { tier in
                tier.sorted {
                    stability(for: $0, usage: usage) > stability(for: $1, usage: usage)
                }
            }
        case .lowestCost:
            return tiers.flatMap { tier in
                tier.sorted { estimatedUnitCost(for: $0) < estimatedUnitCost(for: $1) }
            }
        case .largestContext:
            return tiers.flatMap { tier in
                tier.sorted {
                    ($0.profile?.contextWindow ?? -1) > ($1.profile?.contextWindow ?? -1)
                }
            }
        case .balanced:
            return tiers.flatMap { tier in
                tier.sorted {
                    balancedScore(for: $0, health: health, usage: usage)
                        < balancedScore(for: $1, health: health, usage: usage)
                }
            }
        }
    }

    private func compare(
        _ lhs: RouteTarget,
        _ rhs: RouteTarget,
        providers: [ProviderConfig],
        health: ModelHealthIndex,
        usage: [UsageAggregate],
        defaultRule: DefaultRoutingRule
    ) -> Bool {
        let leftModel = lhs.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rightModel = rhs.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard leftModel == rightModel else { return lhs.id.uuidString < rhs.id.uuidString }
        let leftProvider = providers.first { $0.id == lhs.providerID }
        let rightProvider = providers.first { $0.id == rhs.providerID }
        switch defaultRule {
        case .sameModelLowestCost:
            let left = estimatedUnitCost(for: lhs)
            let right = estimatedUnitCost(for: rhs)
            if left != right { return left < right }
        case .sameModelLowestLatency:
            let left = latency(for: lhs, health: health, usage: usage)
            let right = latency(for: rhs, health: health, usage: usage)
            if left != right { return left < right }
        case .sameModelOfficial:
            let left = leftProvider?.kind.isOfficialProvider(for: lhs.model) == true
            let right = rightProvider?.kind.isOfficialProvider(for: rhs.model) == true
            if left != right { return left && !right }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func latency(
        for target: RouteTarget,
        health: ModelHealthIndex,
        usage: [UsageAggregate] = []
    ) -> Int {
        let p90 = usage.filter {
            $0.providerID == target.providerID && $0.model == target.model
        }.compactMap(\.p90LatencyMilliseconds).max()
        if let p90, p90 > 0 { return p90 }
        let measured = health.record(providerID: target.providerID, model: target.model)?
            .latencyMilliseconds
        return measured.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
    }

    private func estimatedUnitCost(for target: RouteTarget) -> Double {
        guard let profile = target.profile, profile.hasKnownPrice else {
            return .greatestFiniteMagnitude
        }
        return profile.configuredUnitCostUSD
    }

    private func stability(for target: RouteTarget, usage: [UsageAggregate]) -> Double {
        let matching = usage.filter {
            $0.providerID == target.providerID && $0.model == target.model
        }
        let requests = matching.reduce(0) { $0 + $1.requests }
        guard requests > 0 else { return -1 }
        let success = matching.reduce(0) { $0 + $1.successfulRequests }
        return Double(success) / Double(requests)
    }

    private func balancedScore(
        for target: RouteTarget,
        health: ModelHealthIndex,
        usage: [UsageAggregate]
    ) -> Double {
        let latencyScore = Double(min(latency(for: target, health: health, usage: usage), 60_000)) / 1_000
        let cost = estimatedUnitCost(for: target)
        let costScore = cost.isFinite ? min(cost, 1_000) : 100
        let context = Double(target.profile?.contextWindow ?? 0)
        let contextCredit = min(context / 100_000, 20)
        let priorityPenalty = Double(max(target.priority, 0)) * 2
        let stabilityCredit = max(0, stability(for: target, usage: usage)) * 20
        return latencyScore + costScore + priorityPenalty - contextCredit - stabilityCredit
    }
}
