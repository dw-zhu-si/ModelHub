import Foundation
import XCTest
@testable import ModelHubCore

final class ModelProxyFailoverTests: XCTestCase {
    func testLegacyProxyConfigurationDecodesWithAutomaticFailoverDisabled() throws {
        let providerID = UUID()
        let nodeID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee::Node A"
        let data = try JSONSerialization.data(withJSONObject: [
            "enabled": true,
            "kind": "http",
            "host": "127.0.0.1",
            "port": 7897,
            "selections": [],
            "subscriptions": [],
            "nodes": [],
            "assignments": [[
                "providerID": providerID.uuidString,
                "model": "legacy-model",
                "nodeID": nodeID
            ]]
        ])

        let decoded = try JSONDecoder().decode(ModelProxySettings.self, from: data)

        XCTAssertFalse(decoded.automaticFailover.enabled)
        XCTAssertEqual(decoded.automaticFailover.consecutiveFailureThreshold, 2)
        XCTAssertEqual(decoded.assignments.first?.candidateNodeIDs, [])
    }

    func testFailoverRequiresGlobalProxyAndAutomaticFailoverToBeEnabled() {
        let fixture = makeProxyFixture()
        var disabledProxy = fixture.settings
        disabledProxy.enabled = false
        XCTAssertNil(ModelProxyFailoverIndex(settings: disabledProxy).initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))

        var disabledFailover = fixture.settings
        disabledFailover.automaticFailover.enabled = false
        XCTAssertNil(ModelProxyFailoverIndex(settings: disabledFailover).initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
    }

    func testFailoverSwitchesAfterTwoConsecutiveTransientFailuresInDeclaredOrder() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
        XCTAssertEqual(initial.activeNodeID, fixture.nodes[0].id)

        let first = try XCTUnwrap(index.transition(from: initial, event: .transportFailure))
        XCTAssertEqual(first.outcome, .stayed)
        XCTAssertEqual(first.state.activeNodeID, fixture.nodes[0].id)
        XCTAssertEqual(first.state.consecutiveTransientFailures, 1)

        let second = try XCTUnwrap(index.transition(from: first.state, event: .transportFailure))
        XCTAssertEqual(second.outcome, .switched)
        XCTAssertEqual(second.state.activeNodeID, fixture.nodes[1].id)
        XCTAssertEqual(second.state.consecutiveTransientFailures, 0)

