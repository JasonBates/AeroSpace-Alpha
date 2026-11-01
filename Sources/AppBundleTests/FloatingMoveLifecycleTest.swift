@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class FloatingMoveLifecycleTest: XCTestCase {
    override func setUp() async throws {
        try await resetManipulatedWithMouseIfPossible()
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        try await resetManipulatedWithMouseIfPossible()
    }

    func testDelayedCenterDoesNotMoveReplacementNativeTab() async throws {
        let (left, right) = twoWorkspaces()
        let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
        let logicalId = window.windowId
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(logicalId, 100)
        window.nativeWindowIdForTest = 100
        let generation = window.nativeGeometryGeneration
        window.onGetAxRect = {
            XCTAssertEqual(remapNativeTabWindow(background: 100, frontmost: 101, mapping: &mapping, window: window), logicalId)
            window.nativeWindowIdForTest = 101
            window.setAxFrame(self.leftFrame.topLeftCorner, self.leftFrame.size)
        }

        try await window.bindFloatingWindowToMonitorUnderCenter()

        XCTAssertTrue(window.nodeWorkspace === left)
        XCTAssertTrue(window.parent === left.floatingWindowsContainer)
        XCTAssertFalse(right.allLeafWindowsRecursive.contains(window))
        XCTAssertEqual(window.windowId, logicalId)
        XCTAssertEqual(mapping.forward[logicalId], 101)
        XCTAssertEqual(window.nativeWindowId, 101)
        XCTAssertEqual(window.nativeGeometryGeneration, generation + 1)
        let frame = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(frame, leftFrame)
        XCTAssertEqual(window.setAxFrameCallCountForTest, 1)
    }

    func testDelayedCenterDoesNotReinsertClosedOrUnboundWindow() async throws {
        for dead in [false, true] {
            let (left, right) = twoWorkspaces()
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
            window.onGetAxRect = {
                window.closeAxWindow()
                if dead { window.lifeStatus = .dead }
            }

            try await window.bindFloatingWindowToMonitorUnderCenter()

            XCTAssertNil(window.parent)
            XCTAssertNil(window.nodeWorkspace)
            XCTAssertNil(Window.get(byId: window.windowId))
            XCTAssertFalse(left.allLeafWindowsRecursive.contains(window))
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window))
            XCTAssertEqual(window.lifeStatus, dead ? .dead : .alive)
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0)
        }
    }

    func testDelayedCenterDoesNotMoveInvisibleOrDeadBoundWindow() async throws {
        for status in [WindowLifeStatus.invisible, .dead] {
            let (left, right) = twoWorkspaces()
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
            window.onGetAxRect = { window.lifeStatus = status }

            try await window.bindFloatingWindowToMonitorUnderCenter()

            XCTAssertTrue(window.parent === left.floatingWindowsContainer)
            XCTAssertTrue(window.nodeWorkspace === left)
            XCTAssertEqual(window.lifeStatus, status)
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window))
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0)
        }
    }

    func testDelayedCenterPreservesExplicitWorkspaceTilingAndNativeStateChanges() async throws {
        for change in ["workspace", "tiled", "fullscreen"] {
            let (left, right) = twoWorkspaces()
            let moved = Workspace.get(byName: "explicit-destination")
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
            let parent: NonLeafTreeNodeObject = switch change {
                case "workspace": moved.floatingWindowsContainer
                case "tiled": left.rootTilingContainer
                default: left.macOsNativeFullscreenWindowsContainer
            }
            window.onGetAxRect = { window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }

            try await window.bindFloatingWindowToMonitorUnderCenter()

            XCTAssertTrue(window.parent === parent, change)
            XCTAssertTrue(window.nodeWorkspace === (change == "workspace" ? moved : left), change)
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window), change)
            XCTAssertEqual(Workspace.all.flatMap { $0.allLeafWindowsRecursive }.count(where: { $0 === window }), 1, change)
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0, change)
        }
    }

    func testRequiresBoundAliveFloatingWindowBeforeReadingCenter() async throws {
        for state in ["unbound", "invisible", "dead", "tiled", "fullscreen"] {
            let (left, right) = twoWorkspaces()
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
            switch state {
                case "unbound": window.unbindFromParent()
                case "invisible": window.lifeStatus = .invisible
                case "dead": window.lifeStatus = .dead
                case "tiled": window.bind(to: left.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                default: window.bind(to: left.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            let parent = window.parent
            var readCenter = false
            window.onGetAxRect = { readCenter = true }

            try await window.bindFloatingWindowToMonitorUnderCenter()

            XCTAssertFalse(readCenter, state)
            XCTAssertTrue(window.parent === parent, state)
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window), state)
        }
    }

    func testOrdinaryCrossMonitorMovesPreserveIdentityAndFrame() async throws {
        for count in [2, 3] {
            setUpWorkspacesForTests()
            let monitors = lifecycleMonitors(count)
            setMonitorInfosForTests(monitors)
            let workspaces = (0 ..< count).map { Workspace.get(byName: "display-\($0)") }
            for (monitor, workspace) in zip(monitors, workspaces) { XCTAssertTrue(monitor.setVisibleWorkspace(workspace)) }
            let window = TestWindow.new(id: 1, parent: workspaces[0].floatingWindowsContainer, rect: leftFrame)
            for index in Array(0 ..< count) + Array((0 ..< count).reversed()) {
                let rect = Rect(topLeftX: monitors[index].rect.topLeftX + 200, topLeftY: 120, width: 600, height: 400)
                window.setAxFrame(rect.topLeftCorner, rect.size)
                let writes = window.setAxFrameCallCountForTest

                try await window.bindFloatingWindowToMonitorUnderCenter()

                XCTAssertTrue(window.nodeWorkspace === workspaces[index])
                XCTAssertTrue(window.parent === workspaces[index].floatingWindowsContainer)
                XCTAssertTrue(Window.get(byId: window.windowId) === window)
                XCTAssertEqual(Workspace.all.flatMap { $0.allLeafWindowsRecursive }.count(where: { $0 === window }), 1)
                let frame = try await window.getAxRect(.nonCancellable)
                XCTAssertEqual(frame, rect)
                XCTAssertEqual(window.setAxFrameCallCountForTest, writes)
            }
        }
    }

    func testSameMonitorAndMissingCenterKeepExistingBindingOrder() async throws {
        for rect in [leftFrame, nil] {
            let (left, _) = twoWorkspaces()
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rect)
            let sibling = TestWindow.new(id: 2, parent: left.floatingWindowsContainer, rect: leftFrame)

            try await window.bindFloatingWindowToMonitorUnderCenter()

            XCTAssertEqual(left.floatingWindowsContainer.children, [window, sibling])
            XCTAssertEqual(window.setAxFrameCallCountForTest, 0)
        }
    }

    func testReleaseRebindsDroppedWindowAndClearsManipulation() async throws {
        let (left, right) = twoWorkspaces()
        let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
        currentlyManipulatedWithMouseWindowId = window.windowId

        try await resetManipulatedWithMouseIfPossible()

        XCTAssertNil(currentlyManipulatedWithMouseWindowId)
        XCTAssertTrue(window.parent === right.floatingWindowsContainer)
        XCTAssertTrue(window.nodeWorkspace === right)
        XCTAssertTrue(Window.get(byId: window.windowId) === window)
        XCTAssertEqual(window.setAxFrameCallCountForTest, 0)
        try await resetManipulatedWithMouseIfPossible()
        XCTAssertTrue(window.nodeWorkspace === right)
    }

    func testReleaseRejectsDelayedRemapAndClosureWhileClearingManipulation() async throws {
        for closes in [false, true] {
            let (left, right) = twoWorkspaces()
            let window = TestWindow.new(id: 1, parent: left.floatingWindowsContainer, rect: rightFrame)
            currentlyManipulatedWithMouseWindowId = window.windowId
            window.onGetAxRect = {
                if closes {
                    window.closeAxWindow()
                    window.lifeStatus = .dead
                } else {
                    window.invalidateNativeWindowGeometry()
                    window.setAxFrame(self.leftFrame.topLeftCorner, self.leftFrame.size)
                }
            }

            try await resetManipulatedWithMouseIfPossible()

            XCTAssertNil(currentlyManipulatedWithMouseWindowId)
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window))
            if closes {
                XCTAssertNil(window.parent)
                XCTAssertNil(Window.get(byId: window.windowId))
            } else {
                XCTAssertTrue(window.parent === left.floatingWindowsContainer)
                let frame = try await window.getAxRect(.nonCancellable)
                XCTAssertEqual(frame, leftFrame)
            }
            try await resetManipulatedWithMouseIfPossible()
            XCTAssertFalse(right.allLeafWindowsRecursive.contains(window))
        }
    }

    private var leftFrame: Rect { Rect(topLeftX: 200, topLeftY: 120, width: 600, height: 400) }
    private var rightFrame: Rect { Rect(topLeftX: 2200, topLeftY: 120, width: 600, height: 400) }

    private func twoWorkspaces() -> (Workspace, Workspace) {
        setUpWorkspacesForTests()
        let monitors = lifecycleMonitors(2)
        setMonitorInfosForTests(monitors)
        let left = globalFocus.workspace
        let right = Workspace.get(byName: "right-display")
        XCTAssertTrue(monitors[0].setVisibleWorkspace(left))
        XCTAssertTrue(monitors[1].setVisibleWorkspace(right))
        return (left, right)
    }
}
