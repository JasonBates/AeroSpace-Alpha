@testable import AppBundle
import Common
import Foundation
import XCTest

private final class AdapterLifetimeProbe {
    var cancelled = false
}

@MainActor
private final class LaunchHarness {
    let process = LaunchProcessIdentity(pid: 42, launchedAt: Date(timeIntervalSince1970: 100))
    var now = ContinuousClock.now
    var processes: [String: [LaunchProcessIdentity]] = [:]
    var baselineIds: Set<OpaqueWindowId> = [1]
    var baselineAction: (@MainActor (String) async throws -> LaunchWindowBaseline)?
    var sleepAction: (@MainActor () async throws -> Void)?
    var failSpawn = false
    var completions: [@MainActor (Bool) -> Void] = []
    var invocations: [[String]] = []
    var environments: [[String: String]] = []
    var cancellations = 0
    var cancellationFactory: (@MainActor () -> (@MainActor () -> Void))?
    var logs: [String] = []
    lazy var placement = makePlacement()

    private func makePlacement() -> LaunchPlacement {
        LaunchPlacement(.init(
            now: { [unowned self] in now },
            sleep: { [unowned self] _ in
                if let sleepAction { try await sleepAction() }
                else { try await Task.sleep(for: .seconds(3600)) }
            },
            runningProcesses: { [unowned self] in processes[$0] ?? [] },
            baseline: { [unowned self] bundle in
                if let baselineAction { return try await baselineAction(bundle) }
                guard (processes[bundle] ?? []).count <= 1 else { throw LaunchWindowBaselineError.unavailable }
                return LaunchWindowBaseline(process: processes[bundle]?.first, windowIds: baselineIds)
            },
            startAdapter: { [unowned self] argv, environment, completion in
                if failSpawn { throw LaunchWindowBaselineError.unavailable }
                invocations.append(argv)
                environments.append(environment)
                completions.append(completion)
                let injectedCancellation = cancellationFactory?()
                return { [weak self] in
                    self?.cancellations += 1
                    injectedCancellation?()
                }
            },
            log: { [unowned self] in logs.append($0) },
        ))
    }

    init() { processes = ["app": [process], "other": [process]] }

    @discardableResult
    func accept(_ bundle: String = "app", workspace: String = "destination") -> ResOrStr<UUID> {
        placement.accept(bundleId: bundle, workspaceName: workspace, timeout: 10, adapter: ["/adapter", "secret"], environment: ["CUSTOM": "value"])
    }

    func observation(
        id: OpaqueWindowId = 2,
        type: AxUiElementWindowType = .window,
        complete: Bool = true,
        stable: Bool = true,
        hidden: Bool = false,
        minimized: Bool? = false,
        fullscreen: Bool? = false,
        registered: Bool = false,
        cached: Bool = false,
        identity: LaunchProcessIdentity? = nil,
    ) -> LaunchWindowObservation {
        LaunchWindowObservation(
            process: identity ?? process,
            windowId: id,
            windowType: type,
            isAliveAndComplete: complete,
            nativeMappingIsStable: stable,
            isHidden: hidden,
            isMinimized: minimized,
            isFullscreen: fullscreen,
            isRegistered: registered,
            restoresClosedWindow: cached,
        )
    }
}

@MainActor
final class LaunchPlacementTest: XCTestCase {
    private var harnesses: [LaunchHarness] = []

    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws {
        for h in harnesses {
            h.placement.cancelAll(reason: "test-teardown")
            for completion in h.completions { completion(false) }
        }
        harnesses = []
    }

    private func harness() -> LaunchHarness {
        let h = LaunchHarness()
        harnesses.append(h)
        return h
    }

    private func awaitCondition(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 10000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Owned task did not reach the injected checkpoint", file: file, line: line)
    }

    private func armed(_ h: LaunchHarness, bundle: String = "app") async -> UUID? {
        h.accept(bundle)
        await awaitCondition { h.placement.candidateToken(bundleId: bundle) != nil }
        return h.placement.candidateToken(bundleId: bundle)
    }

