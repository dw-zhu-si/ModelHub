import Foundation
import ModelHubCore

public struct MobileModelHealthSummary: Codable, Equatable, Sendable {
    public let total: Int
    public let available: Int
    public let unavailable: Int
    public let unknown: Int
    public let configurationRequired: Int
    public let unsupported: Int

    public init(
        total: Int,
        available: Int,
        unavailable: Int,
        unknown: Int,
        configurationRequired: Int,
        unsupported: Int
    ) {
        self.total = total
        self.available = available
        self.unavailable = unavailable
        self.unknown = unknown
        self.configurationRequired = configurationRequired
        self.unsupported = unsupported
    }
}

public struct MobileProviderHealthSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let totalModels: Int
    public let availableModels: Int
    public let quarantinedModels: Int

    public init(
        id: UUID,
        name: String,
        totalModels: Int,
        availableModels: Int,
        quarantinedModels: Int
    ) {
        self.id = id
        self.name = name
        self.totalModels = totalModels
        self.availableModels = availableModels
        self.quarantinedModels = quarantinedModels
    }
}

public struct MobileGatewayOverview: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let gatewayVersion: String
    public let generatedAt: Date
    public let isGatewayRunning: Bool
    public let defaultModel: String?
    public let enabledProviderCount: Int
    public let enabledRouteCount: Int
    public let modelHealth: MobileModelHealthSummary
    public let providers: [MobileProviderHealthSummary]

    public init(
        protocolVersion: String,
        gatewayVersion: String,
        generatedAt: Date,
        isGatewayRunning: Bool,
        defaultModel: String?,
        enabledProviderCount: Int,
        enabledRouteCount: Int,
        modelHealth: MobileModelHealthSummary,
        providers: [MobileProviderHealthSummary]
    ) {
        self.protocolVersion = protocolVersion
        self.gatewayVersion = gatewayVersion
        self.generatedAt = generatedAt
        self.isGatewayRunning = isGatewayRunning
        self.defaultModel = defaultModel
        self.enabledProviderCount = enabledProviderCount
        self.enabledRouteCount = enabledRouteCount
        self.modelHealth = modelHealth
        self.providers = providers
    }
}

public enum MobileOverviewBuilder {
    public static func make(
        configuration: AppConfiguration,
        gatewayVersion: String,
        isGatewayRunning: Bool,
        generatedAt: Date = .now
    ) -> MobileGatewayOverview {
        let providers = configuration.providers.filter(\.enabled)
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let health = ModelHealthIndex(records: configuration.modelHealth)
        var available = 0
        var unavailable = 0
        var unknown = 0
        var configurationRequired = 0
        var unsupported = 0

        let providerSummaries = providers.map { provider in
            var providerAvailable = 0
            for model in provider.models {
                switch health.status(providerID: provider.id, model: model) {
                case .available:
                    available += 1
                    providerAvailable += 1
                case .unavailable: unavailable += 1
                case .unknown: unknown += 1
                case .configurationRequired: configurationRequired += 1
                case .unsupported: unsupported += 1
                }
            }
            return MobileProviderHealthSummary(
                id: provider.id,
                name: provider.name,
                totalModels: provider.models.count,
                availableModels: providerAvailable,
                quarantinedModels: provider.models.count - providerAvailable
            )
        }

        let defaultRoute = configuration.routes.first { route in
            route.enabled && route.targets.contains { target in
                providerByID[target.providerID] != nil
                    && health.status(providerID: target.providerID, model: target.model) == .available
            }
        }?.alias
        let fallbackModel = providers.lazy.compactMap { provider in
            provider.models.first {
                health.status(providerID: provider.id, model: $0) == .available
            }.map { "\(provider.name)/\($0)" }
        }.first

        return MobileGatewayOverview(
            protocolVersion: "1.0",
            gatewayVersion: gatewayVersion,
            generatedAt: generatedAt,
            isGatewayRunning: isGatewayRunning,
            defaultModel: defaultRoute ?? fallbackModel,
            enabledProviderCount: providers.count,
            enabledRouteCount: configuration.routes.filter(\.enabled).count,
            modelHealth: MobileModelHealthSummary(
                total: available + unavailable + unknown + configurationRequired + unsupported,
                available: available,
                unavailable: unavailable,
                unknown: unknown,
                configurationRequired: configurationRequired,
                unsupported: unsupported
            ),
            providers: providerSummaries
        )
    }
}
