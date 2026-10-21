@testable import AppBundle
import Common
import XCTest

@MainActor
final class BalanceSizesCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testBalanceSizesCommand() async {
        let workspace = Workspace.get(byName: name).apply { wsp in
            wsp.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 1)
                TestWindow.new(id: 2, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 2)
                TestWindow.new(id: 3, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 3)
            }
        }

        await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(name), .emptyStdin)

        for window in workspace.rootTilingContainer.children {
            assertEquals(window.getWeight(workspace.rootTilingContainer.orientation), 1)
        }
    }

    func testBalanceSizesResetsClosedWindowsCache() async throws {
        resetClosedWindowsCache()
        defer { resetClosedWindowsCache() }

        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 100)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        let closedWindow = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        _ = window1.focusWindow()

        cacheClosedWindowIfNeeded()
        closedWindow.unbindFromParent()

        let result = await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(name), .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window1.hWeight, window2.hWeight)
        assertFalse(try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: closedWindow))
    }

    func testBalanceSizesResetsNestedTileAndFocusAdjustmentsWithoutResizingFloatingWindow() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        var first: Window!
        var second: Window!
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 3).apply {
            first = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 3)
            second = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        TestWindow.new(id: 3, parent: root, adaptiveWeight: 1)
        let floating = TestWindow.new(
            id: 4,
            parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 120, width: 500, height: 350),
        )
        first.singleWindowWidthAdjustment = 90
        first.focusModeHeightAdjustment = -80
        floating.singleWindowWidthAdjustment = 70
        floating.focusModeHeightAdjustment = 60
        let floatingFrame = try await floating.getAxRect(.nonCancellable)

        let result = await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.children.map(\.hWeight), [1, 1])
        assertEquals(nested.children.map(\.vWeight), [1, 1])
        for window in [first, second, floating].compactMap({ $0 }) {
            assertEquals(window.singleWindowWidthAdjustment, 0)
            assertEquals(window.focusModeHeightAdjustment, 0)
        }
        assertEquals(try await floating.getAxRect(.nonCancellable), floatingFrame)
    }
}
