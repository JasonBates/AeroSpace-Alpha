@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class AdaptiveLayoutTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.adaptiveLayout.enabled = .constant(true)
    }

    func testOneTwoAndThreeColumnFramesAndRepeatedLayout() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)

        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 643.2, y: 54, width: 633.6, height: 972)
        assertRect(workspace.lastAppliedLayoutPhysicalRect, x: 643.2, y: 54, width: 633.6, height: 971)
        assertRect(try await first.getAxRect(.nonCancellable), x: 643.2, y: 54, width: 633.6, height: 971)

        let second = TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 633.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 960, y: 54, width: 633.6, height: 971)

        let third = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 54, width: 640, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 640, y: 54, width: 640, height: 971)
        assertRect(try await third.getAxRect(.nonCancellable), x: 1280, y: 54, width: 640, height: 971)

        let weights = root.children.map(\.hWeight)
        try await workspace.layoutWorkspace()
        assertEquals(root.children.map(\.hWeight), weights)
        assertRect(try await third.getAxRect(.nonCancellable), x: 1280, y: 54, width: 640, height: 971)
    }

    func testOneAndTwoRowFrames() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: root)

        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 643.2, y: 54, width: 633.6, height: 971)

        let second = TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 0, width: 1267.2, height: 539.5)
        assertRect(try await second.getAxRect(.nonCancellable), x: 326.4, y: 539.5, width: 1267.2, height: 539.5)
    }

    func testSingleColumnUsesTwoColumnWidthFromSecondStructuralRow() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)

        for row in 1 ... 8 {
            TestWindow.new(id: UInt32(row), parent: root, adaptiveWeight: row == 1 ? 1 : WEIGHT_AUTO)
            try await workspace.layoutWorkspace()
            if row >= 2 {
                assertEquals(root.tilingFootprint, TilingFootprint(columns: 1, rows: row))
                assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
            }
        }
    }

    func testTallFootprintsWithMultipleColumnsKeepTheirNormalWidthRules() {
        let available = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)

        assertRect(
            adaptiveWorkspaceRect(
                available: available,
                footprint: TilingFootprint(columns: 2, rows: 8),
                config: config.adaptiveLayout,
            ),
            x: 326.4,
            y: 0,
            width: 1267.2,
            height: 1080,
        )
        assertRect(
            adaptiveWorkspaceRect(
                available: available,
                footprint: TilingFootprint(columns: 3, rows: 8),
                config: config.adaptiveLayout,
            ),
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
        )
    }

    func testTwoAboveSpanningBottomUsesTwoByTwoBounds() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        var topLeft: Window!
        var topRight: Window!
        let top = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            topLeft = TestWindow.new(id: 1, parent: $0)
            topRight = TestWindow.new(id: 2, parent: $0)
        }
        let bottom = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)

        try await workspace.layoutWorkspace()

        assertEquals(root.tilingFootprint, TilingFootprint(columns: 2, rows: 2))
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
        assertRect(top.lastAppliedLayoutPhysicalRect, x: 326.4, y: 0, width: 1267.2, height: 539.5)
        assertRect(try await topLeft.getAxRect(.nonCancellable), x: 326.4, y: 0, width: 633.6, height: 539.5)
        assertRect(try await topRight.getAxRect(.nonCancellable), x: 960, y: 0, width: 633.6, height: 539.5)
        assertRect(try await bottom.getAxRect(.nonCancellable), x: 326.4, y: 539.5, width: 1267.2, height: 539.5)
    }

    func testTwoByTwoAndThreeByTwoFrames() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        var first: Window!
        var second: Window!
        for column in 0 ..< 2 {
            TilingContainer.newVTiles(parent: root, adaptiveWeight: column == 0 ? 1 : WEIGHT_AUTO).apply {
                let top = TestWindow.new(id: UInt32(column * 2 + 1), parent: $0)
                TestWindow.new(id: UInt32(column * 2 + 2), parent: $0, adaptiveWeight: WEIGHT_AUTO)
                if column == 0 {
                    first = top
                } else {
                    second = top
                }
            }
        }

        try await workspace.layoutWorkspace()
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 2, rows: 2))
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 0, width: 633.6, height: 539.5)
        assertRect(try await second.getAxRect(.nonCancellable), x: 960, y: 0, width: 633.6, height: 539.5)

        var fifth: Window!
        TilingContainer.newVTiles(parent: root, adaptiveWeight: WEIGHT_AUTO).apply {
            fifth = TestWindow.new(id: 5, parent: $0)
            TestWindow.new(id: 6, parent: $0, adaptiveWeight: WEIGHT_AUTO)
        }
        try await workspace.layoutWorkspace()
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 3, rows: 2))
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 0, width: 1920, height: 1080)
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 0, width: 640, height: 539.5)
        assertRect(try await second.getAxRect(.nonCancellable), x: 640, y: 0, width: 640, height: 539.5)
        assertRect(try await fifth.getAxRect(.nonCancellable), x: 1280, y: 0, width: 640, height: 539.5)
    }

    func testPendingEmptyNestedAndFloatingWindowsDoNotAffectFootprintOrReserveArea() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let active = TestWindow.new(id: 1, parent: root)
        let pendingContainer = TilingContainer.newVTiles(parent: root, adaptiveWeight: WEIGHT_AUTO)
        let pending = TestWindow.new(id: 2, parent: pendingContainer)
        pending.isAwaitingOnWindowDetected = true
        _ = TestWindow.new(
            id: 3,
            parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 10, topLeftY: 10, width: 300, height: 200),
        )

        try await workspace.layoutWorkspace()
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 1, rows: 1))
        assertRect(try await active.getAxRect(.nonCancellable), x: 643.2, y: 54, width: 633.6, height: 971)
        assertNil(pendingContainer.lastAppliedLayoutPhysicalRect)
        assertNil(try await pending.getAxRect(.nonCancellable))

        pending.isAwaitingOnWindowDetected = false
        try await workspace.layoutWorkspace()
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 2, rows: 1))
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        XCTAssertNotNil(pendingContainer.lastAppliedLayoutPhysicalRect)
    }

    func testAccordionFootprintDoesNotChangeWithFocus() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let first = TestWindow.new(id: 1, parent: root)
        let windows = (2 ... 8).map { TestWindow.new(id: UInt32($0), parent: root) }

        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        let firstBounds = workspace.lastAppliedLayoutVirtualRect
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 1, rows: 1))
        assertRect(firstBounds, x: 643.2, y: 54, width: 633.6, height: 972)

        assertTrue(windows.last.orDie().focusWindow())
        try await workspace.layoutWorkspace()
        assertEquals(root.tilingFootprint, TilingFootprint(columns: 1, rows: 1))
        assertEquals(workspace.lastAppliedLayoutVirtualRect, firstBounds)
    }

    func testNestedUnchangedSplitSurvivesThirdColumnElsewhere() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        var topLeft: Window!
        var topRight: Window!
        let top = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            topLeft = TestWindow.new(id: 1, parent: $0)
            topRight = TestWindow.new(id: 2, parent: $0)
        }
        let bottom = TilingContainer.newHTiles(parent: root, adaptiveWeight: WEIGHT_AUTO).apply {
            TestWindow.new(id: 3, parent: $0)
            TestWindow.new(id: 4, parent: $0, adaptiveWeight: WEIGHT_AUTO)
        }
        try await workspace.layoutWorkspace()
        topLeft.hWeight = 887.04
        topRight.hWeight = 380.16
        try await workspace.layoutWorkspace()

        TestWindow.new(id: 5, parent: bottom, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()

        assertEquals(root.tilingFootprint, TilingFootprint(columns: 3, rows: 2))
        assertRect(try await topLeft.getAxRect(.nonCancellable), x: 0, y: 0, width: 1344, height: 539.5)
        assertRect(try await topRight.getAxRect(.nonCancellable), x: 1344, y: 0, width: 576, height: 539.5)
        assertEquals(top.children.map(\.hWeight), [1344, 576])
    }

    func testExpandedGappedPairSurvivesAddingSpanningBottomAndRepeatedLayout() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        config.gaps.inner.horizontal = .constant(20)
        var topLeft: Window!
        var topRight: Window!
        TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            topLeft = TestWindow.new(id: 1, parent: $0)
            topRight = TestWindow.new(id: 2, parent: $0)
        }
        try await workspace.layoutWorkspace()
        assertTrue(topLeft.focusWindow())

        _ = await parseCommand("resize width +500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 198.12, y: 54, width: 1523.76, height: 972)
        let expandedTopLeft = try await topLeft.getAxRect(.nonCancellable).orDie()
        let expandedTopRight = try await topRight.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(expandedTopLeft.width, 1123.6, accuracy: 0.001)
        XCTAssertEqual(expandedTopRight.width, 380.16, accuracy: 0.001)

        let bottom = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 198.12, y: 0, width: 1523.76, height: 1080)
        assertRect(try await topLeft.getAxRect(.nonCancellable), x: 198.12, y: 0, width: 1123.6, height: 539.5)
        assertRect(try await topRight.getAxRect(.nonCancellable), x: 1341.72, y: 0, width: 380.16, height: 539.5)
        assertRect(try await bottom.getAxRect(.nonCancellable), x: 198.12, y: 539.5, width: 1523.76, height: 539.5)
        let firstFrames = try await frames(of: [topLeft, topRight, bottom])
        let firstWeights = root.children.map(\.vWeight)

        try await workspace.layoutWorkspace()

        assertEquals(try await frames(of: [topLeft, topRight, bottom]), firstFrames)
        assertEquals(root.children.map(\.vWeight), firstWeights)
    }

    func testAddingThirdColumnReconcilesExpandedPairWithoutViolatingMinimums() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        assertTrue(first.focusWindow())
        _ = await parseCommand("resize width +500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        let third = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()

        let minimum = adaptiveMinimumWindowPhysicalWidth(availableWidth: 1920, config: config.adaptiveLayout)
        let framesAfterAdd = try await frames(of: [first, second, third]).compactMap { $0 }
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
        XCTAssertTrue(framesAfterAdd.allSatisfy { $0.width >= minimum - 0.001 })
        XCTAssertGreaterThan(framesAfterAdd[0].width, 633.6)
        let weightsAfterAdd = root.children.map(\.hWeight)

        try await workspace.layoutWorkspace()
        for (actual, expected) in zip(root.children.map(\.hWeight), weightsAfterAdd) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        let framesAfterSecondLayout = try await frames(of: [first, second, third]).compactMap { $0 }
        for (actual, expected) in zip(framesAfterSecondLayout, framesAfterAdd) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000_001)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001)
        }

        third.unbindFromParent()
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        let firstAfterClose = try await first.getAxRect(.nonCancellable).orDie()
        let secondAfterClose = try await second.getAxRect(.nonCancellable).orDie()
        XCTAssertGreaterThanOrEqual(firstAfterClose.width, minimum - 0.001)
        XCTAssertGreaterThanOrEqual(secondAfterClose.width, minimum - 0.001)
    }

    func testEnablingAndDisablingPreservesExistingSplit() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.adaptiveLayout.enabled = .constant(false)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        first.hWeight = 1344
        second.hWeight = 576
        try await workspace.layoutWorkspace()

        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 887.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1213.44, y: 54, width: 380.16, height: 971)

        config.adaptiveLayout.enabled = .constant(false)
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 0, width: 1344, height: 1079)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1344, y: 0, width: 576, height: 1079)
    }

    func testKeyboardResizeUsesLiveWeightsWhenAdaptiveAreaChanges() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertTrue(first.focusWindow())
        assertEquals((await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        let resizedRatio = first.hWeight / CGFloat(root.children.sumOfDouble { $0.hWeight })

        config.adaptiveLayout.twoColumnWidthPercent = 80
        try await workspace.layoutWorkspace()

        assertEquals(first.hWeight / 1536, resizedRatio)
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 192, y: 54, width: 1536, height: 972)
    }

    func testKeyboardResizeShrinksDonorToMinimumThenExpandsAndContractsWorkspace() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()

        _ = await parseCommand("resize width +200").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 833.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1160, y: 54, width: 433.6, height: 971)

        XCTAssertNotNil(resizeAdaptiveHorizontally(
            node: first,
            parent: root,
            requestedPhysicalWidth: 887.04,
            workspace: workspace,
        ))
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 887.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1213.44, y: 54, width: 380.16, height: 971)

        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 276.4, y: 54, width: 1367.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 276.4, y: 54, width: 987.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1263.44, y: 54, width: 380.16, height: 971)
        let expandedWeights = root.children.map(\.hWeight)
        try await workspace.layoutWorkspace()
        assertEquals(root.children.map(\.hWeight), expandedWeights)

        _ = await parseCommand("resize width -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 887.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1213.44, y: 54, width: 380.16, height: 971)

        _ = await parseCommand("resize width -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 787.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1113.44, y: 54, width: 480.16, height: 971)
    }

    func testKeyboardResizeClampsAtScreenEdge() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()

        _ = await parseCommand("resize width +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 54, width: 1539.84, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1539.84, y: 54, width: 380.16, height: 971)
    }

    func testChainedAdaptiveResizeCommandsUseLiveIntendedWidthBeforeLayout() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()

        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 833.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1160, y: 54, width: 433.6, height: 971)

        _ = await parseCommand("resize smart 800").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = await parseCommand("resize width -50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 750, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1076.4, y: 54, width: 517.2, height: 971)
    }

    func testResizeInOneRowHonoursWidthRequiredByAnotherRow() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        var topLeft: Window!
        var topRight: Window!
        var bottomLeft: Window!
        var bottomRight: Window!
        TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            topLeft = TestWindow.new(id: 1, parent: $0)
            topRight = TestWindow.new(id: 2, parent: $0)
        }
        TilingContainer.newHTiles(parent: root, adaptiveWeight: WEIGHT_AUTO).apply {
            bottomLeft = TestWindow.new(id: 3, parent: $0)
            bottomRight = TestWindow.new(id: 4, parent: $0)
        }
        try await workspace.layoutWorkspace()
        topLeft.hWeight = 1119.84
        topRight.hWeight = 380.16
        bottomLeft.hWeight = 380.16
        bottomRight.hWeight = 1119.84
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 210, y: 0, width: 1500, height: 1080)
        assertTrue(topLeft.focusWindow())

        _ = await parseCommand("resize width -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 210, y: 0, width: 1500, height: 1080)
        assertRect(try await topLeft.getAxRect(.nonCancellable), x: 210, y: 0, width: 1019.84, height: 539.5)
        assertRect(try await topRight.getAxRect(.nonCancellable), x: 1229.84, y: 0, width: 480.16, height: 539.5)
        assertRect(try await bottomRight.getAxRect(.nonCancellable), x: 590.16, y: 539.5, width: 1119.84, height: 539.5)
    }

    func testGrowingSmallSideOfExpandedPairContractsToMinimumFeasibleWorkspace() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 1119.84
        second.hWeight = 380.16
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 210, y: 54, width: 1500, height: 972)
        assertTrue(second.focusWindow())

        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 787.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1113.44, y: 54, width: 480.16, height: 971)
    }

    func testThreeColumnsRedistributeEquallyAndSaturateDonors() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 400
        second.hWeight = 390
        third.hWeight = 1130
        try await workspace.layoutWorkspace()
        assertTrue(first.focusWindow())

        _ = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 54, width: 500, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 500, y: 54, width: 380.16, height: 971)
        assertRect(try await third.getAxRect(.nonCancellable), x: 880.16, y: 54, width: 1039.84, height: 971)

        assertTrue(second.focusWindow())
        _ = await parseCommand("resize width +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let firstFrame = try await first.getAxRect(.nonCancellable)
        let thirdFrame = try await third.getAxRect(.nonCancellable)
        XCTAssertGreaterThan(firstFrame?.width ?? 0, 0)
        XCTAssertGreaterThan(thirdFrame?.width ?? 0, 0)
        assertRect(try await second.getAxRect(.nonCancellable), x: 380.16, y: 54, width: 1159.68, height: 971)
    }

    func testRepeatedResizeOnRepresentativeNestedTreeStaysFiniteAndReportsTiming() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        var target: Window!
        var targetParent: TilingContainer!
        for row in 0 ..< 4 {
            TilingContainer.newHTiles(parent: root, adaptiveWeight: row == 0 ? 1 : WEIGHT_AUTO).apply { container in
                for column in 0 ..< 4 {
                    let window = TestWindow.new(
                        id: UInt32(row * 4 + column + 1),
                        parent: container,
                        adaptiveWeight: column == 0 ? 1 : WEIGHT_AUTO,
                    )
                    if row == 0, column == 0 {
                        target = window
                        targetParent = container
                    }
                }
            }
        }
        try await workspace.layoutWorkspace()

        let iterations = 1000
        let start = ContinuousClock.now
        var allResizesSucceeded = true
        for index in 0 ..< iterations {
            allResizesSucceeded = resizeAdaptiveHorizontally(
                node: target,
                parent: targetParent,
                requestedPhysicalWidth: index.isMultiple(of: 2) ? 500 : 700,
                workspace: workspace,
            ) != nil && allResizesSucceeded
        }
        let elapsed = start.duration(to: .now)
        print("adaptive nested resize benchmark: loops=\(iterations) nodes=21 elapsed=\(elapsed)")
        XCTAssertTrue(allResizesSucceeded)

        try await workspace.layoutWorkspace()
        XCTAssertTrue(root.allLeafWindowsRecursive.allSatisfy {
            $0.lastAppliedLayoutPhysicalRect?.width.isFinite == true &&
                ($0.lastAppliedLayoutPhysicalRect?.width ?? 0) > 0
        })
    }

    func testBalanceSizesContractsExpandedWorkspaceToNormalBounds() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        _ = await parseCommand("resize width +500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        XCTAssertGreaterThan(workspace.lastAppliedLayoutVirtualRect?.width ?? 0, 1267.2)

        _ = await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 633.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 960, y: 54, width: 633.6, height: 971)
    }

    func testChangedTopologyShrinkCannotCollapsePositiveChild() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 1632
        second.hWeight = 192
        third.hWeight = 96
        try await workspace.layoutWorkspace()

        third.unbindFromParent()
        try await workspace.layoutWorkspace()

        XCTAssertGreaterThan(second.hWeight, 0)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 887.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1213.44, y: 54, width: 380.16, height: 971)
    }

    func testAdaptiveBoundsKeepOuterAndInnerGapsOnOffsetMonitor() async throws {
        let monitor = AdaptiveTestMonitor(name: "DELL U3225QE", x: 2000, y: 100, isMain: true)
        monitorInfosForTests = [monitor]
        let workspace = focus.workspace
        assertTrue(monitor.setActiveWorkspace(workspace))
        config.gaps = Gaps(
            inner: .init(vertical: 0, horizontal: 10),
            outer: .init(left: 20, bottom: 50, top: 30, right: 40),
        )
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)

        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 2336.2, y: 180, width: 1227.6, height: 900)
        assertRect(workspace.lastAppliedLayoutPhysicalRect, x: 2336.2, y: 180, width: 1227.6, height: 899)
        assertRect(try await first.getAxRect(.nonCancellable), x: 2336.2, y: 180, width: 608.8, height: 899)
        assertRect(try await second.getAxRect(.nonCancellable), x: 2955, y: 180, width: 608.8, height: 899)
    }

    func testChangedTopologyShrinkAccountsForInnerGapBeforeAChildCollapses() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.gaps.inner.horizontal = .constant(60)
        let first = TestWindow.new(id: 1, parent: root)
        let removed = TestWindow.new(id: 2, parent: root)
        let last = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 1245
        removed.hWeight = 640
        last.hWeight = 35
        try await workspace.layoutWorkspace()

        removed.unbindFromParent()
        try await workspace.layoutWorkspace()

        let lastFrame = try await last.getAxRect(.nonCancellable)
        XCTAssertGreaterThan(last.hWeight, 30)
        XCTAssertGreaterThan(lastFrame?.width ?? 0, 0)
    }

    func testAreaScalingReservesInnerGapForNarrowPositiveTileAndStaysStableAfterRoundTrip() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.adaptiveLayout.enabled = .constant(false)
        config.gaps.inner.horizontal = .constant(20)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 1905
        second.hWeight = 15
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 0, width: 1895, height: 1079)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1915, y: 0, width: 5, height: 1079)

        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()
        let adaptiveWeights = root.children.map(\.hWeight)
        XCTAssertEqual(adaptiveWeights[0], 877.04, accuracy: 0.001)
        XCTAssertEqual(adaptiveWeights[1], 390.16, accuracy: 0.001)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 867.04, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1213.44, y: 54, width: 380.16, height: 971)

        config.adaptiveLayout.enabled = .constant(false)
        try await workspace.layoutWorkspace()
        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()

        XCTAssertEqual(root.children[0].hWeight, adaptiveWeights[0], accuracy: 0.001)
        XCTAssertEqual(root.children[1].hWeight, adaptiveWeights[1], accuracy: 0.001)
        let secondFrame = try await second.getAxRect(.nonCancellable)
        XCTAssertGreaterThan(secondFrame?.width ?? 0, 0)
    }

    func testAreaScalingKeepsRawWeightRatioWhenInnerGapDoesNotCollapseAChild() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.adaptiveLayout.enabled = .constant(false)
        config.gaps.inner.horizontal = .constant(20)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        first.hWeight = 1280
        second.hWeight = 640
        try await workspace.layoutWorkspace()

        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()

        XCTAssertEqual(first.hWeight, 844.8, accuracy: 0.001)
        XCTAssertEqual(second.hWeight, 422.4, accuracy: 0.001)
    }

    func testImpossibleInnerGapStillProducesFiniteWeightsAndFrames() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.adaptiveLayout.enabled = .constant(false)
        config.gaps.inner.horizontal = .constant(2000)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()

        XCTAssertTrue(root.children.allSatisfy { $0.hWeight.isFinite })
        let firstFrame = try await first.getAxRect(.nonCancellable)
        let secondFrame = try await second.getAxRect(.nonCancellable)
        XCTAssertTrue(firstFrame?.width.isFinite == true)
        XCTAssertTrue(secondFrame?.width.isFinite == true)
    }

    func testImpossibleMinimumsOnNarrowMonitorDegradeToPositiveFiniteFramesInsideScreen() async throws {
        let narrow = AdaptiveTestMonitor(
            name: "Narrow",
            x: 400,
            isMain: true,
            monitorWidth: 1200,
        )
        monitorInfosForTests = [narrow]
        let workspace = focus.workspace
        assertTrue(narrow.setActiveWorkspace(workspace))
        let windows = (1 ... 6).map { TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }

        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 400, y: 54, width: 1200, height: 972)
        for frame in try await frames(of: windows).compactMap({ $0 }) {
            XCTAssertTrue(frame.width.isFinite)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, narrow.visibleRect.minX)
            XCTAssertLessThanOrEqual(frame.maxX, narrow.visibleRect.maxX + 0.001)
        }
    }

    func testHorizontalAccordionIsAnOpaqueRecursiveMinimumDuringResize() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let accordion = TilingContainer(
            parent: root,
            adaptiveWeight: 1,
            .h,
            .accordion,
            index: INDEX_BIND_LAST,
        )
        let accordionWindows = (1 ... 3).map { TestWindow.new(id: UInt32($0), parent: accordion) }
        let sibling = TestWindow.new(id: 4, parent: root)
        try await workspace.layoutWorkspace()
        assertTrue(accordionWindows[1].focusWindow())

        _ = await parseCommand("resize width +500").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        XCTAssertEqual(accordion.hWeight, 1133.6, accuracy: 0.001)
        XCTAssertEqual(sibling.hWeight, 380.16, accuracy: 0.001)
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 203.12, y: 54, width: 1513.76, height: 972)
        let accordionFrames = try await frames(of: accordionWindows).compactMap { $0 }
        XCTAssertTrue(accordionFrames.allSatisfy { $0.width > 0 })
    }

    func testAdaptiveLoneWindowWidthAndSmartResizeApplyOnNextLayout() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())
        try await workspace.layoutWorkspace()

        let widthResult = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(widthResult.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 593.2, y: 54, width: 733.6, height: 971)

        let smartResult = await parseCommand("resize smart -50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(smartResult.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 618.2, y: 54, width: 683.6, height: 971)
    }

    func testAdaptiveMultirowHeightResizeAppliesOnNextLayout() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()

        let result = await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()

        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 0, width: 1267.2, height: 639.5)
        assertRect(try await second.getAxRect(.nonCancellable), x: 326.4, y: 639.5, width: 1267.2, height: 439.5)
    }

    func testVerticalMinimumAppliesToTwoThreeAndFourStacksOnAdaptiveAndNormalDisplays() async throws {
        for adaptiveEnabled in [false, true] {
            for count in 2 ... 4 {
                setUpWorkspacesForTests()
                config.adaptiveLayout.enabled = .constant(adaptiveEnabled)
                config.gaps.inner.vertical = .constant(20)
                let workspace = focus.workspace
                workspace.rootTilingContainer.changeOrientation(.v)
                let windows = (1 ... count).map {
                    TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer)
                }

                try await workspace.layoutWorkspace()

                let laidOut = try await frames(of: windows).compactMap { $0 }
                XCTAssertEqual(laidOut.count, count)
                XCTAssertTrue(laidOut.allSatisfy { $0.height >= 200 })
                for pair in zip(laidOut, laidOut.dropFirst()) {
                    XCTAssertEqual(pair.1.minY - pair.0.maxY, 20, accuracy: 0.001)
                }
            }
        }
    }

    func testVerticalMinimumReducesInnerGapBeforeWindowFloor() async throws {
        let monitor = AdaptiveTestMonitor(
            name: "Short",
            x: 0,
            isMain: true,
            monitorWidth: 800,
            monitorHeight: 411,
        )
        monitorInfosForTests = [monitor]
        let workspace = focus.workspace
        assertTrue(monitor.setActiveWorkspace(workspace))
        config.gaps.inner.vertical = .constant(30)
        workspace.rootTilingContainer.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        try await workspace.layoutWorkspace()

        assertRect(try await first.getAxRect(.nonCancellable), x: 136, y: 0, width: 528, height: 200)
        assertRect(try await second.getAxRect(.nonCancellable), x: 136, y: 210, width: 528, height: 200)
    }

    func testImpossibleVerticalMinimumsStayPositiveAndInsideBounds() async throws {
        let monitor = AdaptiveTestMonitor(
            name: "Short",
            x: 0,
            isMain: true,
            monitorWidth: 800,
            monitorHeight: 411,
        )
        monitorInfosForTests = [monitor]
        let workspace = focus.workspace
        assertTrue(monitor.setActiveWorkspace(workspace))
        config.gaps.inner.vertical = .constant(30)
        workspace.rootTilingContainer.changeOrientation(.v)
        let windows = (1 ... 4).map {
            TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer)
        }

        try await workspace.layoutWorkspace()

        let laidOut = try await frames(of: windows).compactMap { $0 }
        XCTAssertTrue(laidOut.allSatisfy { $0.height > 0 })
        XCTAssertGreaterThanOrEqual(laidOut.first.orDie().minY, 0)
        XCTAssertLessThanOrEqual(laidOut.last.orDie().maxY, 410.001)
        for pair in zip(laidOut, laidOut.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.maxY, pair.1.minY + 0.001)
        }
    }

    func testMouseVerticalShrinkClampsAtFloorFromBothDividerEdges() async throws {
        for lowerEdge in [true, false] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(true)
            let workspace = focus.workspace
            workspace.rootTilingContainer.changeOrientation(.v)
            TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
            let middle = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
            TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
            try await workspace.layoutWorkspace()
            let baseline = try await middle.getAxRect(.nonCancellable).orDie()
            let observed = lowerEdge
                ? Rect(topLeftX: baseline.minX, topLeftY: baseline.minY, width: baseline.width, height: 20)
                : Rect(topLeftX: baseline.minX, topLeftY: baseline.maxY - 20, width: baseline.width, height: 20)
            middle.setAxFrame(observed.topLeftCorner, observed.size)

            try await resizeWithMouse(middle)

            let clamped = try await middle.getAxRect(.nonCancellable).orDie()
            XCTAssertEqual(clamped.height, 200, accuracy: 0.001)
            if lowerEdge {
                XCTAssertEqual(clamped.minY, baseline.minY, accuracy: 0.001)
            } else {
                XCTAssertEqual(clamped.maxY, baseline.maxY, accuracy: 0.001)
            }
            try await resetManipulatedWithMouseIfPossible()
        }
    }

    func testMouseVerticalGrowthStopsWhenDonorReachesFloor() async throws {
        let workspace = focus.workspace
        workspace.rootTilingContainer.changeOrientation(.v)
        let top = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let bottom = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        top.vWeight = 829
        bottom.vWeight = 250
        try await workspace.layoutWorkspace()
        let baseline = try await top.getAxRect(.nonCancellable).orDie()
        top.setAxFrame(nil, CGSize(width: baseline.width, height: baseline.height + 100))

        try await resizeWithMouse(top)

        XCTAssertEqual(top.vWeight, 879, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 200, accuracy: 0.001)
        let clamped = try await top.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(clamped.minY, baseline.minY, accuracy: 0.001)
        XCTAssertEqual(clamped.height, baseline.height + 50, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testMouseVerticalGestureReversalUsesImmutableBaselineAcrossRelayout() async throws {
        let workspace = focus.workspace
        workspace.rootTilingContainer.changeOrientation(.v)
        let top = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let bottom = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let baseline = try await top.getAxRect(.nonCancellable).orDie()
        top.setAxFrame(nil, CGSize(width: baseline.width, height: baseline.height + 50))
        try await resizeWithMouse(top)
        XCTAssertEqual(top.vWeight, 589.5, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 489.5, accuracy: 0.001)
        try await workspace.layoutWorkspace()

        top.setAxFrame(baseline.topLeftCorner, baseline.size)
        try await resizeWithMouse(top)

        XCTAssertEqual(top.vWeight, 539.5, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 539.5, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testBalanceSizesDuringMouseGestureRefusesQueuedEventThenAllowsNewGesture() async throws {
        let workspace = focus.workspace
        workspace.rootTilingContainer.changeOrientation(.v)
        let top = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let bottom = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertTrue(top.focusWindow())
        try await workspace.layoutWorkspace()
        let baseline = try await top.getAxRect(.nonCancellable).orDie()
        top.setAxFrame(nil, CGSize(width: baseline.width, height: baseline.height + 50))
        try await resizeWithMouse(top)

        _ = await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        top.setAxFrame(nil, CGSize(width: baseline.width, height: baseline.height + 50))
        try await resizeWithMouse(top) // Queued notification from the cancelled gesture.
        XCTAssertEqual(top.vWeight, bottom.vWeight, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()

        try await workspace.layoutWorkspace()
        let resetFrame = try await top.getAxRect(.nonCancellable).orDie()
        top.setAxFrame(nil, CGSize(width: resetFrame.width, height: resetFrame.height + 50))
        try await resizeWithMouse(top)
        XCTAssertGreaterThan(top.vWeight, bottom.vWeight)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testMouseWidthResizeSurvivesAdaptiveAreaChange() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let firstFrame = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: firstFrame.width + 100, height: firstFrame.height))

        try await resizeWithMouse(first)
        assertEquals(first.hWeight, 733.6)
        assertEquals(second.hWeight, 533.6)
        currentlyManipulatedWithMouseWindowId = nil
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 733.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1060, y: 54, width: 533.6, height: 971)

        let resizedRatio = first.hWeight / CGFloat(root.children.sumOfDouble { $0.hWeight })
        config.adaptiveLayout.twoColumnWidthPercent = 80
        try await workspace.layoutWorkspace()
        XCTAssertEqual(first.hWeight / 1536, resizedRatio, accuracy: 0.000_001)
        XCTAssertEqual(second.hWeight / 1536, 1 - resizedRatio, accuracy: 0.000_001)
    }

    func testAdaptiveMouseRightEdgeUsesGestureBaselineReversesAndRestoresClampedActualFrame() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()

        first.setAxFrame(nil, CGSize(width: baseline.width + 3, height: baseline.height))
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [633.6, 633.6])

        first.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [733.6, 533.6])

        first.setAxFrame(nil, CGSize(width: baseline.width + 200, height: baseline.height))
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [833.6, 433.6])

        first.setAxFrame(baseline.topLeftCorner, baseline.size)
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [633.6, 633.6])

        first.setAxFrame(nil, CGSize(width: baseline.width - 50, height: baseline.height))
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [583.6, 683.6])

        first.setAxFrame(nil, CGSize(width: 100, height: baseline.height))
        try await resizeWithMouse(first)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 380.16, height: 971)
        XCTAssertEqual(first.hWeight, 380.16, accuracy: 0.001)

        first.setAxFrame(nil, CGSize(width: baseline.width + 10000, height: baseline.height))
        try await resizeWithMouse(first)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1593.6, height: 972)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1539.84, y: 54, width: 380.16, height: 971)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 1213.44, height: 971)

        try await resetManipulatedWithMouseIfPossible()
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 163.2, y: 54, width: 1593.6, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 163.2, y: 54, width: 1213.44, height: 971)

        let secondGestureBaseline = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: secondGestureBaseline.width - 100, height: secondGestureBaseline.height))
        try await resizeWithMouse(first)
        XCTAssertEqual(first.hWeight, 1113.44, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testAdaptiveMouseLeftEdgeKeepsRightEdgeFixedThroughZeroAndReversalThenRecentres() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()

        first.setAxFrame(
            CGPoint(x: baseline.minX - 100, y: baseline.minY),
            CGSize(width: baseline.width + 100, height: baseline.height),
        )
        try await resizeWithMouse(first)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 226.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 226.4, y: 54, width: 733.6, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 960, y: 54, width: 533.6, height: 971)

        first.setAxFrame(baseline.topLeftCorner, baseline.size)
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), [633.6, 633.6])

        first.setAxFrame(
            CGPoint(x: baseline.minX + 50, y: baseline.minY),
            CGSize(width: baseline.width - 50, height: baseline.height),
        )
        try await resizeWithMouse(first)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 376.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await second.getAxRect(.nonCancellable), x: 960, y: 54, width: 683.6, height: 971)

        try await resetManipulatedWithMouseIfPossible()
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 583.6, height: 971)
    }

    func testAdaptiveMouseMiddleWindowKeepsOppositeEdgeAtFullWidthInBothDirections() async throws {
        for edge in [AdaptiveHorizontalResizeAnchorEdge.minX, .maxX] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(true)
            let workspace = focus.workspace
            let root = workspace.rootTilingContainer
            let first = TestWindow.new(id: 1, parent: root)
            let middle = TestWindow.new(id: 2, parent: root)
            let third = TestWindow.new(id: 3, parent: root)
            try await workspace.layoutWorkspace()
            let baseline = try await middle.getAxRect(.nonCancellable).orDie()

            switch edge {
                case .minX:
                    middle.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
                case .maxX:
                    middle.setAxFrame(
                        CGPoint(x: baseline.minX - 100, y: baseline.minY),
                        CGSize(width: baseline.width + 100, height: baseline.height),
                    )
            }
            try await resizeWithMouse(middle)
            try await workspace.layoutWorkspace()

            let firstFrame = try await first.getAxRect(.nonCancellable).orDie()
            let middleFrame = try await middle.getAxRect(.nonCancellable).orDie()
            let thirdFrame = try await third.getAxRect(.nonCancellable).orDie()
            assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
            XCTAssertEqual(middleFrame.width, 740, accuracy: 0.001)
            switch edge {
                case .minX:
                    XCTAssertEqual(middleFrame.minX, baseline.minX, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.maxX, middleFrame.minX, accuracy: 0.001)
                    XCTAssertEqual(middleFrame.maxX, thirdFrame.minX, accuracy: 0.001)
                case .maxX:
                    XCTAssertEqual(middleFrame.maxX, baseline.maxX, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.maxX, middleFrame.minX, accuracy: 0.001)
                    XCTAssertEqual(middleFrame.maxX, thirdFrame.minX, accuracy: 0.001)
            }

            switch edge {
                case .minX:
                    middle.setAxFrame(nil, CGSize(width: baseline.width + 400, height: baseline.height))
                case .maxX:
                    middle.setAxFrame(
                        CGPoint(x: baseline.minX - 400, y: baseline.minY),
                        CGSize(width: baseline.width + 400, height: baseline.height),
                    )
            }
            try await resizeWithMouse(middle)
            try await workspace.layoutWorkspace()
            let cappedFirst = try await first.getAxRect(.nonCancellable).orDie()
            let cappedMiddle = try await middle.getAxRect(.nonCancellable).orDie()
            let cappedThird = try await third.getAxRect(.nonCancellable).orDie()
            XCTAssertEqual(cappedMiddle.width, 899.84, accuracy: 0.001)
            XCTAssertEqual(cappedFirst.maxX, cappedMiddle.minX, accuracy: 0.001)
            XCTAssertEqual(cappedMiddle.maxX, cappedThird.minX, accuracy: 0.001)

            switch edge {
                case .minX:
                    middle.setAxFrame(nil, CGSize(width: baseline.width + 50, height: baseline.height))
                case .maxX:
                    middle.setAxFrame(
                        CGPoint(x: baseline.minX - 50, y: baseline.minY),
                        CGSize(width: baseline.width + 50, height: baseline.height),
                    )
            }
            try await resizeWithMouse(middle)
            try await workspace.layoutWorkspace()
            let reversedMiddle = try await middle.getAxRect(.nonCancellable).orDie()
            let reversedThird = try await third.getAxRect(.nonCancellable).orDie()
            XCTAssertEqual(reversedMiddle.width, 690, accuracy: 0.001)
            XCTAssertEqual(reversedMiddle.maxX, reversedThird.minX, accuracy: 0.001)

            switch edge {
                case .minX:
                    middle.setAxFrame(nil, CGSize(width: baseline.width + 400, height: baseline.height))
                case .maxX:
                    middle.setAxFrame(
                        CGPoint(x: baseline.minX - 400, y: baseline.minY),
                        CGSize(width: baseline.width + 400, height: baseline.height),
                    )
            }
            try await resizeWithMouse(middle)
            try await workspace.layoutWorkspace()
            let recappedMiddle = try await middle.getAxRect(.nonCancellable).orDie()
            XCTAssertEqual(recappedMiddle.width, 899.84, accuracy: 0.001)
            try await resetManipulatedWithMouseIfPossible()
            try await workspace.layoutWorkspace()
            assertEquals(try await middle.getAxRect(.nonCancellable), middle.lastAppliedLayoutPhysicalRect)
        }
    }

    func testAdaptiveMouseNestedGappedTargetKeepsFixedEdgeAndNeighbourGap() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        config.gaps.inner.horizontal = .constant(20)
        var top: Window!
        var bottom: Window!
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            top = TestWindow.new(id: 1, parent: $0)
            bottom = TestWindow.new(id: 2, parent: $0)
        }
        let right = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await top.getAxRect(.nonCancellable).orDie()

        top.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(top)
        try await workspace.layoutWorkspace()

        let topFrame = try await top.getAxRect(.nonCancellable).orDie()
        let bottomFrame = try await bottom.getAxRect(.nonCancellable).orDie()
        let rightFrame = try await right.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(topFrame.minX, baseline.minX, accuracy: 0.001)
        XCTAssertEqual(topFrame.width, 723.6, accuracy: 0.001)
        XCTAssertEqual(bottomFrame.width, 723.6, accuracy: 0.001)
        XCTAssertEqual(rightFrame.minX - topFrame.maxX, 20, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testAdaptiveMouseClampRefusalGuardRetriesOnlyAfterHorizontalInputChanges() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()

        first.setAxFrame(nil, CGSize(width: baseline.width + 10000, height: baseline.height))
        first.rejectAxFrameChangesForTest = true
        let callsBeforeClamp = first.setAxFrameCallCountForTest
        try await resizeWithMouse(first)
        XCTAssertEqual(first.setAxFrameCallCountForTest, callsBeforeClamp + 1)
        try await resizeWithMouse(first)
        XCTAssertEqual(first.setAxFrameCallCountForTest, callsBeforeClamp + 1)

        let refusedFrame = try await first.getAxRect(.nonCancellable).orDie()
        first.rejectAxFrameChangesForTest = false
        first.setAxFrame(
            CGPoint(x: refusedFrame.minX, y: refusedFrame.minY - 20),
            CGSize(width: refusedFrame.width, height: refusedFrame.height + 20),
        )
        first.rejectAxFrameChangesForTest = true
        let callsAfterVerticalChange = first.setAxFrameCallCountForTest
        try await resizeWithMouse(first)
        XCTAssertEqual(first.setAxFrameCallCountForTest, callsAfterVerticalChange + 1)

        first.rejectAxFrameChangesForTest = false
        first.setAxFrame(nil, CGSize(width: baseline.width + 9000, height: baseline.height))
        try await resizeWithMouse(first)
        let callsAfterSuccessfulClamp = first.setAxFrameCallCountForTest
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 1213.44, height: 971)

        try await resizeWithMouse(first)
        first.setAxFrame(nil, CGSize(width: baseline.width + 10000, height: baseline.height))
        try await resizeWithMouse(first)
        XCTAssertEqual(first.setAxFrameCallCountForTest, callsAfterSuccessfulClamp + 2)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testAdaptiveMouseTopologyInvalidationDoesNotMutateNewNodeAndReleaseRestoresActualFrame() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(first)

        let third = TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)
        let weightsAfterTopologyChange = root.children.map(\.hWeight)
        first.setAxFrame(nil, CGSize(width: baseline.width + 200, height: baseline.height))
        try await resizeWithMouse(first)
        try await resizeWithMouse(first)
        assertEquals(root.children.map(\.hWeight), weightsAfterTopologyChange)
        XCTAssertEqual(third.hWeight, weightsAfterTopologyChange[2], accuracy: 0.001)

        try await resetManipulatedWithMouseIfPossible()
        try await workspace.layoutWorkspace()
        let restoredFirst = try await first.getAxRect(.nonCancellable).orDie()
        let restoredSecond = try await second.getAxRect(.nonCancellable).orDie()
        assertEquals(restoredFirst, first.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(restoredFirst.width, baseline.width + 200)
        XCTAssertGreaterThan(restoredSecond.width, 0)
    }

    func testAdaptiveMouseInvalidationSuppressesLaterLegacyWidthEvents() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(first)
        let adaptiveWeights = root.children.map(\.hWeight)

        config.adaptiveLayout.enabled = .constant(false)
        first.setAxFrame(nil, CGSize(width: baseline.width + 200, height: baseline.height))
        try await resizeWithMouse(first)
        first.setAxFrame(nil, CGSize(width: baseline.width + 300, height: baseline.height))
        try await resizeWithMouse(first)

        assertEquals(root.children.map(\.hWeight), adaptiveWeights)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testAdaptiveMouseFocusActivationSuppressesLaterGestureEvents() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(first)
        let adaptiveWeights = root.children.map(\.hWeight)

        let startedFocusMode = await FocusMode.shared.start(window: first, workspace: workspace, stayOnMonitor: true)
        assertTrue(startedFocusMode)
        first.setAxFrame(nil, CGSize(width: baseline.width + 200, height: baseline.height))
        try await resizeWithMouse(first)
        first.setAxFrame(nil, CGSize(width: baseline.width + 300, height: baseline.height))
        try await resizeWithMouse(first)

        assertEquals(root.children.map(\.hWeight), adaptiveWeights)
        FocusMode.shared.stop()
        try await resetManipulatedWithMouseIfPossible()
    }

    func testAdaptiveMouseDisplayInvalidationRestoresWindowOnDestinationMonitor() async throws {
        let wide = AdaptiveTestMonitor(name: "Wide", x: 0, isMain: true)
        let narrow = AdaptiveTestMonitor(
            name: "Narrow",
            x: 1920,
            isMain: false,
            monitorWidth: 1200,
        )
        monitorInfosForTests = [wide, narrow]
        let workspace = focus.workspace
        assertTrue(wide.setActiveWorkspace(workspace))
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let baseline = try await first.getAxRect(.nonCancellable).orDie()
        first.setAxFrame(nil, CGSize(width: baseline.width + 100, height: baseline.height))
        try await resizeWithMouse(first)
        let gestureWeights = workspace.rootTilingContainer.children.map(\.hWeight)

        assertTrue(narrow.setActiveWorkspace(workspace))
        first.setAxFrame(nil, CGSize(width: baseline.width + 200, height: baseline.height))
        try await resizeWithMouse(first)
        try await resizeWithMouse(first)
        assertEquals(workspace.rootTilingContainer.children.map(\.hWeight), gestureWeights)

        try await resetManipulatedWithMouseIfPossible()
        try await workspace.layoutWorkspace()
        let restored = try await first.getAxRect(.nonCancellable).orDie()
        assertEquals(restored, first.lastAppliedLayoutPhysicalRect)
        XCTAssertGreaterThanOrEqual(restored.minX, narrow.visibleRect.minX)
        XCTAssertLessThanOrEqual(restored.maxX, narrow.visibleRect.maxX)
    }

    func testExpandedWorkspaceContractsSafelyWhenMovedToSmallerMonitor() async throws {
        let wide = AdaptiveTestMonitor(name: "Wide", x: 0, isMain: true)
        let narrow = AdaptiveTestMonitor(
            name: "Narrow",
            x: 1920,
            isMain: false,
            monitorWidth: 1200,
        )
        monitorInfosForTests = [wide, narrow]
        let workspace = focus.workspace
        assertTrue(wide.setActiveWorkspace(workspace))
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        _ = await parseCommand("resize width +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)

        assertTrue(narrow.setActiveWorkspace(workspace))
        try await workspace.layoutWorkspace()

        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 1920, y: 54, width: 1200, height: 972)
        for frame in try await frames(of: [first, second]).compactMap({ $0 }) {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, narrow.visibleRect.minX)
            XCTAssertLessThanOrEqual(frame.maxX, narrow.visibleRect.maxX + 0.001)
        }
    }

    func testMouseHeightResizeUpdatesNestedVerticalDivider() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        var top: Window!
        var bottom: Window!
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            top = TestWindow.new(id: 1, parent: $0)
            bottom = TestWindow.new(id: 2, parent: $0)
        }
        TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        let topFrame = try await top.getAxRect(.nonCancellable).orDie()
        top.setAxFrame(nil, CGSize(width: topFrame.width, height: topFrame.height + 80))

        try await resizeWithMouse(top)
        assertEquals(top.vWeight, 619.5)
        assertEquals(bottom.vWeight, 459.5)
        currentlyManipulatedWithMouseWindowId = nil
        try await workspace.layoutWorkspace()

        assertRect(try await top.getAxRect(.nonCancellable), x: 326.4, y: 0, width: 633.6, height: 619.5)
        assertRect(try await bottom.getAxRect(.nonCancellable), x: 326.4, y: 619.5, width: 633.6, height: 459.5)
    }

    func testAdaptiveMouseCornerDragKeepsHorizontalSnapshotSeparateFromVerticalResize() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        var top: Window!
        var bottom: Window!
        let left = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            top = TestWindow.new(id: 1, parent: $0)
            bottom = TestWindow.new(id: 2, parent: $0)
        }
        let right = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        let baseline = try await top.getAxRect(.nonCancellable).orDie()

        top.setAxFrame(
            nil,
            CGSize(width: baseline.width + 100, height: baseline.height + 80),
        )
        try await resizeWithMouse(top)
        XCTAssertEqual(left.hWeight, 733.6, accuracy: 0.001)
        XCTAssertEqual(right.hWeight, 533.6, accuracy: 0.001)
        XCTAssertEqual(top.vWeight, 619.5, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 459.5, accuracy: 0.001)

        top.setAxFrame(
            nil,
            CGSize(width: baseline.width + 150, height: baseline.height + 100),
        )
        try await resizeWithMouse(top)
        XCTAssertEqual(left.hWeight, 783.6, accuracy: 0.001)
        XCTAssertEqual(right.hWeight, 483.6, accuracy: 0.001)
        XCTAssertEqual(top.vWeight, 639.5, accuracy: 0.001)
        XCTAssertEqual(bottom.vWeight, 439.5, accuracy: 0.001)
        try await resetManipulatedWithMouseIfPossible()
    }

    func testFocusModeAndFullscreenOverrideOnlyTheirLeafFrames() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        TestWindow.new(id: 3, parent: root, adaptiveWeight: WEIGHT_AUTO)
        assertTrue(first.focusWindow())

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 643.2, y: 54, width: 633.6, height: 971)

        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        first.isFullscreen = true
        try await workspace.layoutWorkspace()
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 0, y: 54, width: 1920, height: 972)
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 0, width: 1920, height: 1080)

        first.isFullscreen = false
        try await workspace.layoutWorkspace()
        assertRect(try await first.getAxRect(.nonCancellable), x: 0, y: 54, width: 640, height: 971)
    }

    func testFocusModeResizeUsesAdaptiveBaseAndCarriesAdjustmentToLoneLayout() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())
        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let result = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 593.2, y: 54, width: 733.6, height: 971)

        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 593.2, y: 54, width: 733.6, height: 971)
    }

    func testFocusModeExitRestoresTwoByTwoAdaptiveFramesAndWeights() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        var windows: [Window] = []
        for column in 0 ..< 2 {
            TilingContainer.newVTiles(parent: root, adaptiveWeight: column == 0 ? 1 : WEIGHT_AUTO).apply {
                windows.append(TestWindow.new(id: UInt32(column * 2 + 1), parent: $0))
                windows.append(TestWindow.new(id: UInt32(column * 2 + 2), parent: $0, adaptiveWeight: WEIGHT_AUTO))
            }
        }
        try await workspace.layoutWorkspace()
        let originalFrames = try await frames(of: windows)
        let originalRootWeights = root.children.map(\.hWeight)
        let originalNestedWeights = root.children
            .filterIsInstance(of: TilingContainer.self)
            .map { $0.children.map(\.vWeight) }
        assertTrue(windows[0].focusWindow())

        _ = await parseCommand("focus-mode --stay-on-monitor").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        _ = await parseCommand("focus-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertEquals(try await frames(of: windows), originalFrames)
        assertEquals(root.children.map(\.hWeight), originalRootWeights)
        assertEquals(
            root.children.filterIsInstance(of: TilingContainer.self).map { $0.children.map(\.vWeight) },
            originalNestedWeights,
        )
        assertRect(workspace.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
    }

    func testPerMonitorEnablementAndLegacyWidthPrecedence() async throws {
        let builtIn = AdaptiveTestMonitor(name: "Built-in Retina Display", x: 0, isMain: true)
        let dell = AdaptiveTestMonitor(name: "DELL U3225QE", x: 1920, isMain: false)
        monitorInfosForTests = [builtIn, dell]
        config = parseConfig(
            """
            single-window-width-rules = [{ min-monitor-width = 0, width-percent = 50 }]
            [adaptive-layout]
                enabled = [{ monitor."DELL U3225QE" = true }, false]
            """,
        ).config
        config.enableNormalizationFlattenContainers = false
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 480, y: 0, width: 960, height: 1079)

        assertTrue(dell.setActiveWorkspace(workspace))
        try await workspace.layoutWorkspace()
        assertRect(try await window.getAxRect(.nonCancellable), x: 2563.2, y: 54, width: 633.6, height: 971)
    }
}

private struct AdaptiveTestMonitor: MonitorInfo {
    let name: String
    let x: CGFloat
    var y: CGFloat = 0
    let isMain: Bool
    var monitorWidth: CGFloat = 1920
    var monitorHeight: CGFloat = 1080
    var monitorAppKitNsScreenScreensId: Int { isMain ? 1 : 2 }
    var rect: Rect { Rect(topLeftX: x, topLeftY: y, width: monitorWidth, height: monitorHeight) }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

@MainActor
private func frames(of windows: [Window]) async throws -> [Rect?] {
    var result: [Rect?] = []
    for window in windows {
        result.append(try await window.getAxRect(.nonCancellable))
    }
    return result
}

private func assertRect(
    _ actual: Rect?,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line,
) {
    guard let actual else {
        XCTFail("Expected a rect", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.topLeftX, x, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.topLeftY, y, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.width, width, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.height, height, accuracy: 0.001, file: file, line: line)
}
