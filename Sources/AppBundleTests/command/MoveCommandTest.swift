@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertNil(parseCommand("move --fail-if-fullscreen left").errorOrNil)
        assertNil(parseCommand("move --fail-if-macos-native-fullscreen --window-id 1 right").errorOrNil)
        assertNil(parseCommand("move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors right").errorOrNil)
        assertNil(parseCommand("move --boundaries all-monitors-outer-frame --tile-before-monitor right").errorOrNil)
        assertEquals(
            parseCommand("move --tile-before-monitor right").errorOrNil,
            "--tile-before-monitor requires --boundaries all-monitors-outer-frame",
        )
        assertEquals(
            parseCommand("move --boundaries-action wrap-around-all-monitors right").errorOrNil,
            "workspace and wrap-around-all-monitors is an invalid combination of values",
        )
    }

    func testTileBeforeMonitor_rearrangesThenTransfersInAllDirections() async {
        let cases: [(CardinalDirection, Rect, Rect)] = [
            (.left, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)),
            (.right, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)),
            (.up, Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080), Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)),
            (.down, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080)),
        ]

        for (direction, sourceRect, targetRect) in cases {
            setUpWorkspacesForTests()
            let monitors = useTestMonitors([sourceRect, targetRect])
            let source = Workspace.get(byName: "source-\(direction.rawValue)")
            let target = Workspace.get(byName: "target-\(direction.rawValue)")
            assertTrue(monitors[0].setVisibleWorkspace(source))
            assertTrue(monitors[1].setVisibleWorkspace(target))
            let originalRoot = source.rootTilingContainer
            originalRoot.changeOrientation(direction.orientation.opposite)
            TestWindow.new(id: 1, parent: originalRoot)
            TestWindow.new(id: 2, parent: originalRoot)
            let moved = TestWindow.new(id: 3, parent: originalRoot)
            assertTrue(moved.focusWindow())
            let command = "move --boundaries all-monitors-outer-frame --tile-before-monitor \(direction.rawValue)"

            let tileResult = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)

            let newRoot = source.rootTilingContainer
            assertEquals(tileResult.exitCode.rawValue, 0)
            assertEquals(newRoot.orientation, direction.orientation)
            XCTAssertTrue(newRoot.children.contains { $0 === originalRoot })
            XCTAssertTrue(moved.parent === newRoot)
            assertEquals(moved.ownIndex, direction.isPositive ? 1 : 0)
            assertEquals(moved.nodeWorkspace, source)
            assertEquals(globalFocus.windowOrNil, moved)

            let transferResult = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)

            assertEquals(transferResult.exitCode.rawValue, 0)
            assertEquals(moved.nodeWorkspace, target)
            assertEquals(globalFocus.windowOrNil, moved)
            assertEquals(globalFocus.workspace, target)
        }
    }

    func testTileBeforeMonitor_crossesImmediatelyWhenAloneOrAlreadyOnRootAxis() async {
        for shouldBeAlone in [true, false] {
            setUpWorkspacesForTests()
            let (leftMonitor, rightMonitor) = useTwoTestMonitors()
            let source = Workspace.get(byName: "source-\(shouldBeAlone)")
            let target = Workspace.get(byName: "target-\(shouldBeAlone)")
            assertTrue(leftMonitor.setVisibleWorkspace(source))
            assertTrue(rightMonitor.setVisibleWorkspace(target))
            let root = source.rootTilingContainer
            root.changeOrientation(shouldBeAlone ? .v : .h)
            if !shouldBeAlone {
                TestWindow.new(id: 1, parent: root)
            }
            let moved = TestWindow.new(id: 2, parent: root)
            assertTrue(moved.focusWindow())

            let result = await parseCommand(
                "move --boundaries all-monitors-outer-frame --tile-before-monitor right",
            ).cmdOrDie.run(.defaultEnv, .emptyStdin)

            assertEquals(result.exitCode.rawValue, 0)
            XCTAssertTrue(source.rootTilingContainer === root)
            assertEquals(moved.nodeWorkspace, target)
        }
    }

    func testTileBeforeMonitor_ignoresPendingAndEmptyBranchesWhenDecidingToTile() async {
        let monitors = useTestMonitors([
            Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080),
        ])
        let source = Workspace.get(byName: "source")
        let target = Workspace.get(byName: "target")
        assertTrue(monitors[0].setVisibleWorkspace(source))
        assertTrue(monitors[1].setVisibleWorkspace(target))
        let root = source.rootTilingContainer
        let active = TestWindow.new(id: 1, parent: root)
        let pendingContainer = TilingContainer.newVTiles(parent: root, adaptiveWeight: WEIGHT_AUTO)
        let pending = TestWindow.new(id: 2, parent: pendingContainer)
        pending.isAwaitingOnWindowDetected = true
        _ = TilingContainer.newVTiles(parent: root, adaptiveWeight: WEIGHT_AUTO)
        assertTrue(active.focusWindow())

        let result = await parseCommand(
            "move --boundaries all-monitors-outer-frame --tile-before-monitor down",
        ).cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertTrue(source.rootTilingContainer === root)
        assertEquals(active.nodeWorkspace, target)
    }

    func testTileBeforeMonitor_nestedLayoutNormalizesAfterSecondMove() async {
        config.enableNormalizationFlattenContainers = true
        let monitors = useTestMonitors([
            Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080),
        ])
        let source = Workspace.get(byName: "source")
        let target = Workspace.get(byName: "target")
        assertTrue(monitors[0].setVisibleWorkspace(source))
        assertTrue(monitors[1].setVisibleWorkspace(target))
        let root = source.rootTilingContainer
        var moved: Window!
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
            moved = TestWindow.new(id: 2, parent: $0)
        }
        TestWindow.new(id: 3, parent: root)
        assertTrue(moved.focusWindow())
        let command = "move --boundaries all-monitors-outer-frame --tile-before-monitor down"

        assertEquals((await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        assertEquals(source.rootTilingContainer.layoutDescription, .v_tiles([.h_tiles([.window(1), .window(3)]), .window(2)]))
        assertEquals((await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        source.normalizeContainers()

        assertEquals(source.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
        assertEquals(moved.nodeWorkspace, target)
        assertEquals(globalFocus.windowOrNil, moved)
    }

    func testTileBeforeMonitor_doesNotChangeNoNeighborBoundaryActions() async {
        let cases: [(String, Int32, LayoutDescription)] = [
            ("stop", 0, .h_tiles([.window(1), .window(2)])),
            ("fail", 2, .h_tiles([.window(1), .window(2)])),
            ("create-implicit-container", 0, .v_tiles([.h_tiles([.window(1)]), .window(2)])),
            ("wrap-around-all-monitors", 0, .v_tiles([.window(2), .h_tiles([.window(1)])])),
        ]
        for (action, expectedExitCode, expectedLayout) in cases {
            setUpWorkspacesForTests()
            let workspace = globalFocus.workspace
            workspace.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                assertTrue(TestWindow.new(id: 2, parent: $0).focusWindow())
            }

            let result = await parseCommand(
                "move --boundaries all-monitors-outer-frame --boundaries-action \(action) --tile-before-monitor down",
            ).cmdOrDie.run(.defaultEnv, .emptyStdin)

            assertEquals(result.exitCode.rawValue, expectedExitCode)
            assertEquals(workspace.rootTilingContainer.layoutDescription, expectedLayout)
        }
    }

    func testTileBeforeMonitor_preservesAdaptiveGeometryAndResizeBeforeTransfer() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let monitors = useTestMonitors([
            Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080),
        ])
        let source = Workspace.get(byName: "source")
        let target = Workspace.get(byName: "target")
        assertTrue(monitors[0].setVisibleWorkspace(source))
        assertTrue(monitors[1].setVisibleWorkspace(target))
        let root = source.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let moved = TestWindow.new(id: 3, parent: root)
        assertTrue(moved.focusWindow())
        let command = "move --boundaries all-monitors-outer-frame --tile-before-monitor down"

        assertEquals((await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        try await source.layoutWorkspace()
        assertEquals(source.rootTilingContainer.tilingFootprint, TilingFootprint(columns: 2, rows: 2))
        assertMoveRect(source.lastAppliedLayoutVirtualRect, x: 326.4, y: 0, width: 1267.2, height: 1080)
        let initialHeight = try await moved.getAxRect(.nonCancellable).orDie().height

        assertEquals((await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        try await source.layoutWorkspace()
        let resizedHeight = try await moved.getAxRect(.nonCancellable).orDie().height
        XCTAssertEqual(resizedHeight, initialHeight + 100, accuracy: 0.001)

        assertEquals((await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)).exitCode.rawValue, 0)
        try await source.layoutWorkspace()
        try await target.layoutWorkspace()
        assertMoveRect(source.lastAppliedLayoutVirtualRect, x: 326.4, y: 54, width: 1267.2, height: 972)
        assertMoveRect(target.lastAppliedLayoutVirtualRect, x: 643.2, y: 1134, width: 633.6, height: 972)
    }

    func testWrapAroundAllMonitors_onSingleMonitor() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
        }

        let command = "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors"
        var result = await parseCommand("\(command) right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(1), .window(2)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 3)

        result = await parseCommand("\(command) left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
    }

    func testWrapAroundAllMonitors_onSingleMonitorWithOppositeRootOrientation() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand(
            "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors up",
        ).cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .v_tiles([
                    .h_tiles([.window(2)]),
                    .window(1),
                ]),
            ]),
        )
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    func testWrapAroundAllMonitors_acrossTwoMonitors() async {
        let (leftMonitor, rightMonitor) = useTwoTestMonitors()
        let leftWorkspace = Workspace.get(byName: "left")
        let rightWorkspace = Workspace.get(byName: "right")
        assertEquals(leftMonitor.setVisibleWorkspace(leftWorkspace), true)
        assertEquals(rightMonitor.setVisibleWorkspace(rightWorkspace), true)

        leftWorkspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        rightWorkspace.rootTilingContainer.apply {
            TestWindow.new(id: 3, parent: $0)
            assertEquals(TestWindow.new(id: 4, parent: $0).focusWindow(), true)
        }

        let result = await parseCommand(
            "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors right",
        ).cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(leftWorkspace.rootTilingContainer.layoutDescription, .h_tiles([.window(4), .window(1), .window(2)]))
        assertEquals(rightWorkspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 4)
        assertEquals(globalFocus.workspace, leftWorkspace)

        let reverseResult = await parseCommand(
            "move --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors left",
        ).cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(reverseResult.exitCode.rawValue, 0)
        assertEquals(leftWorkspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(rightWorkspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(4)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 4)
        assertEquals(globalFocus.workspace, rightWorkspace)
    }

    func testWrapAroundAllMonitors_usesSameMonitorAsFocus() async {
        for orientation in [Orientation.h, .v] {
            let positive: CardinalDirection = orientation == .h ? .right : .down
            let negative: CardinalDirection = orientation == .h ? .left : .up
            for (direction, sourceIndex, expectedIndex) in [(positive, 2, 0), (negative, 0, 2), (positive, 1, 2), (negative, 1, 0)] {
                setUpWorkspacesForTests()
                config.defaultRootContainerOrientation = orientation == .h ? .horizontal : .vertical
                let monitors = useTestMonitors((0 ..< 3).map { index in
                    Rect(
                        topLeftX: orientation == .h ? CGFloat(index) * 1920 : 0,
                        topLeftY: orientation == .v ? CGFloat(index) * 1080 : 0,
                        width: 1920,
                        height: 1080,
                    )
                })
                let workspaces = monitors.enumerated().map { index, monitor in
                    let workspace = Workspace.get(byName: "monitor-\(index)")
                    assertEquals(monitor.setVisibleWorkspace(workspace), true)
                    return workspace
                }
                let windows = workspaces.enumerated().map { index, workspace in
                    TestWindow.new(id: UInt32(index + 1), parent: workspace.rootTilingContainer)
                }
                let sourceWindow = windows[sourceIndex]
                assertEquals(sourceWindow.focusWindow(), true)

                let options = "--boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors \(direction.rawValue)"
                let focusResult = await parseCommand("focus \(options)").cmdOrDie.run(.defaultEnv, .emptyStdin)
                assertEquals(focusResult.exitCode.rawValue, 0)
                let focusWorkspace = globalFocus.workspace
                assertEquals(focusWorkspace, workspaces[expectedIndex])

                assertEquals(sourceWindow.focusWindow(), true)
                let moveResult = await parseCommand("move \(options)").cmdOrDie.run(.defaultEnv, .emptyStdin)
                assertEquals(moveResult.exitCode.rawValue, 0)
                assertEquals(sourceWindow.nodeWorkspace, focusWorkspace)
                assertEquals(globalFocus.workspace, focusWorkspace)
                assertEquals(globalFocus.windowOrNil?.windowId, sourceWindow.windowId)
            }
        }
    }

    func testWrapAroundAllMonitors_doesNotStealFocusForExplicitWindow() async {
        let (leftMonitor, rightMonitor) = useTwoTestMonitors()
        let leftWorkspace = Workspace.get(byName: "left")
        let rightWorkspace = Workspace.get(byName: "right")
        assertEquals(leftMonitor.setVisibleWorkspace(leftWorkspace), true)
        assertEquals(rightMonitor.setVisibleWorkspace(rightWorkspace), true)

        leftWorkspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        TestWindow.new(id: 2, parent: rightWorkspace.rootTilingContainer)

        let result = await parseCommand(
            "move --window-id 2 --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors right",
        ).cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(leftWorkspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1)]))
        assertEquals(rightWorkspace.rootTilingContainer.layoutDescription, .h_tiles([]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(globalFocus.workspace, leftWorkspace)
    }

    func testParseFloatingPixels() {
        assertNil(parseCommand("move --floating-pixels 25 down").errorOrNil)
        assertNotNil(parseCommand("move --floating-pixels -1 down").errorOrNil)
        assertNotNil(parseCommand("move --floating-pixels nope down").errorOrNil)
    }

    func testMoveFloatingWindowByPixels() async throws {
        let window = TestWindow.new(
            id: 1,
            parent: Workspace.get(byName: name).floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400),
        )
        assertTrue(window.focusWindow())

        for command in ["left", "up", "right", "down"] {
            let result = await parseCommand("move --floating-pixels 25 \(command)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertEquals(result.exitCode.rawValue, 0)
        }

        let rect = try await window.getAxRect(.cancellable).orDie()
        assertEquals(rect.topLeftX, 100)
        assertEquals(rect.topLeftY, 200)
        assertEquals(rect.width, 300)
        assertEquals(rect.height, 400)
    }

    func testMoveFloatingWindowDefaultsToTenPercentOfMonitor() async throws {
        let window = TestWindow.new(
            id: 1,
            parent: Workspace.get(byName: name).floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400),
        )
        assertTrue(window.focusWindow())

        let rightResult = await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let downResult = await parseCommand("move down").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(rightResult.exitCode.rawValue, 0)
        assertEquals(downResult.exitCode.rawValue, 0)
        let rect = try await window.getAxRect(.cancellable).orDie()
        assertEquals(rect.topLeftX, 292)
        assertEquals(rect.topLeftY, 308)
    }

    func testFailIfFullscreen() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            let window = TestWindow.new(id: 1, parent: $0)
            assertEquals(window.focusWindow(), true)
            window.isFullscreen = true
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand("move --fail-if-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testFailIfMacosNativeFullscreen() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            let window = TestWindow.new(id: 1, parent: $0)
            assertEquals(window.focusWindow(), true)
            window.isMacosFullscreenForTest = true
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand("move --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testFailIfFullscreenAllowsRegularWindows() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand("move --fail-if-fullscreen --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    func testMove_swapWindows() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    func testMoveInto_findTopMostContainerWithRightOrientation() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(0),
                .h_tiles([
                    .window(1),
                    .h_tiles([
                        .window(2),
                    ]),
                ]),
            ]),
        )
    }

    func testMove_mru() async {
        var window3: Window!
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    window3 = TestWindow.new(id: 3, parent: $0)
                }
                TestWindow.new(id: 4, parent: $0)
            }
        }
        window3.markAsMostRecentChild()

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(0),
                .v_tiles([
                    .h_tiles([
                        .window(1),
                        .window(2),
                        .window(3),
                    ]),
                    .window(4),
                ]),
            ]),
        )
    }

    func testSwap_preserveWeight() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
        let window2 = TestWindow.new(id: 2, parent: root, adaptiveWeight: 2)
        _ = window2.focusWindow()

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window2.hWeight, 2)
        assertEquals(window1.hWeight, 1)
    }

    func testMoveIn_newWeight() async {
        var window1: Window!
        var window2: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0, adaptiveWeight: 1)
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
            }
        }
        _ = window1.focusWindow()

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window2.hWeight, 1)
        assertEquals(window2.vWeight, 1)
        assertEquals(window1.vWeight, 1)
        assertEquals(window1.hWeight, 1)
    }

    func testCreateImplicitContainer() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }

        let result = await parseCommand("move up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .v_tiles([
                    .window(2),
                    .h_tiles([.window(1), .window(3)]),
                ]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testStop_onRootNode() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }

        let result = await parseCommand("move --boundaries-action stop left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .h_tiles([.window(1), .window(2), .window(3)]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testStop_onRootNode_withOppositeOrientation() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }

        let result = await parseCommand("move --boundaries-action stop up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .h_tiles([.window(1), .window(2), .window(3)]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testStop_onRootNode_whenNoBoundary() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }

        let result = await parseCommand("move --boundaries-action stop left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .h_tiles([.window(2), .window(1), .window(3)]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testStop_onInnerNode() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        let result = await parseCommand("move --boundaries-action stop right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .h_tiles([.window(1), .v_tiles([.window(3)]), .window(2)]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testFail() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }

        let result = await parseCommand("move --boundaries-action fail left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.layoutDescription,
            .workspace([
                .h_tiles([.window(1), .window(2), .window(3)]),
            ]),
        )
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testMoveOut() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .window(2),
                .v_tiles([
                    .window(3),
                    .window(4),
                ]),
            ]),
        )
    }

    func testMoveOutWithNormalization_right() async {
        config.enableNormalizationFlattenContainers = true

        let workspace = Workspace.get(byName: name).apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
            assertEquals(TestWindow.new(id: 2, parent: $0.rootTilingContainer).focusWindow(), true)
        }

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .window(2),
            ]),
        )
        assertEquals(globalFocus.windowOrNil?.windowId, 2)
    }

    func testMoveOutWithNormalization_left() async {
        config.enableNormalizationFlattenContainers = true

        let workspace = Workspace.get(byName: name).apply {
            assertEquals(TestWindow.new(id: 1, parent: $0.rootTilingContainer).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0.rootTilingContainer)
        }

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .window(2),
            ]),
        )
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }
}

