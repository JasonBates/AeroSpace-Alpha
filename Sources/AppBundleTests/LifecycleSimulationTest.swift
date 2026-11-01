@testable import AppBundle
import AppKit
import Common
import XCTest

/// These scenarios run the production model/commands against synthetic windows, never a running MacApp.
/// AX enumeration, notification ordering, close broadcasts and native activation still need the live trial.
@MainActor
final class LifecycleSimulationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.automaticallyUnhideMacosHiddenApps = true // Avoid consulting a real NSRunningApplication.
        workspaceFocusHold = nil
        for child in macosMinimizedWindowsContainer.children + macosPopupWindowsContainer.children { child.unbindFromParent() }
        _ = collectWindowMovedEvents()
    }

    func testBrowserWorkdayAcrossThreeMonitorsKeepsWorkspaceOnClose() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        let browser = TestApp(pid: 101, bundleId: "test.browser")
        let workspaces = ["reading", "writing", "reference"].map { Workspace.get(byName: $0) }
        var windows: [TestWindow] = []
        for (index, workspace) in workspaces.enumerated() {
            try await day.step("open browser pair on monitor \(index)") {
                XCTAssertTrue(day.monitors[index].setVisibleWorkspace(workspace), day.context)
                windows.append(day.open(in: workspace.rootTilingContainer, app: browser))
                windows.append(day.open(in: workspace.rootTilingContainer, app: browser))
            }
        }
        for index in 0 ..< 3 {
            let workspace = workspaces[index]
            let focused = windows[index * 2]
            let background = windows[index * 2 + 1]
            try await day.command("focus --window-id \(focused.windowId)")
            try await day.command("resize width +60")
            try await day.command("resize width -20")
            try await day.step("close background browser on \(workspace.name)") {
                XCTAssertNil(workspaceFocusHold(forLeaving: background), day.context)
                background.closeAxWindow()
                XCTAssertTrue(globalFocus.windowOrNil === focused, day.context)
            }
            let now = Date(timeIntervalSince1970: 100)
            let hold = workspaceFocusHold(forLeaving: focused, now: now)
            try await day.step("close last local browser on \(workspace.name)") {
                focused.closeAxWindow()
                XCTAssertTrue(globalFocus.workspace === workspace, day.context)
                XCTAssertNil(globalFocus.windowOrNil, day.context)
                let remote = windows.first { $0.isBound && $0.nodeWorkspace !== workspace }
                if let remote {
                    XCTAssertTrue(isPulledOffHeldWorkspace(remote, hold: hold, now: now.addingTimeInterval(0.1)), day.context)
                    XCTAssertFalse(canRemapNativeTabWindow(source: focused, destination: remote), day.context)
                }
                XCTAssertTrue(hasFocusSettledOnHeldWorkspace(nil, hold: hold, aeroSpaceIsFrontmost: true), day.context)
            }
            try await day.step("reopen browser with a new logical identity") {
                let reopened = day.open(in: workspace.rootTilingContainer, app: browser)
                XCTAssertNotEqual(reopened.windowId, focused.windowId, day.context)
                XCTAssertTrue(reopened.focusWindow(), day.context)
            }
            try await day.command("workspace \(workspaces[(index + 1) % 3].name)")
            XCTAssertFalse(isPulledOffHeldWorkspace(globalFocus.windowOrNil!, hold: hold, now: now), day.context)
        }
        XCTAssertNil(nativeTabRemapCandidate(previous: [100: .alive], current: [200: .alive], isMouseButtonDown: false))
        day.report("browser-three-monitors")
    }

    func testInterleavedAppsAndFloatingDialogStayIndependent() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        let workspace = globalFocus.workspace
        let browserApp = TestApp(pid: 201, bundleId: "test.browser")
        let editorApp = TestApp(pid: 202, bundleId: "test.editor")
        let browser = day.open(in: workspace.rootTilingContainer, app: browserApp)
        let editor = day.open(in: workspace.rootTilingContainer, app: editorApp)
        try await day.command("focus --window-id \(browser.windowId)")
        var dialog: TestWindow!
        try await day.step("open editor dialog over browser") {
            dialog = day.open(in: workspace.floatingWindowsContainer, app: editorApp)
            XCTAssertTrue(dialog.focusWindow(), day.context)
            dialog.nativeFocus()
            XCTAssertTrue(appForTests === editorApp, day.context)
            XCTAssertTrue(editorApp.focusedWindow === dialog, day.context)
            XCTAssertFalse(canRemapNativeTabWindow(source: browser, destination: dialog), day.context)
            XCTAssertFalse(canRemapNativeTabWindow(source: dialog, destination: editor), day.context)
        }
        try await day.command("resize width +70")
        try await day.command("resize height -40")
        try await day.command("center")
        try await day.step("close dialog; browser and editor survive") {
            XCTAssertNotNil(workspaceFocusHold(forLeaving: dialog), day.context)
            dialog.closeAxWindow()
            XCTAssertTrue(browser.isBound && editor.isBound, day.context)
            XCTAssertTrue(globalFocus.workspace === workspace, day.context)
            XCTAssertTrue(collectWindowMovedEvents().isEmpty, day.context)
        }
        try await day.command("focus --window-id \(editor.windowId)")
        try await day.step("background browser closes, editor remains focused") {
            XCTAssertNil(workspaceFocusHold(forLeaving: browser), day.context)
            browser.closeAxWindow()
            XCTAssertTrue(globalFocus.windowOrNil === editor, day.context)
        }
        day.report("interleaved-apps-dialog")
    }

    func testNativeFullscreenNestedUnequalLayoutRestoresAndHandlesEdits() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        config.adaptiveLayout.enabled = .constant(true)
        config.enableNormalizationFlattenContainers = true
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let left = day.open(in: root)
        let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 2)
        let top = day.open(in: stack)
        let bottom = day.open(in: stack)
        try await day.step("settle unequal nested layout") {
            XCTAssertTrue(top.focusWindow(), day.context)
        }
        try await day.command("resize height +100")
        try await day.command("resize width +80")
        let original = try await day.frames([left, top, bottom])
        let originalLayout = root.layoutDescription
        try await day.command("macos-native-fullscreen on")
        XCTAssertTrue(top.parent === workspace.macOsNativeFullscreenWindowsContainer, day.context)
        try await day.step("normalize while fullscreen") { workspace.normalizeContainers() }
        try await day.command("macos-native-fullscreen off")
        XCTAssertEqual(root.layoutDescription, originalLayout, day.context)
        try await day.assertFrames([left, top, bottom], equalTo: original)

        try await day.command("macos-native-fullscreen on")
        try await day.step("create and close unrelated floating dialog while fullscreen") {
            let dialog = day.open(in: workspace.floatingWindowsContainer)
            dialog.closeAxWindow()
            workspace.normalizeContainers()
        }
        try await day.command("macos-native-fullscreen off")
        XCTAssertEqual(root.layoutDescription, originalLayout, day.context)
        try await day.assertFrames([left, top, bottom], equalTo: original)

        try await day.command("macos-native-fullscreen on")
        try await day.command("move-node-to-workspace --window-id \(bottom.windowId) changed")
        try await day.step("close left neighbour and add another tiled window") {
            left.closeAxWindow()
            _ = day.open(in: root)
            workspace.normalizeContainers()
        }
        try await day.command("macos-native-fullscreen off")
        XCTAssertTrue(top.nodeWorkspace === workspace, day.context)
        XCTAssertTrue(top.parent is TilingContainer, day.context)
        XCTAssertEqual(bottom.nodeWorkspace?.name, "changed", day.context)
        XCTAssertFalse(left.isBound, day.context)
        day.report("native-fullscreen-nested")
    }

    func testFocusModeWorkdayStageAndStayPreserveTilingAndAdjustments() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = Workspace.get(byName: "focus-work")
        XCTAssertTrue(day.monitors[0].setVisibleWorkspace(workspace))
        let root = workspace.rootTilingContainer
        let browser = TestApp(pid: 301, bundleId: "test.browser")
        let first = day.open(in: root, app: browser)
        let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 2)
        let second = day.open(in: stack, app: browser)
        _ = day.open(in: stack)
        try await day.command("focus --window-id \(first.windowId)")
        let originalLayout = root.layoutDescription
        let weights = root.children.map(\.hWeight)
        let original = try await day.frames([first, second])
        for stay in [false, true] {
            try await day.command(stay ? "focus-mode --stay-on-monitor" : "focus-mode")
            XCTAssertEqual(FocusMode.shared.baseGeometry(for: workspace).monitor.rect, day.monitors[stay ? 0 : 1].rect, day.context)
            try await day.command("resize width +100")
            try await day.command("resize width -40")
            try await day.command("resize height -100")
            try await day.command("resize height +30")
            let widthAdjustment = first.singleWindowWidthAdjustment
            let heightAdjustment = first.focusModeHeightAdjustment
            try await day.command("focus --window-id \(second.windowId)")
            XCTAssertEqual(FocusMode.shared.windowId, second.windowId, day.context)
            XCTAssertEqual(second.singleWindowWidthAdjustment, 0, day.context)
            try await day.command("focus --window-id \(first.windowId)")
            XCTAssertEqual(first.singleWindowWidthAdjustment, widthAdjustment, day.context)
            XCTAssertEqual(first.focusModeHeightAdjustment, heightAdjustment, day.context)
            try await day.step("create and close a background window during Focus Mode") {
                let temporary = day.open(in: workspace.floatingWindowsContainer)
                temporary.closeAxWindow()
            }
            XCTAssertEqual(root.children.map(\.hWeight), weights, day.context)
            try await day.command("workspace pause")
            XCTAssertFalse(FocusMode.shared.isActive, day.context)
            try await day.command("workspace focus-work")
            try await day.command("focus --window-id \(first.windowId)")
            try await day.assertFrames([first, second], equalTo: original)
            try await day.command(stay ? "focus-mode --stay-on-monitor" : "focus-mode")
            XCTAssertEqual(first.singleWindowWidthAdjustment, widthAdjustment, day.context)
            try await day.command("focus-mode")
            XCTAssertFalse(FocusMode.shared.isActive, day.context)
            XCTAssertEqual(root.layoutDescription, originalLayout, day.context)
        }
        day.report("focus-mode-stage-stay")
    }

    func testTiledFloatingMovesResizeMinimaAndBalanceKeepIdentity() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let window = day.open(in: workspace.rootTilingContainer)
        _ = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(window.windowId)")
        for command in ["resize smart +80", "resize width -40", "resize width +30", "resize smart -20"] {
            try await day.command(command)
        }
        try await day.command("move-node-to-monitor --focus-follows-window 3")
        XCTAssertEqual(window.nodeMonitorInfo?.rect, day.monitors[2].rect, day.context)
        try await day.command("move-node-to-workspace --focus-follows-window travel")
        XCTAssertEqual(window.nodeWorkspace?.name, "travel", day.context)
        try await day.command("layout floating")
        try await day.command("move-node-to-monitor --focus-follows-window 2")
        XCTAssertTrue(window.isFloating, day.context)
        XCTAssertEqual(window.nodeMonitorInfo?.rect, day.monitors[1].rect, day.context)
        try await day.command("center")
        for command in ["resize smart +100", "resize smart -60", "resize width +70", "resize width -30", "resize height +50", "resize height -20"] {
            try await day.command(command)
            let read = try await window.getAxRect(.nonCancellable)
            let frame = try XCTUnwrap(read)
            let bounds = window.nodeWorkspace!.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.001, day.context)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.001, day.context)
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.001, day.context)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.001, day.context)
        }
        try await day.command("layout tiling")
        try await day.step("add minimum-constrained neighbour") {
            _ = day.open(in: window.nodeWorkspace!.rootTilingContainer)
            window.appMinimumSizeForTest = CGSize(width: 700, height: 0)
        }
        try await day.command("resize width -500")
        try await day.step("confirm app's refused frame") {
            try await window.confirmObservedMinimumSize(requested: XCTUnwrap(window.lastAppliedLayoutPhysicalRect).size)
        }
        XCTAssertEqual(window.observedMinimumSize.width, 700, day.context)
        try await day.command("resize width -100")
        let constrained = try await window.getAxRect(.nonCancellable)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(constrained).width, 700, day.context)
        window.appMinimumSizeForTest = nil
        try await day.command("balance-sizes")
        XCTAssertEqual(window.observedMinimumSize, ObservedMinimumSize(), day.context)
        XCTAssertEqual(window.singleWindowWidthAdjustment, 0, day.context)
        XCTAssertTrue(Window.get(byId: window.windowId) === window, day.context)
        day.report("tiled-floating-moves-minima")
    }

    func testRepeatedInvisiblePlaceholdersReclaimSpaceAndRestoreWithoutDrift() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 2)
        let top = day.open(in: stack)
        let bottom = day.open(in: stack)
        let right = day.open(in: root)
        try await day.command("focus --window-id \(right.windowId)")
        try await day.command("resize width -100")
        try await day.command("resize --window-id \(top.windowId) height +80")
        let original = try await day.frames([top, bottom, right])
        let order = root.layoutDescription
        for cycle in 0 ..< 16 {
            let writes = bottom.setAxFrameCallCountForTest
            let weight = bottom.getWeight(.v)
            try await day.step("invisible native Space, cycle \(cycle)") {
                bottom.lifeStatus = .invisible
            }
            XCTAssertEqual(bottom.setAxFrameCallCountForTest, writes, day.context)
            XCTAssertEqual(bottom.getWeight(.v), weight, day.context)
            XCTAssertTrue(bottom.parent === stack, day.context)
            XCTAssertEqual(stack.tilingFootprint, TilingFootprint(columns: 1, rows: 1), day.context)
            let read = try await top.getAxRect(.nonCancellable)
            let expanded = try XCTUnwrap(read)
            XCTAssertGreaterThan(expanded.height, original[0].height, day.context)
            try await day.command("focus --window-id \(bottom.windowId)")
            XCTAssertEqual(root.layoutDescription, order, day.context)
            XCTAssertNil(FocusMode.shared.frame(for: bottom, in: workspace), day.context)
            try await day.step("native Space returns, cycle \(cycle)") { bottom.lifeStatus = .alive }
            try await day.assertFrames([top, bottom, right], equalTo: original)
            XCTAssertGreaterThan(bottom.setAxFrameCallCountForTest, writes, day.context)
            try await day.command("focus --window-id \(right.windowId)")
        }
        day.report("invisible-placeholders")
    }

    func testMinimizeRestoreUsesProductionNormalizationAndMoveEvents() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        let workspace = globalFocus.workspace
        let first = day.open(in: workspace.rootTilingContainer)
        let second = day.open(in: workspace.rootTilingContainer)
        try await day.command("focus --window-id \(first.windowId)")
        _ = collectWindowMovedEvents()
        for cycle in 0 ..< 4 {
            try await day.step("minimize through normalization \(cycle)") {
                second.isMacosMinimizedForTest = true
                try await normalizeLayoutReason()
            }
            XCTAssertTrue(second.parent === macosMinimizedWindowsContainer, day.context)
            let minimized = collectWindowMovedEvents()
            XCTAssertEqual(minimized.count, 1, day.context)
            XCTAssertTrue(eventJson(minimized[0]).contains("\"windowId\":\(second.windowId)"), day.context)
            XCTAssertFalse(eventJson(minimized[0]).contains("\"workspace\":"), day.context)
            try await day.step("restore through normalization \(cycle)") {
                second.isMacosMinimizedForTest = false
                try await normalizeLayoutReason()
            }
            XCTAssertTrue(second.nodeWorkspace === workspace, day.context)
            let restored = collectWindowMovedEvents()
            XCTAssertEqual(restored.count, 1, day.context)
            XCTAssertFalse(eventJson(restored[0]).contains("prevWorkspace"), day.context)
            XCTAssertTrue(globalFocus.windowOrNil === first, day.context)
        }
        day.report("minimize-restore-events")
    }

    func testNativeTabRemapsDuringFocusResizeDiscardOldMinimumReply() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(2))
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let browser = day.open(in: workspace.rootTilingContainer)
        let neighbour = day.open(in: workspace.rootTilingContainer)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(browser.windowId, browser.nativeWindowId!)
        mapping.put(neighbour.windowId, neighbour.nativeWindowId!)
        try await day.command("focus --window-id \(browser.windowId)")
        try await day.command("focus-mode --stay-on-monitor")
        try await day.command("resize width +100")
        try await day.command("resize height -80")
        let placement = workspace.rootTilingContainer.layoutDescription
        let weights = workspace.rootTilingContainer.children.map(\.hWeight)
        _ = collectWindowMovedEvents()
        for cycle in 0 ..< 8 {
            let old = browser.nativeWindowId!
            let replacement = UInt32(5000 + cycle)
            let requested = try XCTUnwrap(browser.lastAppliedLayoutPhysicalRect).size
            browser.appMinimumSizeForTest = CGSize(width: requested.width + 100, height: requested.height + 50)
            browser.setAxFrame(nil, browser.appMinimumSizeForTest)
            browser.onGetAxSize = {
                XCTAssertEqual(remapNativeTabWindow(background: old, frontmost: replacement, mapping: &mapping, window: browser), browser.windowId)
                browser.nativeWindowIdForTest = replacement
                browser.appMinimumSizeForTest = nil
            }
            try await day.step("old AX minimum reply arrives after tab remap \(cycle)") {
                try await browser.confirmObservedMinimumSize(requested: requested)
            }
            XCTAssertEqual(browser.observedMinimumSize, ObservedMinimumSize(), day.context)
            XCTAssertEqual(mapping.forward[browser.windowId], replacement, day.context)
            XCTAssertNil(mapping.backward[old], day.context)
            XCTAssertEqual(workspace.rootTilingContainer.layoutDescription, placement, day.context)
            XCTAssertEqual(workspace.rootTilingContainer.children.map(\.hWeight), weights, day.context)
            XCTAssertEqual(browser.singleWindowWidthAdjustment, 100, day.context)
            XCTAssertEqual(browser.focusModeHeightAdjustment, -80, day.context)
            XCTAssertEqual(FocusMode.shared.windowId, browser.windowId, day.context)
            XCTAssertNil(workspaceFocusHold, day.context)
            XCTAssertTrue(collectWindowMovedEvents().isEmpty, day.context)
        }
        try await day.command("focus-mode")
        XCTAssertNil(nativeTabRemapCandidate(previous: [1: .alive, 2: .alive], current: [1: .invisible, 2: .invisible, 3: .alive, 4: .alive], isMouseButtonDown: false))
        XCTAssertNil(nativeTabRemapCandidate(previous: [1: .alive], current: [2: .alive], isMouseButtonDown: false))
        XCTAssertFalse(canRemapNativeTabWindow(source: browser, destination: neighbour))
        day.report("native-remap-minimum-replies")
    }

    func testMonitorBlinkDisconnectReconnectDuringFocusModePreservesHomes() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(3))
        config.adaptiveLayout.enabled = .constant(true)
        let spaces = ["left-home", "stage-home", "right-home"].map { Workspace.get(byName: $0) }
        for (index, workspace) in spaces.enumerated() {
            XCTAssertTrue(day.monitors[index].setVisibleWorkspace(workspace))
            _ = day.open(in: workspace.rootTilingContainer)
            _ = day.open(in: workspace.rootTilingContainer)
        }
        let right = spaces[2].allLeafWindowsRecursive[0]
        try await day.command("focus --window-id \(right.windowId)")
        try await day.command("focus-mode")
        try await day.command("resize width +80")
        for cycle in 0 ..< 5 {
            try await day.step("all monitors blink off \(cycle)") { setMonitorInfosForTests([]) }
            XCTAssertEqual(Monitor.all.count, 3, day.context)
            try await day.step("only main display remains \(cycle)") { setMonitorInfosForTests([day.monitors[1]]) }
            for workspace in spaces { XCTAssertEqual(workspace.workspaceMonitorInfo.rect, day.monitors[1].rect, day.context) }
            XCTAssertEqual(FocusMode.shared.baseGeometry(for: spaces[2]).monitor.rect, day.monitors[1].rect, day.context)
            try await day.step("three monitors reconnect \(cycle)") { setMonitorInfosForTests(day.monitors) }
            for (index, workspace) in spaces.enumerated() {
                XCTAssertEqual(workspace.workspaceMonitorInfo.rect, day.monitors[index].rect, day.context)
                XCTAssertTrue(day.monitors[index].visibleWorkspace === workspace, day.context)
            }
            XCTAssertTrue(globalFocus.windowOrNil === right, day.context)
            XCTAssertEqual(right.singleWindowWidthAdjustment, 80, day.context)
        }
        try await day.command("focus-mode")
        try await day.command("workspace left-home")
        XCTAssertTrue(globalFocus.workspace === spaces[0], day.context)
        day.report("monitor-blink-reconnect")
    }

    func testDelayedFloatingResizeReplyCannotResizeReplacementNativeTab() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        let browser = day.open(in: globalFocus.workspace.floatingWindowsContainer)
        try await day.command("focus --window-id \(browser.windowId)")
        let replacementFrame = Rect(topLeftX: 700, topLeftY: 300, width: 900, height: 650)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(browser.windowId, browser.nativeWindowId!)
        browser.onGetAxRect = {
            remapNativeTabWindow(background: browser.nativeWindowId!, frontmost: 9000, mapping: &mapping, window: browser)
            browser.nativeWindowIdForTest = 9000
            browser.setAxFrame(replacementFrame.topLeftCorner, replacementFrame.size)
        }
        try await day.step("floating resize awaits old native frame while tab remaps") {
            _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        // Cancellation/retry is acceptable; applying a frame computed from the old native tab is not.
        try await day.assertFrames([browser], equalTo: [replacementFrame])
        XCTAssertEqual(mapping.forward[browser.windowId], 9000, day.context)
        day.report("late-floating-resize-frame")
    }

    func testDelayedFocusModeFrameReplyCannotRestoreOldNativeTabGeometry() async throws {
        let day = LifecycleScenario(monitors: lifecycleMonitors(1))
        let browser = day.open(in: globalFocus.workspace.floatingWindowsContainer)
        try await day.command("focus --window-id \(browser.windowId)")
        let replacementFrame = Rect(topLeftX: 700, topLeftY: 300, width: 900, height: 650)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(browser.windowId, browser.nativeWindowId!)
        browser.onGetAxRect = {
            remapNativeTabWindow(background: browser.nativeWindowId!, frontmost: 9001, mapping: &mapping, window: browser)
            browser.nativeWindowIdForTest = 9001
            browser.setAxFrame(replacementFrame.topLeftCorner, replacementFrame.size)
        }
        try await day.step("Focus Mode awaits old floating frame while tab remaps") {
            _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        if FocusMode.shared.isActive { try await day.command("focus-mode") }
        try await day.assertFrames([browser], equalTo: [replacementFrame])
        XCTAssertEqual(mapping.forward[browser.windowId], 9001, day.context)
        day.report("late-focus-mode-frame")
    }

    func testSeededMixedWorkdaysCheckEveryTransition() async throws {
        // Each seed runs the same supported action vocabulary with different windows/workspaces/signs.
        // Geometry, process identities and logical IDs do not depend on the machine or the wall clock.
        for (count, seed) in [(1, UInt64(0xA110)), (2, 0xB220), (3, 0xC330)] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(true)
            let day = LifecycleScenario(monitors: lifecycleMonitors(count), seed: seed)
            let spaces = (0 ..< count + 1).map { Workspace.get(byName: "seed-\(seed)-\($0)") }
            let apps = [TestApp(pid: 401, bundleId: "test.browser"), TestApp(pid: 402, bundleId: "test.editor")]
            for (index, workspace) in spaces.enumerated() {
                if index < count { XCTAssertTrue(day.monitors[index].setVisibleWorkspace(workspace)) }
                _ = day.open(in: workspace.rootTilingContainer, app: apps[index % 2])
                _ = day.open(in: workspace.rootTilingContainer, app: apps[(index + 1) % 2])
            }
            var random = LifecycleRandom(seed: seed)
            for action in 0 ..< 120 {
                let live = day.windows.filter { $0.isBound && $0.lifeStatus == .alive }
                let target = live[random.next(live.count)]
                try await day.command("focus --window-id \(target.windowId)")
                switch action % 12 {
                    case 0, 1, 2:
                        try await day.command("resize \(action % 2 == 0 ? "width" : "smart") \(random.next(2) == 0 ? "+" : "-")\(20 + random.next(61))")
                    case 3:
                        try await day.command("move-node-to-workspace --focus-follows-window \(spaces[random.next(spaces.count)].name)")
                    case 4:
                        try await day.command("layout \(target.isFloating ? "tiling" : "floating")")
                    case 5:
                        try await day.step("open then retain a distinct app window") {
                            _ = day.open(in: globalFocus.workspace.rootTilingContainer, app: apps[random.next(apps.count)])
                        }
                    case 6:
                        try await day.command("focus-mode \(random.next(2) == 0 ? "--stay-on-monitor" : "")")
                        try await day.command("resize height -30")
                        try await day.command("focus-mode")
                    case 7:
                        try await day.step("native tab/Space temporarily invisible") { target.lifeStatus = .invisible }
                        try await day.step("native tab/Space alive again") { target.lifeStatus = .alive }
                    case 8:
                        try await day.command("move-node-to-monitor --focus-follows-window \(1 + random.next(count))")
                    case 9:
                        try await day.command("balance-sizes")
                    case 10:
                        try await day.step("background window closes without switching workspace") {
                            let workspace = globalFocus.workspace
                            if let background = live.first(where: { $0 !== target && $0.nodeWorkspace === workspace }) {
                                XCTAssertNil(workspaceFocusHold(forLeaving: background), day.context)
                                background.closeAxWindow()
                            }
                            XCTAssertTrue(globalFocus.workspace === workspace, day.context)
                        }
                    default:
                        try await day.command("workspace \(spaces[random.next(spaces.count)].name)")
                }
            }
            XCTAssertEqual(day.actionIndex, 270, day.context)
            day.report("mixed-workdays")
        }
    }
}

