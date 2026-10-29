@testable import AppBundle
import XCTest

@MainActor
final class MonitorTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testStaleMonitorFallsBackToClosestLiveMonitor() {
        let left = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        let right = testMonitor(2, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([left, right])
        let workspace = Workspace.get(byName: "right")
        assertTrue(right.setVisibleWorkspace(workspace))

        setMonitorInfosForTests([left]) // The right monitor is unplugged; `right` is now a stale snapshot

        // Used to recurse until the stack guard was hit (issue #506)
        assertTrue(right.toMonitorOrRearrangeMonitors() === left.toMonitorOrRearrangeMonitors())
        assertEquals(right.visibleWorkspace, left.visibleWorkspace)
        assertEquals(workspace.workspaceMonitorInfo.rect, left.rect) // Moved to the remaining monitor
    }

    func testEmptyScreenListKeepsKnownMonitors() {
        let left = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        let right = testMonitor(2, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([left, right])
        let workspace = Workspace.get(byName: "right")
        assertTrue(right.setVisibleWorkspace(workspace))

        setMonitorInfosForTests([]) // Every display momentarily off during reconfiguration

        assertEquals(Monitor.all.count, 2)
        assertEquals(right.visibleWorkspace, workspace)
        _ = CGPoint(x: 100, y: 100).monitorApproximation // Used to die on the empty list
    }

    func testGeometryChangeAtSameCornerRefreshesMonitorInfo() {
        let before = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([before])
        assertEquals(before.toMonitorOrRearrangeMonitors().info.visibleRect, before.visibleRect)

        // The Dock appears: same corner and size, smaller visible rect. macOS reports it without a monitor change
        let after = testMonitor(1, before.rect, visibleRect: Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 980))
        monitorInfosForTests = [after]
        gcMonitors()

        assertEquals(after.toMonitorOrRearrangeMonitors().info.visibleRect, after.visibleRect)
        assertEquals(Workspace.get(byName: name).workspaceMonitorInfo.visibleRect, after.visibleRect)
    }

    func testWorkspacesReturnWhenTheirMonitorReconnects() {
        let left = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        let right = testMonitor(2, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([left, right])
        let shown = Workspace.get(byName: "shown")
        let hidden = Workspace.get(byName: "hidden")
        TestWindow.new(id: 1, parent: shown.rootTilingContainer)
        TestWindow.new(id: 2, parent: hidden.rootTilingContainer)
        assertTrue(right.setVisibleWorkspace(hidden))
        assertTrue(right.setVisibleWorkspace(shown))
        let leftVisible = left.visibleWorkspace

        setMonitorInfosForTests([left]) // Unplugged, or asleep
        assertEquals(shown.workspaceMonitorInfo.rect, left.rect)
        assertEquals(hidden.workspaceMonitorInfo.rect, left.rect)

        setMonitorInfosForTests([left, right]) // Back
        assertEquals(shown.workspaceMonitorInfo.rect, right.rect)
        assertEquals(hidden.workspaceMonitorInfo.rect, right.rect)
        assertEquals(right.visibleWorkspace, shown)
        assertEquals(left.visibleWorkspace, leftVisible)
    }

    func testWorkspaceShownElsewhereMeanwhileStaysThere() {
        let left = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        let right = testMonitor(2, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([left, right])
        let workspace = Workspace.get(byName: "moved")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(right.setVisibleWorkspace(workspace))

        setMonitorInfosForTests([left])
        assertTrue(left.setVisibleWorkspace(workspace)) // The user switches to it while the monitor is gone
        setMonitorInfosForTests([left, right])

        assertEquals(workspace.workspaceMonitorInfo.rect, left.rect)
        assertEquals(left.visibleWorkspace, workspace)
        assertTrue(right.visibleWorkspace != workspace)
    }

    func testRecreatedWorkspaceDoesNotFollowItsCollectedNamesake() {
        let left = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        let right = testMonitor(2, Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([left, right])
        assertTrue(right.setVisibleWorkspace(Workspace.get(byName: "w")))
        assertTrue(right.setVisibleWorkspace(Workspace.get(byName: "other")))

        setMonitorInfosForTests([left]) // "w" now remembers the right monitor as its home
        Workspace.garbageCollectUnusedWorkspaces() // "w" is empty and invisible
        let recreated = Workspace.get(byName: "w")
        TestWindow.new(id: 1, parent: recreated.rootTilingContainer)
        setMonitorInfosForTests([left, right])

        assertEquals(recreated.workspaceMonitorInfo.rect, left.rect)
    }

    func testClamshellDayKeepsEveryWorkspace() {
        // Lid closed at work: the external monitor is the only screen
        let work = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 3840, height: 2160))
        setMonitorInfosForTests([work])
        let mail = Workspace.get(byName: "mail")
        let code = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: mail.rootTilingContainer)
        TestWindow.new(id: 2, parent: code.rootTilingContainer)
        TestWindow.new(id: 3, parent: code.rootTilingContainer)
        assertTrue(work.setVisibleWorkspace(mail))
        assertTrue(work.setVisibleWorkspace(code))

        setMonitorInfosForTests([]) // Unplugged with the lid closed: no screen at all, the Mac sleeps

        let builtIn = testMonitor(2, Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982))
        setMonitorInfosForTests([builtIn]) // At home with the lid open
        assertEquals(mail.workspaceMonitorInfo.rect, builtIn.rect)
        assertEquals(code.workspaceMonitorInfo.rect, builtIn.rect)
        assertTrue(builtIn.setVisibleWorkspace(mail))

        setMonitorInfosForTests([work]) // Back at work, lid closed, monitor plugged in
        assertEquals(Monitor.all.count, 1)
        assertEquals(mail.workspaceMonitorInfo.rect, work.rect)
        assertEquals(code.workspaceMonitorInfo.rect, work.rect)
        assertEquals(code.rootTilingContainer.children.count, 2)
        assertEquals(work.visibleWorkspace, mail) // Whatever was last shown at home
    }

    func testWindowMacosMovedWhileTheDisplayBlinkedIsTiledAgain() async throws {
        let screen = testMonitor(1, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080))
        setMonitorInfosForTests([screen])
        let workspace = screen.visibleWorkspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let tiled = try await window.getAxRect(.nonCancellable).orDie()

        // The display goes off and on again, and macOS moves the window meanwhile
        setMonitorInfosForTests([])
        window.setAxFrame(CGPoint(x: 100, y: 100), CGSize(width: 800, height: 600))
        setMonitorInfosForTests([screen])

        // Its tile comes out the same as before, which used to skip the write and leave it where macOS put it
        try await workspace.layoutWorkspace()
        assertEquals(try await window.getAxRect(.nonCancellable), tiled)
    }

    func testGarbageCollectedWorkspaceLeavesTheTree() {
        let workspace = Workspace.get(byName: "collected")
        let container = workspace.parent
        assertTrue(container != nil)

        Workspace.garbageCollectUnusedWorkspaces() // Empty, invisible and unfocused

        assertTrue(workspace.parent == nil)
        assertTrue(container?.children.contains(where: { $0 === workspace }) == false)
        assertTrue(Workspace.get(byName: "collected") !== workspace)
    }
}

private struct MonitorTestMonitorInfo: MonitorInfo {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

private func testMonitor(_ id: Int, _ rect: Rect, visibleRect: Rect? = nil) -> MonitorInfo {
    MonitorTestMonitorInfo(
        monitorAppKitNsScreenScreensId: id,
        name: "Test Monitor \(id)",
        rect: rect,
        visibleRect: visibleRect ?? rect,
        isMain: rect.topLeftX == 0 && rect.topLeftY == 0,
    )
}
