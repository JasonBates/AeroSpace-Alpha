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
        assertEquals(focusedFrame?.width, 960)
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
    var monitorAppKitNsScreenScreensId: Int { 1 }
    var name: String { "Focus Mode test display" }
    var rect: Rect { Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080) }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}
