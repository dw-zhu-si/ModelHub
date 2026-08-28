import XCTest
@testable import ModelHub
@testable import ModelHubCore

final class ModelTestingTests: XCTestCase {
    func testStreamingProxyFailoverClassifiesSetupAndMidstreamFailures() {
        XCTAssertEqual(
            StreamingProxyFailoverPolicy.event(for: .nonHTTPResponse),
            .transportFailure
        )
        XCTAssertEqual(
            StreamingProxyFailoverPolicy.event(for: .missingAPIKey),
            .nonTransientFailure
        )
        XCTAssertEqual(
            StreamingProxyFailoverPolicy.transportEvent(isCancelled: false),
            .transportFailure
        )
        XCTAssertNil(StreamingProxyFailoverPolicy.transportEvent(isCancelled: true))
    }

    func testBatchProbeRequiresManagedRuntimeRecoveryForExactNodeAssignment() {
        let providerID = UUID()
        let subscription = ProxySubscription(
            name: "Synthetic",
            sourceHost: "example.invalid"
        )
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "Synthetic Node",
            type: "Direct"
        )
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: providerID,
                model: "assigned-model",
                nodeID: node.id
            )]
        )

        XCTAssertEqual(
            ModelTestProxyPreflightPolicy.decision(
                settings: settings,
                providerID: providerID,
                model: "assigned-model",
                managedRuntimeIsRunning: false
            ),
            .requiresManagedRuntimeRecovery
        )
        XCTAssertEqual(
            ModelTestProxyPreflightPolicy.decision(
                settings: settings,
                providerID: providerID,
                model: "assigned-model",
                managedRuntimeIsRunning: true
            ),
            .ready
        )
    }

    func testBatchProbeDoesNotRequireManagedRuntimeForUnassignedOrDisabledProxy() {
        let providerID = UUID()
        let otherProviderID = UUID()
        let subscription = ProxySubscription(
            name: "Synthetic",
            sourceHost: "example.invalid"
        )
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "Synthetic Node",
            type: "Direct"
        )
        let enabled = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: otherProviderID,
                model: "other-model",
                nodeID: node.id
            )]
        )
        var disabled = enabled
        disabled.enabled = false

        XCTAssertEqual(
            ModelTestProxyPreflightPolicy.decision(
                settings: enabled,
                providerID: providerID,
                model: "direct-model",
                managedRuntimeIsRunning: false
            ),
            .ready
        )
        XCTAssertEqual(
            ModelTestProxyPreflightPolicy.decision(
                settings: disabled,
                providerID: otherProviderID,
                model: "other-model",
                managedRuntimeIsRunning: false
            ),
            .ready
        )
    }

    @MainActor
    func testBatchProbeStopsBeforeAnyModelRequestWhenManagedRuntimeCannotRecover() async throws {
        let provider = ProviderConfig(
            name: "Synthetic Ollama",
            kind: .ollama,
            baseURL: "http://127.0.0.1:65534/v1",
            models: ["assigned-model"],
            endpointURLs: [:]
        )
        let subscription = ProxySubscription(
            name: "Missing Synthetic Subscription",
            sourceHost: "example.invalid"
        )
        let node = ProxySubscriptionNode(
            subscriptionID: subscription.id,
            name: "Synthetic Node",
            type: "Direct"
        )
        let settings = ModelProxySettings(
            enabled: true,
            subscriptions: [subscription],
            nodes: [node],
            assignments: [ModelProxyAssignment(
                providerID: provider.id,
                model: "assigned-model",
                nodeID: node.id
            )]
        )
        let model = AppModel()
        model.configuration = AppConfiguration(
            providers: [provider],
            operational: OperationalSettings(modelProxy: settings)
        )

        model.startTestingAllModels()
        for _ in 0..<100 where model.isTestingModels {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isTestingModels)
        XCTAssertEqual(model.modelTestProgress?.completed, 0)
        XCTAssertFalse(model.modelTestProgress?.isCancelled == true)
        XCTAssertTrue(model.configuration.modelHealth.isEmpty)
        XCTAssertTrue(model.configuration.modelHealthActivities.isEmpty)
        XCTAssertTrue(model.notice?.contains("没有改为直连") == true)
    }

    func testSingleModelProbeDoesNotRefreshCatalogBeforeTestingSavedModel() {
        XCTAssertFalse(
            ModelTestCatalogRefreshPolicy.shouldRefreshCatalog(for: .singleModel)
        )
        XCTAssertTrue(
            ModelTestCatalogRefreshPolicy.shouldRefreshCatalog(for: .batch)
        )
    }

    func testQuarantinedPlanIncludesSelectedPendingAndUnavailableChatModelsAndSkipsNativeModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "image-model", "already-failed", "healthy-model"]
        )
        let health = ModelHealthIndex(records: [
            ModelHealthRecord(
                providerID: provider.id,
                model: "chat-model",
                status: .unknown,
                detail: "已撤销瞬态网络故障造成的隔离，等待重新验证（原错误 -1200）"
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "image-model",
                status: .unknown,
                detail: "已撤销瞬态网络故障造成的隔离，等待重新验证（原错误 -1200）"
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "already-failed",
                status: .unavailable
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "healthy-model",
                status: .available
            )
        ])

        let plan = AppModel.makeQuarantinedModelTestPlan(
            provider: provider,
            health: health,
            selectedModels: ["chat-model", "image-model", "already-failed"]
        )

        XCTAssertEqual(plan.candidates.map(\.model), ["chat-model", "already-failed"])
        XCTAssertEqual(plan.preflightSkipped, 1)
    }

    func testModelPriceRefreshProgressIsBoundedAndReportsCompletion() {
        var progress = ModelPriceRefreshProgress(
            total: 4,
            completed: 1
        )
        XCTAssertEqual(progress.fractionCompleted, 0.25)

        progress.completed = 4
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(
            ModelPriceRefreshProgress(
                total: 0,
                completed: 0
            ).fractionCompleted,
            0
        )
    }

    func testManualTestPlanIncludesQuarantinedChatAndNativeModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "image-model"]
        )
        let health = ModelHealthIndex(records: [
            ModelHealthRecord(
                providerID: provider.id,
                model: "chat-model",
                status: .unavailable
            ),
            ModelHealthRecord(
                providerID: provider.id,
                model: "image-model",
                status: .unavailable
            )
        ])

        let plan = AppModel.makeManualModelTestPlan(
            providers: [provider],
            health: health
        )

        XCTAssertEqual(plan.candidates.map(\.model), ["chat-model", "image-model"])
        XCTAssertEqual(plan.preflightSkipped, 0)
    }

    func testManualTestPlanDeduplicatesModelsWithoutFilteringHealthyCandidates() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["chat-model", "chat-model"]
        )

        let plan = AppModel.makeManualModelTestPlan(
            providers: [provider],
            health: ModelHealthIndex(records: [])
        )

        XCTAssertEqual(plan.candidates.map(\.model), ["chat-model"])
        XCTAssertEqual(plan.preflightSkipped, 0)
    }

    func testManualTestPlanUsesChatModelAsProviderCanaryBeforeNativeModels() {
        let provider = ProviderConfig(
            name: "测试供应商",
            kind: .unifiedCompatible,
            baseURL: "https://example.com/v1",
            models: ["image-model", "chat-model", "video-model"]
        )

        let plan = AppModel.makeManualModelTestPlan(
            providers: [provider],
            health: ModelHealthIndex(records: [])
        )

        XCTAssertEqual(
            plan.candidates.map(\.model),
            ["chat-model", "image-model", "video-model"]
        )
    }

    func testProviderProbeCircuitOpensAfterRetriedCanaryTransportFailure() {
        let providerID = UUID()
        var circuit = ModelTestProviderCircuitBreaker()

        XCTAssertTrue(
            circuit.observe(
                providerID: providerID,
                wasCanary: true,
                transientNetworkFailures: [true]
            )
        )
        XCTAssertTrue(circuit.shouldSkip(providerID: providerID))
    }

    func testProviderProbeCircuitDoesNotOpenForModelSpecificOrMixedFailures() {
        let providerID = UUID()
        var circuit = ModelTestProviderCircuitBreaker()

        XCTAssertFalse(
            circuit.observe(
                providerID: providerID,
                wasCanary: true,
                transientNetworkFailures: [false]
            )
        )
        XCTAssertFalse(
            circuit.observe(
                providerID: providerID,
                wasCanary: false,
                transientNetworkFailures: [true, false, true]
            )
        )
        XCTAssertFalse(circuit.shouldSkip(providerID: providerID))
    }

    func testProviderProbeCircuitRequiresRepeatedTransientBatchesAfterSuccessfulCanary() {
        let providerID = UUID()
        var circuit = ModelTestProviderCircuitBreaker()

        XCTAssertFalse(
            circuit.observe(
                providerID: providerID,
                wasCanary: true,
                transientNetworkFailures: [false]
            )
        )
        XCTAssertFalse(
            circuit.observe(
                providerID: providerID,
                wasCanary: false,
                transientNetworkFailures: [true, true, true]
            )
        )
        XCTAssertTrue(
            circuit.observe(
                providerID: providerID,
                wasCanary: false,
                transientNetworkFailures: [true, true, true]
            )
        )
        XCTAssertTrue(circuit.shouldSkip(providerID: providerID))
    }

    func testLatestProviderProbeCircuitIssueUsesTheNewestRelevantRun() {
        let providerID = UUID()
        let otherProviderID = UUID()
        let olderCircuit = ModelHealthActivity(
            kind: .probe,
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 110),
            circuitOpenedProviderIDs: [providerID],
            circuitSkipped: 20
        )
        let newerSuccessfulRun = ModelHealthActivity(
            kind: .probe,
            startedAt: Date(timeIntervalSince1970: 200),
            completedAt: Date(timeIntervalSince1970: 210),
            providerID: providerID,
            available: 1
        )
        let unrelatedCircuit = ModelHealthActivity(
            kind: .probe,
            startedAt: Date(timeIntervalSince1970: 300),
            completedAt: Date(timeIntervalSince1970: 310),
            providerID: otherProviderID,
            circuitOpenedProviderIDs: [otherProviderID],
            circuitSkipped: 5
        )

        XCTAssertNil(ModelTestCircuitDiagnostics.latestBlockingActivity(
            providerID: providerID,
            activities: [unrelatedCircuit, newerSuccessfulRun, olderCircuit]
        ))
    }

    func testLatestProviderProbeCircuitIssueRecognizesGlobalRunThatSkippedProvider() throws {
        let providerID = UUID()
        let activity = ModelHealthActivity(
            kind: .probe,
            startedAt: Date(timeIntervalSince1970: 200),
            completedAt: Date(timeIntervalSince1970: 210),
            transientFailures: 1,
            circuitOpenedProviderIDs: [providerID],
            circuitSkipped: 284
        )

        let blocker = try XCTUnwrap(
            ModelTestCircuitDiagnostics.latestBlockingActivity(
                providerID: providerID,
                activities: [activity]
            )
        )

        XCTAssertEqual(blocker.id, activity.id)
        XCTAssertEqual(blocker.transientFailures, 1)
    }

    func testTransientNetworkProbePreservesLastKnownAvailableHealth() {
        let providerID = UUID()
        let previous = ModelHealthRecord(
            providerID: providerID,
            model: "stable-model",
            status: .available,
            statusCode: 200,
            detail: "HTTP 200"
        )
        let failedProbe = ModelProbeResult(
            providerID: providerID,
            model: "stable-model",
            status: .unavailable,
            detail: "网络错误（-1200）",
            transientNetworkFailure: true
        )

        XCTAssertTrue(
            ModelTestHealthUpdatePolicy.shouldPreserve(
                existing: previous,
                after: failedProbe
            )
        )
        XCTAssertFalse(
            ModelTestHealthUpdatePolicy.shouldPreserve(
                existing: previous,
                after: ModelProbeResult(
                    providerID: providerID,
                    model: "stable-model",
                    status: .unavailable,
                    statusCode: 403,
                    detail: "HTTP 403"
                )
            )
        )
    }

    func testDeferredNativeProbePreservesExistingVerifiedHealth() {
        let providerID = UUID()
        let previous = ModelHealthRecord(
            providerID: providerID,
            model: "verified-image",
            status: .available,
            statusCode: 200,
            detail: "原生图像生成验证成功"
        )
        let deferred = ModelProbeResult(
            providerID: providerID,
            model: "verified-image",
            status: .unknown,
            detail: "图像生成等待显式原生验证",
            deferredNativeProbe: true
        )

        XCTAssertTrue(
            ModelTestHealthUpdatePolicy.shouldPreserve(
                existing: previous,
                after: deferred
            )
        )
        XCTAssertFalse(
            ModelTestHealthUpdatePolicy.shouldPreserve(
                existing: nil,
                after: deferred
            )
        )
    }

    func testModelTestRunAccumulatorProducesStructuredRetryAndCircuitSummary() {
        let providerID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)
        var accumulator = ModelTestRunAccumulator(
            total: 4,
            providerID: providerID,
            startedAt: startedAt
        )
        accumulator.observe(
            ModelProbeResult(
                providerID: providerID,
                model: "preserved",
                status: .unavailable,
                detail: "网络错误（-1200）",
                transientNetworkFailure: true,
                attemptCount: 2
            ),
            preservedAvailable: true
        )
        accumulator.observe(
            ModelProbeResult(
                providerID: providerID,
                model: "available",
                status: .available,
                statusCode: 200,
                detail: "HTTP 200",
                attemptCount: 1
            ),
            preservedAvailable: false
        )
        accumulator.observeCircuitOpened(providerID: providerID, skipped: 2)

        let activity = accumulator.activity(
            completedAt: startedAt.addingTimeInterval(5),
            cancelled: false
        )

        XCTAssertEqual(activity.kind, .probe)
        XCTAssertEqual(activity.total, 4)
        XCTAssertEqual(activity.completed, 4)
        XCTAssertEqual(activity.available, 1)
        XCTAssertEqual(activity.preservedAvailable, 1)
        XCTAssertEqual(activity.transientFailures, 1)
        XCTAssertEqual(activity.retryAttempts, 1)
        XCTAssertEqual(activity.circuitSkipped, 2)
        XCTAssertEqual(activity.circuitOpenedProviderIDs, [providerID])
        XCTAssertFalse(activity.cancelled)
    }
}
