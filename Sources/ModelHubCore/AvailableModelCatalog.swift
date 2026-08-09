import Foundation

public struct AvailableModelEntry: Equatable, Sendable {
    public let id: String
    public let owner: String
    public let isRoute: Bool
    public let providerID: UUID?
    public let targetModel: String?

    public init(
        id: String,
        owner: String,
        isRoute: Bool,
        providerID: UUID? = nil,
        targetModel: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.isRoute = isRoute
        self.providerID = providerID
        self.targetModel = targetModel
    }
}

public enum AvailableModelCatalog {
    public static func entries(
        routes: [RouteConfig],
        providers: [ProviderConfig],
        healthRecords: [ModelHealthRecord]
    ) -> [AvailableModelEntry] {
        entries(
            routes: routes,
            providers: providers,
            health: ModelHealthIndex(records: healthRecords)
        )
    }

    public static func entries(
        routes: [RouteConfig],
        providers: [ProviderConfig],
        health: ModelHealthIndex
    ) -> [AvailableModelEntry] {
        let enabledProviders = Dictionary(
            providers.filter(\.enabled).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var seen = Set<String>()
        var result: [AvailableModelEntry] = []

        for route in routes where route.enabled {
            let hasAvailableTarget = route.targets.contains { target in
                guard let provider = enabledProviders[target.providerID],
                      provider.models.contains(where: {
                          $0.caseInsensitiveCompare(target.model) == .orderedSame
                      })
                else { return false }
                return health.status(
                    providerID: target.providerID,
                    model: target.model
                ) == .available
            }
            if hasAvailableTarget, seen.insert(normalized(route.alias)).inserted {
                result.append(
                    AvailableModelEntry(
                        id: route.alias,
                        owner: "modelhub-route",
                        isRoute: true,
                        providerID: nil,
                        targetModel: nil
                    )
                )
            }
        }

        for provider in providers where provider.enabled {
            for model in provider.models where health.status(
                providerID: provider.id,
                model: model
            ) == .available {
                let qualified = "\(provider.name)/\(model)"
                if seen.insert(normalized(qualified)).inserted {
                    result.append(
                        AvailableModelEntry(
                            id: qualified,
                            owner: provider.name,
                            isRoute: false,
                            providerID: provider.id,
                            targetModel: model
                        )
                    )
                }
            }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
