@testable import AppBundle
import XCTest

@MainActor
final class NativeTabWindowReplacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testReplacementPreservesNestedTreeSlotAndWeight() throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let container = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: container)
        let oldWindow = TestWindow.new(id: 2, parent: container, adaptiveWeight: 3)
        TestWindow.new(id: 3, parent: container)

        let replacement = takeNativeTabReplacementBinding(from: oldWindow)
        let bindingData = try XCTUnwrap(replacement).bindingData
        let newWindow = TestWindow.new(id: 4, parent: root)
        newWindow.bind(
            to: bindingData.parent,
            adaptiveWeight: bindingData.adaptiveWeight,
            index: bindingData.index,
        )

        assertEquals(container.layoutDescription, .h_tiles([.window(1), .window(4), .window(3)]))
        assertEquals(newWindow.getWeight(.h), 3)
    }

    func testNoReplacementWhenStaleWindowIsNil() {
        let replacement = takeNativeTabReplacementBinding(from: nil)
        XCTAssertNil(replacement)
    }

    func testNoReplacementWhenStaleWindowIsAlreadyUnbound() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        window.unbindFromParent()

        let replacement = takeNativeTabReplacementBinding(from: window)

        XCTAssertNil(replacement)
    }

    func testReplacementUnbindsExactlyTheGivenWindow() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let untouched = TestWindow.new(id: 1, parent: root)
        let staleWindow = TestWindow.new(id: 2, parent: root)

        let replacement = takeNativeTabReplacementBinding(from: staleWindow)

        XCTAssertNotNil(replacement)
        XCTAssertTrue(untouched.isBound)
        XCTAssertFalse(staleWindow.isBound)
    }

    func testDetectsNativeTabReplacement() {
        assertEquals(
            nativeTabReplacementCandidate(
                previousFocusedWindowId: 1,
                focusedWindowId: 2,
                liveWindowIds: [2],
                trackedWindowIds: [1, 2],
                isMouseButtonDown: false,
            ),
            1,
        )
    }

    func testDoesNotReplaceLiveOrUntrackedPreviousWindow() {
        XCTAssertNil(nativeTabReplacementCandidate(
            previousFocusedWindowId: 1,
            focusedWindowId: 2,
            liveWindowIds: [1, 2],
            trackedWindowIds: [1, 2],
            isMouseButtonDown: false,
        ))
        XCTAssertNil(nativeTabReplacementCandidate(
            previousFocusedWindowId: 1,
            focusedWindowId: 2,
            liveWindowIds: [2],
            trackedWindowIds: [2],
            isMouseButtonDown: false,
        ))
    }

    func testDefersNativeTabReplacementWhileDragging() {
        XCTAssertNil(nativeTabReplacementCandidate(
            previousFocusedWindowId: 1,
            focusedWindowId: 2,
            liveWindowIds: [2],
            trackedWindowIds: [1, 2],
            isMouseButtonDown: true,
        ))
    }

    func testReplacementRectFetchIsNonCancellable() {
        XCTAssertEqual(nativeTabReplacementCancellationMode(replacingNativeTabWindowId: 2), .nonCancellable)
    }

    func testNewWindowRectFetchStaysCancellable() {
        XCTAssertEqual(nativeTabReplacementCancellationMode(replacingNativeTabWindowId: nil), .cancellable)
    }

    // Cmd-W on a browser window: the browser keys its long-lived window on another workspace
    func testAppFocusingItsWindowOnAnotherWorkspaceMeansTheOldWindowClosed() {
        let closed = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let elsewhere = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)

        assertTrue(isWindowCloseRatherThanTabSwitch(stale: closed, focused: elsewhere))
    }

    func testAppFocusingAnotherWindowOnTheSameWorkspaceMayBeATabSwitch() {
        let workspace = Workspace.get(byName: name)
        let oldTab = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let otherTab = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertFalse(isWindowCloseRatherThanTabSwitch(stale: oldTab, focused: otherTab))
    }

    // Switching away from a native fullscreen window's Space takes it out of AXWindows; it hasn't closed
    func testNativeFullscreenWindowLeftForAnotherWorkspaceIsNotTakenForClosed() {
        let fullscreen = TestWindow.new(id: 1, parent: Workspace.get(byName: name).macOsNativeFullscreenWindowsContainer)
        let elsewhere = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)

        assertFalse(isWindowCloseRatherThanTabSwitch(stale: fullscreen, focused: elsewhere))
    }
}
