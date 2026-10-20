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
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 1133.810526, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1460.210526, y: 54, width: 133.389474, height: 971)
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
        XCTAssertEqual(adaptiveWeights[0], 1253.9178947368423, accuracy: 0.001)
        XCTAssertEqual(adaptiveWeights[1], 13.282105263157895, accuracy: 0.001)
        assertRect(try await first.getAxRect(.nonCancellable), x: 326.4, y: 54, width: 1243.9178947368423, height: 971)
        assertRect(try await second.getAxRect(.nonCancellable), x: 1590.3178947368424, y: 54, width: 3.282105263157895, height: 971)

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
        first.hWeight = 1344
        second.hWeight = 576
        try await workspace.layoutWorkspace()

        config.adaptiveLayout.enabled = .constant(true)
        try await workspace.layoutWorkspace()

        XCTAssertEqual(first.hWeight, 887.04, accuracy: 0.001)
        XCTAssertEqual(second.hWeight, 380.16, accuracy: 0.001)
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
    var monitorAppKitNsScreenScreensId: Int { isMain ? 1 : 2 }
    var rect: Rect { Rect(topLeftX: x, topLeftY: y, width: 1920, height: 1080) }
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
