import Foundation
import XCTest
@testable import ModelHubCore

final class OperationalCoreTests: XCTestCase {
    func testUsageRecordingPerformanceBaseline() {
        let providerID = UUID()
        let date = Date(timeIntervalSince1970: 1_775_865_600)
        var aggregates = (0..<1_000).map { index in
            UsageAggregate(
                month: UsageAccounting.monthKey(for: date),
                requestedModel: "request-\(index)",
                providerID: providerID,
                providerName: "Performance",
                model: "model-\(index)",
                requests: 1,
                successfulRequests: 1,
                totalLatencyMilliseconds: 100,
                lastUsedAt: date,
                recentLatencyMilliseconds: [100]
            )
        }
        let clock = ContinuousClock()
        let started = clock.now

        for _ in 0..<10_000 {
            aggregates = UsageAccounting.recording(
                aggregates: aggregates,
                requestedModel: "request-999",
                providerID: providerID,
                providerName: "Performance",
                model: "model-999",
                statusCode: 200,
                latencyMilliseconds: 120,
                tokens: UsageTokenCounts(input: 10, output: 5),
                estimatedCostUSD: 0.001,
                contextCharactersSaved: 2,
                date: date
            )
        }

        let duration = started.duration(to: clock.now)
        XCTAssertEqual(aggregates.count, 1_000)
        XCTAssertEqual(aggregates.last?.requests, 10_001)
        print("USAGE_RECORDING_BASELINE workload=1000_aggregates_10000_updates duration=\(duration)")
#if !DEBUG
        XCTAssertLessThan(duration, .seconds(1))
#endif
    }

    func testUsageRecordingKeepsRotatingHotSetAtTail() {
        let providerID = UUID()
        let date = Date(timeIntervalSince1970: 1_775_865_600)
        var aggregates = (0..<1_000).map { index in
            UsageAggregate(
                month: UsageAccounting.monthKey(for: date),
                requestedModel: "request-\(index)",
                providerID: providerID,
                providerName: "Performance",
                model: "model-\(index)",
                requests: 1,
                successfulRequests: 1,
                lastUsedAt: date
            )
        }
        let clock = ContinuousClock()
        let started = clock.now

        for update in 0..<10_000 {
            let key = update % 10
            aggregates = UsageAccounting.recording(
                aggregates: aggregates,
                requestedModel: "request-\(key)",
                providerID: providerID,
                providerName: "Performance",
                model: "model-\(key)",
                statusCode: 200,
                latencyMilliseconds: 20,
                tokens: .init(),
                estimatedCostUSD: nil,
                contextCharactersSaved: 0,
                date: date
            )
        }

        let duration = started.duration(to: clock.now)
        let hotRows = aggregates.suffix(10)
        XCTAssertEqual(Set(hotRows.map(\.model)), Set((0..<10).map { "model-\($0)" }))
        XCTAssertEqual(hotRows.reduce(0) { $0 + $1.requests }, 10_010)
        print("USAGE_ROTATING_HOT_SET workload=1000_aggregates_10_hot_keys_10000_updates duration=\(duration)")
#if !DEBUG
        XCTAssertLessThan(duration, .seconds(1))
#endif
    }

    func testUsageMonthComponentUsesUTCAndCrossesYearBoundary() {
        let january = UsageMonth(date: Date(timeIntervalSince1970: 1_767_225_600))

        XCTAssertEqual(january.key, "2026-01")
        XCTAssertEqual(january.adding(months: -1).key, "2025-12")
        XCTAssertEqual(january.adding(months: 12).key, "2027-01")
    }

    func testUsageRecordingPreservesArrayCodableContractAndRetentionOrder() throws {
        let providerID = UUID()
        let date = Date(timeIntervalSince1970: 1_775_865_600)
        let old = UsageAggregate(
            month: "2024-01",
            requestedModel: "old",
            providerID: providerID,
            providerName: "Performance",
            model: "old-model"
        )
        let current = UsageAggregate(
            month: UsageAccounting.monthKey(for: date),
            requestedModel: "current",
            providerID: providerID,
            providerName: "Performance",
            model: "current-model",
            requests: 2
        )

        let recorded = UsageAccounting.recording(
            aggregates: [old, current],
            requestedModel: "current",
            providerID: providerID,
            providerName: "Performance",
            model: "current-model",
            statusCode: 200,
            latencyMilliseconds: 50,
            tokens: .init(),
            estimatedCostUSD: nil,
            contextCharactersSaved: 0,
            date: date,
            retentionMonths: 12
        )
        let encoded = try JSONEncoder().encode(recorded)
        let decoded = try JSONDecoder().decode([UsageAggregate].self, from: encoded)

        XCTAssertEqual(decoded.map(\.id), [current.id])
        XCTAssertEqual(decoded.first?.requests, 3)
    }

