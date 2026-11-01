@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NativeTabWindowReplacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testReplacementPreservesNestedTreeSlotAndWeight() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let container = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: container)
        let window = TestWindow.new(id: 2, parent: container, adaptiveWeight: 3)
        TestWindow.new(id: 3, parent: container)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(window.windowId, 100)

        assertEquals(remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: window), 2)
        assertEquals(container.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(window.getWeight(.h), 3)
        assertEquals(mapping.forward[2], 200)
        XCTAssertNil(mapping.backward[100])
        assertEquals(mapping.backward[200], 2)
    }

    func testNoReplacementWhenStaleWindowIsUnknown() {
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        XCTAssertNil(remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: nil))
        XCTAssertTrue(mapping.forward.isEmpty)
    }

    func testNoReplacementWhenStaleWindowIsAlreadyUnbound() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(1, 100)
        window.unbindFromParent()
        XCTAssertNil(remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: window))
        assertEquals(mapping.forward[1], 100)
    }

    func testReplacementChangesExactlyTheGivenLogicalWindow() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let untouched = TestWindow.new(id: 1, parent: root)
        let window = TestWindow.new(id: 2, parent: root)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(1, 100)
        mapping.put(2, 200)
        remapNativeTabWindow(background: 200, frontmost: 300, mapping: &mapping, window: window)
        XCTAssertTrue(untouched.isBound)
        XCTAssertTrue(window.isBound)
        assertEquals(mapping.forward[1], 100)
        assertEquals(mapping.forward[2], 300)
    }

    func testDetectsNativeTabReplacement() {
        let candidate = nativeTabRemapCandidate(previous: [100: .alive], current: [100: .invisible, 200: .alive], isMouseButtonDown: false)
        assertEquals(candidate?.background, 100)
        assertEquals(candidate?.frontmost, 200)
    }

    func testDoesNotReplaceLiveOrUntrackedPreviousWindow() {
        XCTAssertNil(nativeTabRemapCandidate(previous: [100: .alive], current: [100: .alive, 200: .alive], isMouseButtonDown: false))
        XCTAssertNil(nativeTabRemapCandidate(previous: [:], current: [200: .alive], isMouseButtonDown: false))
    }

    func testDefersNativeTabReplacementWhileDragging() {
        XCTAssertNil(nativeTabRemapCandidate(previous: [100: .alive], current: [100: .invisible, 200: .alive], isMouseButtonDown: true))
    }

    func testTabRemapNeedsNoCancellableRectFetch() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        window.onGetAxRect = { XCTFail("A logical remap must not fetch AX geometry or splice nodes") }
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(1, 100)
        remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: window)
        XCTAssertNotNil(window.onGetAxRect)
    }

    func testEarlyFocusedTabWaitsForEnumerationAndCanRemapOnNextCycle() {
        XCTAssertFalse(shouldRegisterFocusedWindow(lifeStatus: .invisible, incomplete: false))
        XCTAssertFalse(shouldRegisterFocusedWindow(lifeStatus: .alive, incomplete: true))
        XCTAssertTrue(shouldRegisterFocusedWindow(lifeStatus: .alive, incomplete: false))
        let candidate = nativeTabRemapCandidate(previous: [100: .alive, 200: .invisible], current: [100: .invisible, 200: .alive], isMouseButtonDown: false)
        assertEquals(candidate?.background, 100)
        assertEquals(candidate?.frontmost, 200)
    }

    func testAppFocusingItsWindowOnAnotherWorkspaceMeansTheOldWindowClosed() {
        let source = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let destination = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        XCTAssertFalse(canRemapNativeTabWindow(source: source, destination: destination))
        XCTAssertNil(nativeTabRemapCandidate(previous: [100: .alive], current: [200: .alive], isMouseButtonDown: false))
    }

    func testFloatingNativeTabPreservesItsParentAndFrame() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        window.lastFloatingSize = CGSize(width: 700, height: 500)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(1, 100)
        XCTAssertTrue(canRemapNativeTabWindow(source: window, destination: nil))
        remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: window)
        XCTAssertTrue(window.parent === workspace.floatingWindowsContainer)
        assertEquals(window.lastFloatingSize, CGSize(width: 700, height: 500))
    }

    func testNativeFullscreenSpaceChangeIsNotTakenForTabSwap() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).macOsNativeFullscreenWindowsContainer)
        XCTAssertFalse(canRemapNativeTabWindow(source: window, destination: nil))
    }

    func testBorderUsesNativeIdentityAndSkipsInvisibleWindows() {
        let window = TestWindow.new(id: OpaqueWindowId(4_294_967_301), parent: Workspace.get(byName: name).rootTilingContainer)
        XCTAssertNil(nativeWindowIdForBorder(window))
        window.nativeWindowIdForTest = 54321
        assertEquals(nativeWindowIdForBorder(window), 54321)
        window.lifeStatus = .invisible
        XCTAssertNil(nativeWindowIdForBorder(window))
    }

    func testRemapInvalidatesPhysicalGeometryAndMinimaButKeepsUserSizingAndFocus() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 700, height: 500)
        window.lastAppliedLayoutVirtualRect = rect
        window.lastAppliedLayoutPhysicalRect = rect
        window.observedMinimumSize = ObservedMinimumSize(width: 650, height: 400)
        window.singleWindowWidthAdjustment = 50
        window.focusModeHeightAdjustment = 25
        window.isFullscreen = true
        XCTAssertTrue(window.focusWindow())
        workspaceFocusHold = nil
        rememberWindowWorkspace(window)
        var mapping = BiDictionary<OpaqueWindowId, UInt32>()
        mapping.put(1, 100)

        remapNativeTabWindow(background: 100, frontmost: 200, mapping: &mapping, window: window)
        XCTAssertNil(window.lastAppliedLayoutPhysicalRect)
        assertEquals(window.lastAppliedLayoutVirtualRect, rect)
        assertEquals(window.observedMinimumSize, ObservedMinimumSize())
        assertEquals(window.singleWindowWidthAdjustment, 50)
        assertEquals(window.focusModeHeightAdjustment, 25)
        XCTAssertTrue(window.isFullscreen)
        XCTAssertTrue(globalFocus.windowOrNil === window)
        XCTAssertNil(workspaceFocusHold)
        XCTAssertTrue(collectWindowMovedEvents().isEmpty)
        assertEquals(window.nativeGeometryGeneration, 1)
    }
}
