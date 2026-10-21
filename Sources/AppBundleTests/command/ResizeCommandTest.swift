@testable import AppBundle
import Common
import XCTest

@MainActor
final class ResizeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseSingleCommandSucc("resize smart +10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(10)))
        testParseSingleCommandSucc("resize smart -10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .subtract(10)))
        testParseSingleCommandSucc("resize smart 10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .set(10)))

        testParseSingleCommandSucc("resize smart-opposite +10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .add(10)))
        testParseSingleCommandSucc("resize smart-opposite -10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .subtract(10)))
        testParseSingleCommandSucc("resize smart-opposite 10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .set(10)))

        testParseSingleCommandSucc("resize height 10", ResizeCmdArgs(rawArgs: [], dimension: .height, units: .set(10)))
        testParseSingleCommandSucc("resize width 10", ResizeCmdArgs(rawArgs: [], dimension: .width, units: .set(10)))

        testParseCommandFail("resize s 10", msg: """
            ERROR: Can't parse 's'.
                   Possible values: (width|height|smart|smart-opposite)
            """, exitCode: 2)
        testParseCommandFail("resize smart foo", msg: "ERROR: <number> argument must be a number", exitCode: 2)
    }

    func testWidthAdd_growsTargetShrinksSiblings() async {
        var window1: Window!
        var window2: Window!
        var window3: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
        }
        _ = window1.focusWindow()

        await parseCommand("resize width +2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // diff = +2, childDiff = 2 / (3 - 1) = 1
        assertEquals(window1.hWeight, 6)
        assertEquals(window2.hWeight, 3)
        assertEquals(window3.hWeight, 3)
    }

    func testWidthSubtract_shrinksTargetGrowsSiblings() async {
        var window1: Window!
        var window2: Window!
        var window3: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
        }
        _ = window1.focusWindow()

        await parseCommand("resize width -2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // diff = -2, childDiff = -1
        assertEquals(window1.hWeight, 2)
        assertEquals(window2.hWeight, 5)
        assertEquals(window3.hWeight, 5)
    }

    func testWidthSet_diffIsAbsoluteMinusCurrent() async {
        var window1: Window!
        var window2: Window!
        var window3: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
        }
        _ = window1.focusWindow()

        await parseCommand("resize width 6").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // diff = 6 - 4 = 2, childDiff = 1
        assertEquals(window1.hWeight, 6)
        assertEquals(window2.hWeight, 3)
        assertEquals(window3.hWeight, 3)
    }

    func testHeight_climbsToVerticalAncestor() async throws {
        // Root is horizontal; height must locate the nested vertical tile container.
        var window1: Window!
        var window2: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            }
        }
        _ = window1.focusWindow()
        try await focus.workspace.layoutWorkspace()

        await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window1.vWeight, 639.5)
        assertEquals(window2.vWeight, 439.5)
    }

    func testSmart_usesImmediateParentOrientation() async throws {
        // .smart resizes along the immediate tile container's axis, even when an ancestor
        // would also qualify.
        var window1: Window!
        var window2: Window!
        var sibling: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 4).apply {
                window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
            }
            sibling = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
        }
        _ = window1.focusWindow()
        try await focus.workspace.layoutWorkspace()
        let siblingWidth = sibling.hWeight

        await parseCommand("resize smart +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // immediate parent is vertical; resize is along .v
        assertEquals(window1.vWeight, 639.5)
        assertEquals(window2.vWeight, 439.5)
        // The horizontal sibling at the root is untouched.
        assertEquals(sibling.hWeight, siblingWidth)
    }

    func testConsecutiveHeightCommandsUseUpdatedIntendedHeightBeforeLayout() async throws {
        let root = focus.workspace.rootTilingContainer
        root.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        assertTrue(first.focusWindow())
        try await focus.workspace.layoutWorkspace()

        _ = await parseCommand("resize height +50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = await parseCommand("resize height +50").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(first.vWeight, 639.5)
        assertEquals(second.vWeight, 439.5)
    }

    func testHeightResizeSaturatesUnequalDonorsAndRepeatedCommandsStayStable() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let target = TestWindow.new(id: 1, parent: root)
        let firstDonor = TestWindow.new(id: 2, parent: root)
        let secondDonor = TestWindow.new(id: 3, parent: root)
        assertTrue(target.focusWindow())
        try await workspace.layoutWorkspace()
        target.vWeight = 200
        firstDonor.vWeight = 300
        secondDonor.vWeight = 579
        try await workspace.layoutWorkspace()

        _ = await parseCommand("resize height +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals([target.vWeight, firstDonor.vWeight, secondDonor.vWeight], [679, 200, 200])
        _ = await parseCommand("resize height +99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals([target.vWeight, firstDonor.vWeight, secondDonor.vWeight], [679, 200, 200])

        _ = await parseCommand("resize height -99999").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals([target.vWeight, firstDonor.vWeight, secondDonor.vWeight], [200, 439.5, 439.5])
        _ = await parseCommand("resize height 400").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals([target.vWeight, firstDonor.vWeight, secondDonor.vWeight], [400, 339.5, 339.5])
    }

    func testNestedConsecutiveHeightCommandsUseLiveAncestorHeight() async throws {
        for adaptiveEnabled in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptiveEnabled)
            let workspace = focus.workspace
            let root = workspace.rootTilingContainer
            root.changeOrientation(.v)
            var innerTop: Window!
            var innerBottom: Window!
            var spanning: Window!
            TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    innerTop = TestWindow.new(id: 1, parent: $0)
                    innerBottom = TestWindow.new(id: 2, parent: $0)
                }
                spanning = TestWindow.new(id: 3, parent: $0)
            }
            TestWindow.new(id: 4, parent: root)
            try await workspace.layoutWorkspace()

            assertTrue(spanning.focusWindow())
            _ = await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertTrue(innerTop.focusWindow())
            _ = await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)

            assertEquals(innerTop.vWeight, 419.75)
            assertEquals(innerBottom.vWeight, 219.75)
            try await workspace.layoutWorkspace()
            let topFrame = try await innerTop.getAxRect(.nonCancellable).orDie()
            let bottomFrame = try await innerBottom.getAxRect(.nonCancellable).orDie()
            XCTAssertEqual(topFrame.height, 419.75, accuracy: 0.001)
            XCTAssertEqual(bottomFrame.height, 219.75, accuracy: 0.001)
        }
    }

    func testNestedConsecutiveHeightCommandsMatchAdaptiveAndNormalDimensionNormalization() async throws {
        for adaptiveEnabled in [false, true] {
            setUpWorkspacesForTests()
            config.adaptiveLayout.enabled = .constant(adaptiveEnabled)
            let workspace = focus.workspace
            let root = workspace.rootTilingContainer
            root.changeOrientation(.v)
            var innerTop: Window!
            var innerBottom: Window!
            var spanning: Window!
            TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    innerTop = TestWindow.new(id: 1, parent: $0)
                    innerBottom = TestWindow.new(id: 2, parent: $0)
                }
                spanning = TestWindow.new(id: 3, parent: $0)
            }
            TestWindow.new(id: 4, parent: root)
            try await workspace.layoutWorkspace()
            innerTop.vWeight = 323.7
            innerBottom.vWeight = 215.8
            try await workspace.layoutWorkspace()

            assertTrue(spanning.focusWindow())
            _ = await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertTrue(innerTop.focusWindow())
            _ = await parseCommand("resize height +20").cmdOrDie.run(.defaultEnv, .emptyStdin)

            let expectedTop: CGFloat = adaptiveEnabled ? 403.7 : 393.7
            let expectedBottom: CGFloat = adaptiveEnabled ? 235.8 : 245.8
            XCTAssertEqual(innerTop.vWeight, expectedTop, accuracy: 0.001)
            XCTAssertEqual(innerBottom.vWeight, expectedBottom, accuracy: 0.001)
        }
    }

    func testSmartOpposite_resizesAncestorContainer() async {
        // .smart-opposite resolves to the opposite axis (.h here) and climbs to the
        // ancestor tile container with that orientation. That ancestor's child — the
        // intermediate vertical container — is the node that gets resized.
        var verticalContainer: TilingContainer!
        var sibling: Window!
        var inner: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            verticalContainer = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 4).apply {
                inner = TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
            sibling = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
        }
        _ = inner.focusWindow()

        await parseCommand("resize smart-opposite +2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        // diff = +2 along .h; root has 2 children, childDiff = 2
        assertEquals(verticalContainer.hWeight, 6)
        assertEquals(sibling.hWeight, 2)
    }

    func testHeight_noVerticalAncestor_returnsFail() async {
        // Root is horizontal; with no vertical container present, height has nothing to resize.
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand("resize height +2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testSingleChildParent_failsCleanly() async {
        // The root has only one tiling child; dividing the diff across 0 siblings must fail.
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4).focusWindow(), true)
        }

        let result = await parseCommand("resize width +2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testSingleWindowSmartResizeAdjustsOnlyThatWindow() async {
        config.singleWindowWidthRules = [SingleWindowWidthRule(minMonitorWidth: 0, widthPercent: 50)]
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        assertEquals(window.focusWindow(), true)

        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 960)
        let grow = await parseCommand("resize smart +50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(grow.exitCode.rawValue, 0)
        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 1010)

        let otherWindow = TestWindow.new(id: 2, parent: root)
        assertEquals(otherWindow.singleWindowWidthAdjustment, 0)
        assertEquals(window.singleWindowWidthAdjustment, 50)
        otherWindow.unbindFromParent()

        let shrink = await parseCommand("resize smart -50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(shrink.exitCode.rawValue, 0)
        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 960)
        assertEquals(window.singleWindowWidthAdjustment, 0)
    }

    func testSingleWindowWidthResizeClampsAndKeepsAdjustmentOnWindow() async {
        config.singleWindowWidthRules = [SingleWindowWidthRule(minMonitorWidth: 0, widthPercent: 50)]
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        assertEquals(window.focusWindow(), true)

        let grow = await parseCommand("resize width +2000").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(grow.exitCode.rawValue, 0)
        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 1920)

        let shrink = await parseCommand("resize width -2000").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(shrink.exitCode.rawValue, 0)
        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 200)

        let secondWindow = TestWindow.new(id: 2, parent: root)
        assertEquals(secondWindow.focusWindow(), true)
        assertEquals(secondWindow.singleWindowWidthAdjustment, 0)
        assertEquals(window.singleWindowWidth(base: 960, available: 1920), 200)
    }

    func testFloatingWidthKeepsCentre() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.floatingWindowsContainer, rect: Rect(topLeftX: 500, topLeftY: 300, width: 400, height: 200))
        assertTrue(window.focusWindow())

        await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.size, CGSize(width: 500, height: 200))
        assertEquals(rect?.center, CGPoint(x: 700, y: 400))
    }

    func testFloatingSmartScalesLongerSideKeepingAspectRatio() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.floatingWindowsContainer, rect: Rect(topLeftX: 500, topLeftY: 300, width: 400, height: 200))
        assertTrue(window.focusWindow())

        await parseCommand("resize smart -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals((try await window.getAxRect(.nonCancellable))?.size, CGSize(width: 300, height: 150))

        await parseCommand("resize smart-opposite 300").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals((try await window.getAxRect(.nonCancellable))?.size, CGSize(width: 600, height: 300))
    }

    func testFloatingResizeStaysInsideMonitor() async throws {
        let bounds = focus.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let window = TestWindow.new(id: 1, parent: focus.workspace.floatingWindowsContainer, rect: Rect(topLeftX: bounds.topLeftX, topLeftY: bounds.topLeftY, width: 400, height: 200))
        assertTrue(window.focusWindow())

        await parseCommand("resize height \(Int(bounds.height) + 1000)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.height, bounds.height)
        assertEquals(rect?.topLeftX, bounds.topLeftX)
        assertEquals(rect?.topLeftY, bounds.topLeftY)
    }
}