        let third = try XCTUnwrap(index.transition(from: second.state, event: .httpStatus(503)))
        let fourth = try XCTUnwrap(index.transition(from: third.state, event: .httpStatus(502)))
        XCTAssertEqual(fourth.outcome, .switched)
        XCTAssertEqual(fourth.state.activeNodeID, fixture.nodes[2].id)
    }

    func testSuccessAndModelOrClientFourHundredsResetFailureCountWithoutSwitching() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
        let onceFailed = try XCTUnwrap(index.transition(from: initial, event: .transportFailure))

        for statusCode in [400, 401, 403, 404, 408, 409, 422, 429] {
            let response = try XCTUnwrap(index.transition(
                from: onceFailed.state,
                event: .httpStatus(statusCode)
            ))
            XCTAssertEqual(response.outcome, .stayed)
            XCTAssertEqual(response.state.activeNodeID, fixture.nodes[0].id)
            XCTAssertEqual(
                response.state.consecutiveTransientFailures,
                0,
                "HTTP \(statusCode) proves the node transported a response and must not count as a node failure"
            )
        }

        let success = try XCTUnwrap(index.transition(from: onceFailed.state, event: .succeeded))
        XCTAssertEqual(success.state.activeNodeID, fixture.nodes[0].id)
        XCTAssertEqual(success.state.consecutiveTransientFailures, 0)
    }

    func testNonTransientFailureResetsPendingTransportStreak() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
        let onceFailed = try XCTUnwrap(index.transition(from: initial, event: .transportFailure))
        XCTAssertEqual(onceFailed.state.consecutiveTransientFailures, 1)

        let reset = try XCTUnwrap(index.transition(
            from: onceFailed.state,
            event: .nonTransientFailure
        ))
        XCTAssertEqual(reset.outcome, .stayed)
        XCTAssertEqual(reset.state.activeNodeID, fixture.nodes[0].id)
        XCTAssertEqual(reset.state.consecutiveTransientFailures, 0)

        let nextFailure = try XCTUnwrap(index.transition(
            from: reset.state,
            event: .transportFailure
        ))
        XCTAssertEqual(nextFailure.outcome, .stayed)
        XCTAssertEqual(nextFailure.state.activeNodeID, fixture.nodes[0].id)
        XCTAssertEqual(nextFailure.state.consecutiveTransientFailures, 1)
    }

    func testSuccessfulEOFFeedbackPreventsNextFailureFromSwitchingEarly() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
        let firstFailure = try XCTUnwrap(index.transition(
            from: initial,
            attemptedNodeID: fixture.nodes[0].id,
            event: .transportFailure
        ))
        let successfulEOF = try XCTUnwrap(index.transition(
            from: firstFailure.state,
            attemptedNodeID: fixture.nodes[0].id,
            event: .succeeded
        ))
        let nextFailure = try XCTUnwrap(index.transition(
            from: successfulEOF.state,
            attemptedNodeID: fixture.nodes[0].id,
            event: .transportFailure
        ))

        XCTAssertEqual(nextFailure.outcome, .stayed)
        XCTAssertEqual(nextFailure.state.activeNodeID, fixture.nodes[0].id)
        XCTAssertEqual(nextFailure.state.consecutiveTransientFailures, 1)
    }

    func testFailoverUsesOnlyExistingAliveNodesFromEnabledSubscriptions() throws {
        let fixture = makeProxyFixture()
        var settings = fixture.settings
        settings.nodes[1].isAlive = false
        settings.subscriptions[0].enabled = false

        let index = ModelProxyFailoverIndex(settings: settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))
        XCTAssertEqual(initial.activeNodeID, fixture.nodes[2].id)

        let first = try XCTUnwrap(index.transition(from: initial, event: .transportFailure))
        let exhausted = try XCTUnwrap(index.transition(from: first.state, event: .transportFailure))
        XCTAssertEqual(exhausted.outcome, .exhausted)
        XCTAssertEqual(exhausted.state.activeNodeID, fixture.nodes[2].id)
        XCTAssertNil(index.endpoint(for: ModelProxyFailoverState(
            providerID: fixture.providerID,
            model: fixture.model,
            activeNodeID: "unconfigured-node",
            consecutiveTransientFailures: 0
        )))
    }

    func testFailoverNeverFallsBackToManualOrDirectEndpointWhenCandidatesAreExhausted() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        var state = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))

        for _ in 0..<6 {
            state = try XCTUnwrap(index.transition(from: state, event: .transportFailure)).state
        }
        let exhausted = try XCTUnwrap(index.transition(from: state, event: .transportFailure))

        XCTAssertEqual(exhausted.outcome, .exhausted)
        XCTAssertEqual(exhausted.state.activeNodeID, fixture.nodes[2].id)
        XCTAssertNotNil(index.endpoint(for: exhausted.state))
    }

    func testLateFeedbackFromSupersededNodeCannotPolluteNewActiveNode() throws {
        let fixture = makeProxyFixture()
        let index = ModelProxyFailoverIndex(settings: fixture.settings)
        let initial = try XCTUnwrap(index.initialState(
            providerID: fixture.providerID,
            model: fixture.model
        ))

        let firstFailure = try XCTUnwrap(index.transition(
            from: initial,
            attemptedNodeID: fixture.nodes[0].id,
            event: .transportFailure
        ))
        let switchedToSecond = try XCTUnwrap(index.transition(
            from: firstFailure.state,
            attemptedNodeID: fixture.nodes[0].id,
            event: .transportFailure
        ))
        XCTAssertEqual(switchedToSecond.state.activeNodeID, fixture.nodes[1].id)

        XCTAssertNil(index.transition(
            from: switchedToSecond.state,
            attemptedNodeID: fixture.nodes[0].id,
            event: .succeeded
        ))
        XCTAssertNil(index.transition(
            from: switchedToSecond.state,
            attemptedNodeID: fixture.nodes[0].id,
            event: .transportFailure
        ))

        let secondNodeFailure = try XCTUnwrap(index.transition(
            from: switchedToSecond.state,
            attemptedNodeID: fixture.nodes[1].id,
            event: .transportFailure
        ))
        XCTAssertEqual(secondNodeFailure.state.activeNodeID, fixture.nodes[1].id)
        XCTAssertEqual(secondNodeFailure.state.consecutiveTransientFailures, 1)

        let switchedToThird = try XCTUnwrap(index.transition(
            from: secondNodeFailure.state,
            attemptedNodeID: fixture.nodes[1].id,
            event: .transportFailure
        ))
        XCTAssertEqual(switchedToThird.state.activeNodeID, fixture.nodes[2].id)
    }

    private func makeProxyFixture() -> (
        settings: ModelProxySettings,
        providerID: UUID,
        model: String,
        nodes: [ProxySubscriptionNode]
    ) {
        let providerID = UUID()
        let model = "exact-model"
        let firstSubscription = ProxySubscription(name: "Primary", sourceHost: "primary.invalid")
        let secondSubscription = ProxySubscription(name: "Secondary", sourceHost: "secondary.invalid")
        let nodes = [
            ProxySubscriptionNode(
                subscriptionID: firstSubscription.id,
                name: "Node A",
                type: "Shadowsocks"
            ),
            ProxySubscriptionNode(
                subscriptionID: firstSubscription.id,
                name: "Node B",
                type: "VLESS"
            ),
            ProxySubscriptionNode(
                subscriptionID: secondSubscription.id,
                name: "Node C",
                type: "Trojan"
            )
        ]
        let assignment = ModelProxyAssignment(
            providerID: providerID,
            model: model,
            nodeID: nodes[0].id,
            candidateNodeIDs: [nodes[1].id, nodes[2].id]
        )
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [firstSubscription, secondSubscription],
            nodes: nodes,
            assignments: [assignment],
            automaticFailover: ModelProxyAutomaticFailoverSettings(
                enabled: true,
                consecutiveFailureThreshold: 2
            )
        )
        return (settings, providerID, model, nodes)
    }
}
