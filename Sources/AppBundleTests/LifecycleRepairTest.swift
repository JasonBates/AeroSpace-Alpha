@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class LifecycleRepairTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.automaticallyUnhideMacosHiddenApps = true
        for child in macosMinimizedWindowsContainer.children + macosPopupWindowsContainer.children {
            child.unbindFromParent()
        }
    }

    func testNestedHiddenPlaceholdersPreserveVisibleResizeOnAdaptiveAndNormalLayouts() async throws {
        for adaptive in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
            let top = TestWindow.new(id: 1, parent: stack)
            let middle = TestWindow.new(id: 2, parent: stack)
            let hidden = TestWindow.new(id: 3, parent: stack)
            let outerHidden = TestWindow.new(id: 4, parent: root)
            XCTAssertTrue(top.focusWindow())
            try await workspace.layoutWorkspace()
            let originalHidden = try await frame(hidden)
            let hiddenWeight = hidden.vWeight
            let outerWeight = outerHidden.hWeight
            let visiblePool = top.vWeight + middle.vWeight
            hidden.lifeStatus = .invisible
            outerHidden.lifeStatus = .invisible
            try await workspace.layoutWorkspace()
            let expanded = try await frame(top)
            let result = await parseCommand("resize height +60").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode.rawValue, 0)
            try await workspace.layoutWorkspace()
            let resized = try await frame(top)
            XCTAssertEqual(resized.height, expanded.height + 60, accuracy: 0.001)
            XCTAssertEqual(hidden.vWeight, hiddenWeight)
            XCTAssertEqual(outerHidden.hWeight, outerWeight)
            XCTAssertEqual(top.vWeight + middle.vWeight, visiblePool, accuracy: 0.001)
            XCTAssertGreaterThan(top.vWeight, middle.vWeight)
            let resizedWeights = stack.children.map(\.vWeight)
            for _ in 0 ..< 5 {
                hidden.lifeStatus = .alive
                outerHidden.lifeStatus = .alive
                try await workspace.layoutWorkspace()
                let restoredHidden = try await frame(hidden)
                XCTAssertEqual(restoredHidden.height, originalHidden.height, accuracy: 0.001)
                XCTAssertEqual(stack.children.map(\.vWeight), resizedWeights)
                hidden.lifeStatus = .invisible
                outerHidden.lifeStatus = .invisible
                try await workspace.layoutWorkspace()
                XCTAssertEqual(stack.children.map(\.vWeight), resizedWeights)
            }
            let reverse = await parseCommand("resize height -60").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(reverse.exitCode.rawValue, 0)
            try await workspace.layoutWorkspace()
            assertFrame(try await frame(top), equals: expanded)
        }
    }

    func testHiddenHorizontalSiblingKeyboardRoundTripUsesDisplayedPoints() async throws {
        for adaptive in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root)
            let second = TestWindow.new(id: 2, parent: root)
            let hidden = TestWindow.new(id: 3, parent: root)
            XCTAssertTrue(first.focusWindow())
            try await workspace.layoutWorkspace()
            hidden.lifeStatus = .invisible
            try await workspace.layoutWorkspace()
            let before = try await frame(first)
            let retained = root.children.map(\.hWeight)
            for command in ["resize width +60", "resize width -60"] {
                let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
                XCTAssertEqual(result.exitCode.rawValue, 0)
                try await workspace.layoutWorkspace()
                let current = try await frame(first)
                XCTAssertEqual(current.width, before.width + (command.contains("+60") ? 60 : 0), accuracy: 0.001)
                XCTAssertEqual(hidden.hWeight, retained[2])
                XCTAssertEqual(first.hWeight + second.hWeight, retained[0] + retained[1], accuracy: 0.001)
            }
            hidden.lifeStatus = .alive
            try await workspace.layoutWorkspace()
            for (weight, expected) in zip(root.children.map(\.hWeight), retained) {
                XCTAssertEqual(weight, expected, accuracy: 0.001)
            }
        }
    }

    func testHiddenHorizontalSiblingMouseRoundTripUsesRetainedPool() async throws {
        for (adaptive, hidesSibling) in [(false, false), (true, false), (false, true), (true, true)] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root)
            let second = TestWindow.new(id: 2, parent: root)
            let hidden = TestWindow.new(id: 3, parent: root)
            try await workspace.layoutWorkspace()
            if hidesSibling { hidden.lifeStatus = .invisible }
            try await workspace.layoutWorkspace()
            let before = try await frame(first)
            let retained = root.children.map(\.hWeight)
            first.setAxFrame(nil, CGSize(width: before.width + 60, height: before.height))
            try await resizeWithMouse(first)
            if hidesSibling {
                XCTAssertEqual(hidden.hWeight, retained[2])
                XCTAssertEqual(first.hWeight + second.hWeight, retained[0] + retained[1], accuracy: 0.001)
            } else {
                XCTAssertEqual(root.children.reduce(CGFloat.zero) { $0 + $1.hWeight }, retained.reduce(0, +), accuracy: 0.001)
            }
            first.setAxFrame(before.topLeftCorner, before.size)
            try await resizeWithMouse(first)
            try await resetManipulatedWithMouseIfPossible()
            try await workspace.layoutWorkspace()
            assertFrame(try await frame(first), equals: before)
            for (weight, expected) in zip(root.children.map(\.hWeight), retained) {
                XCTAssertEqual(weight, expected, accuracy: 0.001)
            }
        }
    }

    func testHiddenProjectionRestoresLogicalWeightsBeforeChildFrameCallback() async throws {
        for adaptive in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
            let top = TestWindow.new(id: 1, parent: stack)
            let bottom = TestWindow.new(id: 2, parent: stack)
            let hidden = TestWindow.new(id: 3, parent: root)
            try await workspace.layoutWorkspace()
            let outerWeights = root.children.map(\.hWeight)
            let innerWeights = stack.children.map(\.vWeight)
            hidden.lifeStatus = .invisible
            bottom.lifeStatus = .invisible
            var callbackCount = 0
            top.onSetAxFrame = {
                callbackCount += 1
                XCTAssertEqual(root.children.map(\.hWeight), outerWeights)
                XCTAssertEqual(stack.children.map(\.vWeight), innerWeights)
            }
            try await workspace.layoutWorkspace()
            XCTAssertEqual(callbackCount, 1)
        }
    }

    func testHiddenVerticalSiblingMouseUsesDisplayedUnequalBaseline() async throws {
        for adaptive in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let stack = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
            let top = TestWindow.new(id: 1, parent: stack, adaptiveWeight: 500)
            let middle = TestWindow.new(id: 2, parent: stack, adaptiveWeight: 350)
            let hidden = TestWindow.new(id: 3, parent: stack, adaptiveWeight: 229)
            try await workspace.layoutWorkspace()
            hidden.lifeStatus = .invisible
            try await workspace.layoutWorkspace()
            let baseline = try await frame(top)
            let weights = stack.children.map(\.vWeight)
            top.setAxFrame(nil, CGSize(width: baseline.width, height: baseline.height + 60))
            try await resizeWithMouse(top)
            let resizedHeight = try XCTUnwrap(tiledPhysicalHeight(node: top, parent: stack, workspace: workspace))
            XCTAssertEqual(resizedHeight, baseline.height + 60, accuracy: 0.001)
            XCTAssertEqual(hidden.vWeight, weights[2])
            XCTAssertEqual(top.vWeight + middle.vWeight, weights[0] + weights[1], accuracy: 0.001)
            top.setAxFrame(baseline.topLeftCorner, baseline.size)
            try await resizeWithMouse(top)
            try await resetManipulatedWithMouseIfPossible()
            try await workspace.layoutWorkspace()
            assertFrame(try await frame(top), equals: baseline)
            for (weight, expected) in zip(stack.children.map(\.vWeight), weights) {
                XCTAssertEqual(weight, expected, accuracy: 0.001)
            }
        }
    }

    func testNormalMouseBaselineReplayRejectsQueuedEventsFromChangedContext() async throws {
        for change in ["native", "topology", "monitor"] {
            setUpWorkspacesForTests()
            let monitors = lifecycleMonitors(2)
            setMonitorInfosForTests(monitors)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root)
            TestWindow.new(id: 2, parent: root)
            try await workspace.layoutWorkspace()
            let baseline = try await frame(first)
            first.setAxFrame(nil, CGSize(width: baseline.width + 60, height: baseline.height))
            try await resizeWithMouse(first)
            switch change {
                case "native": first.invalidateNativeWindowGeometry()
                case "topology": TestWindow.new(id: 3, parent: root)
                default: XCTAssertTrue(monitors[1].setVisibleWorkspace(workspace))
            }
            let weights = root.children.map(\.hWeight)
            // Model a layout arriving before an old queued notification: the gesture still owns its baseline.
            first.lastAppliedLayoutPhysicalRect = baseline
            first.setAxFrame(baseline.topLeftCorner, baseline.size)
            try await resizeWithMouse(first)
            XCTAssertEqual(root.children.map(\.hWeight), weights, change)
            try await resetManipulatedWithMouseIfPossible()
        }
    }

    func testFullscreenRejectsIntentionalResizeBalanceAndEqualDeltaEdits() async throws {
        for edit in ["resize width +80", "balance-sizes", "equal-delta"] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(true)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            let fullscreen = TestWindow.new(id: 2, parent: root, adaptiveWeight: 1)
            let last = TestWindow.new(id: 3, parent: root, adaptiveWeight: 2)
            XCTAssertTrue(first.focusWindow())
            try await workspace.layoutWorkspace()
            enterMacOsNativeFullscreen(window: fullscreen, workspace: workspace)
            try await workspace.layoutWorkspace()
            if edit == "equal-delta" {
                first.hWeight += 25
                last.hWeight += 25
            } else {
                let result = await parseCommand(edit).cmdOrDie.run(.defaultEnv, .emptyStdin)
                XCTAssertEqual(result.exitCode.rawValue, 0)
            }
            let edits = [first.hWeight, last.hWeight]
            try await exitMacOsNativeUnconventionalState(window: fullscreen, prevParentKind: .tilingContainer, workspace: workspace, .nonCancellable)
            XCTAssertEqual(root.children, [first, last, fullscreen], edit)
            XCTAssertEqual([first.hWeight, last.hWeight], edits, edit)
        }
    }

    func testFullscreenRejectsIntentionalResizeAfterNestedParentFlattens() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        config.enableNormalizationFlattenContainers = true
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let left = TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 2)
        let fullscreen = TestWindow.new(id: 2, parent: stack)
        let bottom = TestWindow.new(id: 3, parent: stack)
        XCTAssertTrue(bottom.focusWindow())
        try await workspace.layoutWorkspace()
        enterMacOsNativeFullscreen(window: fullscreen, workspace: workspace)
        try await workspace.layoutWorkspace()
        workspace.normalizeContainers()
        XCTAssertFalse(stack.isBound)
        let result = await parseCommand("resize width +80").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        let resized = [left.hWeight, bottom.hWeight]
        try await exitMacOsNativeUnconventionalState(window: fullscreen, prevParentKind: .tilingContainer, workspace: workspace, .nonCancellable)
        XCTAssertFalse(stack.isBound)
        XCTAssertEqual([left.hWeight, bottom.hWeight], resized)
        XCTAssertEqual(root.children, [left, bottom, fullscreen])
    }

    func testFloatingResizeCancelsChangedNativeWorkspaceOrLiveness() async throws {
        for change in ["native", "workspace", "invisible", "closed"] {
            setUpWorkspacesForTests()
            let workspace = globalFocus.workspace
            let original = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
            let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
            XCTAssertTrue(window.focusWindow())
            window.onGetAxRect = {
                switch change {
                    case "native": window.invalidateNativeWindowGeometry()
                    case "workspace": window.bindAsFloatingWindow(to: Workspace.get(byName: "moved"))
                    case "invisible": window.lifeStatus = .invisible
                    default: window.closeAxWindow()
                }
            }
            let result = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode.rawValue, 2, change)
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0, change)
            assertFrame(try await frame(window), equals: original)
        }
    }

    func testFocusModeOriginalFloatingFrameExpiresAfterActiveNativeRemap() async throws {
        let workspace = globalFocus.workspace
        let original = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let replacement = Rect(topLeftX: 500, topLeftY: 200, width: 900, height: 650)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
        XCTAssertTrue(window.focusWindow())
        let started = await FocusMode.shared.start(window: window, workspace: workspace)
        XCTAssertTrue(started)
        try await workspace.layoutWorkspace()
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(window.windowId, 100)
        remapNativeTabWindow(background: 100, frontmost: 101, mapping: &mapping, window: window)
        window.setAxFrame(replacement.topLeftCorner, replacement.size)
        await FocusMode.shared.syncWithFocus()
        XCTAssertFalse(FocusMode.shared.isActive)
        for _ in 0 ..< 3 { try await workspace.layoutWorkspace() }
        let writes = window.setAxFrameCallCountForTest
        FocusMode.shared.stop()
        XCTAssertEqual(window.setAxFrameCallCountForTest, writes)
        assertFrame(try await frame(window), equals: replacement)
    }

    func testFocusModeSetupCancelsWhenFocusOrWorkspaceChangesDuringRead() async {
        for change in ["focus", "workspace", "invisible", "closed", "stopped"] {
            setUpWorkspacesForTests()
            let workspace = globalFocus.workspace
            let original = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
            let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
            let other = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
            XCTAssertTrue(window.focusWindow())
            window.onGetAxRect = {
                switch change {
                    case "focus": XCTAssertTrue(other.focusWindow())
                    case "workspace": XCTAssertTrue(Workspace.get(byName: "other").focusWorkspace())
                    case "invisible": window.lifeStatus = .invisible
                    case "closed": window.closeAxWindow()
                    default: FocusMode.shared.stop()
                }
            }
            let started = await FocusMode.shared.start(window: window, workspace: workspace)
            XCTAssertFalse(started, change)
            XCTAssertFalse(FocusMode.shared.isActive, change)
            XCTAssertNil(FocusMode.shared.windowId, change)
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0, change)
        }
    }

    func testFocusModeSyncCancelsStaleFloatingReadAndRestoresOnlyPreviousWindow() async throws {
        for change in ["native", "focus", "workspace", "moved", "invisible", "closed"] {
            setUpWorkspacesForTests()
            let workspace = globalFocus.workspace
            let original = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
            let replacement = Rect(topLeftX: 500, topLeftY: 200, width: 900, height: 650)
            let first = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
            let second = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, rect: original)
            let third = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
            XCTAssertTrue(first.focusWindow())
            let started = await FocusMode.shared.start(window: first, workspace: workspace)
            XCTAssertTrue(started)
            try await workspace.layoutWorkspace()
            XCTAssertTrue(second.focusWindow())
            second.onGetAxRect = {
                switch change {
                    case "native":
                        second.invalidateNativeWindowGeometry()
                        second.setAxFrame(replacement.topLeftCorner, replacement.size)
                    case "focus": XCTAssertTrue(third.focusWindow())
                    case "workspace": XCTAssertTrue(Workspace.get(byName: "other").focusWorkspace())
                    case "moved": second.bindAsFloatingWindow(to: Workspace.get(byName: "moved"))
                    case "invisible": second.lifeStatus = .invisible
                    default: second.closeAxWindow()
                }
            }
            await FocusMode.shared.syncWithFocus()
            XCTAssertFalse(FocusMode.shared.isActive, change)
            assertFrame(try await frame(first), equals: original)
            assertFrame(try await frame(second), equals: change == "native" ? replacement : original)
            XCTAssertEqual(second.setAxFrameCallCountForTest, change == "native" ? 1 : 0, change)
        }
    }

    func testFreshMouseResizeDuringFocusModeRestoresViewWithoutEditingTiles() async throws {
        for adaptive in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptive)
            let workspace = globalFocus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root)
            TestWindow.new(id: 2, parent: root)
            XCTAssertTrue(first.focusWindow())
            try await workspace.layoutWorkspace()
            let original = try await frame(first)
            let weights = root.children.map(\.hWeight)
            let started = await FocusMode.shared.start(window: first, workspace: workspace)
            XCTAssertTrue(started)
            try await workspace.layoutWorkspace()
            let focused = try await frame(first)
            first.setAxFrame(nil, CGSize(width: focused.width + 120, height: focused.height - 100))
            try await resizeWithMouse(first)
            try await workspace.layoutWorkspace()
            XCTAssertEqual(root.children.map(\.hWeight), weights)
            XCTAssertEqual(first.singleWindowWidthAdjustment, 0)
            XCTAssertEqual(first.focusModeHeightAdjustment, 0)
            assertFrame(try await frame(first), equals: focused)
            FocusMode.shared.stop()
            try await workspace.layoutWorkspace()
            assertFrame(try await frame(first), equals: original)
        }
    }

    private func frame(_ window: Window) async throws -> Rect {
        let rect = try await window.getAxRect(.nonCancellable)
        return try XCTUnwrap(rect)
    }

    private func assertFrame(_ frame: Rect, equals expected: Rect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.topLeftX, expected.topLeftX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.topLeftY, expected.topLeftY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
