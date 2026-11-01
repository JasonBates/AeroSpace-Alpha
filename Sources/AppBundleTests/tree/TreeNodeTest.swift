@testable import AppBundle
import XCTest

@MainActor
final class TreeNodeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testChildParentCyclicReferenceMemoryLeak() {
        let workspace = Workspace.get(byName: name) // Don't cache root node
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        XCTAssertTrue(window.parent != nil)
        workspace.rootTilingContainer.unbindFromParent()
        XCTAssertTrue(window.parent == nil)
    }

    func testIsEffectivelyEmpty() {
        let workspace = Workspace.get(byName: name)

        XCTAssertTrue(workspace.isEffectivelyEmpty)
        weak let window: TestWindow? = .new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertNotEqual(window, nil)
        XCTAssertTrue(!workspace.isEffectivelyEmpty)
        window!.unbindFromParent()
        XCTAssertTrue(workspace.isEffectivelyEmpty)

        // Don't save to local variable
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(!workspace.isEffectivelyEmpty)
    }

    func testToLiveFocus_skipsEmptyFloatingContainer() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertTrue(TestWindow.new(id: 2, parent: $0).focusWindow())
        }
        let dialog = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        assertTrue(dialog.focusWindow())

        dialog.unbindFromParent()
        assertEquals(workspace.toLiveFocus().windowOrNil?.windowId, 2)
    }

    func testToLiveFocus_skipsEmptyTilingContainer() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        assertTrue(TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer).focusWindow())
        let tilingWindow = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        assertTrue(tilingWindow.focusWindow())

        tilingWindow.unbindFromParent()
        assertEquals(workspace.toLiveFocus().windowOrNil?.windowId, 2)
    }

    func testBindWeightAuto_skipsTombstones() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 2)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 10).lifeStatus = .invisible
        TestWindow.new(id: 3, parent: root, adaptiveWeight: 4)
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 20).lifeStatus = .deadOrInvisible

        let window = TestWindow.new(id: 4, parent: root, adaptiveWeight: WEIGHT_AUTO)
        assertEquals(window.getWeight(root.orientation), 3) // (2 + 4) / 2
    }

    func testBindWeightAuto_onlyTombstoneSiblings() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 10).lifeStatus = .dead

        let window = TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        assertEquals(window.getWeight(root.orientation), 1)
    }

    func testRootAbsorptionPreservesOrderWeightsAndMru() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let child = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        child.layout = .accordion
        let first = TestWindow.new(id: 1, parent: child, adaptiveWeight: 100)
        let second = TestWindow.new(id: 2, parent: child, adaptiveWeight: 200)
        let third = TestWindow.new(id: 3, parent: child, adaptiveWeight: 300)
        assertTrue(second.focusWindow())

        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer === root)
        XCTAssertFalse(child.isBound)
        assertEquals(root.orientation, .v)
        assertEquals(root.layout, .accordion)
        assertEquals(root.children, [first, second, third])
        assertEquals(root.children.map { $0.getWeight(root.orientation) }, [100, 200, 300])
        XCTAssertTrue(root.mostRecentChild === second)
        assertEquals(Array(root._mruChildren), [second, third, first])
    }

    func testNormalizeContainers_dontRemoveRoot() {
        let workspace = Workspace.get(byName: name)
        weak let root = workspace.rootTilingContainer
        func test() {
            XCTAssertNotEqual(root, nil)
            XCTAssertTrue(root!.isEffectivelyEmpty)
            workspace.normalizeContainers()
            XCTAssertNotEqual(root, nil)
        }
        test()

        config.enableNormalizationFlattenContainers = true
        test()
    }

    func testNormalizeContainers_singleWindowChild() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            .h_tiles([.window(0), .window(1)]),
            workspace.rootTilingContainer.layoutDescription,
        )
    }

    func testNormalizeContainers_removeEffectivelyEmpty() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                _ = TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1)
            }
        }
        assertEquals(workspace.rootTilingContainer.children.count, 1)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.children.count, 0)
    }

    func testNormalizeContainers_flattenContainers() {
        let workspace = Workspace.get(byName: name) // Don't cache root node
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            }
        }
        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer.children.singleOrNil() is TilingContainer)

        config.enableNormalizationFlattenContainers = true
        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer.children.singleOrNil() is TestWindow)
    }
}
