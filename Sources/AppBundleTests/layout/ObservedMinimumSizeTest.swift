@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class ObservedMinimumSizeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRefusalTeachesTheMinimumAndAcceptanceBelowItForgetsIt() {
        let unknown = ObservedMinimumSize()
        let learned = unknown.updated(requested: CGSize(width: 400, height: 900), observed: CGSize(width: 570, height: 900))
        assertEquals(learned, ObservedMinimumSize(width: 570, height: nil))

        // Rounding noise repeats the known minimum instead of replacing it
        assertEquals(learned.updated(requested: CGSize(width: 400, height: 900), observed: CGSize(width: 570.4, height: 900)), learned)
        // An app's minimum can grow (a sidebar opens) and is replaced, not maximised
        assertEquals(
            learned.updated(requested: CGSize(width: 400, height: 900), observed: CGSize(width: 650, height: 900)),
            ObservedMinimumSize(width: 650, height: nil),
        )
        // Accepting less than the known minimum means the minimum has shrunk
        assertEquals(learned.updated(requested: CGSize(width: 300, height: 900), observed: CGSize(width: 300, height: 900)), unknown)
        // Accepting more says nothing new
        assertEquals(learned.updated(requested: CGSize(width: 800, height: 900), observed: CGSize(width: 800, height: 900)), learned)
        // Coming back smaller than requested is a maximum or a size increment, not a minimum
        assertEquals(unknown.updated(requested: CGSize(width: 800, height: 900), observed: CGSize(width: 790, height: 880)), unknown)
        // Each axis is learned on its own
        assertEquals(
            unknown.updated(requested: CGSize(width: 800, height: 300), observed: CGSize(width: 800, height: 500)),
            ObservedMinimumSize(width: nil, height: 500),
        )
    }

    func testAdaptiveColumnGrowsToTheAppMinimumInsteadOfOverlappingItsNeighbour() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let browser = TestWindow.new(id: 1, parent: root)
        let neighbour = TestWindow.new(id: 2, parent: root, adaptiveWeight: WEIGHT_AUTO)
        browser.appMinimumSizeForTest = CGSize(width: 500, height: 0)
        try await workspace.layoutWorkspace()

        // The configured floor (60% of 633.6) allows a 433.6 tile, but the app stays 500 wide
        assertTrue(browser.focusWindow())
        let result = await parseCommand("resize width -200").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        assertRect(try await browser.getAxRect(.nonCancellable), x: 326.4, width: 500)
        assertRect(try await neighbour.getAxRect(.nonCancellable), x: 760, width: 833.6)

        try await learnFromLastFrame(browser)
        assertEquals(browser.observedMinimumSize, ObservedMinimumSize(width: 500, height: nil))
        try await workspace.layoutWorkspace()
        // Like a configured floor, the minimum widens the centred layout and keeps the neighbour's share
        try await assertSideBySide(browser, neighbour, firstWidth: 500)
        let neighbourWidth = try await neighbour.getAxRect(.nonCancellable)?.width ?? 0
        assertTrue(neighbourWidth > 767.2)

        // Further shrinking stops at the app's minimum
        _ = await parseCommand("resize width -100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        try await assertSideBySide(browser, neighbour, firstWidth: 500)
    }

    func testAdaptiveVerticalStackKeepsItsWidestObservedMinimum() async throws {
        config.adaptiveLayout.enabled = .constant(true)
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let browser = TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: WEIGHT_AUTO)
        let top = TestWindow.new(id: 2, parent: stack)
        TestWindow.new(id: 3, parent: stack)
        top.appMinimumSizeForTest = CGSize(width: 800, height: 0)
        try await workspace.layoutWorkspace()
        assertRect(try await browser.getAxRect(.nonCancellable), x: 326.4, width: 633.6)
        assertRect(try await top.getAxRect(.nonCancellable), x: 960, width: 800)

        try await learnFromLastFrame(top)
        try await workspace.layoutWorkspace()
        // The whole stack widens to its widest window's minimum, so the windows below it line up.
        // The centred layout grows to 1600 to keep the columns' equal shares
        assertRect(try await browser.getAxRect(.nonCancellable), x: 160, width: 800)
        for window in stack.children {
            assertRect(try await (window as! Window).getAxRect(.nonCancellable), x: 960, width: 800)
        }
    }

    func testNormalTilesMakeRoomForAnObservedMinimumWhileItFits() async throws {
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let wide = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        wide.appMinimumSizeForTest = CGSize(width: 900, height: 0)
        try await workspace.layoutWorkspace()
        assertRect(try await wide.getAxRect(.nonCancellable), x: 0, width: 900)
        assertRect(try await second.getAxRect(.nonCancellable), x: 640, width: 640)

        try await learnFromLastFrame(wide)
        try await workspace.layoutWorkspace()
        assertRect(try await wide.getAxRect(.nonCancellable), x: 0, width: 900)
        assertRect(try await second.getAxRect(.nonCancellable), x: 900, width: 510)
        assertRect(try await third.getAxRect(.nonCancellable), x: 1410, width: 510)
    }

    func testNormalTilesKeepTheirWeightsWhenObservedMinimumsCannotFit() async throws {
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        let windows = [TestWindow.new(id: 1, parent: root), TestWindow.new(id: 2, parent: root)]
        for window in windows {
            window.appMinimumSizeForTest = CGSize(width: 1000, height: 0)
        }
        try await workspace.layoutWorkspace()
        for window in windows {
            try await learnFromLastFrame(window)
        }
        try await workspace.layoutWorkspace()
        assertEquals(root.children.map(\.hWeight), [960, 960])
    }

    func testStackedWindowKeepsItsObservedMinimumHeight() async throws {
        let workspace = globalFocus.workspace
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let top = TestWindow.new(id: 1, parent: root)
        let bottom = TestWindow.new(id: 2, parent: root)
        bottom.appMinimumSizeForTest = CGSize(width: 0, height: 700)
        try await workspace.layoutWorkspace()
        try await learnFromLastFrame(bottom)
        try await workspace.layoutWorkspace()
        assertRect(try await top.getAxRect(.nonCancellable), y: 0, height: 379)
        assertRect(try await bottom.getAxRect(.nonCancellable), y: 379, height: 700)
    }

    func testConfirmationIgnoresAFrameThatHasSinceBeenReplaced() async throws {
        let workspace = globalFocus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window.appMinimumSizeForTest = CGSize(width: 1200, height: 0)
        try await workspace.layoutWorkspace()
        try await window.confirmObservedMinimumSize(requested: CGSize(width: 500, height: 1079))
        assertEquals(window.observedMinimumSize, ObservedMinimumSize())
    }

    func testBalanceSizesForgetsObservedMinimums() async {
        let workspace = globalFocus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.observedMinimumSize = ObservedMinimumSize(width: 900, height: 700)
        assertTrue(window.focusWindow())
        let result = await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window.observedMinimumSize, ObservedMinimumSize())
    }
}

