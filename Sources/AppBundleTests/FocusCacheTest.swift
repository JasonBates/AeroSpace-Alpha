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

    func testVisibleWindowIsNeverAnArtifact() {
        let visible = Workspace.get(byName: name)
        assertTrue(mainMonitorInfo.setVisibleWorkspace(visible))
        let window = TestWindow.new(id: 1, parent: visible.floatingWindowsContainer)
        assertFalse(isActivationArtifact(window))
    }
}