@MainActor
final class LifecycleScenario {
    let monitors: [MonitorInfo]
    let seed: UInt64
    private(set) var actionIndex = 0
    private var action = "setup"
    private(set) var windows: [TestWindow] = []
    var context: String {
        "seed=\(seed) action=\(actionIndex) [\(action)] focus=\(globalFocus.workspace.name)/\(globalFocus.windowOrNil?.windowId.description ?? "none") " +
            Workspace.all.lazy.map { "\($0.name):\($0.rootTilingContainer.layoutDescription)" }.joined(separator: " ")
    }

    init(monitors: [MonitorInfo], seed: UInt64 = 0) {
        self.monitors = monitors
        self.seed = seed
        setMonitorInfosForTests(monitors)
    }

    @discardableResult
    func open(in parent: NonLeafTreeNodeObject, app: TestApp = .shared) -> TestWindow {
        let id = UInt64(4_294_967_300 + windows.count)
        let window = TestWindow.new(
            id: OpaqueWindowId(id),
            parent: parent,
            adaptiveWeight: WEIGHT_AUTO,
            rect: Rect(topLeftX: 100, topLeftY: 100, width: 600, height: 400),
            app: app,
        )
        window.nativeWindowIdForTest = UInt32(1000 + windows.count)
        windows.append(window)
        return window
    }