    func testProxyEndpointIndexMatchesValidatedSettingsForAssignedAndManualModels() {
        let subscription = ProxySubscription(
            name: "性能测试订阅",
            sourceHost: "example.invalid"
        )
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "节点 A",
            type: "Direct"
        )
        let assignedProviderID = UUID()
        let manualProviderID = UUID()
        let settings = ModelProxySettings(
            enabled: true,
            kind: .socks5,
            host: "127.0.0.1",
            port: 7890,
            selections: [ModelProxySelection(
                providerID: manualProviderID,
                model: "manual-model"
            )],
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: assignedProviderID,
                model: "assigned-model",
                nodeID: node.id
            )]
        )

        let index = ModelProxyEndpointIndex(settings: settings)

        XCTAssertEqual(
            index.endpoint(providerID: assignedProviderID, model: "assigned-model"),
            settings.endpoint(providerID: assignedProviderID, model: "assigned-model")
        )
        XCTAssertEqual(
            index.endpoint(providerID: manualProviderID, model: "manual-model"),
            settings.endpoint(providerID: manualProviderID, model: "manual-model")
        )
        XCTAssertNil(index.endpoint(providerID: manualProviderID, model: "other-model"))
    }

    func testProxyEndpointIndexLargeLookupBaseline() {
        let subscription = ProxySubscription(
            name: "Synthetic",
            sourceHost: "example.invalid"
        )
        let nodes = (0..<2).map {
            ProxySubscriptionNode(
                subscriptionID: subscription.id,
                name: "Node \($0)",
                type: "Direct"
            )
        }
        let providerID = UUID()
        let assignments = (0..<768).map { index in
            ModelProxyAssignment(
                providerID: providerID,
                model: "model-\(index)",
                nodeID: nodes[index % nodes.count].id
            )
        }
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: nodes,
            assignments: assignments
        )
        let index = ModelProxyEndpointIndex(settings: settings)
        let clock = ContinuousClock()

        let legacyStart = clock.now
        for lookup in 0..<1_000 {
            XCTAssertNotNil(settings.endpoint(
                providerID: providerID,
                model: "model-\(lookup % assignments.count)"
            ))
        }
        let legacy = legacyStart.duration(to: clock.now)

        let indexedStart = clock.now
        for lookup in 0..<1_000 {
            XCTAssertNotNil(index.endpoint(
                providerID: providerID,
                model: "model-\(lookup % assignments.count)"
            ))
        }
        let indexed = indexedStart.duration(to: clock.now)
        print("PROXY_ENDPOINT_LOOKUP legacy=\(legacy) indexed=\(indexed)")
    }

    func testBulkProxyNodeAssignmentDeduplicatesModelsAndPreservesOtherProviders() {
        let subscriptionID = UUID()
        let providerID = UUID()
        let otherProviderID = UUID()
        let firstNode = ProxySubscriptionNode(
            subscriptionID: subscriptionID,
            name: "节点 A",
            type: "ss"
        )
        let secondNode = ProxySubscriptionNode(
            subscriptionID: subscriptionID,
            name: "节点 B",
            type: "ss"
        )
        var settings = ModelProxySettings(
            subscriptions: [ProxySubscription(
                id: subscriptionID,
                name: "测试订阅",
                sourceHost: "example.com"
            )],
            nodes: [firstNode, secondNode],
            assignments: [
                ModelProxyAssignment(
                    providerID: otherProviderID,
                    model: "other-model",
                    nodeID: firstNode.id
                ),
                ModelProxyAssignment(
                    providerID: providerID,
                    model: "model-a",
                    nodeID: firstNode.id
                )
            ]
        )

        let changed = settings.setAssignedNode(
            secondNode.id,
            providerID: providerID,
            models: ["model-a", " model-b ", "model-b", ""]
        )

        XCTAssertEqual(changed, 2)
        XCTAssertEqual(settings.assignments.count, 3)
        XCTAssertTrue(settings.assignments.contains {
            $0.providerID == otherProviderID && $0.nodeID == firstNode.id
        })
        XCTAssertEqual(
            Set(settings.assignments.filter { $0.providerID == providerID }.map(\.nodeID)),
            [secondNode.id]
        )
    }

    func testApplyingAChosenNodeCanEnableTheExactModelProxyInOneAction() {
        let subscriptionID = UUID()
        let providerID = UUID()
        let node = ProxySubscriptionNode(
            subscriptionID: subscriptionID,
            name: "节点 A",
            type: "ss"
        )
        var settings = ModelProxySettings(
            enabled: false,
            subscriptions: [ProxySubscription(
                id: subscriptionID,
                name: "测试订阅",
                sourceHost: "example.com"
            )],
            nodes: [node]
        )

        let changed = settings.setAssignedNode(
            node.id,
            providerID: providerID,
            models: ["chat-model"],
            enableWhenAssigned: true
        )

        XCTAssertEqual(changed, 1)
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.endpoint(providerID: providerID, model: "chat-model"))
    }

    func testRemovingAssignmentsDoesNotEnableTheModelProxy() {
        var settings = ModelProxySettings(enabled: false)

        _ = settings.setAssignedNode(
            nil,
            providerID: UUID(),
            models: ["chat-model"],
            enableWhenAssigned: true
        )

        XCTAssertFalse(settings.enabled)
    }

    func testFixedPerRequestPriceAccountsForMediaWithoutTokenUsage() {
        let profile = TargetProfile(requestCostUSD: 0.08, pricingSource: "official")

        XCTAssertEqual(
            UsageAccounting.estimatedCostUSD(tokens: .init(), profile: profile),
            0.08
        )
    }

    func testFixedPerRequestPriceDoesNotHideMissingTokenRate() {
        let profile = TargetProfile(
            inputCostPerMillionTokens: 1,
            requestCostUSD: 0.08,
            pricingSource: "official"
        )

        XCTAssertNil(UsageAccounting.estimatedCostUSD(
            tokens: UsageTokenCounts(input: 100, output: 50),
            profile: profile
        ))
    }

    func testPricingScheduleDefaultsToLocalMidnightAndSupportsConfiguredTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 10, minute: 15
        )))

        let defaults = PricingUpdateSettings()
        let mostRecent = try XCTUnwrap(defaults.mostRecentScheduledDate(
            before: now,
            calendar: calendar
        ))
        XCTAssertEqual(calendar.component(.hour, from: mostRecent), 0)
        XCTAssertEqual(calendar.component(.day, from: mostRecent), 8)

        let configured = PricingUpdateSettings(localHour: 6, localMinute: 30)
        let next = try XCTUnwrap(configured.nextScheduledDate(after: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: next), 9)
        XCTAssertEqual(calendar.component(.hour, from: next), 6)
        XCTAssertEqual(calendar.component(.minute, from: next), 30)

        let sanitized = PricingUpdateSettings(localHour: 99, localMinute: -3).sanitized
        XCTAssertEqual(sanitized.localHour, 23)
        XCTAssertEqual(sanitized.localMinute, 0)
    }

    func testPricingScheduleDoesNotRunCatchUpOnFirstLaunch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 10, minute: 15
        )))
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 7, hour: 23, minute: 50
        )))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 0, minute: 5
        )))

        XCTAssertFalse(PricingUpdateSettings().shouldCatchUp(at: now, calendar: calendar))
        XCTAssertTrue(
            PricingUpdateSettings(lastAttemptAt: beforeMidnight)
                .shouldCatchUp(at: now, calendar: calendar)
        )
        XCTAssertFalse(
            PricingUpdateSettings(lastAttemptAt: afterMidnight)
                .shouldCatchUp(at: now, calendar: calendar)
        )
    }

    func testLegacyOperationalSettingsDecodeWithDefaultPricingSchedule() throws {
        let encoded = try JSONEncoder().encode(OperationalSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "pricingUpdate")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(OperationalSettings.self, from: legacy)
        XCTAssertNil(decoded.pricingUpdate)
        XCTAssertEqual((decoded.pricingUpdate ?? .init()).localHour, 0)
    }

    func testLegacyOperationalSettingsDecodeWithDefaultDisplayCurrency() throws {
        let encoded = try JSONEncoder().encode(OperationalSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "currencyDisplay")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(OperationalSettings.self, from: legacy)

        XCTAssertNil(decoded.currencyDisplay)
        XCTAssertEqual((decoded.currencyDisplay ?? .init()).currency, .usd)
    }

    func testLegacyOperationalSettingsDecodeWithProxyDisabled() throws {
        let encoded = try JSONEncoder().encode(OperationalSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "modelProxy")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(OperationalSettings.self, from: legacy)

        XCTAssertNil(decoded.modelProxy)
        XCTAssertFalse((decoded.modelProxy ?? .init()).enabled)
    }

    func testModelProxyMatchesExactProviderAndModelOnly() {
        let providerID = UUID()
        let settings = ModelProxySettings(
            enabled: true,
            kind: .http,
            host: "127.0.0.1",
            port: 7897,
            selections: [
                ModelProxySelection(providerID: providerID, model: "qwen-image-3.0-pro")
            ]
        )

        XCTAssertNotNil(settings.endpoint(providerID: providerID, model: "qwen-image-3.0-pro"))
        XCTAssertNil(settings.endpoint(providerID: providerID, model: "qwen-image-3.0"))
        XCTAssertNil(settings.endpoint(providerID: UUID(), model: "qwen-image-3.0-pro"))
    }

    func testLegacyModelProxyDecodesWithoutSubscriptionFields() throws {
        let providerID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "enabled": true,
            "kind": "http",
            "host": "127.0.0.1",
            "port": 7897,
            "selections": [[
                "providerID": providerID.uuidString,
                "model": "legacy-model"
            ]]
        ])

        let decoded = try JSONDecoder().decode(ModelProxySettings.self, from: data)

        XCTAssertTrue(decoded.subscriptions.isEmpty)
        XCTAssertTrue(decoded.nodes.isEmpty)
        XCTAssertTrue(decoded.assignments.isEmpty)
        XCTAssertNotNil(decoded.endpoint(providerID: providerID, model: "legacy-model"))
    }

    func testSubscriptionNodeAssignmentOverridesManualProxyForExactModel() throws {
        let providerID = UUID()
        let subscription = ProxySubscription(name: "Work", sourceHost: "example.com")
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "Hong Kong 01",
            type: "Shadowsocks"
        )
        let settings = ModelProxySettings(
            enabled: true,
            kind: .socks5,
            host: "127.0.0.1",
            port: 7890,
            selections: [ModelProxySelection(providerID: providerID, model: "direct-proxy")],
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: providerID,
                model: "subscribed-model",
                nodeID: node.id
            )]
        )

        let subscribed = try XCTUnwrap(settings.endpoint(
            providerID: providerID,
            model: "subscribed-model"
        ))
        XCTAssertEqual(subscribed.kind, .http)
        XCTAssertEqual(subscribed.host, "127.0.0.1")
        XCTAssertEqual(subscribed.port, ModelProxySettings.firstNodePort)
        XCTAssertEqual(
            settings.endpoint(providerID: providerID, model: "direct-proxy")?.port,
            7890
        )
        XCTAssertNil(settings.endpoint(providerID: providerID, model: "other"))
    }

    func testSubscriptionSanitizationRemovesCredentialBearingDisplayName() throws {
        let subscription = ProxySubscription(
            name: "https://subscription.example/path?token=super-secret-token",
            sourceHost: "subscription.example"
        ).sanitized

        XCTAssertEqual(subscription.name, "subscription.example")
        let encoded = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)
        XCTAssertFalse(encoded.contains("super-secret-token"))
        XCTAssertFalse(encoded.contains("https://subscription.example"))
    }

    func testSubscriptionProxyLimitsDistinctActiveNodes() {
        let providerID = UUID()
        let subscription = ProxySubscription(name: "Work", sourceHost: "example.com")
        let nodes = (0...ModelProxySettings.maximumActiveNodes).map {
            ProxySubscriptionNode(
                subscriptionID: subscription.id,
                name: "Node \($0)",
                type: "VMess"
            )
        }
        let assignments = nodes.enumerated().map { index, node in
            ModelProxyAssignment(
                providerID: providerID,
                model: "model-\(index)",
                nodeID: node.id
            )
        }
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: nodes,
            assignments: assignments
        )

        XCTAssertNotNil(settings.validationMessage)
    }

    func testMihomoRuntimeConfigUsesLoopbackAndContainsNoSubscriptionURL() throws {
        let providerID = UUID()
        let subscription = ProxySubscription(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Secure subscription",
            sourceHost: "secret.example.com"
        )
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "HK \"01\"",
            type: "Trojan"
        )
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: providerID,
                model: "model-a",
                nodeID: node.id
            )]
        )

        let yaml = try ModelProxyRuntimeConfiguration.yaml(
            settings: settings,
            subscriptionFiles: [ProxyRuntimeSubscriptionFile(
                subscription: subscription,
                path: "/private/tmp/modelhub/subscription.yaml"
            )],
            controllerSecret: "local-secret"
        )

        XCTAssertTrue(yaml.contains("external-controller: \"127.0.0.1:11453\""))
        XCTAssertTrue(yaml.contains("dns:\n  enable: true"))
        XCTAssertTrue(yaml.contains("enhanced-mode: redir-host"))
        XCTAssertTrue(yaml.contains("https://223.5.5.5/dns-query"))
        XCTAssertTrue(yaml.contains("https://1.1.1.1/dns-query"))
        XCTAssertTrue(yaml.contains("proxy-server-nameserver:"))
        XCTAssertTrue(yaml.contains("listen: \"127.0.0.1\""))
        XCTAssertTrue(yaml.contains("port: 11454"))
        XCTAssertTrue(yaml.contains("name: \"modelhub-route-11454\""))
        XCTAssertTrue(yaml.contains("filter: \"^\\\\[mh-aaaaaaaa] HK \\\"01\\\"$\""))
        XCTAssertTrue(yaml.contains("proxy: \"modelhub-route-11454\""))
        XCTAssertFalse(yaml.contains("secret.example.com"))
        XCTAssertFalse(yaml.contains("http://"))
        XCTAssertFalse(yaml.contains("https://secret.example.com"))
    }

    func testModelProxyRejectsCredentialBearingOrPathBearingHost() {
        XCTAssertNotNil(ModelProxySettings(
            enabled: true,
            host: "http://user:secret@127.0.0.1/path",
            port: 7897
        ).validationMessage)
        XCTAssertNotNil(ModelProxySettings(
            enabled: true,
            host: "127.0.0.1/path",
            port: 7897
        ).validationMessage)
        XCTAssertNotNil(ModelProxySettings(
            enabled: true,
            host: "127.0.0.1",
            port: 0
        ).validationMessage)
    }

    func testDisabledModelProxyStillRejectsCredentialBearingHost() {
        let settings = ModelProxySettings(
            enabled: false,
            host: "user:secret@127.0.0.1",
            port: 7897
        )

        XCTAssertNotNil(settings.validationMessage)
        XCTAssertNil(settings.endpoint(providerID: UUID(), model: "safe-model"))
    }

    func testCurrencyDisplayConvertsAndFormatsWithoutChangingStoredUSD() throws {
        let settings = CurrencyDisplaySettings(
            currency: .cny,
            unitsPerUSD: ["USD": 1, "CNY": 7.2]
        )
        XCTAssertEqual(settings.convertedFromUSD(2), 14.4, accuracy: 0.000_001)
        XCTAssertTrue(settings.formattedUSD(2).contains("14.4000"))
    }

    func testParsesOfficialEURReferenceRatesIntoUSDConversions() throws {
        let xml = Data(#"""
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
          xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <Cube><Cube time="2026-08-08">
            <Cube currency="USD" rate="1.2000"/>
            <Cube currency="CNY" rate="8.4000"/>
            <Cube currency="JPY" rate="180.0000"/>
          </Cube></Cube>
        </gesmes:Envelope>
        """#.utf8)
        let snapshot = try CurrencyRateClient.parse(xml)

        XCTAssertEqual(snapshot.unitsPerUSD["USD"], 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["EUR"]), 1 / 1.2, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["CNY"]), 7, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(snapshot.unitsPerUSD["JPY"]), 150, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveDate, "2026-08-08")
    }

    func testCurrencyDisplaySanitizesInvalidOrUnsupportedRates() {
        let settings = CurrencyDisplaySettings(
            currency: .cny,
            unitsPerUSD: ["CNY": -.infinity, "FAKE": 99]
        ).sanitized

        XCTAssertEqual(settings.currency, .usd)
        XCTAssertEqual(settings.unitsPerUSD, ["USD": 1])
    }

    func testRateLimitConcurrencyCircuitAndCooldown() async {
        let controller = ResilienceController()
        let providerID = UUID()
        let key = TargetRuntimeKey(providerID: providerID, model: "m")
        let now = Date(timeIntervalSince1970: 1_000)
        let settings = ResilienceSettings(
            requestsPerMinute: 2,
            maxConcurrentRequestsPerTarget: 1,
            failureThreshold: 2,
            cooldownSeconds: 10,
            maxFallbackAttempts: 3,
            backoffBaseMilliseconds: 50
        )

        let gateway1 = await controller.admitGatewayRequest(settings: settings, now: now)
        let gateway2 = await controller.admitGatewayRequest(settings: settings, now: now)
        let gateway3 = await controller.admitGatewayRequest(settings: settings, now: now)
        XCTAssertEqual(gateway1, .allowed)
        XCTAssertEqual(gateway2, .allowed)
        XCTAssertEqual(gateway3, .rateLimited(retryAfterSeconds: 60))
        let target1 = await controller.beginTarget(key, settings: settings, now: now)
        let target2 = await controller.beginTarget(key, settings: settings, now: now)
        XCTAssertEqual(target1, .allowed)
        XCTAssertEqual(target2, .concurrencyLimited)
        await controller.finishTarget(key, succeeded: false, transientFailure: true, settings: settings, now: now)
        let target3 = await controller.beginTarget(key, settings: settings, now: now)
        XCTAssertEqual(target3, .allowed)
        await controller.finishTarget(key, succeeded: false, transientFailure: true, settings: settings, now: now)
        let target4 = await controller.beginTarget(key, settings: settings, now: now)
        let target5 = await controller.beginTarget(
            key,
            settings: settings,
            now: now.addingTimeInterval(11)
        )
        XCTAssertEqual(target4, .circuitOpen(retryAfterSeconds: 10))
        XCTAssertEqual(target5, .allowed)
    }

    func testUsageAccountingDoesNotInventUnknownPrices() throws {
        let response = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500}}"#.utf8)
        let tokens = UsageAccounting.tokenCounts(from: response)
        XCTAssertEqual(tokens, UsageTokenCounts(input: 1_000, output: 500))
        XCTAssertNil(UsageAccounting.estimatedCostUSD(tokens: tokens, profile: nil))
        XCTAssertNil(UsageAccounting.estimatedCostUSD(
            tokens: tokens,
            profile: TargetProfile(inputCostPerMillionTokens: 1)
        ))
        let estimated = try XCTUnwrap(
            UsageAccounting.estimatedCostUSD(
                tokens: tokens,
                profile: TargetProfile(
                    inputCostPerMillionTokens: 1,
                    outputCostPerMillionTokens: 2,
                    pricingSource: "manual"
                )
            )
        )
        XCTAssertEqual(estimated, 0.002, accuracy: 0.000_001)

        let eventStream = Data("data: {\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}\n\ndata: [DONE]\n\n".utf8)
        XCTAssertEqual(
            UsageAccounting.tokenCounts(fromEventStream: eventStream),
            UsageTokenCounts(input: 12, output: 7)
        )
    }

    func testContextOptimizerPreservesToolArgumentsAndCodeBlocks() throws {
        let body = Data(#"{"model":"m","messages":[{"role":"user","content":"hello   \n\n\n\nworld"},{"role":"assistant","content":"```swift\nlet x = 1   \n```","tool_calls":[{"function":{"arguments":"{  \\\"x\\\": 1 }"}}]}]}"#.utf8)
        let originalRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let originalMessages = try XCTUnwrap(originalRoot["messages"] as? [[String: Any]])
        let originalCalls = try XCTUnwrap(originalMessages[1]["tool_calls"] as? [[String: Any]])
        let originalFunction = try XCTUnwrap(originalCalls[0]["function"] as? [String: Any])
        let result = ContextOptimizer.optimizeChatBody(
            body,
            settings: ContextOptimizationSettings(mode: .conservative, minimumCharacters: 1)
        )
        XCTAssertGreaterThan(result.charactersSaved, 0)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["content"] as? String, "```swift\nlet x = 1   \n```")
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, originalFunction["arguments"] as? String)
    }

    func testBackupRoundTripContainsConfigurationButNoSecretField() throws {
        let configuration = AppConfiguration(
            providers: [ProviderConfig(name: "Local", kind: .ollama, baseURL: "http://127.0.0.1:11434")],
            routes: [RouteConfig(alias: "smart")]
        )
        let data = try ConfigurationBackup.exportData(configuration: configuration, appVersion: "1.7.0")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("api_key"))
        let preview = try ConfigurationBackup.preview(data)
        XCTAssertEqual(preview.providerCount, 1)
        XCTAssertEqual(preview.routeCount, 1)
        XCTAssertEqual(try ConfigurationBackup.configuration(from: data).providers.first?.name, "Local")
        XCTAssertThrowsError(
            try ConfigurationBackup.preview(Data(count: ConfigurationBackup.maximumBytes + 1))
        )
    }

    func testBackupRejectsCredentialBearingProxyEvenWhenProxyIsDisabled() throws {
        var configuration = AppConfiguration()
        configuration.operational.modelProxy = ModelProxySettings(
            enabled: false,
            host: "user:secret@127.0.0.1",
            port: 7897
        )

        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(
                configuration: configuration,
                appVersion: "1.9.2"
            )
        )

        let untrustedBackup = try JSONEncoder().encode(
            ConfigurationBackupEnvelope(
                appVersion: "1.9.2",
                configuration: configuration
            )
        )
        XCTAssertThrowsError(try ConfigurationBackup.preview(untrustedBackup))
    }

    func testBackupIncludesOnlySubscriptionMetadataAndRejectsInvalidSourceHost() throws {
        let subscriptionID = UUID()
        var configuration = AppConfiguration()
        configuration.operational.modelProxy = ModelProxySettings(
            subscriptions: [
                ProxySubscription(
                    id: subscriptionID,
                    name: "Private route",
                    sourceHost: "subscription.example",
                    updateIntervalHours: 12,
                    nodeCount: 3
                )
            ]
        )

        let data = try ConfigurationBackup.exportData(
            configuration: configuration,
            appVersion: "1.9.2"
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("subscription.example"))
        XCTAssertFalse(text.contains("https://subscription.example"))
        XCTAssertFalse(text.contains("super-secret-subscription-token"))

        var invalidConfiguration = configuration
        invalidConfiguration.operational.modelProxy?.subscriptions[0].sourceHost =
            "user:secret@subscription.example/path"
        XCTAssertThrowsError(
            try ConfigurationBackup.exportData(
                configuration: invalidConfiguration,
                appVersion: "1.9.2"
            )
        )
        let untrustedBackup = try JSONEncoder().encode(
            ConfigurationBackupEnvelope(
                appVersion: "1.9.2",
                configuration: invalidConfiguration
            )
        )
        XCTAssertThrowsError(try ConfigurationBackup.preview(untrustedBackup))
    }

    func testMCPToolsExposeReadOnlyContextAndBillableGenerationContracts() throws {
        let snapshot = AgentReadOnlySnapshot(
            serviceRunning: true,
            baseURL: "http://127.0.0.1:11435/v1",
            availableModels: ["usable"],
            enabledProviders: 1,
            enabledRoutes: 1,
            month: "2026-08",
            requests: 3,
            successfulRequests: 2,
            estimatedCostUSD: 0.1,
            taskContext: "读取当前任务并检查可用模型"
        )
        let listRequest = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let listResponse = LocalAgentProtocols.mcp(requestBody: listRequest, snapshot: snapshot)
        let listRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: listResponse.body) as? [String: Any]
        )
        let listResult = try XCTUnwrap(listRoot["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
        XCTAssertNotNil(toolsByName["get_task_context"])
        XCTAssertNotNil(toolsByName["generate_text"])
        XCTAssertNotNil(toolsByName["generate_image"])
        XCTAssertNotNil(toolsByName["generate_video"])
        XCTAssertNotNil(toolsByName["generate_music"])
        XCTAssertNotNil(toolsByName["generate_speech"])
        XCTAssertNotNil(toolsByName["get_video_task"])
        XCTAssertNotNil(toolsByName["get_music_task"])
        XCTAssertNotNil(toolsByName["create_embeddings"])
        XCTAssertNotNil(toolsByName["rerank_documents"])

        let videoTool = try XCTUnwrap(toolsByName["generate_video"])
        let videoSchema = try XCTUnwrap(videoTool["inputSchema"] as? [String: Any])
        let required = try XCTUnwrap(videoSchema["required"] as? [String])
        XCTAssertTrue(required.contains("model"))
        XCTAssertTrue(required.contains("prompt"))
        XCTAssertTrue(required.contains("confirm_billable"))
        let videoAnnotations = try XCTUnwrap(videoTool["annotations"] as? [String: Any])
        XCTAssertEqual(videoAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(videoAnnotations["idempotentHint"] as? Bool, false)

        let callRequest = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_available_models","arguments":{}}}"#.utf8)
        let callResponse = LocalAgentProtocols.mcp(requestBody: callRequest, snapshot: snapshot)
        let callText = String(decoding: callResponse.body, as: UTF8.self)
        XCTAssertTrue(callText.contains("usable"))
        XCTAssertFalse(callText.contains("quarantined"))

        let taskRequest = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_task_context","arguments":{}}}"#.utf8)
        let taskResponse = LocalAgentProtocols.mcp(requestBody: taskRequest, snapshot: snapshot)
        XCTAssertTrue(String(decoding: taskResponse.body, as: UTF8.self).contains("读取当前任务并检查可用模型"))

        let generationRequest = Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"generate_video","arguments":{"model":"video-model","prompt":"海面日出","duration_seconds":4,"confirm_billable":true}}}"#.utf8)
        let invocation = try XCTUnwrap(
            LocalAgentProtocols.mcpActionInvocation(requestBody: generationRequest)
        )
        XCTAssertEqual(invocation.tool, .generateVideo)
        let invocationArguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocation.argumentsJSON) as? [String: Any]
        )
        XCTAssertEqual(invocationArguments["model"] as? String, "video-model")
        XCTAssertEqual(invocationArguments["prompt"] as? String, "海面日出")
        XCTAssertEqual(invocationArguments["duration_seconds"] as? Int, 4)
        XCTAssertEqual(invocationArguments["confirm_billable"] as? Bool, true)

        let initializeRequest = Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize"}"#.utf8)
        let initializeText = String(
            decoding: LocalAgentProtocols.mcp(
                requestBody: initializeRequest,
                snapshot: snapshot
            ).body,
            as: UTF8.self
        )
        XCTAssertTrue(initializeText.contains(#""version":"1.9.1""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.a2aAgentCard(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.9.1""#))
        XCTAssertTrue(String(
            decoding: LocalAgentProtocols.acpManifest(baseURL: "http://127.0.0.1"),
            as: UTF8.self
        ).contains(#""version":"1.9.1""#))
    }

    func testMCPGenerationArgumentsMapToProtectedGatewayRequests() throws {
        let videoInvocation = MCPActionInvocation(
            tool: .generateVideo,
            argumentsJSON: Data(#"{"model":"video-model","prompt":"海面日出","duration_seconds":4,"size":"720p","confirm_billable":true}"#.utf8)
        )
        let videoRequest = try LocalAgentProtocols.gatewayRequest(for: videoInvocation)
        XCTAssertEqual(videoRequest.method, "POST")
        XCTAssertEqual(videoRequest.path, "/v1/videos/generations")
        let videoBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: videoRequest.body) as? [String: Any]
        )
        XCTAssertEqual(videoBody["model"] as? String, "video-model")
        XCTAssertEqual(videoBody["prompt"] as? String, "海面日出")
        XCTAssertEqual(videoBody["duration"] as? Int, 4)
        XCTAssertNil(videoBody["confirm_billable"])

        let musicInvocation = MCPActionInvocation(
            tool: .generateMusic,
            argumentsJSON: Data(#"{"model":"music-model","prompt":"轻快钢琴曲","lyrics":"你好世界","style":"流行","title":"清晨","duration_seconds":30,"instrumental":false,"confirm_billable":true}"#.utf8)
        )
        let musicRequest = try LocalAgentProtocols.gatewayRequest(for: musicInvocation)
        XCTAssertEqual(musicRequest.method, "POST")
        XCTAssertEqual(musicRequest.path, "/v1/music/generations")
        let musicBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: musicRequest.body) as? [String: Any]
        )
        XCTAssertEqual(musicBody["prompt"] as? String, "轻快钢琴曲")
        XCTAssertEqual(musicBody["lyrics"] as? String, "你好世界")
        XCTAssertEqual(musicBody["style"] as? String, "流行")
        XCTAssertEqual(musicBody["title"] as? String, "清晨")
        XCTAssertEqual(musicBody["duration"] as? Int, 30)
        XCTAssertEqual(musicBody["instrumental"] as? Bool, false)
        XCTAssertNil(musicBody["confirm_billable"])

        let deniedMusicInvocation = MCPActionInvocation(
            tool: .generateMusic,
            argumentsJSON: Data(#"{"model":"music-model","prompt":"钢琴曲","confirm_billable":false}"#.utf8)
        )
        XCTAssertThrowsError(try LocalAgentProtocols.gatewayRequest(for: deniedMusicInvocation)) { error in
            XCTAssertEqual(error as? MCPActionValidationError, .billableConfirmationRequired)
        }

        let deniedInvocation = MCPActionInvocation(
            tool: .generateImage,
            argumentsJSON: Data(#"{"model":"image-model","prompt":"蓝点","confirm_billable":false}"#.utf8)
        )
        XCTAssertThrowsError(try LocalAgentProtocols.gatewayRequest(for: deniedInvocation)) { error in
            XCTAssertEqual(error as? MCPActionValidationError, .billableConfirmationRequired)
        }

        let speechInvocation = MCPActionInvocation(
            tool: .generateSpeech,
            argumentsJSON: Data(#"{"model":"tts-model","input":"你好","voice":"Cherry","confirm_billable":true}"#.utf8)
        )
        let speechRequest = try LocalAgentProtocols.gatewayRequest(for: speechInvocation)
        XCTAssertEqual(speechRequest.path, "/v1/audio/speech")
        let speechBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: speechRequest.body) as? [String: Any]
        )
        XCTAssertEqual(speechBody["voice"] as? String, "Cherry")

        let unsafeTaskInvocation = MCPActionInvocation(
            tool: .getVideoTask,
            argumentsJSON: Data(#"{"model":"video-model","task_id":"task/unsafe"}"#.utf8)
        )
        XCTAssertThrowsError(try LocalAgentProtocols.gatewayRequest(for: unsafeTaskInvocation))

        let taskInvocation = MCPActionInvocation(
            tool: .getVideoTask,
            argumentsJSON: Data(#"{"model":"video-model","task_id":"task-safe_123"}"#.utf8)
        )
        let taskRequest = try LocalAgentProtocols.gatewayRequest(for: taskInvocation)
        XCTAssertEqual(taskRequest.method, "GET")
        XCTAssertEqual(taskRequest.path, "/v1/videos/task-safe_123")
        XCTAssertEqual(taskRequest.queryItems["model"], "video-model")

        let musicTaskInvocation = MCPActionInvocation(
            tool: .getMusicTask,
            argumentsJSON: Data(#"{"model":"music-model","task_id":"music-safe_123"}"#.utf8)
        )
        let musicTaskRequest = try LocalAgentProtocols.gatewayRequest(for: musicTaskInvocation)
        XCTAssertEqual(musicTaskRequest.method, "GET")
        XCTAssertEqual(musicTaskRequest.path, "/v1/music/music-safe_123")
        XCTAssertEqual(musicTaskRequest.queryItems["model"], "music-model")
    }
}
