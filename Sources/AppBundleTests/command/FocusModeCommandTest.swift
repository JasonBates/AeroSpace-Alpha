@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusModeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDestinationMonitorUsesMiddleDisplayAndSingleDisplayStaysPut() {
        func display(_ x: CGFloat, main: Bool = false) -> MonitorInfo {
            TestFocusMonitor(x: x, isMain: main)
        }
        let left = display(-1920)
        let centre = display(0, main: true)
        let right = display(1920)

        let mode = FocusMode.shared
        assertEquals(mode.destinationMonitor(for: left, among: [right, left, centre]).rect.minX, 0)
        assertEquals(mode.destinationMonitor(for: right, among: [right, left, centre]).rect.minX, 0)
        assertEquals(mode.destinationMonitor(for: left, among: [left, centre]).rect.minX, 0)
        assertEquals(mode.destinationMonitor(for: left, among: [left]).rect.minX, -1920)
    }

    func testStayOnMonitorOverridesStageAndResetsAfterToggle() async {
        let source = TestFocusMonitor(x: -1920, isMain: false)
        let centre = TestFocusMonitor(x: 0, isMain: true)
        let right = TestFocusMonitor(x: 1920, isMain: false)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        assertTrue(window.focusWindow())

        let result = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let mode = FocusMode.shared
        assertEquals(mode.destinationMonitor(for: source, among: [source, centre]).rect.minX, -1920)
        assertEquals(mode.destinationMonitor(for: right, among: [source, centre, right]).rect.minX, 1920)
        let second = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        assertTrue(second.focusWindow())
        await mode.syncWithFocus()
        assertEquals(mode.windowId, 2)
        assertEquals(mode.destinationMonitor(for: source, among: [source, centre]).rect.minX, -1920)

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertFalse(mode.isActive)
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(mode.destinationMonitor(for: source, among: [source, centre]).rect.minX, 0)
    }

    func testToggleCentresFocusedWindowAndRestoresTiles() async throws {
        config.singleWindowWidthRules = [SingleWindowWidthRule(minMonitorWidth: 0, widthPercent: 50)]
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
        let second = TestWindow.new(id: 2, parent: root, adaptiveWeight: 1)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        let initialFrame = try await first.getAxRect(.nonCancellable)
        let initialWeights = root.children.map(\.hWeight)

        let on = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(on.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        let focusedFrame = try await first.getAxRect(.nonCancellable)
        assertEquals(focusedFrame?.topLeftX, 480)
        assertEquals(focusedFrame?.topLeftY, 0)
        assertEquals(focusedFrame?.width, 960)
        assertEquals(focusedFrame?.height, 1079)
        assertTrue(FocusMode.shared.containsFocusedWindow(at: CGPoint(x: 900, y: 500)))
        assertFalse(FocusMode.shared.containsFocusedWindow(at: CGPoint(x: 100, y: 500)))
        assertEquals(root.layout, .tiles)
        assertEquals(root.children.map(\.hWeight), initialWeights)
        assertEquals((try await second.getAxRect(.nonCancellable))?.width, initialFrame?.width)

        let off = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(off.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        let restoredFrame = try await first.getAxRect(.nonCancellable)
        assertEquals(restoredFrame?.topLeftX, initialFrame?.topLeftX)
        assertEquals(restoredFrame?.width, initialFrame?.width)
        assertEquals(root.children.map(\.hWeight), initialWeights)
    }

    func testAdaptiveToggleKeepsLoneWindowSizeAndCentre() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())
        try await workspace.layoutWorkspace()
        let before = try await window.getAxRect(.nonCancellable)

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let focused = try await window.getAxRect(.nonCancellable)

        assertEquals(focused, before)
        assertEquals(focused?.center, before?.center)
        assertEquals(focused, Rect(topLeftX: 643.2, topLeftY: 54, width: 633.6, height: 971))
    }

    func testAdaptiveFocusUsesSingleWindowBaselineWithoutChangingMultiwindowWeights() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        let weights = root.children.map(\.hWeight)

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertEquals(
            try await first.getAxRect(.nonCancellable),
            Rect(topLeftX: 643.2, topLeftY: 54, width: 633.6, height: 971),
        )
        assertEquals(root.children.map(\.hWeight), weights)
    }

    func testAdaptiveFocusResizeOffsetsUseAdaptiveBaseAndSurviveToggle() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())
        try await workspace.layoutWorkspace()
        let tiledFrame = try await window.getAxRect(.nonCancellable)
        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)

        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = await parseCommand("resize height -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            FocusMode.shared.frame(for: window, in: workspace),
            Rect(topLeftX: 593.2, topLeftY: 104, width: 733.6, height: 871),
        )

        _ = await parseCommand("resize height 500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, 500)
        _ = await parseCommand("resize height +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, 1079)

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals((try await window.getAxRect(.nonCancellable))?.height, tiledFrame?.height)
        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.width, 733.6)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, 1079)
    }

    func testDestinationMonitorControlsAdaptiveFocusGeometry() async {
        let source = TestFocusMonitor(x: -1920, isMain: false, id: 1, name: "Standard")
        let destination = TestFocusMonitor(x: 0, isMain: true, id: 2, name: "Adaptive")
        monitorInfosForTests = [source, destination]
        config.adaptiveLayout.enabled = .perMonitor(
            [PerMonitorValue(description: .pattern("Adaptive")!, value: true)],
            default: false,
        )
        let workspace = focus.workspace
        assertTrue(source.setActiveWorkspace(workspace))
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())

        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(
            FocusMode.shared.frame(for: window, in: workspace),
            Rect(topLeftX: 643.2, topLeftY: 54, width: 633.6, height: 971),
        )
    }

    func testFollowsFocusAndStopsOnWorkspaceSwitch() async {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertTrue(first.focusWindow())
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.windowId, 1)

        assertTrue(second.focusWindow())
        await FocusMode.shared.syncWithFocus()
        assertEquals(FocusMode.shared.windowId, 2)

        assertTrue(Workspace.get(byName: "another").focusWorkspace())
        await FocusMode.shared.syncWithFocus()
        assertFalse(FocusMode.shared.isActive)
    }

    func testRestoresFloatingWindowFrame() async throws {
        let workspace = focus.workspace
        let original = Rect(topLeftX: 70, topLeftY: 80, width: 500, height: 400)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
        assertTrue(window.focusWindow())

        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let focused = try await window.getAxRect(.nonCancellable)
        assertEquals(focused?.width, 1267.2)

        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let restored = try await window.getAxRect(.nonCancellable)
        assertEquals(restored?.topLeftX, original.topLeftX)
        assertEquals(restored?.topLeftY, original.topLeftY)
        assertEquals(restored?.width, original.width)
        assertEquals(restored?.height, original.height)
    }

    func testHeightResizeCentresClampsAndRestoresTiledLayout() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        let other = TestWindow.new(id: 2, parent: root)
        assertTrue(window.focusWindow())
        try await workspace.layoutWorkspace()
        let original = try await window.getAxRect(.nonCancellable)
        let weights = root.children.map(\.vWeight)
        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let initial = FocusMode.shared.frame(for: window, in: workspace)!
        let result = await parseCommand("resize height -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        let reduced = try await window.getAxRect(.nonCancellable)
        assertEquals(reduced?.height, initial.height - 100)
        assertEquals(reduced?.width, initial.width)
        assertEquals(reduced?.center, initial.center)
        assertEquals(root.children.map(\.vWeight), weights)

        assertTrue(other.focusWindow())
        await FocusMode.shared.syncWithFocus()
        assertEquals(FocusMode.shared.frame(for: other, in: workspace)?.height, initial.height)
        assertTrue(window.focusWindow())
        await FocusMode.shared.syncWithFocus()
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, initial.height - 100)
        _ = await parseCommand("resize height 500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, 500)
        _ = await parseCommand("resize height -99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, 200)
        _ = await parseCommand("resize height +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, initial.height)
        _ = await parseCommand("resize height -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals((try await window.getAxRect(.nonCancellable))?.height, original?.height)
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(FocusMode.shared.frame(for: window, in: workspace)?.height, initial.height - 100)
    }

    func testHeightResizeRestoresFloatingFrame() async throws {
        let workspace = focus.workspace
        let original = Rect(topLeftX: 70, topLeftY: 80, width: 500, height: 400)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
        assertTrue(window.focusWindow())
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let initial = FocusMode.shared.frame(for: window, in: workspace)!
        _ = await parseCommand("resize height -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals((try await window.getAxRect(.nonCancellable))?.height, initial.height - 100)
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let restored = try await window.getAxRect(.nonCancellable)
        assertEquals(restored?.size, original.size)
        assertEquals(restored?.center, original.center)
    }

    func testDoesNotMoveFloatingWindowWhenItsOriginalFrameIsUnavailable() async {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        assertTrue(window.focusWindow())

        let result = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertFalse(FocusMode.shared.isActive)
    }
}

private struct TestFocusMonitor: MonitorInfo {
    let x: CGFloat
    let isMain: Bool
    var id: Int = 1
    var name: String = "Focus Mode test display"
    var monitorAppKitNsScreenScreensId: Int { id }
    var rect: Rect { Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080) }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}
