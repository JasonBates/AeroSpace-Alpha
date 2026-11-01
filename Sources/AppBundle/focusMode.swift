import AppKit
import Common

/// A visual override only: the workspace tree and its tile weights stay intact.
@MainActor
final class FocusMode {
    static let shared = FocusMode()
    static let minimumHeight: CGFloat = 600

    private(set) var workspaceName: String?
    private(set) var windowId: OpaqueWindowId?
    private var stayOnMonitor = false
    private var originalFloatingFrame: Rect?
    private var originalFloatingGeneration: Int?
    private var revision = 0

    var isActive: Bool { workspaceName != nil }

    func start(window: Window, workspace: Workspace, stayOnMonitor: Bool = false) async -> Bool {
        revision += 1
        let requestRevision = revision
        let generation = window.nativeGeometryGeneration
        let parent = window.parent
        let floatingFrame: Rect?
        if window.isFloating {
            guard let frame = try? await window.getAxRect(.nonCancellable) else { return false }
            floatingFrame = frame
        } else {
            floatingFrame = nil
        }
        guard revision == requestRevision,
              validFocusedWindow(window, workspace: workspace, parent: parent, generation: generation)
        else { return false }
        self.stayOnMonitor = stayOnMonitor
        workspaceName = workspace.name
        windowId = window.windowId
        originalFloatingFrame = floatingFrame
        originalFloatingGeneration = floatingFrame == nil ? nil : generation
        return true
    }

    func stop() {
        revision += 1
        restoreFloatingWindow()
        workspaceName = nil
        windowId = nil
        originalFloatingFrame = nil
        originalFloatingGeneration = nil
        stayOnMonitor = false
        FocusDimmer.shared.hide()
    }

    /// Called before every layout, so focus changes and closed windows cannot leave a stale cutout.
    func syncWithFocus() async {
        guard let workspaceName else { return }
        guard globalFocus.workspace.name == workspaceName,
              let window = globalFocus.windowOrNil,
              window.isFloating || window.parent is TilingContainer
        else {
            stop()
            return
        }
        if windowId == window.windowId, let originalFloatingGeneration,
           originalFloatingGeneration != window.nativeGeometryGeneration
        {
            // A replacement native tab has its own geometry; end the override without restoring the old tab.
            stop()
            return
        }
        if windowId != window.windowId {
            let requestRevision = revision
            let generation = window.nativeGeometryGeneration
            let parent = window.parent
            let workspace = globalFocus.workspace
            let floatingFrame: Rect?
            if window.isFloating {
                guard let frame = try? await window.getAxRect(.nonCancellable) else {
                    if revision == requestRevision { stop() }
                    return
                }
                floatingFrame = frame
            } else {
                floatingFrame = nil
            }
            guard revision == requestRevision else { return }
            guard validFocusedWindow(window, workspace: workspace, parent: parent, generation: generation),
                  globalFocus.workspace.name == workspaceName
            else {
                stop()
                return
            }
            restoreFloatingWindow()
            revision += 1
            windowId = window.windowId
            originalFloatingFrame = floatingFrame
            originalFloatingGeneration = floatingFrame == nil ? nil : generation
        }
    }

    func frame(for window: Window, in workspace: Workspace) -> Rect? {
        guard window.lifeStatus == .alive, workspaceName == workspace.name, windowId == window.windowId else { return nil }
        if let originalFloatingGeneration, originalFloatingGeneration != window.nativeGeometryGeneration { return nil }
        let geometry = baseGeometry(for: workspace)
        let width = window.singleWindowWidth(base: geometry.frame.width, available: geometry.available.width)
        let fullHeight = geometry.available.height - 1
        let height = min(
            fullHeight,
            max(min(Self.minimumHeight, fullHeight), geometry.frame.height + window.focusModeHeightAdjustment),
        )
        return Rect(
            topLeftX: geometry.frame.center.x - width / 2,
            topLeftY: geometry.frame.center.y - height / 2,
            width: width,
            height: height,
        )
    }

    func baseGeometry(for workspace: Workspace) -> FocusModeBaseGeometry {
        let monitor = destinationMonitor(for: workspace.workspaceMonitorInfo, among: globalUnsortedMonitorInfos)
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
              window.nativeGeometryGeneration == originalFloatingGeneration,
              window.lifeStatus == .alive,
              window.isFloating,
              window.nodeWorkspace?.name == workspaceName
        else { return }
        window.setAxFrame(originalFloatingFrame.topLeftCorner, originalFloatingFrame.size)
    }

    private func validFocusedWindow(_ window: Window, workspace: Workspace, parent: NonLeafTreeNodeObject?, generation: Int) -> Bool {
        window.isBound && window.lifeStatus == .alive && window.nativeGeometryGeneration == generation &&
            window.parent === parent && window.nodeWorkspace === workspace &&
            globalFocus.workspace === workspace && globalFocus.windowOrNil === window &&
            (window.isFloating || window.parent is TilingContainer)
    }
}

struct FocusModeBaseGeometry {
    let monitor: MonitorInfo
    let available: Rect
    let frame: Rect
}
