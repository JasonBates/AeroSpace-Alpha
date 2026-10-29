import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

@MainActor
private var enumerationRetryTask: Task<(), Never>? = nil
@MainActor
private var consecutiveEnumerationRetries = 0

/// Delay before retrying a refresh after an app failed to answer the window enumeration in time:
/// exponential backoff capped at 30 seconds, so a permanently hung app can't cause a refresh storm
func enumerationRetryDelaySeconds(attempt: Int) -> Int {
    min(1 << min(attempt, 5), 30)
}

/// Schedule a delayed complete refresh because some app didn't respond to the window enumeration
/// request in time. Debounced: at most one pending retry. Upstream PR #2326, issue #1615
@MainActor
private func scheduleEnumerationRetry() {
    if enumerationRetryTask != nil { return }
    let delaySeconds = enumerationRetryDelaySeconds(attempt: consecutiveEnumerationRetries)
    consecutiveEnumerationRetries += 1
    enumerationRetryTask = Task.startUnstructured { @MainActor in
        defer { enumerationRetryTask = nil }
        try? await Task.sleep(for: .seconds(delaySeconds))
        if Task.isCancelled { return }
        scheduleCancellableCompleteRefreshSession(.ax("windowsEnumerationRetry"))
    }
}

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    activeRefreshTask?.cancel()
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
            optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
        )
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            updateFocusCache(nativeFocused)

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            try await refresh()
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        }
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    activeRefreshTask?.cancel() // Give priority to runSession
    activeRefreshTask = nil
    return try await $refreshSessionEvent.withValue(event) {
        let nativeFocused = try await getNativeFocusedWindow(.cancellable)
        if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
        updateFocusCache(nativeFocused)
        let focusBefore = focus.windowOrNil

        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = focus.windowOrNil

        updateTrayText()
        SecureInputPanel.shared.refresh()
        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        if !event.isFocusFollowsMouse { scheduleCancellableCompleteRefreshSession(event) }
        return result
    }
}

enum RunSessionGuard: Sendable {
    case forceRun

    @MainActor
    static var isServerEnabled: Self? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> Self? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> Self {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        Workspace.forceAssignWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
        checkWindowWorkspaceChanges()
    }
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    if mapping.values.contains(where: \.incomplete) {
        // Some app didn't answer in time (e.g. the system is under load during boot). Without a
        // retry, its new windows stay undetected until the next AX event, which on an idle
        // system may never come. #1615
        scheduleEnumerationRetry()
    } else {
        consecutiveEnumerationRetries = 0
    }
    // A mouse-driven native-tab switch can be observed first by this periodic refresh rather
    // than getFocusedWindow. Preserve the old tree slot before garbage collection removes it.
    var splicedWindowIds: Set<UInt32> = []
    for (app, refreshResult) in mapping {
        if let replacement = refreshResult.nativeTabReplacement,
           refreshResult.aliveWindowIds.contains(replacement.focusedWindowId)
        {
            _ = try await MacWindow.getOrRegister(
                windowId: replacement.focusedWindowId,
                macApp: app,
                replacingNativeTabWindowId: replacement.staleWindowId,
            )
            splicedWindowIds.insert(replacement.focusedWindowId)
        }
    }
    let aliveWindowIds = mapping.values.flatMap(\.aliveWindowIds).toSet()

    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, refreshResult) in mapping {
        for windowId in refreshResult.aliveWindowIds where !splicedWindowIds.contains(windowId) {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

@MainActor
private func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        FocusMode.shared.stop()
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        FocusedWindowBorder.shared.hide()
        HideCornerCovers.shared.hideAll()
        return
    }
    await FocusMode.shared.syncWithFocus()
    let monitors = monitorInfos
    let spots = hideSpots(monitors.map(\.rect))
    var monitorToHideSpot: [CGPoint: (corner: OptimalHideCorner, monitor: MonitorInfo)] = [:]
    for (monitor, spot) in zip(monitors, spots) {
        monitorToHideSpot[monitor.rect.topLeftCorner] = (spot.corner, monitors[spot.monitorIndex])
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.visibleWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    var coveredSpots: [HideCornerCoverSpot: Rect] = [:]
    for workspace in Workspace.all where !workspace.isVisible {
        let spot = monitorToHideSpot[workspace.workspaceMonitorInfo.rect.topLeftCorner]
        let windows = workspace.allLeafWindowsRecursive
        for window in windows {
            try await (window as! MacWindow).hideInCorner(spot?.corner ?? .bottomRightCorner, on: spot?.monitor) // todo as!
        }
        if config.hiddenWindowsOcclusionCover && !windows.isEmpty {
            let corner = spot?.corner ?? .bottomRightCorner
            let monitor = spot?.monitor ?? workspace.workspaceMonitorInfo
            coveredSpots[HideCornerCoverSpot(monitorTopLeft: monitor.rect.topLeftCorner, corner: corner)] =
                hideCornerCoverRect(visibleRect: monitor.visibleRect, corner: corner)
        }
    }
    HideCornerCovers.shared.sync(coveredSpots)
    FocusMode.shared.refreshBackdrop()

    FocusedWindowBorder.shared.refresh()
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
