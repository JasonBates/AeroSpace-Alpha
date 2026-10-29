import AppKit

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// Reads the native focused window and adopts it (see updateFocusCache).
///
/// The read asks the frontmost app over AX, and an app that is losing focus can take ~100 ms to answer. If macOS
/// made another app frontmost meanwhile, a later session has usually adopted that app's window already, and this
/// stale answer would pull focus back to the app the user just left: the focus border flicks back to it, and stays
/// there if no later session corrects it. So the answer is dropped when the frontmost app changed during the read.
@MainActor func syncFocusFromMacOs(_ cm: CancellationMode) async throws {
    let frontmostPidBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let nativeFocused = try await getNativeFocusedWindow(cm)
    let frontmostPidAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if isNativeFocusReadingStale(frontmostPidBefore: frontmostPidBefore, frontmostPidAfter: frontmostPidAfter) { return }
    if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, cm) }
    updateFocusCache(nativeFocused)
}

func isNativeFocusReadingStale(frontmostPidBefore: pid_t?, frontmostPidAfter: pid_t?) -> Bool {
    frontmostPidBefore != frontmostPidAfter
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused, isFocusHandedOverByClose(nativeFocused, closed: lastClosedFocusedWindow) {
            // Keep the workspace, and key its window so keystrokes don't go to the parked one
            globalFocus.windowOrNil?.nativeFocus()
        } else if let nativeFocused, !isActivationArtifact(nativeFocused) {
            _ = nativeFocused.focusWindow()
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    // Dialogs/sheets (e.g. Finder's "Connect to Server") aren't native-tab group members. Letting
    // one become the replacement candidate poisons the comparison: it closes normally later, so
    // whichever tiled window is actually mid-tab-swap when it closes never gets matched.
    if !(nativeFocused?.parent is FloatingWindowsContainer) {
        nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
    }
}

/// The focused window that closed last: its app, its workspace and when (see isFocusHandedOverByClose)
struct ClosedFocusedWindow: Equatable {
    let pid: pid_t
    let workspaceName: String
    let date: Date
}

@MainActor var lastClosedFocusedWindow: ClosedFocusedWindow? = nil

/// Closing an app's focused window makes macOS key that app's next window, wherever it is. A browser window
/// opened on this workspace and closed with Cmd-W hands focus to a long-lived browser window on another
/// workspace, and adopting it takes the user there. For a second after the close, a window of the same app
/// outside the workspace is ignored while the workspace still has a window for AeroSpace to focus.
/// A workspace left empty still follows the app, so the user can see the window that now takes keystrokes.
@MainActor func isFocusHandedOverByClose(_ nativeFocused: Window, closed: ClosedFocusedWindow?, now: Date = .now) -> Bool {
    guard let closed, closed.date.distance(to: now) < 1, nativeFocused.app.pid == closed.pid else { return false }
    let focus = globalFocus
    guard focus.workspace.name == closed.workspaceName, let window = focus.windowOrNil, window != nativeFocused else {
        return false
    }
    return nativeFocused.visualWorkspace != focus.workspace
}

/// Upstream PR #2280. When an app with windows on two monitors is activated, macOS may make one of
/// its off-screen windows (parked, on an invisible workspace) the key window. That window cannot
/// have been clicked, so adopting the focus would pull its workspace onto its monitor for no reason.
///
/// Narrowed from the PR: a window on an invisible workspace is ignored only while the same app has
/// a window on a visible workspace. If nothing of the app is visible, the user asked for it
/// (Cmd-Tab, a Dock click, a notification), and its workspace must come up as before.
@MainActor func isActivationArtifact(_ nativeFocused: Window) -> Bool {
    if nativeFocused.visualWorkspace?.isVisible != false { return false }
    let pid = nativeFocused.app.pid
    return Workspace.all.contains { workspace in
        workspace.isVisible && workspace.allLeafWindowsRecursive.contains { $0.app.pid == pid }
    }
}