private struct MoveCommandTestMonitorInfo: MonitorInfo {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

@MainActor private func useTwoTestMonitors() -> (left: MonitorInfo, right: MonitorInfo) {
    let monitors = useTestMonitors([
        Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
        Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
    ])
    return (monitors[0], monitors[1])
}

@MainActor private func useTestMonitors(_ rects: [Rect]) -> [MonitorInfo] {
    let monitors = rects.enumerated().map { index, rect in
        MoveCommandTestMonitorInfo(
            monitorAppKitNsScreenScreensId: index + 1,
            name: "Test Monitor \(index + 1)",
            rect: rect,
            visibleRect: rect,
            isMain: index == 0,
        )
    }
    setMonitorInfosForTests(monitors)
    return monitors
}

private func assertMoveRect(
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

extension TreeNode {
    var layoutDescription: LayoutDescription {
        return switch nodeCases {
            case .window(let window): .window(window.windowId)
            case .workspace(let workspace): .workspace(workspace.children.map(\.layoutDescription))
            case .floatingWindowsContainer(let container): .floatingWindowsContainer(container.children.map(\.layoutDescription))
            case .macosMinimizedWindowsContainer: .macosMinimized
            case .macosFullscreenWindowsContainer: .macosFullscreen
            case .macosHiddenAppsWindowsContainer: .macosHiddeAppWindow
            case .monitor: .monitor
            case .workspacesContainer: .workspacesContainer
            case .macosPopupWindowsContainer: .macosPopupWindowsContainer
            case .tilingContainer(let container):
                switch container.layout {
                    case .tiles:
                        container.orientation == .h
                            ? .h_tiles(container.children.map(\.layoutDescription))
                            : .v_tiles(container.children.map(\.layoutDescription))
                    case .accordion:
                        container.orientation == .h
                            ? .h_accordion(container.children.map(\.layoutDescription))
                            : .v_accordion(container.children.map(\.layoutDescription))
                }
        }
    }
}

enum LayoutDescription: Equatable {
    case workspace([LayoutDescription])
    case h_tiles([LayoutDescription])
    case v_tiles([LayoutDescription])
    case h_accordion([LayoutDescription])
    case v_accordion([LayoutDescription])
    case floatingWindowsContainer([LayoutDescription])
    case window(UInt32)
    case macosPopupWindowsContainer
    case macosMinimized
    case macosHiddeAppWindow
    case macosFullscreen

    // todo think about it
    case workspacesContainer
    case monitor
}