@MainActor
private func assertSideBySide(_ first: Window, _ second: Window, firstWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws {
    let leftRect = try await first.getAxRect(.nonCancellable)
    let rightRect = try await second.getAxRect(.nonCancellable)
    let left = try XCTUnwrap(leftRect, file: file, line: line)
    let right = try XCTUnwrap(rightRect, file: file, line: line)
    XCTAssertEqual(left.width, firstWidth, accuracy: 0.001, "width", file: file, line: line)
    XCTAssertEqual(right.minX, left.maxX, accuracy: 0.001, "the windows touch without overlapping", file: file, line: line)
    XCTAssertGreaterThanOrEqual(left.minX, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(right.maxX, 1920, file: file, line: line)
}

/// What MacApp does after a frame write: confirm the size the app settled at against the frame requested.
@MainActor
private func learnFromLastFrame(_ window: Window) async throws {
    let requested = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect).size
    try await window.confirmObservedMinimumSize(requested: requested)
}

private func assertRect(
    _ actual: Rect?,
    x: CGFloat? = nil,
    y: CGFloat? = nil,
    width: CGFloat? = nil,
    height: CGFloat? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
) {
    guard let actual else {
        XCTFail("Expected a rect", file: file, line: line)
        return
    }
    if let x { XCTAssertEqual(actual.topLeftX, x, accuracy: 0.001, "x", file: file, line: line) }
    if let y { XCTAssertEqual(actual.topLeftY, y, accuracy: 0.001, "y", file: file, line: line) }
    if let width { XCTAssertEqual(actual.width, width, accuracy: 0.001, "width", file: file, line: line) }
    if let height { XCTAssertEqual(actual.height, height, accuracy: 0.001, "height", file: file, line: line) }
}
