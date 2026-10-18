@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused, !isActivationArtifact(nativeFocused) {
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
