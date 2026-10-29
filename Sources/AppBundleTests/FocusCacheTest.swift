@testable import AppBundle
import XCTest

// Upstream PR #2280, narrowed so that Cmd-Tab, Dock and notification clicks still bring a hidden workspace up.
// updateFocusCache itself needs a MacApp (macAppUnsafe), so the tests cover the decision it makes.
@MainActor
final class FocusCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOffScreenWindowOfAVisibleAppIsAnActivationArtifact() {
        let visible = Workspace.get(byName: name)
        let hidden = Workspace.get(byName: "hidden")
        assertTrue(mainMonitorInfo.setVisibleWorkspace(visible))
        let visibleWindow = TestWindow.new(id: 1, parent: visible.rootTilingContainer)
        let hiddenWindow = TestWindow.new(id: 2, parent: hidden.rootTilingContainer)
        assertTrue(visibleWindow.focusWindow())

        assertTrue(isActivationArtifact(hiddenWindow))
    }

    func testDeliberateSwitchToAnAppWithNoVisibleWindowIsAdopted() {
        let visible = Workspace.get(byName: name)
        let hidden = Workspace.get(byName: "hidden")
        assertTrue(mainMonitorInfo.setVisibleWorkspace(visible))
        let hiddenWindow = TestWindow.new(id: 2, parent: hidden.rootTilingContainer)

        assertFalse(isActivationArtifact(hiddenWindow))
    }

    // Things answers "my window is focused" after macOS has already switched to Fantastical
    func testReadingIsStaleWhenTheFrontmostAppChangedDuringIt() {
        assertTrue(isNativeFocusReadingStale(frontmostPidBefore: 100, frontmostPidAfter: 200))
        assertTrue(isNativeFocusReadingStale(frontmostPidBefore: 100, frontmostPidAfter: nil))
        assertFalse(isNativeFocusReadingStale(frontmostPidBefore: 100, frontmostPidAfter: 100))
        assertFalse(isNativeFocusReadingStale(frontmostPidBefore: nil, frontmostPidAfter: nil))
    }

    func testVisibleWindowIsNeverAnArtifact() {
        let visible = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(visible))
        let window = TestWindow.new(id: 1, parent: visible.floatingWindowsContainer)
        assertFalse(isActivationArtifact(window))
    }

    // A browser window opened here and closed with Cmd-W: macOS keys the browser's long-lived window elsewhere
    func testCloseKeepsTheWorkspaceWhenMacOsKeysAWindowElsewhere() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        let remaining = TestWindow.new(id: 1, parent: here.rootTilingContainer)
        let browser = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        assertTrue(remaining.focusWindow())
        let closedAt = Date.now
        let hold = WorkspaceFocusHold(workspaceName: here.name, since: closedAt)

        assertTrue(isPulledOffHeldWorkspace(browser, hold: hold, now: closedAt.addingTimeInterval(0.2)))
        assertFalse(isPulledOffHeldWorkspace(browser, hold: hold, now: closedAt.addingTimeInterval(1.5)))
        assertFalse(isPulledOffHeldWorkspace(browser, hold: nil, now: closedAt))
    }

    // The same, opened on an empty workspace: closing it leaves the workspace empty, as `aerospace workspace` would
    func testCloseKeepsAWorkspaceItLeftEmpty() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        assertTrue(here.focusWorkspace())
        let browser = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        let hold = WorkspaceFocusHold(workspaceName: here.name, since: .now)

        assertTrue(isPulledOffHeldWorkspace(browser, hold: hold))
    }

    func testWindowOnTheHeldWorkspaceIsAdopted() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        let remaining = TestWindow.new(id: 1, parent: here.rootTilingContainer)
        let sibling = TestWindow.new(id: 2, parent: here.rootTilingContainer)
        assertTrue(remaining.focusWindow())
        let hold = WorkspaceFocusHold(workspaceName: here.name, since: .now)

        assertFalse(isPulledOffHeldWorkspace(sibling, hold: hold))
    }

    // Once macOS's focus is back on the workspace, a Cmd-Tab to an app elsewhere is a request
    func testHoldSettlesWhenMacOsFocusIsBackOnTheWorkspace() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        let remaining = TestWindow.new(id: 1, parent: here.rootTilingContainer)
        let browser = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        assertTrue(remaining.focusWindow())
        let hold = WorkspaceFocusHold(workspaceName: here.name, since: .now)

        assertTrue(hasFocusSettledOnHeldWorkspace(remaining, hold: hold, aeroSpaceIsFrontmost: false))
        assertFalse(hasFocusSettledOnHeldWorkspace(browser, hold: hold, aeroSpaceIsFrontmost: false))
        assertFalse(hasFocusSettledOnHeldWorkspace(remaining, hold: nil, aeroSpaceIsFrontmost: false))
    }

    // On an emptied workspace AeroSpace takes the keystrokes; an app between windows reports none and has not settled
    func testHoldOnAnEmptiedWorkspaceSettlesWhenAeroSpaceTakesTheKeystrokes() {
        let hold = WorkspaceFocusHold(workspaceName: name, since: .now)

        assertTrue(hasFocusSettledOnHeldWorkspace(nil, hold: hold, aeroSpaceIsFrontmost: true))
        assertFalse(hasFocusSettledOnHeldWorkspace(nil, hold: hold, aeroSpaceIsFrontmost: false))
    }

    // `aerospace workspace` or another command moved focus on after the close
    func testHoldEndsWhenFocusMovesToAnotherWorkspace() {
        let there = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(there))
        let thereWindow = TestWindow.new(id: 1, parent: there.rootTilingContainer)
        let browser = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        assertTrue(thereWindow.focusWindow())
        let hold = WorkspaceFocusHold(workspaceName: "closedHere", since: .now)

        assertFalse(isPulledOffHeldWorkspace(browser, hold: hold))
    }

    func testFocusedWindowLeavingStartsAHoldOnItsWorkspace() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        let tiled = TestWindow.new(id: 1, parent: here.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: here.floatingWindowsContainer)
        let now = Date.now

        assertTrue(tiled.focusWindow())
        assertEquals(workspaceFocusHold(forLeaving: tiled, now: now), WorkspaceFocusHold(workspaceName: here.name, since: now))
        assertNil(workspaceFocusHold(forLeaving: floating, now: now))
        assertTrue(floating.focusWindow())
        assertEquals(workspaceFocusHold(forLeaving: floating, now: now), WorkspaceFocusHold(workspaceName: here.name, since: now))
    }

    // Switching away from a native fullscreen window's Space also takes it out of AXWindows
    func testNativeFullscreenWindowLeavingStartsNoHold() {
        let here = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(here))
        let fullscreen = TestWindow.new(id: 1, parent: here.macOsNativeFullscreenWindowsContainer)
        assertTrue(fullscreen.focusWindow())

        assertNil(workspaceFocusHold(forLeaving: fullscreen))
    }
}
