import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    @MainActor private static var screensSettledTask: Task<(), Never>? = nil

    /// Neither the lid nor a monitor cable reaches AeroSpace otherwise: it noticed new screens only when some
    /// unrelated event refreshed it, often mid-change, and the tiles kept the in-between sizes until the next click
    private static func onScreensChanged(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            forgetAppliedWindowFrames()
            scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            // macOS reports the change in steps (the menu bar and Dock follow the screen) and keeps moving windows
            // meanwhile. Lay out once more after it has settled
            screensSettledTask?.cancel()
            screensSettledTask = Task.startUnstructured { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || !TrayMenuModel.shared.isEnabled { return }
                forgetAppliedWindowFrames()
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onScreensChanged)
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onScreensChanged)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
            using: onScreensChanged,
        )

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { @MainActor _ in
            FocusedWindowBorder.shared.startTracking()
            if FocusMode.shared.isActive && !FocusMode.shared.containsFocusedWindow(at: mouseLocation) {
                FocusMode.shared.stop()
                scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseDown)
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { @MainActor _ in
            // Before the guard: leftMouseDown starts tracking even while AeroSpace is disabled
            FocusedWindowBorder.shared.stopTracking()
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                if FocusMode.shared.isActive && !FocusMode.shared.containsFocusedWindow(at: mouseLocation) {
                    FocusMode.shared.stop()
                }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) &&
                    clickedMonitor.visibleWorkspace != globalFocus.workspace &&
                    !FocusMode.shared.containsFocusedWindow(at: mouseLocation):
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.visibleWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
