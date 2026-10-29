import AppKit
import Common

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
        if let nativeFocused, isPulledOffHeldWorkspace(nativeFocused, hold: workspaceFocusHold) {
            // Keep the workspace, and take the keystrokes from the parked window macOS keyed
            if let window = globalFocus.windowOrNil {
                window.nativeFocus()
            } else {
                takeKeystrokesForEmptyWorkspace()
            }
        } else {
            let aeroSpaceIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == myPid
            if hasFocusSettledOnHeldWorkspace(nativeFocused, hold: workspaceFocusHold, aeroSpaceIsFrontmost: aeroSpaceIsFrontmost) {
                workspaceFocusHold = nil
            }
            if let nativeFocused, !isActivationArtifact(nativeFocused) {
                _ = nativeFocused.focusWindow()
            }
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

/// A window closing never changes the workspace. When the focused window leaves a workspace, macOS hands
/// focus to some other window, wherever it is: Cmd-W on a browser window keys the browser's long-lived
/// window on another workspace, and an app that quits with its last window activates the next app. That is
/// fallout of the close, not a request, so the workspace keeps the focus, on its next window or empty, as it
/// would after `aerospace workspace`. The hold ends once macOS's focus is back on the workspace, within
/// milliseconds, so a Cmd-Tab straight after the close is adopted; a second is the most it lasts. A command
/// that moves focus elsewhere ends it too (the workspace no longer matches), and so does a click.
struct WorkspaceFocusHold: Equatable {
    let workspaceName: String
    let since: Date
}

@MainActor var workspaceFocusHold: WorkspaceFocusHold? = nil

/// Starts the hold when the window leaving the tree is the focused, ordinary window of its workspace,
/// whether it closed or was taken for a native tab switched away from. A native fullscreen window is left
/// out: leaving it is a Space change the native tab check can't tell from a closed window.
@MainActor func workspaceFocusHold(forLeaving window: Window, now: Date = .now) -> WorkspaceFocusHold? {
    guard globalFocus.windowOrNil == window, window.parent is TilingContainer || window.parent is FloatingWindowsContainer,
          let workspace = window.nodeWorkspace
    else { return nil }
    return WorkspaceFocusHold(workspaceName: workspace.name, since: now)
}

@MainActor func holdWorkspaceFocusIfFocused(leaving window: Window) {
    if let hold = workspaceFocusHold(forLeaving: window) { workspaceFocusHold = hold }
}

/// A held workspace the close left empty has no window to give the keystrokes to, and the window macOS keyed is
/// parked on another workspace: a second Cmd-W would close one of its tabs unseen. AeroSpace takes them itself. It
/// has no window that can become key, and its app menu has no Quit or Hide shortcut (AeroSpaceApp), so keystrokes go
/// nowhere until the user picks a window. AeroSpace ignores itself as the frontmost app, so its focus stays put.
@MainActor func takeKeystrokesForEmptyWorkspace() {
    if isUnitTest || serverArgs.isReadOnly { return }
    NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
}

/// macOS reports one of the held workspace's windows, or, on a workspace the close left empty, AeroSpace itself
/// (takeKeystrokesForEmptyWorkspace). The window macOS keyed elsewhere has been dealt with, and its app is no
/// longer frontmost, so it cannot be reported again.
@MainActor func hasFocusSettledOnHeldWorkspace(_ nativeFocused: Window?, hold: WorkspaceFocusHold?, aeroSpaceIsFrontmost: Bool) -> Bool {
    guard let hold else { return false }
    guard let nativeFocused else { return aeroSpaceIsFrontmost }
    return nativeFocused.visualWorkspace?.name == hold.workspaceName
}

@MainActor func isPulledOffHeldWorkspace(_ nativeFocused: Window, hold: WorkspaceFocusHold?, now: Date = .now) -> Bool {
    guard let hold, hold.since.distance(to: now) < 1 else { return false }
    let focus = globalFocus
    return focus.workspace.name == hold.workspaceName && nativeFocused.visualWorkspace != focus.workspace
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