    func command(_ command: String, expecting exitCode: Int32 = 0) async throws {
        try await step(command) {
            let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode.rawValue, exitCode, "\(context) stderr=\(result.stderr)")
        }
    }

    func step(_ description: String, _ body: () async throws -> Void) async throws {
        actionIndex += 1
        action = description
        do {
            try await body()
            await checkOnFocusChangedCallbacks_nonCancellable()
            await FocusMode.shared.syncWithFocus()
            for workspace in Workspace.all { try await workspace.layoutWorkspace() }
            try await assertInvariants()
        } catch {
            XCTFail("\(context): \(error)")
            throw error
        }
    }

    private func assertInvariants() async throws {
        let bound = windows.filter(\.isBound)
        XCTAssertEqual(Set(bound.map(\.windowId)).count, bound.count, context)
        let nativeIds = bound.compactMap(\.nativeWindowId)
        XCTAssertEqual(Set(nativeIds).count, nativeIds.count, context)
        let treeWindows = Workspace.all.flatMap(\.allLeafWindowsRecursive) + macosMinimizedWindowsContainer.children.compactMap { $0 as? Window }
        XCTAssertEqual(Set(treeWindows.map(ObjectIdentifier.init)), Set(bound.map(ObjectIdentifier.init)), context)
        XCTAssertEqual(Set(Workspace.all.map(\.name)).count, Workspace.all.count, context)
        let monitorSpaces = Monitor.all.flatMap { $0.getWorkspacesContainerOrCreate().children }.compactMap { $0 as? Workspace }
        XCTAssertEqual(Set(monitorSpaces.map(ObjectIdentifier.init)), Set(Workspace.all.map(ObjectIdentifier.init)), context)
        XCTAssertEqual(monitorSpaces.count, Workspace.all.count, context)
        for workspace in Workspace.all {
            XCTAssertTrue(workspace.parent != nil, context)
            XCTAssertTrue(Monitor.all.contains { $0.info.rect == workspace.workspaceMonitorInfo.rect }, context)
            checkWeights(workspace.rootTilingContainer)
        }
        if let focused = globalFocus.windowOrNil {
            XCTAssertTrue(focused.isBound, context)
            XCTAssertTrue(focused.visualWorkspace === globalFocus.workspace, context)
            // Explicit --window-id may activate an invisible Space. Automatic workspace selection must skip it.
            if let automatic = globalFocus.workspace.toLiveFocus().windowOrNil {
                XCTAssertEqual(automatic.lifeStatus, .alive, context)
            }
        }
        for window in bound where window.lifeStatus == .alive && window.nodeWorkspace != nil {
            let read = try await window.getAxRect(.nonCancellable)
            let rect = try XCTUnwrap(read, context)
            XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), context)
            XCTAssertGreaterThan(rect.width, 0, context)
            XCTAssertGreaterThan(rect.height, 0, context)
        }
    }

    private func checkWeights(_ container: TilingContainer) {
        for child in container.children {
            if container.layout == .tiles {
                let weight = child.getWeight(container.orientation)
                XCTAssertTrue(weight.isFinite && weight > 0, context)
            }
            if let nested = child as? TilingContainer { checkWeights(nested) }
        }
    }

    func frames(_ windows: [Window]) async throws -> [Rect] {
        var result: [Rect] = []
        for window in windows {
            let read = try await window.getAxRect(.nonCancellable)
            result.append(try XCTUnwrap(read, context))
        }
        return result
    }

    func assertFrames(_ windows: [Window], equalTo expected: [Rect]) async throws {
        let actual = try await frames(windows)
        XCTAssertEqual(actual.count, expected.count, context)
        for (rect, original) in zip(actual, expected) {
            XCTAssertEqual(rect.minX, original.minX, accuracy: 0.001, context)
            XCTAssertEqual(rect.minY, original.minY, accuracy: 0.001, context)
            XCTAssertEqual(rect.width, original.width, accuracy: 0.001, context)
            XCTAssertEqual(rect.height, original.height, accuracy: 0.001, context)
        }
    }

    func report(_ scenario: String) {
        print("lifecycle-checkpoints scenario=\(scenario) seed=\(seed) actions=\(actionIndex)")
    }
}

struct LifecycleMonitor: MonitorInfo {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let isMain: Bool
    var visibleFrame: Rect? = nil
    var visibleRect: Rect { visibleFrame ?? rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

func lifecycleMonitors(_ count: Int) -> [MonitorInfo] {
    (0 ..< count).map { index in
        LifecycleMonitor(
            monitorAppKitNsScreenScreensId: index + 1,
            name: "Lifecycle Display \(index + 1)",
            rect: Rect(topLeftX: CGFloat(index - (count == 3 ? 1 : 0)) * 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: index == (count == 3 ? 1 : 0),
        )
    }
}

struct LifecycleRandom {
    var seed: UInt64
    mutating func next(_ upperBound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 32) % UInt64(upperBound))
    }
}

private func eventJson(_ event: ServerEvent) -> String {
    String(decoding: try! JSONEncoder().encode(event), as: UTF8.self)
}