    func testFirstBindingAndFirstGeometryUseCapturedNameAfterFocusChanges() async throws {
        let h = harness()
        let monitors = lifecycleMonitors(2)
        setMonitorInfosForTests(monitors)
        let destination = Workspace.get(byName: "destination")
        XCTAssertTrue(monitors[1].setVisibleWorkspace(destination))
        let token = await armed(h)
        let elsewhere = Workspace.get(byName: "elsewhere")
        XCTAssertTrue(monitors[0].setVisibleWorkspace(elsewhere))
        XCTAssertTrue(elsewhere.focusWorkspace())
        let focusBefore = globalFocus.workspace.name
        let data = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation())
        assertEquals(data.parent.nodeWorkspace?.name, "destination")
        let window = TestWindow.new(id: 2, parent: data.parent, adaptiveWeight: data.adaptiveWeight)
        var workspaceAtFirstWrite: String?
        window.onSetAxFrame = { workspaceAtFirstWrite = window.nodeWorkspace?.name }
        try await destination.layoutWorkspace()
        assertEquals(workspaceAtFirstWrite, "destination")
        assertEquals(window.setAxFrameCallCountForTest, 1)
        let frameReply = try await window.getAxRect(.nonCancellable)
        let firstFrame = try XCTUnwrap(frameReply)
        XCTAssertGreaterThanOrEqual(firstFrame.minX, monitors[1].rect.minX)
        XCTAssertLessThanOrEqual(firstFrame.maxX, monitors[1].rect.maxX)
        assertEquals(globalFocus.workspace.name, focusBefore)
        h.completions[0](true)
        assertEquals(h.placement.pendingCount, 0)
        assertEquals(globalFocus.workspace.name, focusBefore) // Adapter completion adds no focus action.
        assertEquals(h.invocations, [["/adapter", "secret"]])
        assertEquals(h.environments, [["CUSTOM": "value"]])
        XCTAssertFalse(h.logs.joined().contains("secret"))
    }

    func testSavedNameSurvivesWorkspaceCollection() async {
        let h = harness()
        _ = Workspace.get(byName: "destination")
        let token = await armed(h)
        Workspace.garbageCollectUnusedWorkspaces()
        XCTAssertFalse(Workspace.all.contains { $0.name == "destination" })
        let data = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation())
        assertEquals(data.parent.nodeWorkspace?.name, "destination")
    }

    func testCommandCapturesDefaultAndExplicitDestinationBeforeOwnedTasksStart() async {
        let h = harness()
        XCTAssertTrue(Workspace.get(byName: "9").focusWorkspace())
        let args = LaunchWindowCmdArgs(rawArgs: [])
            .with(\.appBundleId, "app")
            .with(\.adapter, .initialized(["/adapter", "secret"]))
        let io = CmdIoImpl.emptyStdinIgnoringOut
        assertEquals(LaunchWindowCommand(args: args).run(.defaultEnv, io, placement: h.placement), .succ)
        assertEquals(io.stdout.count, 1)
        XCTAssertTrue(io.stdout[0].hasPrefix("accepted "))
        XCTAssertTrue(h.invocations.isEmpty) // No AX or adapter wait inside command acceptance.
        XCTAssertTrue(Workspace.get(byName: "elsewhere").focusWorkspace())
        await awaitCondition { h.invocations.count == 1 }
        let token = h.placement.candidateToken(bundleId: "app")
        assertEquals(h.placement.claim(bundleId: "app", token: token, observation: h.observation()), "9")
        h.completions[0](true)
        let explicit = args.with(\.workspaceName, .parse("3").getOrDie())
        assertEquals(LaunchWindowCommand(args: explicit).run(.defaultEnv, io, placement: h.placement), .succ)
        await awaitCondition { h.invocations.count == 2 }
        assertEquals(h.placement.claim(bundleId: "app", token: h.placement.candidateToken(bundleId: "app"), observation: h.observation(id: 3)), "3")
    }

    func testWatchdogExpiresEligibilityWithoutAnyRegistrationOrAdapterCallback() async {
        let h = harness()
        let tick = AwaitableOneTimeBroadcastLatch()
        var sleeping = false
        h.sleepAction = {
            sleeping = true
            try await tick.await(.cancellable)
        }
        _ = await armed(h)
        await awaitCondition { sleeping }
        h.now = h.now.advanced(by: .seconds(10))
        h.sleepAction = nil
        await tick.signalToAll()
        await awaitCondition { h.logs.contains { $0.hasSuffix(" failed-timeout") } }
        XCTAssertTrue(h.accept().failureOrNil?.contains("busy") == true)
        assertEquals(h.cancellations, 1)
        h.completions[0](false)
        assertEquals(h.placement.pendingCount, 0)
    }

    func testSlowBaselineIsOwnedAndOtherAppsCanLaunchBeforeItsDeadline() async {
        let h = harness()
        let gate = AwaitableOneTimeBroadcastLatch()
        var started = false
        h.baselineAction = { bundle in
            if bundle == "app" {
                started = true
                try await gate.await(.nonCancellable)
            }
            return LaunchWindowBaseline(process: h.process, windowIds: [1])
        }
        h.accept()
        await awaitCondition { started }
        _ = await armed(h, bundle: "other")
        assertEquals(h.invocations.count, 1)
        h.now = h.now.advanced(by: .seconds(10))
        XCTAssertNil(h.placement.candidateToken(bundleId: "app"))
        await gate.signalToAll()
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(h.invocations.count, 1) // The expired baseline cannot spawn its adapter later.
    }

    func testExistingTabCacheAndExcludedStatesDoNotConsume() async {
        let h = harness()
        let token = await armed(h)
        let excluded = [
            h.observation(id: 1), // Baseline logical ID, including a native tab remap.
            h.observation(registered: true),
            h.observation(cached: true),
            h.observation(type: .dialog),
            h.observation(type: .popup),
            h.observation(hidden: true),
            h.observation(minimized: true),
            h.observation(fullscreen: true),
            h.observation(minimized: nil),
            h.observation(fullscreen: nil),
            h.observation(complete: false), // Invisible/unconfirmed native tabs and incomplete enumeration.
            h.observation(stable: false), // Mapping changed while an AX read was suspended.
        ]
        for observation in excluded {
            XCTAssertNil(h.placement.claim(bundleId: "app", token: token, observation: observation))
            assertEquals(h.placement.pendingCount, 1)
        }
        assertEquals(h.placement.claim(bundleId: "app", token: token, observation: h.observation()), "destination")
        XCTAssertNil(h.placement.claim(bundleId: "app", token: token, observation: h.observation(id: 3)))
        assertEquals(h.logs.count(where: { $0.hasSuffix(" placed") }), 1)
    }

    func testCacheMembershipBridgeExcludesRestoration() async {
        let h = harness()
        let token = await armed(h)
        let old = TestWindow.new(id: 2, parent: globalFocus.workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        XCTAssertTrue(isClosedWindowCached(old.windowId))
        let data = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation(cached: isClosedWindowCached(old.windowId)))
        assertEquals(data.parent.nodeWorkspace?.name, globalFocus.workspace.name)
        assertEquals(h.placement.candidateToken(bundleId: "app"), token)
    }

    func testExpiryWhileEligibilityReadIsSuspendedFallsBackBeforeInsertion() async {
        let h = harness()
        let token = await armed(h)
        let gate = AwaitableOneTimeBroadcastLatch()
        var readStarted = false
        var result: BindingData?
        let reader = Task.startUnstructured { @MainActor in
            readStarted = true
            try? await gate.await(.nonCancellable)
            result = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation())
        }
        await awaitCondition { readStarted }
        h.now = h.now.advanced(by: .seconds(10)) // Exact deadline is expired.
        await gate.signalToAll()
        await reader.value
        assertEquals(result?.parent.nodeWorkspace?.name, globalFocus.workspace.name)
        assertEquals(h.placement.pendingCount, 1) // The owned adapter must exit before this app can rearm.
        XCTAssertTrue(h.logs.last?.hasSuffix("failed-timeout") == true)
        h.completions[0](true)
        assertEquals(h.placement.pendingCount, 0)
        XCTAssertFalse(h.logs.contains { $0.hasSuffix(" succeeded") })
    }

    func testStaleNativeRegistrationGuardRejectsDisplacedAndMissingMapping() async {
        XCTAssertTrue(isInitialWindowRegistrationCurrent(nativeIdBeforeReads: 10, nativeIdAfterReads: 10))
        XCTAssertFalse(isInitialWindowRegistrationCurrent(nativeIdBeforeReads: nil, nativeIdAfterReads: nil))
        XCTAssertFalse(isInitialWindowRegistrationCurrent(nativeIdBeforeReads: 10, nativeIdAfterReads: nil))
        XCTAssertFalse(isInitialWindowRegistrationCurrent(nativeIdBeforeReads: 10, nativeIdAfterReads: 11))
        let h = harness()
        let token = await armed(h)
        let before: UInt32? = 10
        var after: UInt32? = before
        let gate = AwaitableOneTimeBroadcastLatch()
        var readStarted = false
        var inserted: TestWindow?
        let reader = Task.startUnstructured { @MainActor in
            readStarted = true
            try? await gate.await(.nonCancellable)
            guard isInitialWindowRegistrationCurrent(nativeIdBeforeReads: before, nativeIdAfterReads: after) else { return }
            let data = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation())
            inserted = TestWindow.new(id: 2, parent: data.parent)
        }
        await awaitCondition { readStarted }
        after = nil // Upstream remapped the native tab and displaced this logical placeholder.
        await gate.signalToAll()
        await reader.value
        XCTAssertNil(inserted)
        assertEquals(h.placement.candidateToken(bundleId: "app"), token)
        XCTAssertFalse(h.logs.contains { $0.hasSuffix(" placed") })
    }

    func testBusyOverlapIsPerBundleAndLateCompletionCannotMutateNewRequest() async {
        let h = harness()
        let firstToken = await armed(h)
        XCTAssertFalse(h.accept().isSuccess)
        h.accept("other")
        await awaitCondition { h.invocations.count == 2 }
        assertEquals(h.placement.pendingCount, 2)
        h.completions[0](false)
        assertEquals(h.placement.pendingCount, 1)
        let nextToken = await armed(h)
        XCTAssertNotEqual(firstToken, nextToken)
        h.completions[0](true) // A cancelled generation's late exit.
        XCTAssertNil(h.placement.claim(bundleId: "app", token: firstToken, observation: h.observation()))
        assertEquals(h.placement.candidateToken(bundleId: "app"), nextToken)
        assertEquals(h.placement.pendingCount, 2)
    }

    func testSuccessRequiresPlacementAndAdapterAndRetainsBusyAfterClaim() async {
        let h = harness()
        let token = await armed(h)
        assertEquals(h.placement.claim(bundleId: "app", token: token, observation: h.observation()), "destination")
        XCTAssertFalse(h.accept().isSuccess)
        assertEquals(h.placement.pendingCount, 1)
        h.completions[0](true)
        assertEquals(h.placement.pendingCount, 0)
        XCTAssertTrue(h.logs.last?.hasSuffix(" succeeded") == true)
        h.completions[0](false)
        XCTAssertTrue(h.logs.last?.hasSuffix(" succeeded") == true)
    }

    func testAdapterCanFinishBeforeWindowAndFailAfterClaim() async {
        let h = harness()
        var token = await armed(h)
        h.completions[0](true)
        assertEquals(h.placement.pendingCount, 1)
        assertEquals(h.placement.claim(bundleId: "app", token: token, observation: h.observation()), "destination")
        assertEquals(h.placement.pendingCount, 0)
        token = await armed(h)
        _ = h.placement.claim(bundleId: "app", token: token, observation: h.observation(id: 3))
        h.completions[1](false)
        assertEquals(h.placement.pendingCount, 0)
        XCTAssertTrue(h.logs.last?.hasSuffix(" failed-adapter-exit") == true)
    }

    func testAdapterSpawnFailureAndBaselineFailureNeverReportSuccess() async {
        let h = harness()
        h.failSpawn = true
        h.accept()
        await awaitCondition { h.placement.pendingCount == 0 }
        XCTAssertTrue(h.invocations.isEmpty)
        h.failSpawn = false
        h.baselineAction = { _ in throw LaunchWindowBaselineError.unavailable }
        h.accept()
        await awaitCondition { h.placement.pendingCount == 0 }
        XCTAssertTrue(h.invocations.isEmpty)
        XCTAssertFalse(h.logs.contains { $0.hasSuffix(" succeeded") })
    }

    func testSuccessfulEnumerationWithOmittedPreexistingWindowFailsBeforeAdapter() async {
        XCTAssertTrue(launchWindowDecodedEnumerationIsComplete(rawCount: 0, decodedCount: 0))
        XCTAssertFalse(launchWindowDecodedEnumerationIsComplete(rawCount: nil, decodedCount: 0))
        XCTAssertFalse(launchWindowDecodedEnumerationIsComplete(rawCount: 2, decodedCount: 1)) // Unreadable native ID compactMapped away.
        XCTAssertTrue(launchWindowEnumerationIsComplete(attributeSucceeded: true, enumerated: [], tracked: []))
        XCTAssertTrue(launchWindowEnumerationIsComplete(attributeSucceeded: true, enumerated: [10, 11], tracked: [10, 11, 12]))
        XCTAssertFalse(launchWindowEnumerationIsComplete(attributeSucceeded: false, enumerated: [], tracked: []))
        XCTAssertFalse(launchWindowEnumerationIsComplete(attributeSucceeded: true, enumerated: nil, tracked: []))
        let h = harness()
        h.baselineAction = { _ in
            // AX succeeded, but native 11 was omitted due to mouse-down/subscription failure.
            guard launchWindowEnumerationIsComplete(attributeSucceeded: true, enumerated: [10, 11], tracked: [10]) else {
                throw LaunchWindowBaselineError.unavailable
            }
            return LaunchWindowBaseline(process: h.process, windowIds: [1])
        }
        h.accept()
        await awaitCondition { h.placement.pendingCount == 0 }
        XCTAssertTrue(h.invocations.isEmpty)
        XCTAssertFalse(h.logs.contains { $0.hasSuffix(" armed") })
    }

    func testBaselineMustFinishBeforeSpawnAndCancellationRejectsLateBaseline() async {
        let h = harness()
        let gate = AwaitableOneTimeBroadcastLatch()
        var started = false
        h.baselineAction = { _ in
            started = true
            try await gate.await(.nonCancellable)
            return LaunchWindowBaseline(process: h.process, windowIds: [1])
        }
        h.accept()
        await awaitCondition { started }
        XCTAssertTrue(h.invocations.isEmpty)
        XCTAssertNil(h.placement.candidateToken(bundleId: "app"))
        h.placement.cancelAll(reason: "disabled")
        await gate.signalToAll()
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertTrue(h.invocations.isEmpty)
        assertEquals(h.placement.pendingCount, 0)
    }

    func testColdLaunchPinsProcessAndRejectsPIDReuseOrMultipleInstances() async {
        let h = harness()
        h.processes["app"] = []
        let token = await armed(h)
        h.processes["app"] = [h.process]
        assertEquals(h.placement.claim(bundleId: "app", token: token, observation: h.observation()), "destination")
        h.completions[0](true)
        let next = await armed(h)
        let reused = LaunchProcessIdentity(pid: h.process.pid, launchedAt: Date(timeIntervalSince1970: 200))
        h.processes["app"] = [reused]
        XCTAssertNil(h.placement.claim(bundleId: "app", token: next, observation: h.observation(identity: reused)))
        assertEquals(h.placement.pendingCount, 1)
        h.completions[1](false)
        assertEquals(h.placement.pendingCount, 0)
        h.processes["app"] = [h.process, reused]
        h.accept()
        await awaitCondition { h.placement.pendingCount == 0 }
        assertEquals(h.invocations.count, 2)
    }

    func testProcessDeathDisableAndTimeoutCancelOwnedAdapter() async {
        let h = harness()
        _ = await armed(h)
        h.placement.processTerminated(h.process)
        assertEquals(h.cancellations, 1)
        h.completions[0](false)
        _ = await armed(h)
        h.placement.cancelAll(reason: "disabled")
        assertEquals(h.cancellations, 2)
        h.completions[1](false)
        _ = await armed(h)
        h.now = h.now.advanced(by: .seconds(11))
        XCTAssertNil(h.placement.candidateToken(bundleId: "app"))
        assertEquals(h.cancellations, 3)
    }

    func testTimeoutDrainsOnlyItsAppUntilMatchingAdapterExit() async {
        let h = harness()
        let token = await armed(h)
        h.now = h.now.advanced(by: .seconds(10))
        XCTAssertNil(h.placement.claim(bundleId: "app", token: token, observation: h.observation()))
        XCTAssertFalse(h.accept().isSuccess)
        XCTAssertNil(h.placement.candidateToken(bundleId: "app"))
        _ = await armed(h, bundle: "other")
        assertEquals(h.placement.pendingCount, 2)
        h.completions[0](false)
        assertEquals(h.placement.pendingCount, 1)
        let newToken = await armed(h)
        XCTAssertNotEqual(newToken, token)
        h.completions[0](true)
        assertEquals(h.placement.candidateToken(bundleId: "app"), newToken)
    }

    func testOwnedAdapterIsRetainedWhileDrainingAndReleasedAtExit() async {
        let h = harness()
        var probe: AdapterLifetimeProbe? = AdapterLifetimeProbe()
        weak var weakProbe = probe
        h.cancellationFactory = {
            let owned = probe!
            return { owned.cancelled = true }
        }
        _ = await armed(h)
        probe = nil
        XCTAssertNotNil(weakProbe)
        h.placement.cancelAll(reason: "disabled")
        XCTAssertNotNil(weakProbe)
        assertEquals(weakProbe?.cancelled, true)
        h.placement.cancelAll(reason: "shutdown")
        assertEquals(h.cancellations, 1) // Termination is requested only once per generation.
        h.completions[0](false)
        XCTAssertNil(weakProbe)
        assertEquals(h.placement.pendingCount, 0)
    }

    func testCallbackSeesInitialDestinationAndRetainsMovementPrecedenceOnce() async {
        let h = harness()
        let token = await armed(h)
        config.onWindowDetected = [WindowDetectedCallback(
            matcher: .command(parseCommand("test %{workspace} = destination").cmdOrDie),
            rawRun: parseCommand("move-node-to-workspace after-rule").cmdOrDie,
        )]
        let data = initialWindowBindingData(windowType: .window, fallbackWorkspace: globalFocus.workspace, placement: h.placement, bundleId: "app", token: token, observation: h.observation())
        let window = TestWindow.new(id: 2, parent: data.parent)
        assertEquals(window.nodeWorkspace?.name, "destination")
        await runOnWindowDetected(ifConventional: window)
        assertEquals(window.nodeWorkspace?.name, "after-rule")
        h.completions[0](true)
        assertEquals(window.nodeWorkspace?.name, "after-rule")
        assertEquals(h.logs.count(where: { $0.hasSuffix(" placed") }), 1)
    }
}
