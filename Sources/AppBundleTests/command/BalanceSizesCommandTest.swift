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
            assertEquals(window.getWeight(workspace.rootTilingContainer.orientation), 6 / 3)
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
        let workspace = globalFocus.workspace
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
        assertEquals(root.children.map(\.hWeight), [2, 2]) // The average weight (upstream 80092f3)
        assertEquals(nested.children.map(\.vWeight), [2, 2])
        for window in [first, second, floating].compactMap({ $0 }) {
            assertEquals(window.singleWindowWidthAdjustment, 0)
            assertEquals(window.focusModeHeightAdjustment, 0)
        }
        assertEquals(try await floating.getAxRect(.nonCancellable), floatingFrame)
    }

    func testBalanceSizesThenResize_behavesLikeResizeAlone() async {
        var window1: Window!
        var window2: Window!
        var window3: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 6)
        }
        _ = window1.focusWindow()

        // Both commands run within a single session, so no layout pass normalizes the weights in between
        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("resize width 6").cmdOrDie.run(.defaultEnv, .emptyStdin)

        // balance-sizes makes it 4, 4, 4. Then diff = 6 - 4 = 2, childDiff = 1
        assertEquals(window1.hWeight, 6)
        assertEquals(window2.hWeight, 3)
        assertEquals(window3.hWeight, 3)
        // The total is unchanged, so the following layout pass doesn't scale the windows up
        assertEquals(window1.hWeight + window2.hWeight + window3.hWeight, 12)
    }
}
