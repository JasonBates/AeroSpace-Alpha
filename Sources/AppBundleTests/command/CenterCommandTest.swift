@testable import AppBundle
import Common
import XCTest

@MainActor
final class CenterCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCentresFloatingWindowOnItsMonitor() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.floatingWindowsContainer, rect: Rect(topLeftX: 10, topLeftY: 20, width: 400, height: 300))
        assertTrue(window.focusWindow())
        let bounds = focus.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps

        let result = await parseCommand("center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.center, bounds.center)
        assertEquals(rect?.size, CGSize(width: 400, height: 300))
    }

    func testShrinksWindowLargerThanMonitor() async throws {
        let bounds = focus.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        let window = TestWindow.new(id: 1, parent: focus.workspace.floatingWindowsContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: bounds.width + 500, height: 300))
        assertTrue(window.focusWindow())

        await parseCommand("center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.width, bounds.width)
        assertEquals(rect?.topLeftX, bounds.topLeftX)
    }

    func testFailsForTilingWindow() async {
        assertTrue(TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer).focusWindow())
        let result = await parseCommand("center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["center command only supports floating windows"])
    }
}
