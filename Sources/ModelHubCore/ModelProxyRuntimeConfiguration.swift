import Foundation

public struct ProxyRuntimeSubscriptionFile: Hashable, Sendable {
    public let subscription: ProxySubscription
    public let path: String

    public init(subscription: ProxySubscription, path: String) {
        self.subscription = subscription
        self.path = path
    }
}

public enum ModelProxyRuntimeConfigurationError: LocalizedError {
    case tooManyActiveNodes(Int)
    case missingNode(String)
    case missingSubscription(UUID)

    public var errorDescription: String? {
        switch self {
        case .tooManyActiveNodes(let count):
            "正在使用的订阅节点有 \(count) 个，超过 \(ModelProxySettings.maximumActiveNodes) 个上限"
        case .missingNode(let id):
            "代理节点不存在或订阅尚未更新：\(id)"
        case .missingSubscription(let id):
            "代理节点所属订阅不存在：\(id.uuidString)"
        }
    }
}

public enum ModelProxyRuntimeConfiguration {
    public static func yaml(
        settings: ModelProxySettings,
        subscriptionFiles: [ProxyRuntimeSubscriptionFile],
        controllerSecret: String
    ) throws -> String {
        let settings = settings.sanitized
        guard settings.activeNodeIDs.count <= ModelProxySettings.maximumActiveNodes else {
            throw ModelProxyRuntimeConfigurationError.tooManyActiveNodes(
                settings.activeNodeIDs.count
            )
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: settings.nodes.map { ($0.id, $0) })
        let subscriptionsByID = Dictionary(
            uniqueKeysWithValues: settings.subscriptions.map { ($0.id, $0) }
        )
        let filesByID = Dictionary(
            uniqueKeysWithValues: subscriptionFiles.map { ($0.subscription.id, $0) }
        )

        var lines = [
            "allow-lan: false",
            "bind-address: \"127.0.0.1\"",
            "mode: global",
            "log-level: warning",
            "ipv6: true",
            "unified-delay: true",
            "external-controller: \"127.0.0.1:\(ModelProxySettings.controllerPort)\"",
            "secret: \(yamlQuoted(controllerSecret))",
            // Clash TUN commonly exposes synthetic 198.18/15 answers through
            // the system resolver. This managed core is intentionally routed
            // DIRECT by process name, so dialing those synthetic addresses
            // would bypass Clash and make every hostname-backed node time out.
            // Resolve proxy servers through IP-addressed DoH endpoints and
            // keep real addresses with redir-host instead.
            "dns:",
            "  enable: true",
            "  ipv6: false",
            "  enhanced-mode: redir-host",
            "  default-nameserver:",
            "    - 223.5.5.5",
            "    - 1.1.1.1",
            "  nameserver:",
            "    - https://223.5.5.5/dns-query",
            "    - https://1.1.1.1/dns-query",
            "  proxy-server-nameserver:",
            "    - https://223.5.5.5/dns-query",
            "    - https://1.1.1.1/dns-query",
            "proxy-providers:"
        ]

        for file in subscriptionFiles.sorted(by: {
            $0.subscription.id.uuidString < $1.subscription.id.uuidString
        }) where file.subscription.enabled {
            let key = providerKey(file.subscription.id)
            lines.append("  \(key):")
            lines.append("    type: file")
            lines.append("    path: \(yamlQuoted(file.path))")
            lines.append("    override:")
            lines.append("      additional-prefix: \(yamlQuoted(file.subscription.runtimePrefix + " "))")
            lines.append("    health-check:")
            lines.append("      enable: false")
        }

        if settings.activeNodeIDs.isEmpty {
            lines.append("proxy-groups: []")
        } else {
            lines.append("proxy-groups:")
        }
        for nodeID in settings.activeNodeIDs {
            guard let node = nodesByID[nodeID] else {
                throw ModelProxyRuntimeConfigurationError.missingNode(nodeID)
            }
            guard let subscription = subscriptionsByID[node.subscriptionID],
                  filesByID[node.subscriptionID] != nil,
                  let port = settings.nodePortMap[nodeID]
            else {
                throw ModelProxyRuntimeConfigurationError.missingSubscription(
                    node.subscriptionID
                )
            }
            let runtimeNodeName = subscription.runtimePrefix + " " + node.name
            lines.append("  - name: \(yamlQuoted(routeGroupName(port)))")
            lines.append("    type: select")
            lines.append("    use:")
            lines.append("      - \(providerKey(subscription.id))")
            lines.append("    filter: \(yamlQuoted("^" + NSRegularExpression.escapedPattern(for: runtimeNodeName) + "$"))")
        }

        if settings.activeNodeIDs.isEmpty {
            lines.append("listeners: []")
        } else {
            lines.append("listeners:")
        }
        for nodeID in settings.activeNodeIDs {
            guard let node = nodesByID[nodeID] else {
                throw ModelProxyRuntimeConfigurationError.missingNode(nodeID)
            }
            guard subscriptionsByID[node.subscriptionID] != nil,
                  filesByID[node.subscriptionID] != nil
            else {
                throw ModelProxyRuntimeConfigurationError.missingSubscription(
                    node.subscriptionID
                )
            }
            guard let port = settings.nodePortMap[nodeID] else {
                throw ModelProxyRuntimeConfigurationError.tooManyActiveNodes(
                    settings.activeNodeIDs.count
                )
            }
            lines.append("  - name: \(yamlQuoted("modelhub-node-\(port)"))")
            lines.append("    type: http")
            lines.append("    listen: \"127.0.0.1\"")
            lines.append("    port: \(port)")
            lines.append("    users: []")
            lines.append("    proxy: \(yamlQuoted(routeGroupName(port)))")
        }

        lines.append("rules:")
        lines.append("  - MATCH,DIRECT")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func providerKey(_ subscriptionID: UUID) -> String {
        "modelhub_\(subscriptionID.uuidString.lowercased().replacingOccurrences(of: "-", with: "_"))"
    }

    public static func routeGroupName(_ port: Int) -> String {
        "modelhub-route-\(port)"
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
