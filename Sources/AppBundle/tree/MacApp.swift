import AppKit
import Common
import PrivateApi

// UserDefaults keys for the best-effort private-focus-API crash guard (see checkFocusPrivateApiCrashGuard
// in initAppBundle.swift). https://github.com/nikitabobko/AeroSpace/issues/101
let privateFocusApiInUseKey = "private-focus-api-in-use"
let privateFocusApiDisabledKey = "private-focus-api-disabled-after-crash"

struct MacAppRefreshResult: Sendable {
    let windows: [OpaqueWindowId: WindowLifeStatus]
    /// An AX timeout leaves enumeration incomplete; retry without treating it as closure or a tab swap.
    let incomplete: Bool

    static let empty = MacAppRefreshResult(windows: [:], incomplete: false)
}

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since #macos14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var focusedWindowAwaitingEnumeration: UInt32?
    private var windowsCount = 0
    var lastFocusedNativeWindowOpaqueId: OpaqueWindowId? = nil
    @MainActor private(set) var launchPlacementSnapshot: MacAppRefreshResult?
    private var thread: Thread?
    private var setFrameJobs: [OpaqueWindowId: RunLoopJob] = [:]
    // Never pruned: while the screen is locked, AX reports windows as gone, and closedWindowsCache matches
    // the windows re-detected after unlock by their OpaqueWindowId
    // todo: start prunning after we get rid of closedWindowsCache
    private var windowIdMapping = BiDictionary<OpaqueWindowId, UInt32>()
    @MainActor private static var focusJob: RunLoopJob? = nil
    @MainActor fileprivate static var isPrivateFocusDisabledForProcess = false
    @MainActor fileprivate static var privateFocusConsecutiveFailures = 0

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ nsApp: NSRunningApplication,
        _ pid: pid_t,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = pid
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor @discardableResult static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        guard let pid = resolveRealPid(nsApp) else { return nil }
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        if let existing = allAppsMap[pid] { return existing }
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await(.cancellable)
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        let thread = Thread {
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                let axApp = AXUIElementCreateApplication(pid)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(pid, axApp, job, handlers)) ?? []
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(nsApp, pid, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp

                Task.startUnstructured { @MainActor in
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(nsApp.idForDebug)"
        thread.start()

        try await wip.await(.cancellable)
        return allAppsMap[pid]
    }

    func nativeWindowId(of windowId: OpaqueWindowId) -> UInt32? { windowIdMapping.forward[windowId] }

    func opaqueWindowId(of nativeWindowId: UInt32) -> OpaqueWindowId? { windowIdMapping.backward[nativeWindowId] }

    @MainActor private func getOrRegisterOpaqueWindowId(_ nativeWindowId: UInt32) -> OpaqueWindowId {
        if let existing = windowIdMapping.backward[nativeWindowId] { return existing }
        let windowId = OpaqueWindowId.nextUniqId()
        windowIdMapping.put(windowId, nativeWindowId)
        return windowId
    }

    func closeAndUnregisterAxWindow(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return }
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: nativeWindowId)
            }
        }
    }

    func getAxSize(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let nativeWindowId = try await thread?.runInLoop(cm) { [pid, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, pid, job) }?
                .windowId
        }
        guard let nativeWindowId else { return nil }
        focusedWindowAwaitingEnumeration = opaqueWindowId(of: nativeWindowId).flatMap { MacWindow.allWindowsMap[$0] } == nil
            ? nativeWindowId : nil
        // Resolve tab swaps before registering the focused native ID. Otherwise a new tab would
        // emit window-detected and run callbacks before refresh discovers its existing logical window.
        let result = try await refreshAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        reconcileKnownWindows(result)
        if result.incomplete { scheduleEnumerationRetry() }
        guard let windowId = opaqueWindowId(of: nativeWindowId) else { return nil }
        // AXFocusedWindow can report a new tab one refresh before AXWindows. Delay its first
        // registration until it is enumerated, so the next complete refresh can remap it atomically.
        guard shouldRegisterFocusedWindow(lifeStatus: result.windows[windowId], incomplete: result.incomplete) else {
            return MacWindow.allWindowsMap[windowId]
        }
        focusedWindowAwaitingEnumeration = nil
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // #101: the public path below can't reliably key the *requested* window of a multi-window app
        // across monitors when "Displays have separate Spaces" is on. Use the private SkyLight API to
        // key the exact window (see aeroMakeKeyWindow). The private call is bracketed by a best-effort
        // crash flag so it disables itself on next launch if it ever crashes (checkFocusPrivateApiCrashGuard).
        let shouldUsePrivateFocus = NSScreen.screensHaveSeparateSpaces &&
            globalUnsortedMonitorInfos.count > 1 &&
            !UserDefaults.standard.bool(forKey: privateFocusApiDisabledKey) &&
            !MacApp.isPrivateFocusDisabledForProcess
        if shouldUsePrivateFocus, aeroPrivateFocusAvailable()
        {
            guard let nativeWindowId = nativeWindowId(of: windowId) else { return }
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [pid, nsApp] window, job in
                UserDefaults.standard.set(true, forKey: privateFocusApiInUseKey)
                let didFocus = aeroMakeKeyWindow(pid, nativeWindowId)
                UserDefaults.standard.set(false, forKey: privateFocusApiInUseKey)
                if didFocus {
                    Task.startUnstructured { @MainActor in recordPrivateFocusSuccess() }
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                } else {
                    // A single failure can be transient (e.g. the app is quitting), so fall back for this
                    // request only; the private path is switched off after several failures in a row.
                    Task.startUnstructured { @MainActor in recordPrivateFocusFailure() }
                    try performNativeFocus(
                        job: job,
                        setMain: { window.set(Ax.isMainAttr, true) },
                        raise: { AXUIElementPerformAction(window, kAXRaiseAction as CFString) },
                        activate: { nsApp.activate(options: .activateIgnoringOtherApps) },
                    )
                }
            }
            return
        } else if shouldUsePrivateFocus {
            disablePrivateFocusForProcess(reason: "the SkyLight symbols are unavailable")
        }
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || globalUnsortedMonitorInfos.count == 1) &&
            (lastFocusedNativeWindowOpaqueId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
        } else {
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                try performNativeFocus(
                    job: job,
                    setMain: { window.set(Ax.isMainAttr, true) },
                    raise: { AXUIElementPerformAction(window, kAXRaiseAction as CFString) },
                    activate: { nsApp.activate(options: .activateIgnoringOtherApps) },
                )
            }
        }
    }

    func setAxFrame(_ windowId: OpaqueWindowId, _ topLeft: CGPoint?, _ size: CGSize?, observedMinimumSize: ObservedMinimumSize, nativeGeometryGeneration: Int) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { [axApp] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            // Read the size back: an app that refuses to shrink shows its minimum size this way
            guard let size else { return }
            try job.checkCancellation()
            guard let observed = window.get(Ax.sizeAttr),
                  observedMinimumSize.updated(requested: size, observed: observed) != observedMinimumSize else { return }
            Task.startUnstructured { @MainActor in
                guard let current = Window.get(byId: windowId), current.nativeGeometryGeneration == nativeGeometryGeneration else { return }
                try await current.confirmObservedMinimumSize(requested: size)
            }
        }
    }

    func setAxFrameForTermination(_ windowId: OpaqueWindowId, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [axApp] window, job in
            try? disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            semaphore.signal()
        }
        switch job.isCancelled {
            case true: return
            case false: semaphore.wait()
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await thread?.runInLoop(cm) { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try AppBundle::getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: OpaqueWindowId) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle::getAxRect(window: window, job: job))
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet()
        }
    }

    func isWindowHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await thread?.runInLoop(cm) { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor func getWindowLevel(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await AppBundle::getWindowLevel(forNativeId: nativeWindowId, cm)
    }

    @MainActor static func refreshAllAndGetAliveWindowIds(
        frontmostAppBundleId: String?,
    ) async throws -> [MacApp: MacAppRefreshResult] {
        for app in MacApp.allAppsMap.values { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(
            of: (MainActorRef<MacApp>, MacAppRefreshResult).self,
            returning: [MacApp: MacAppRefreshResult].self,
        ) { group in
            @MainActor func refreshTheApp(_ app: MacApp) {
                group.addTask { @Sendable @MainActor in
                    return (MainActorRef.init(app), try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular, let app = try await MacApp.getOrRegister(nsApp) {
                    refreshTheApp(app)
                }
            }
            for app in MacApp.allAppsMap.values {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app)
                }
            }
            var result: [MacApp: MacAppRefreshResult] = [:]
            for try await (macAppRef, windowIds) in group {
                result[macAppRef.value] = windowIds
            }
            return result
        }
    }

    @MainActor private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?, requireCompleteEnumeration: Bool = false) async throws -> MacAppRefreshResult {
        if nsApp.isTerminated {
            await destroy()
            if requireCompleteEnumeration { throw LaunchWindowBaselineError.unavailable }
            return .empty
        }
        guard let thread else {
            if requireCompleteEnumeration { throw LaunchWindowBaselineError.unavailable }
            return .empty
        }
        let previousStatuses = lifeStatusesOfLastRefresh
        let snapshot = try await thread
            .runInLoop(.cancellable) { [pid, windows, axApp, bgTabsScheduledForPrune] job -> ([UInt32: WindowLifeStatus], Bool) in
                var tracked = windows.threadGuarded.filter { !bgTabsScheduledForPrune.contains($0.key) }
                let (axWindows, error) = axApp.threadGuarded.getOrError(requireCompleteEnumeration ? Ax.launchBaselineWindowsAttr : Ax.windowsAttr)
                // The normal refresh tolerates unavailable AX attributes. A launch baseline must
                // distinguish a successful empty array from an unreadable/failed enumeration.
                if requireCompleteEnumeration && (error != .success || axWindows == nil) {
                    throw LaunchWindowBaselineError.unavailable
                }
                var unresponsive = error == .cannotComplete
                var windowServerWindowIds: Set<UInt32>?
                if frontmostAppBundleId != lockScreenAppBundleId {
                    tracked = try tracked.filter { entry in
                        try job.checkCancellation()
                        return isTrackedWindowAlive(
                            isAppUnresponsive: &unresponsive,
                            containingWindowIdError: { entry.value.ax.containingNativeWindowIdError() },
                            windowStillExists: {
                                if windowServerWindowIds == nil {
                                    windowServerWindowIds = getWindowServerWindowIds(ownerPid: pid)
                                }
                                return windowServerWindowIds?.contains(entry.key) == true
                            },
                        )
                    }
                }
                let liveWindowIds = Set((axWindows ?? []).map(\.windowId))
                if !unresponsive {
                    for (id, window) in axWindows ?? [] {
                        try job.checkCancellation()
                        try tracked.getOrRegisterAxWindow(windowId: id, window, pid, job)
                    }
                }
                if requireCompleteEnumeration && !launchWindowEnumerationIsComplete(
                    attributeSucceeded: error == .success,
                    enumerated: axWindows.map { Set($0.map(\.windowId)) },
                    tracked: Set(tracked.keys),
                ) {
                    throw LaunchWindowBaselineError.unavailable
                }
                windows.threadGuarded = tracked
                let statuses = tracked.keys.associate { id in
                    retainedWindowLifeStatus(
                        previously: previousStatuses[id],
                        isEnumerated: liveWindowIds.contains(id),
                        incomplete: unresponsive,
                    )
                }
                return (statuses, unresponsive)
            }
        var aliveOrInvisible = snapshot.0
        let incomplete = snapshot.1
        bgTabsScheduledForPrune = []
        windowsCount = aliveOrInvisible.count

        // An incomplete snapshot cannot prove a transition. Keep the last complete observation
        // so a successful retry can still recognise a native tab change.
        if !incomplete {
            nonidempotentNativeTabSwapHeuristic(&aliveOrInvisible)
        }
        var result: [OpaqueWindowId: WindowLifeStatus] = [:]
        for (id, lifeStatus) in aliveOrInvisible {
            result[getOrRegisterOpaqueWindowId(id)] = lifeStatus
        }
        for windowId in setFrameJobs.keys where !result.keys.contains(windowId) {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        let awaitingFocusedWindow = focusedWindowAwaitingEnumeration.map { aliveOrInvisible[$0] != .alive } == true
        let snapshotResult = MacAppRefreshResult(windows: result, incomplete: incomplete || awaitingFocusedWindow)
        launchPlacementSnapshot = snapshotResult
        return snapshotResult
    }

    /// Reuse the upstream enumeration and native-tab reconciliation; never infer logical IDs here.
    @MainActor static func launchWindowBaseline(bundleId: String) async throws -> LaunchWindowBaseline {
        let processes = try launchWindowRunningProcesses(bundleId)
        guard processes.count <= 1 else { throw LaunchWindowBaselineError.unavailable }
        guard let identity = processes.first else { return LaunchWindowBaseline(process: nil, windowIds: []) }
        guard let nsApp = NSRunningApplication(processIdentifier: identity.pid),
              let app = try await getOrRegister(nsApp), launchWindowProcessIdentity(app.nsApp) == identity
        else {
            throw LaunchWindowBaselineError.unavailable
        }
        let snapshot = try await app.refreshAndGetAliveWindowIds(
            frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            requireCompleteEnumeration: true,
        )
        guard !snapshot.incomplete, !nsApp.isTerminated,
              try launchWindowRunningProcesses(bundleId) == [identity] else { throw LaunchWindowBaselineError.unavailable }
        app.reconcileKnownWindows(snapshot)
        let managedIds = MacWindow.allWindows.filter { $0.macApp === app }.map(\.windowId)
        return LaunchWindowBaseline(process: identity, windowIds: Set(snapshot.windows.keys).union(managedIds))
    }

    private var bgTabsScheduledForPrune: Set<UInt32> = []
    private var lifeStatusesOfLastRefresh: [UInt32: WindowLifeStatus] = [:]
    @MainActor private func nonidempotentNativeTabSwapHeuristic(_ statuses: inout [UInt32: WindowLifeStatus]) {
        let candidate = nativeTabRemapCandidate(previous: lifeStatusesOfLastRefresh, current: statuses, isMouseButtonDown: isLeftMouseButtonDown)
        // Keep transitions pending while dragging; a detached tab must get a separate identity.
        if isLeftMouseButtonDown { return }
        lifeStatusesOfLastRefresh = statuses
        guard let candidate else { return }
        let logicalId = getOrRegisterOpaqueWindowId(candidate.background)
        let oldWindow = MacWindow.allWindowsMap[logicalId]
        // A known destination is an independent managed window (Cmd-W can focus one on another
        // workspace), not a new tab. Never merge those windows or suppress their close event.
        if let destination = windowIdMapping.backward[candidate.frontmost],
           MacWindow.allWindowsMap[destination] != nil { return }
        guard canRemapNativeTabWindow(source: oldWindow, destination: nil) else { return }
        setFrameJobs.removeValue(forKey: logicalId)?.cancel()
        guard remapNativeTabWindow(
            background: candidate.background,
            frontmost: candidate.frontmost,
            mapping: &windowIdMapping,
            window: oldWindow,
        ) != nil else { return }
        statuses[candidate.background] = nil
        bgTabsScheduledForPrune.insert(candidate.background)
    }

    @MainActor func reconcileKnownWindows(_ result: MacAppRefreshResult) {
        for window in MacWindow.allWindows where window.macApp === self {
            if let status = result.windows[window.windowId] {
                window.lifeStatus = status
            } else {
                // Capture focus/hold before marking it dead: resolved focus skips tombstones.
                window.garbageCollect(skipClosedWindowsCache: false)
            }
        }
        let focus = globalFocus
        if let focused = focus.windowOrNil, focused.lifeStatus != .alive {
            _ = setFocus(to: focus.workspace.toLiveFocus())
        }
    }

    private func destroy() async {
        let identity = launchWindowProcessIdentity(nsApp)
        _ = await Task.startUnstructured { @MainActor [pid, identity] in
            if let identity { launchPlacement.processTerminated(identity) }
            _ = MacApp.allAppsMap.removeValue(forKey: pid)
        }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: OpaqueWindowId,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await thread?.runInLoop(cm) { [windows] job in
            guard let window = windows.threadGuarded[nativeWindowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(_ windowId: OpaqueWindowId, _ cm: CancellationMode, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return .cancelled }
        return thread?.runInLoopAsync(job: RunLoopJob(cm)) { [windows] job in
            guard let window = windows.threadGuarded[nativeWindowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

/// Consecutive private-focus failures tolerated before the private path is switched off for the process.
private let privateFocusFailureLimit = 3

@MainActor private func recordPrivateFocusSuccess() {
    MacApp.privateFocusConsecutiveFailures = 0
}

@MainActor private func recordPrivateFocusFailure() {
    MacApp.privateFocusConsecutiveFailures += 1
    if MacApp.privateFocusConsecutiveFailures >= privateFocusFailureLimit {
        disablePrivateFocusForProcess(reason: "\(privateFocusFailureLimit) consecutive calls failed")
    }
}

@MainActor private func disablePrivateFocusForProcess(reason: String) {
    guard !MacApp.isPrivateFocusDisabledForProcess else { return }
    MacApp.isPrivateFocusDisabledForProcess = true
    eprint("Private SkyLight focus disabled for this process (\(reason)); using the public focus path. Restart AeroSpace to retry")
}

func performNativeFocus(
    job: RunLoopJob,
    setMain: () -> Void,
    raise: () -> Void,
    activate: () -> Void,
) throws {
    try job.checkCancellation()
    setMain()
    // AX calls can block while another focus request cancels this job.
    try job.checkCancellation()
    raise()
    try job.checkCancellation()
    activate()
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ pid: pid_t, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(pid, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult fileprivate mutating func getOrRegisterAxWindow(
        windowId id: UInt32,
        _ axWindow: AXUIElement,
        _ pid: pid_t,
        _ job: RunLoopJob,
    ) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, pid, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

/// A tab swap replaces one still-existing, now-invisible native window with one newly visible
/// native window. A genuine destroyed window is absent and must follow closure handling instead.
func nativeTabRemapCandidate(
    previous: [UInt32: WindowLifeStatus],
    current: [UInt32: WindowLifeStatus],
    isMouseButtonDown: Bool,
) -> (background: UInt32, frontmost: UInt32)? {
    guard !isMouseButtonDown else { return nil }
    let disappeared = previous.filter { $0.value == .alive && current[$0.key] != .alive }
    let appeared = current.filter { $0.value == .alive && previous[$0.key] != .alive }
    guard let old = disappeared.singleOrNil()?.key, current[old] == .invisible,
          let new = appeared.singleOrNil()?.key else { return nil }
    return (old, new)
}

@MainActor
func canRemapNativeTabWindow(source: Window?, destination: Window?) -> Bool {
    guard destination == nil else { return false }
    guard let source else { return true }
    return source.isBound && (source.parent is TilingContainer || source.parent is FloatingWindowsContainer)
}

func shouldRegisterFocusedWindow(lifeStatus: WindowLifeStatus?, incomplete: Bool) -> Bool {
    !incomplete && lifeStatus == .alive
}

/// Change only the macOS backing window; the logical node, its tree slot and user sizing survive.
@MainActor
@discardableResult
func remapNativeTabWindow(
    background: UInt32,
    frontmost: UInt32,
    mapping: inout BiDictionary<OpaqueWindowId, UInt32>,
    window: Window?,
) -> OpaqueWindowId? {
    guard let logicalId = mapping.backward[background],
          window == nil || window?.isBound == true && window?.windowId == logicalId else { return nil }
    mapping.put(logicalId, frontmost)
    window?.invalidateNativeWindowGeometry()
    return logicalId
}

func retainedWindowLifeStatus(previously: WindowLifeStatus?, isEnumerated: Bool, incomplete: Bool) -> WindowLifeStatus {
    if isEnumerated { return .alive }
    return incomplete ? previously ?? .invisible : .invisible
}

/// Decides whether a tracked window is still alive during a refresh.
///
/// `_AXUIElementGetWindow` failing used to mean
/// "closed", but an app that hangs or is too busy to respond fails it with `.cannotComplete` once the AX
/// messaging timeout expires, and its windows were garbage collected
/// (https://github.com/nikitabobko/AeroSpace/issues/1216, upstream PR #2317). On `.cannotComplete`, ask
/// the WindowServer whether the window still exists instead, and once the app timed out, skip AX for the
/// rest of the refresh. The caller supplies a lazily captured, per-app WindowServer snapshot so off-screen
/// windows remain alive without making one WindowServer request per tracked window.
func isTrackedWindowAlive(
    isAppUnresponsive: inout Bool,
    containingWindowIdError: () -> AXError,
    windowStillExists: () -> Bool,
) -> Bool {
    if isAppUnresponsive { return windowStillExists() }
    switch containingWindowIdError() {
        case .success: return true
        // the app hangs or is too busy to respond. Don't mistake it for a closed window
        case .cannotComplete:
            isAppUnresponsive = true
            return windowStillExists()
        default: return false
    }
}

private func getWindowServerWindowIds(ownerPid: pid_t) -> Set<UInt32> {
    let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(infos.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPid else { return nil }
        return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    })
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}

// Some apps are started via a launcher process that exits after it starts the real process.
// E.g. Xcode 27 "Device Hub" (com.apple.dt.Devices) is started via DevicesTrampoline.
// For such apps, NSRunningApplication.processIdentifier is -1, and the real process isn't in
// NSWorkspace.runningApplications at all. Even NSRunningApplication(processIdentifier: realPid) returns
// an object with processIdentifier == -1. The workaround is to find the real pid by the owner pid of the windows
@MainActor
private func resolveRealPid(_ nsApp: NSRunningApplication) -> pid_t? {
    if nsApp.processIdentifier > 0 { return nsApp.processIdentifier }
    guard let bundleId = nsApp.bundleIdentifier else { return nil }
    // .optionAll because the windows of the app might be minimized or hidden
    guard let cfArray = CGWindowListCopyWindowInfo(.optionAll, CGWindowID(0)) as? [CFDictionary] else { return nil }
    var visitedPids: Set<pid_t> = []
    for elem in cfArray {
        let dict = elem as NSDictionary
        guard let _pid = dict[kCGWindowOwnerPID] else { continue }
        let pid = ((_pid as! CFNumber) as NSNumber).int32Value
        if pid <= 0 || !visitedPids.insert(pid).inserted { continue }
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId {
            return pid
        }
    }
    return nil
}

final class MainActorRef<T>: Sendable {
    @MainActor var value: T
    @MainActor public init(_ value: T) { self.value = value }
}
