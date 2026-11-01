@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class StandardUseSimulationTest: XCTestCase {
    override func setUp() async throws {
        try await resetManipulatedWithMouseIfPossible()
        setUpWorkspacesForTests()
        config.automaticallyUnhideMacosHiddenApps = true
        workspaceFocusHold = nil
        for child in macosMinimizedWindowsContainer.children + macosPopupWindowsContainer.children { child.unbindFromParent() }
        _ = collectWindowMovedEvents()
    }

    override func tearDown() async throws {
        try await resetManipulatedWithMouseIfPossible()
    }

    func testWorkspaceHistorySummonAndMovesKeepIntentionalOwnership() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        let writing = Workspace.get(byName: "writing-desk")
        let reading = Workspace.get(byName: "reading-desk")
        XCTAssertTrue(day.monitors[0].setVisibleWorkspace(writing))
        XCTAssertTrue(day.monitors[2].setVisibleWorkspace(reading))
        let first = day.open(in: writing.rootTilingContainer)
        let second = day.open(in: writing.rootTilingContainer)
        let remote = day.open(in: reading.rootTilingContainer)
        try await day.command("focus --window-id \(first.windowId)")
        try await day.command("workspace empty-break")
        XCTAssertNil(globalFocus.windowOrNil, day.context)
        try await day.command("workspace-back-and-forth")
        XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        try await day.command("focus --window-id \(second.windowId)")
        try await day.command("focus-back-and-forth")
        XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        try await day.command("move-node-to-workspace --window-id \(second.windowId) reading-desk")
        XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        XCTAssertTrue(second.nodeWorkspace === reading, day.context)
        try await day.command("move-node-to-workspace --window-id \(second.windowId) --focus-follows-window writing-desk")
        XCTAssertTrue(globalFocus.windowOrNil === second, day.context)
        try await day.command("summon-workspace reading-desk")
        XCTAssertTrue(reading.workspaceMonitorInfo.rect == day.monitors[0].rect, day.context)
        XCTAssertTrue(globalFocus.windowOrNil === remote, day.context)
        try await day.command("move-workspace-to-monitor 3")
        XCTAssertEqual(reading.workspaceMonitorInfo.rect, day.monitors[2].rect, day.context)
        try await day.command("move-workspace-to-monitor 1")
        XCTAssertEqual(reading.workspaceMonitorInfo.rect, day.monitors[0].rect, day.context)
        XCTAssertTrue(globalFocus.windowOrNil === remote, day.context)
        try await day.command("workspace writing-desk")
        XCTAssertTrue(globalFocus.windowOrNil === second, day.context)
        try await day.command("workspace --auto-back-and-forth writing-desk")
        XCTAssertTrue(globalFocus.workspace === reading, day.context)
        day.report("workspace-history-summon-moves")
    }

    func testNestedKeyboardJoinSplitSwapAccordionAndBoundaryRoundTrips() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let first = day.open(in: root)
        let second = day.open(in: root)
        let third = day.open(in: root)
        let dialog = day.open(in: workspace.floatingWindowsContainer)
        try await day.command("focus --window-id \(second.windowId)")
        try await day.command("join-with right")
        let nested = root.layoutDescription
        XCTAssertEqual(nested, .h_tiles([.window(first.windowId), .v_tiles([.window(second.windowId), .window(third.windowId)])]), day.context)
        try await day.command("resize height +80")
        let original = try await day.frames([first, second, third])
        try await day.command("resize height +30")
        try await day.command("resize height -30")
        try await day.assertFrames([first, second, third], equalTo: original)
        try await day.command("swap down")
        XCTAssertTrue(globalFocus.windowOrNil === second, day.context)
        try await day.command("swap up")
        XCTAssertEqual(root.layoutDescription, nested, day.context)
        try await day.assertFrames([first, second, third], equalTo: original)
        try await day.command("layout v_accordion")
        let bounds = workspace.lastAppliedLayoutVirtualRect
        try await day.command("focus --ignore-floating down")
        XCTAssertTrue(globalFocus.windowOrNil === third, day.context)
        XCTAssertEqual(workspace.lastAppliedLayoutVirtualRect, bounds, day.context)
        try await day.command("focus --ignore-floating --boundaries-action fail down", expecting: 2)
        try await day.command("focus --ignore-floating --boundaries-action wrap-around-the-workspace down")
        XCTAssertTrue(globalFocus.windowOrNil === second, day.context)
        try await day.command("layout v_tiles")
        try await day.assertFrames([first, second, third], equalTo: original)
        try await day.command("focus --dfs-index 0")
        // Default DFS treats the centred floating dialog as a temporary tile before the leftmost tile.
        XCTAssertTrue(globalFocus.windowOrNil === dialog, day.context)
        try await day.command("focus --window-id \(first.windowId)")
        XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        try await day.command("focus --ignore-floating --boundaries-action fail dfs-prev", expecting: 2)
        try await day.command("focus --ignore-floating --boundaries-action wrap-around-the-workspace dfs-prev")
        XCTAssertTrue(globalFocus.windowOrNil === third, day.context)
        try await day.command("split horizontal")
        XCTAssertTrue(third.parent is TilingContainer, day.context)
        try await day.command("flatten-workspace-tree")
        XCTAssertEqual(root.layoutDescription, .h_tiles([.window(first.windowId), .window(second.windowId), .window(third.windowId)]), day.context)
        try await day.command("balance-sizes")
        XCTAssertTrue(dialog.isFloating, day.context)
        XCTAssertTrue(collectWindowMovedEvents().isEmpty, day.context)
        day.report("nested-keyboard-roundtrips")
    }

    func testDetectedWindowRulesTargetArrivalAcrossMoveFloatResizeAndCenter() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        let source = globalFocus.workspace
        let destination = Workspace.get(byName: "media-arrivals")
        XCTAssertTrue(day.monitors[1].setVisibleWorkspace(destination))
        let focused = day.open(in: source.rootTilingContainer)
        try await day.command("focus --window-id \(focused.windowId)")
        let original = try await day.frames([focused])
        let media = TestApp(pid: 501, bundleId: "test.media")
        config.onWindowDetected = [WindowDetectedCallback(
            matcher: .legacy(LegacyWindowDetectedCallbackMatcher(appId: "test.media")),
            rawRun: parseCommand("move-node-to-workspace media-arrivals; layout floating; resize width 800; resize height 500; center").cmdOrDie,
        )]
        var arrival: TestWindow!
        try await day.step("register pending media window beside focused editor") {
            arrival = day.open(in: source.rootTilingContainer, app: media)
            arrival.isAwaitingOnWindowDetected = true
        }
        try await day.assertFrames([focused], equalTo: original)
        try await day.step("execute real detection callback pipeline for arrival") {
            await runOnWindowDetected(ifConventional: arrival)
            arrival.isAwaitingOnWindowDetected = false
        }
        XCTAssertTrue(arrival.nodeWorkspace === destination, day.context)
        XCTAssertTrue(arrival.isFloating, day.context)
        XCTAssertTrue(globalFocus.windowOrNil === focused, day.context)
        let frame = try await day.frames([arrival])[0]
        XCTAssertEqual(frame.size, CGSize(width: 800, height: 500), day.context)
        XCTAssertEqual(frame.center, destination.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.center, day.context)
        try await day.assertFrames([focused], equalTo: original)
        // Shell runs the actual per-command refresh, which already consumes/broadcasts move events.
        // Delivery to a subscribed socket needs the live trial; there must be no duplicate pending event.
        XCTAssertTrue(collectWindowMovedEvents().isEmpty, day.context)
        try await day.command("layout --for-next-detected-window floating")
        try await day.step("one-shot floating override applies only to next unrelated arrival") {
            let next = day.open(in: source.rootTilingContainer)
            await runOnWindowDetected(ifConventional: next)
            XCTAssertTrue(next.isFloating, day.context)
            XCTAssertNil(global_layoutForNextDetectedWindow, day.context)
            let after = day.open(in: source.rootTilingContainer)
            await runOnWindowDetected(ifConventional: after)
            XCTAssertTrue(after.parent is TilingContainer, day.context)
        }
        day.report("window-detection-rules")
    }

    func testFocusModeMinimizeNativeFullscreenAndClosuresDoNotLeaveStaleState() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        let workspace = globalFocus.workspace
        let first = day.open(in: workspace.rootTilingContainer)
        let second = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(first.windowId)")
        try await day.command("focus-mode --stay-on-monitor")
        try await day.command("resize height -80")
        try await day.step("minimize focused window during Focus Mode") {
            first.isMacosMinimizedForTest = true
            try await normalizeLayoutReason()
        }
        XCTAssertEqual(FocusMode.shared.windowId, second.windowId, day.context)
        try await day.step("restore and explicitly select minimized window") {
            first.isMacosMinimizedForTest = false
            try await normalizeLayoutReason()
            XCTAssertTrue(first.focusWindow(), day.context)
        }
        XCTAssertEqual(FocusMode.shared.windowId, first.windowId, day.context)
        XCTAssertEqual(first.focusModeHeightAdjustment, -80, day.context)
        try await day.command("macos-native-fullscreen on")
        XCTAssertFalse(FocusMode.shared.isActive, day.context)
        try await day.command("focus-mode", expecting: 2)
        try await day.command("macos-native-fullscreen off")
        try await day.command("focus-mode")
        try await day.command("close --window-id \(second.windowId)")
        XCTAssertEqual(FocusMode.shared.windowId, first.windowId, day.context)
        try await day.command("close")
        XCTAssertFalse(FocusMode.shared.isActive, day.context)
        XCTAssertTrue(globalFocus.workspace === workspace, day.context)
        try await day.command("focus-mode", expecting: 2)
        try await day.command("workspace interval")
        try await day.command("workspace \(workspace.name)")
        XCTAssertNil(globalFocus.windowOrNil, day.context)
        day.report("focus-minimize-fullscreen-close")
    }

    func testMouseReverseTopologyMonitorAndFocusModeInvalidateQueuedEvents() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let first = day.open(in: workspace.rootTilingContainer)
        let second = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(first.windowId)")
        let original = try await day.frames([first, second])
        try await day.step("mouse widens first from immutable baseline") {
            first.setAxFrame(nil, CGSize(width: original[0].width + 60, height: original[0].height))
            try await resizeWithMouse(first)
        }
        try await day.step("mouse returns to baseline and releases") {
            first.setAxFrame(original[0].topLeftCorner, original[0].size)
            try await resizeWithMouse(first)
            try await resetManipulatedWithMouseIfPossible()
        }
        try await day.assertFrames([first, second], equalTo: original)
        try await day.step("begin another gesture then add a third tile") {
            first.setAxFrame(nil, CGSize(width: original[0].width + 60, height: original[0].height))
            try await resizeWithMouse(first)
            _ = day.open(in: workspace.rootTilingContainer)
        }
        let weights = workspace.rootTilingContainer.children.map(\.hWeight)
        try await day.step("old drag notification after topology edit is ignored") {
            first.setAxFrame(nil, CGSize(width: original[0].width + 180, height: original[0].height))
            try await resizeWithMouse(first)
        }
        XCTAssertEqual(workspace.rootTilingContainer.children.map(\.hWeight), weights, day.context)
        try await day.step("release invalidated gesture") { try await resetManipulatedWithMouseIfPossible() }
        try await day.command("balance-sizes")
        let baseline = try await day.frames([first])[0]
        try await day.step("begin gesture before moving whole workspace") {
            first.setAxFrame(nil, CGSize(width: baseline.width + 50, height: baseline.height))
            try await resizeWithMouse(first)
        }
        try await day.command("move-workspace-to-monitor 2")
        let movedWeights = workspace.rootTilingContainer.children.map(\.hWeight)
        try await day.step("queued old-monitor gesture cannot mutate moved layout") {
            first.setAxFrame(nil, CGSize(width: baseline.width + 150, height: baseline.height))
            try await resizeWithMouse(first)
        }
        XCTAssertEqual(workspace.rootTilingContainer.children.map(\.hWeight), movedWeights, day.context)
        try await day.step("release on destination monitor") { try await resetManipulatedWithMouseIfPossible() }
        try await day.command("focus-mode --stay-on-monitor")
        let modeWeights = workspace.rootTilingContainer.children.map(\.hWeight)
        try await day.step("queued resize while Focus Mode is active") {
            let frame = FocusMode.shared.frame(for: first, in: workspace)!
            first.setAxFrame(nil, CGSize(width: frame.width + 120, height: frame.height))
            try await resizeWithMouse(first)
        }
        XCTAssertEqual(workspace.rootTilingContainer.children.map(\.hWeight), modeWeights, day.context)
        try await day.command("focus-mode")
        day.report("mouse-reverse-topology-monitor-focus")
    }

    func testNativeTabRemapDuringMouseGestureRejectsOldEventsAndAllowsFreshGesture() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let browser = day.open(in: workspace.rootTilingContainer)
        _ = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(browser.windowId)")
        let baseline = try await day.frames([browser])[0]
        try await day.step("native browser edge drag") {
            browser.setAxFrame(nil, CGSize(width: baseline.width + 70, height: baseline.height))
            try await resizeWithMouse(browser)
        }
        let resizedWeights = workspace.rootTilingContainer.children.map(\.hWeight)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(browser.windowId, browser.nativeWindowId!)
        try await day.step("native tab changes while logical window has drag state") {
            remapNativeTabWindow(background: browser.nativeWindowId!, frontmost: 9900, mapping: &mapping, window: browser)
            browser.nativeWindowIdForTest = 9900
        }
        try await day.step("old queued notification after native remap") {
            browser.setAxFrame(nil, CGSize(width: baseline.width + 240, height: baseline.height))
            try await resizeWithMouse(browser)
        }
        XCTAssertEqual(workspace.rootTilingContainer.children.map(\.hWeight), resizedWeights, day.context)
        try await day.step("release remapped window") { try await resetManipulatedWithMouseIfPossible() }
        let after = try await day.frames([browser])[0]
        try await day.step("new gesture uses replacement's current frame") {
            browser.setAxFrame(nil, CGSize(width: after.width - 40, height: after.height))
            try await resizeWithMouse(browser)
            try await resetManipulatedWithMouseIfPossible()
        }
        let final = try await day.frames([browser])[0]
        XCTAssertEqual(final.width, after.width - 40, accuracy: 0.001, day.context)
        XCTAssertEqual(mapping.forward[browser.windowId], 9900, day.context)
        day.report("native-remap-mouse")
    }

    func testUnequalPortraitVerticalNegativeDisplaysAndSameCountGeometryRefresh() async throws {
        let displays = standardUseTopology(2)
        let day = LifecycleScenario(monitors: displays)
        config.adaptiveLayout.enabled = .constant(true)
        let spaces = displays.indices.map { Workspace.get(byName: "display-home-\($0)") }
        for (index, workspace) in spaces.enumerated() {
            XCTAssertTrue(displays[index].setVisibleWorkspace(workspace))
            _ = day.open(in: workspace.rootTilingContainer)
            _ = day.open(in: workspace.rootTilingContainer)
        }
        let first = spaces[0].allLeafWindowsRecursive[0]
        try await day.command("focus --window-id \(first.windowId)")
        try await day.command("resize width +50")
        let original = try await day.frames(spaces[0].allLeafWindowsRecursive)
        try await day.command("move-workspace-to-monitor 'Session Display 2'")
        try await day.command("move-workspace-to-monitor 'Session Display 1'")
        try await day.assertFrames(spaces[0].allLeafWindowsRecursive, equalTo: original)
        let changed: [MonitorInfo] = displays.enumerated().map { index, display in
            LifecycleMonitor(
                monitorAppKitNsScreenScreensId: display.monitorAppKitNsScreenScreensId,
                name: display.name,
                rect: display.rect,
                isMain: display.isMain,
                visibleFrame: Rect(topLeftX: display.rect.minX, topLeftY: display.rect.minY + 30, width: display.rect.width, height: display.rect.height - 80 - CGFloat(index * 10)),
            )
        }
        try await day.step("same-count Dock/menu-bar change refreshes all visible rects") {
            monitorInfosForTests = changed
            gcMonitors()
        }
        for (index, workspace) in spaces.enumerated() {
            XCTAssertEqual(workspace.workspaceMonitorInfo.visibleRect, changed[index].visibleRect, day.context)
        }
        try await day.command("focus-mode")
        try await day.step("portrait and upper displays disconnect") { setMonitorInfosForTests([displays.first(where: \.isMain)!]) }
        try await day.step("unequal negative-origin displays reconnect") { setMonitorInfosForTests(displays) }
        try await day.command("focus-mode")
        for (index, workspace) in spaces.enumerated() {
            XCTAssertEqual(workspace.workspaceMonitorInfo.rect, displays[index].rect, day.context)
        }
        try await day.assertFrames(spaces[0].allLeafWindowsRecursive, equalTo: original)
        day.report("varied-display-recovery")
    }

    func testRuntimeAdaptivePolicyGapAndBalanceChangesPreserveOrderAndFloatingFrame() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let first = day.open(in: root)
        let second = day.open(in: root)
        let floating = day.open(in: workspace.floatingWindowsContainer)
        try await day.command("focus --window-id \(first.windowId)")
        let normal = try await day.frames([first, second])
        let floatFrame = try await day.frames([floating])
        try await day.step("enable adaptive policy at runtime") { config.adaptiveLayout.enabled = .constant(true) }
        try await day.command("resize width +50")
        try await day.command("resize width -50")
        try await day.step("change adaptive percentages and both gap axes") {
            config.adaptiveLayout.twoColumnWidthPercent = 80
            config.gaps.inner.horizontal = .constant(18)
            config.gaps.inner.vertical = .constant(12)
        }
        try await day.command("resize smart +40")
        try await day.command("resize smart -40")
        try await day.step("hide one native Space under changed policy") { second.lifeStatus = .invisible }
        XCTAssertEqual(root.tilingFootprint, TilingFootprint(columns: 1, rows: 1), day.context)
        try await day.step("show it again under changed policy") { second.lifeStatus = .alive }
        try await day.command("balance-sizes")
        try await day.step("restore normal policy and original gaps") {
            config.adaptiveLayout.enabled = .constant(false)
            config.gaps.inner.horizontal = .constant(0)
            config.gaps.inner.vertical = .constant(0)
        }
        XCTAssertEqual(root.layoutDescription, .h_tiles([.window(first.windowId), .window(second.windowId)]), day.context)
        try await day.assertFrames([first, second], equalTo: normal)
        try await day.assertFrames([floating], equalTo: floatFrame)
        day.report("runtime-policy-gaps-balance")
    }

    func testFloatTileFloatResizeFullscreenRoundTripsAndExplicitNoOps() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        let workspace = globalFocus.workspace
        let first = day.open(in: workspace.rootTilingContainer)
        let second = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(first.windowId)")
        let original = try await day.frames([first, second])
        try await day.command("resize width +40")
        try await day.command("resize width -40")
        try await day.assertFrames([first, second], equalTo: original)
        try await day.command("fullscreen on")
        try await day.command("focus --fail-if-fullscreen right", expecting: 2)
        XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        try await day.command("fullscreen --fail-if-noop on", expecting: 2)
        try await day.command("fullscreen off")
        try await day.assertFrames([first, second], equalTo: original)
        try await day.command("layout floating")
        try await day.command("resize width 700")
        try await day.command("resize height 500")
        try await day.command("center")
        let floating = try await day.frames([first])[0]
        try await day.command("layout tiling")
        try await day.command("layout floating")
        let restored = try await day.frames([first])[0]
        XCTAssertEqual(restored.size, floating.size, day.context)
        // float->tile->float restores its saved size; location is deliberately not promised by layout floating.
        try await day.command("center")
        try await day.assertFrames([first], equalTo: [floating])
        try await day.command("resize smart +40")
        try await day.command("resize smart -40")
        try await day.assertFrames([first], equalTo: [floating])
        try await day.command("layout --fail-if-noop floating", expecting: 2)
        try await day.command("move-node-to-workspace --fail-if-noop \(workspace.name)", expecting: 2)
        try await day.command("layout tiling")
        try await day.command("center", expecting: 2)
        day.report("float-tile-fullscreen-roundtrips")
    }

    func testWindowChurnAndCloseAllKeepForeignWorkspacesAndNeverReuseIds() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        let workspace = Workspace.get(byName: "churn")
        let foreign = Workspace.get(byName: "retained")
        XCTAssertTrue(day.monitors[0].setVisibleWorkspace(workspace))
        XCTAssertTrue(day.monitors[2].setVisibleWorkspace(foreign))
        let browser = TestApp(pid: 601, bundleId: "test.browser")
        let editor = TestApp(pid: 602, bundleId: "test.editor")
        let retained = (0 ..< 4).map { _ in day.open(in: foreign.rootTilingContainer, app: editor) }
        let anchor = day.open(in: workspace.rootTilingContainer, app: browser)
        try await day.command("focus --window-id \(anchor.windowId)")
        var retired = Set<OpaqueWindowId>()
        for round in 0 ..< 12 {
            var opened: [TestWindow] = []
            try await day.step("open browser/editor work batch \(round)") {
                for index in 0 ..< 4 { opened.append(day.open(in: workspace.rootTilingContainer, app: index % 2 == 0 ? browser : editor)) }
            }
            try await day.command("focus --window-id \(opened[0].windowId)")
            try await day.command("move-node-to-workspace --window-id \(opened[1].windowId) scratch-churn")
            try await day.command("move-node-to-workspace --window-id \(opened[1].windowId) churn")
            try await day.command("close --window-id \(opened[2].windowId)")
            retired.insert(opened[2].windowId)
            try await day.command("close")
            retired.insert(opened[0].windowId)
            XCTAssertTrue(globalFocus.workspace === workspace, day.context)
            try await day.command("focus --window-id \(anchor.windowId)")
            try await day.command("close-all-windows-but-current")
            retired.formUnion(opened.map(\.windowId))
            XCTAssertEqual(workspace.allLeafWindowsRecursive.map(\.windowId), [anchor.windowId], day.context)
            XCTAssertEqual(foreign.allLeafWindowsRecursive.map(\.windowId), retained.map(\.windowId), day.context)
            XCTAssertTrue(retired.allSatisfy { Window.get(byId: $0) == nil }, day.context)
        }
        XCTAssertEqual(Set(day.windows.map(\.windowId)).count, day.windows.count, day.context)
        day.report("window-churn-close-all")
    }

    func testShuffledStandardSessionsAcrossVariedTopologies() async throws {
        for (topology, seed) in [(0, UInt64(0xD440)), (1, 0xE550), (2, 0xF660)] {
            try await resetManipulatedWithMouseIfPossible()
            setUpWorkspacesForTests()
            config.automaticallyUnhideMacosHiddenApps = true
            config.adaptiveLayout.enabled = .constant(true)
            let day = LifecycleScenario(monitors: standardUseTopology(topology), seed: seed)
            let spaces = day.monitors.indices.map { Workspace.get(byName: "random-\(seed)-\($0)") }
            for (index, workspace) in spaces.enumerated() {
                XCTAssertTrue(day.monitors[index].setVisibleWorkspace(workspace))
                _ = day.open(in: workspace.rootTilingContainer)
                _ = day.open(in: workspace.rootTilingContainer)
            }
            var random = LifecycleRandom(seed: seed)
            var actions: [Int] = []
            for _ in 0 ..< 8 {
                var block = Array(0 ..< 10)
                for index in stride(from: block.count - 1, through: 1, by: -1) { block.swapAt(index, random.next(index + 1)) }
                actions += block
            }
            for action in actions {
                let candidates = day.windows.filter { $0.isBound && $0.lifeStatus == .alive }
                let window = candidates[random.next(candidates.count)]
                try await day.command("focus --window-id \(window.windowId)")
                switch action {
                    case 0:
                        if window.isFloating { try await day.command("center") }
                        let before = try await day.frames([window])[0]
                        let width = window.nodeWorkspace!.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.width
                        let shrinkFirst = window.isFloating && before.width + 20 > width
                        // Choose the direction that avoids monitor clamping for the floating round trip.
                        try await day.command(shrinkFirst ? "resize width -20" : "resize width +20")
                        try await day.command(shrinkFirst ? "resize width +20" : "resize width -20")
                        if window.isFloating { try await day.assertFrames([window], equalTo: [before]) }
                    case 1:
                        try await day.command("layout \(window.isFloating ? "tiling" : "floating")")
                    case 2:
                        try await day.command("move-node-to-workspace --focus-follows-window \(spaces[random.next(spaces.count)].name)")
                    case 3:
                        try await day.command("focus-mode --stay-on-monitor")
                        try await day.command("resize height -20")
                        try await day.command("focus-mode")
                    case 4:
                        try await day.command("balance-sizes")
                    case 5:
                        try await day.step("shuffled dialog opening and background close") {
                            let dialog = day.open(in: globalFocus.workspace.floatingWindowsContainer)
                            dialog.closeAxWindow()
                        }
                    case 6:
                        try await day.command("workspace \(spaces[random.next(spaces.count)].name)")
                    case 7:
                        try await day.command("move-workspace-to-monitor '\(day.monitors[random.next(day.monitors.count)].name)'")
                    case 8:
                        try await day.step("shuffled runtime adaptive width policy") {
                            config.adaptiveLayout.twoColumnWidthPercent = random.next(2) == 0 ? 66 : 80
                        }
                    default:
                        if window.isFloating {
                            try await day.command("center")
                        } else {
                            try await day.command("swap --wrap-around dfs-next")
                        }
                }
            }
            XCTAssertEqual(actions.count, 80, day.context)
            day.report("shuffled-varied-sessions")
        }
    }

    func testTileBeforeMonitorWrapAndBoundaryFailuresKeepFocusAndIdentity() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        config.adaptiveLayout.enabled = .constant(true)
        let spaces = ["edge-left", "edge-middle", "edge-right"].map { Workspace.get(byName: $0) }
        for (index, workspace) in spaces.enumerated() { XCTAssertTrue(day.monitors[index].setVisibleWorkspace(workspace)) }
        let leftRoot = spaces[0].rootTilingContainer
        leftRoot.changeOrientation(.v)
        let first = day.open(in: leftRoot)
        let second = day.open(in: leftRoot)
        let moved = day.open(in: leftRoot)
        _ = day.open(in: spaces[1].rootTilingContainer)
        _ = day.open(in: spaces[2].rootTilingContainer)
        _ = day.open(in: spaces[2].rootTilingContainer)
        try await day.command("focus --window-id \(moved.windowId)")
        let tileBefore = "move --boundaries all-monitors-outer-frame --tile-before-monitor right"
        try await day.command(tileBefore)
        XCTAssertTrue(moved.nodeWorkspace === spaces[0], day.context)
        XCTAssertEqual(spaces[0].rootTilingContainer.orientation, .h, day.context)
        try await day.command("resize width +40")
        try await day.command("resize width -40")
        try await day.command(tileBefore)
        XCTAssertTrue(moved.nodeWorkspace === spaces[1], day.context)
        XCTAssertEqual(spaces[0].allLeafWindowsRecursive.map(\.windowId), [first.windowId, second.windowId], day.context)
        try await day.command("move-node-to-monitor --focus-follows-window 3")
        let original = try await day.frames(spaces[2].allLeafWindowsRecursive)
        let originalLayout = spaces[2].rootTilingContainer.layoutDescription
        let wrap = "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors"
        try await day.command("\(wrap) right")
        XCTAssertTrue(moved.nodeWorkspace === spaces[0], day.context)
        XCTAssertTrue(globalFocus.windowOrNil === moved, day.context)
        try await day.command("\(wrap) left")
        XCTAssertTrue(moved.nodeWorkspace === spaces[2], day.context)
        XCTAssertEqual(spaces[2].rootTilingContainer.layoutDescription, originalLayout, day.context)
        try await day.assertFrames(spaces[2].allLeafWindowsRecursive, equalTo: original)
        try await day.command("move --boundaries-action fail right", expecting: 2)
        try await day.command("move --boundaries-action stop right")
        try await day.command("focus --ignore-floating --boundaries all-monitors-outer-frame --boundaries-action fail right", expecting: 2)
        try await day.command("focus --ignore-floating --boundaries all-monitors-outer-frame --boundaries-action stop right")
        XCTAssertTrue(globalFocus.windowOrNil === moved, day.context)
        try await day.command("focus-monitor --wrap-around next")
        XCTAssertTrue(globalFocus.workspace === spaces[0], day.context)
        try await day.command("focus-monitor --wrap-around prev")
        XCTAssertTrue(globalFocus.workspace === spaces[2], day.context)
        try await day.assertFrames(spaces[2].allLeafWindowsRecursive, equalTo: original)
        day.report("tile-before-monitor-wrap-boundaries")
    }
}

private func standardUseTopology(_ kind: Int) -> [MonitorInfo] {
    let rects: [Rect] = switch kind {
        case 0:
            [Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982)]
        case 1:
            [Rect(topLeftX: -1200, topLeftY: 0, width: 1200, height: 1920),
             Rect(topLeftX: 0, topLeftY: 0, width: 2560, height: 1440)]
        default:
            [Rect(topLeftX: -1080, topLeftY: -200, width: 1080, height: 1920),
             Rect(topLeftX: 0, topLeftY: 0, width: 2560, height: 1440),
             Rect(topLeftX: 0, topLeftY: -1080, width: 1920, height: 1080)]
    }
    return rects.enumerated().map { index, rect in
        LifecycleMonitor(monitorAppKitNsScreenScreensId: index + 1, name: "Session Display \(index + 1)", rect: rect, isMain: rect.minX == 0 && rect.minY == 0)
    }
}
