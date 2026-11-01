import Common

/// The workspace of every window as of the last check. Used to report window-moved events.
/// Minimized windows are recorded as `minimizedMarker`; workspace names are never empty
@MainActor private var lastKnownWindowWorkspaces: [OpaqueWindowId: String] = [:]
private let minimizedMarker = ""

/// Where a window is for window-moved purposes: its workspace name, `minimizedMarker`, or nil if untracked (popups)
@MainActor private func trackedLocation(_ window: Window) -> String? {
    if let workspace = window.nodeWorkspace { return workspace.name }
    return window.parent is MacosMinimizedWindowsContainer ? minimizedMarker : nil
}

@MainActor func rememberWindowWorkspace(_ window: Window) {
    lastKnownWindowWorkspaces[window.windowId] = trackedLocation(window)
}

@MainActor func forgetWindowWorkspace(_ windowId: OpaqueWindowId) {
    lastKnownWindowWorkspaces.removeValue(forKey: windowId)
}

// Should be called in refreshSession
@MainActor func checkWindowWorkspaceChanges() {
    for event in collectWindowMovedEvents() {
        broadcastEvent(event)
    }
}

/// Windows that are somewhere else than at the previous check: on another workspace, minimized
/// (the event has no `workspace`) or restored from the Dock (the event has no `prevWorkspace`)
@MainActor func collectWindowMovedEvents() -> [ServerEvent] {
    let windows = Workspace.all.flatMap(\.allLeafWindowsRecursive) +
        macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    var current: [OpaqueWindowId: String] = [:]
    var events: [ServerEvent] = []
    for window in windows {
        guard let location = trackedLocation(window) else { continue }
        current[window.windowId] = location
        if let prev = lastKnownWindowWorkspaces[window.windowId], prev != location {
            events.append(.windowMoved(
                windowId: window.windowId,
                workspace: location == minimizedMarker ? nil : location,
                prevWorkspace: prev == minimizedMarker ? nil : prev,
                appBundleId: window.app.rawAppBundleId,
                appName: window.app.name,
            ))
        }
    }
    lastKnownWindowWorkspaces = current
    return events
}
