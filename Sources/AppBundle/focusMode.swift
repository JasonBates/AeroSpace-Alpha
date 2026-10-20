import AppKit

/// A visual override only: the workspace tree and its tile weights stay intact.
@MainActor
final class FocusMode {
    static let shared = FocusMode()

    private(set) var workspaceName: String?
    private(set) var windowId: UInt32?
    private var stayOnMonitor = false
    private var originalFloatingFrame: Rect?

    var isActive: Bool { workspaceName != nil }

    func start(window: Window, workspace: Workspace, stayOnMonitor: Bool = false) async -> Bool {
        let floatingFrame: Rect?
        if window.isFloating {
            guard let frame = try? await window.getAxRect(.nonCancellable) else { return false }
            floatingFrame = frame
        } else {
            floatingFrame = nil
        }
        self.stayOnMonitor = stayOnMonitor
        workspaceName = workspace.name
        windowId = window.windowId
        originalFloatingFrame = floatingFrame
        return true
    }

    func stop() {
        restoreFloatingWindow()
        workspaceName = nil
        windowId = nil
        originalFloatingFrame = nil
        stayOnMonitor = false
        FocusDimmer.shared.hide()
    }

    /// Called before every layout, so focus changes and closed windows cannot leave a stale cutout.
    func syncWithFocus() async {
        guard let workspaceName else { return }
        guard focus.workspace.name == workspaceName,
              let window = focus.windowOrNil,
              window.isFloating || window.parent is TilingContainer
        else {
            stop()
            return
        }
        if windowId != window.windowId {
            let floatingFrame: Rect?
            if window.isFloating {
                guard let frame = try? await window.getAxRect(.nonCancellable) else {
                    stop()
                    return
                }
                floatingFrame = frame
            } else {
                floatingFrame = nil
            }
            restoreFloatingWindow()
            windowId = window.windowId
            originalFloatingFrame = floatingFrame
        }
    }

    func frame(for window: Window, in workspace: Workspace) -> Rect? {
        guard workspaceName == workspace.name, windowId == window.windowId else { return nil }
        let geometry = baseGeometry(for: workspace)
        let width = window.singleWindowWidth(base: geometry.frame.width, available: geometry.available.width)
        let fullHeight = geometry.available.height - 1
        let height = min(
            fullHeight,
            max(min(200, fullHeight), geometry.frame.height + window.focusModeHeightAdjustment),
        )
        return Rect(
            topLeftX: geometry.frame.center.x - width / 2,
            topLeftY: geometry.frame.center.y - height / 2,
            width: width,
            height: height,
        )
    }

    func baseGeometry(for workspace: Workspace) -> FocusModeBaseGeometry {
        let monitor = destinationMonitor(for: workspace.workspaceMonitor, among: monitorInfos)
        let available = monitor.visibleRectPaddedByOuterGaps
        let fullHeight = available.height - 1
        let frame: Rect
        if config.adaptiveLayout.enabled.getValue(for: monitor) {
            let adaptive = adaptiveWorkspaceRect(
                available: available,
                footprint: TilingFootprint(columns: 1, rows: 1),
                config: config.adaptiveLayout,
            )
            frame = Rect(
                topLeftX: adaptive.topLeftX,
                topLeftY: adaptive.topLeftY,
                width: adaptive.width,
                height: max(0, adaptive.height - 1),
            )
        } else {
            let width = config.singleWindowWidth(
                monitorWidth: monitor.width,
                availableWidth: available.width,
                height: fullHeight,
            ) ?? available.width * 0.66
            frame = Rect(
                topLeftX: available.topLeftX + (available.width - width) / 2,
                topLeftY: available.topLeftY,
                width: width,
                height: fullHeight,
            )
        }
        return FocusModeBaseGeometry(monitor: monitor, available: available, frame: frame)
    }

    /// With --stay-on-monitor, keep the source display. Otherwise,
    /// the middle display is the Focus Mode stage. With two displays, use the
    /// macOS main display; with one, keep the window where it already is.
    func destinationMonitor(for source: MonitorInfo, among available: [MonitorInfo]) -> MonitorInfo {
        guard !stayOnMonitor, available.count > 1 else { return source }
        if available.count == 2 {
            return available.first(where: \.isMain) ?? source
        }
        let ordered = available.sortedBy([\.rect.minX, \.rect.minY])
        return ordered[ordered.count / 2]
    }

    func refreshBackdrop() {
        guard let windowId,
              let window = Window.get(byId: windowId),
              let workspace = window.nodeWorkspace,
              let frame = frame(for: window, in: workspace)
        else {
            FocusDimmer.shared.hide()
            return
        }
        FocusDimmer.shared.show(around: frame)
    }

    func containsFocusedWindow(at point: CGPoint) -> Bool {
        guard let windowId,
              let window = Window.get(byId: windowId),
              let workspace = window.nodeWorkspace,
              let frame = frame(for: window, in: workspace)
        else { return false }
        return frame.contains(point)
    }

    private func restoreFloatingWindow() {
        guard let windowId,
              let originalFloatingFrame,
              let window = Window.get(byId: windowId),
              window.isFloating,
              window.nodeWorkspace?.name == workspaceName
        else { return }
        window.setAxFrame(originalFloatingFrame.topLeftCorner, originalFloatingFrame.size)
    }
}

struct FocusModeBaseGeometry {
    let monitor: MonitorInfo
    let available: Rect
    let frame: Rect
}
