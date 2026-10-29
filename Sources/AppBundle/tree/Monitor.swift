import AppKit
import Common

@MainActor private var pointToMonitor: [CGPoint: Monitor] = [:]

/// Where each workspace lived before its monitor disappeared, so that it goes back when a monitor appears at that
/// point again (wake from sleep, a cable glitch, the lid reopening). Cleared when the workspace is placed explicitly
@MainActor var workspaceNameToHomeMonitorPoint: [String: CGPoint] = [:]
@MainActor private var homeMonitorPointToVisibleWorkspaceName: [CGPoint: String] = [:]

final class Monitor: TreeNode, NonLeafTreeNodeObject {
    fileprivate var _info: MonitorInfo
    var info: MonitorInfo { _info }

    @MainActor fileprivate init(_ info: MonitorInfo) {
        self._info = info
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        info.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Monitor")
    }

    @MainActor static var all: [Monitor] { Array(pointToMonitor.values) }
}

@MainActor private func rearrangeMonitors() {
    var newMonitorPoints = monitorInfos.grouped(by: { $0.rect.topLeftCorner }).mapValues { $0.singleOrNil().orDie() }
    // Every display can be momentarily off during reconfiguration. Keep the known monitors until macOS reports
    // screens again, instead of dropping them all and dying on the empty list below
    if newMonitorPoints.isEmpty { return }

    var oldPointToMonitor = pointToMonitor
    pointToMonitor = [:]

    var newPointToClosestOldPoint = [CGPoint: CGPoint]()
    var oldPointToClosestNewPoint = [CGPoint: CGPoint]()

    for point in newMonitorPoints.keys {
        newPointToClosestOldPoint[point] = oldPointToMonitor.keys.minBy { ($0 - point).vectorLength }
    }

    for point in oldPointToMonitor.keys {
        oldPointToClosestNewPoint[point] = newMonitorPoints.keys.minBy { ($0 - point).vectorLength }
    }

    for (newPoint, closestOldPoint) in newPointToClosestOldPoint {
        if oldPointToClosestNewPoint[closestOldPoint] == newPoint { // Closest points of each other
            pointToMonitor[newPoint] = oldPointToMonitor.removeValue(forKey: closestOldPoint)
            pointToMonitor[newPoint].orDie()._info = newMonitorPoints.removeValue(forKey: newPoint).orDie()
        }
    }

    var monitors = oldPointToMonitor.values.sortedBy { $0.info.rect.topLeftCorner.vectorLength } // [Monitor]
    let monitorInfos = newMonitorPoints.values.sortedBy { $0.rect.topLeftCorner.vectorLength } // [MonitorInfo]

    let mainMonitor = pointToMonitor[CGPoint(x: 0, y: 0)] ?? pointToMonitor.first?.value
    while monitors.count > monitorInfos.count, let mainMonitor {
        let monitor = monitors.removeLast()
        for child in monitor.children {
            switch child.nodeCases {
                case .floatingWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosPopupWindowsContainer,
                     .monitor,
                     .tilingContainer,
                     .window,
                     .workspace: illegalChildParentRelation(child: child, parent: monitor)
                case .workspacesContainer(let it):
                    let homePoint = monitor.info.rect.topLeftCorner
                    homeMonitorPointToVisibleWorkspaceName[homePoint] = it.visibleWorkspaceNameOrStale
                    for workspace in it.children {
                        if let workspace = workspace as? Workspace {
                            workspaceNameToHomeMonitorPoint[workspace.name] = homePoint
                        }
                        workspace.bind(to: mainMonitor.getWorkspacesContainerOrCreate(), adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    }
            }
        }
    }

    for j in monitors.indices {
        monitors[j]._info = monitorInfos.getOrNil(atIndex: j).orDie()
        pointToMonitor[monitors[j].info.rect.topLeftCorner] = monitors[j]
    }

    var i = monitors.count
    while let monitorInfo = monitorInfos.getOrNil(atIndex: i) {
        let monitor = Monitor(monitorInfo)
        monitors.append(monitor)
        pointToMonitor[monitor.info.rect.topLeftCorner] = monitor
        i += 1
    }

    returnDisplacedWorkspaces()
}

/// Upstream moves the workspaces of a vanished monitor to the main monitor for good, and a monitor that comes back
/// shows an empty stub. Move them back instead, and show the workspace that was visible there
@MainActor private func returnDisplacedWorkspaces() {
    if workspaceNameToHomeMonitorPoint.isEmpty { return }
    for (point, monitor) in pointToMonitor {
        let container = monitor.getWorkspacesContainerOrCreate()
        for workspace in Workspace.all where workspaceNameToHomeMonitorPoint[workspace.name] == point {
            workspaceNameToHomeMonitorPoint[workspace.name] = nil
            if workspace.isVisible { continue } // Shown elsewhere meanwhile: it stays there
            _ = container.bindWorkspace(workspace)
        }
        if let name = homeMonitorPointToVisibleWorkspaceName.removeValue(forKey: point),
           let workspace = Workspace.all.first(where: { $0.name == name }),
           workspace.parent === container
        {
            _ = container.setVisibleWorkspace(workspace)
        }
    }
}

@MainActor func forgetDisplacedWorkspacesForTests() {
    check(isUnitTest)
    workspaceNameToHomeMonitorPoint = [:]
    homeMonitorPointToVisibleWorkspaceName = [:]
}

extension MonitorInfo {
    @MainActor var visibleWorkspace: Workspace { // todo revisit this API
        let monitor = toMonitorOrRearrangeMonitors()
        return monitor.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: monitor)
    }

    @MainActor func toMonitorOrRearrangeMonitors() -> Monitor {
        if let existing = pointToMonitor[rect.topLeftCorner] {
            return existing
        }
        rearrangeMonitors() // If monitor configuration changed
        if let existing = pointToMonitor[rect.topLeftCorner] {
            return existing
        }
        // `self` is a stale snapshot of a monitor that `NSScreen.screens` no longer reports (the lid opening with
        // external monitors attached, or every display momentarily off). Retrying can never succeed: the old
        // recursive call ran until the stack guard was hit (EXC_BAD_ACCESS, issue #506). Fall back to the closest
        // live monitor instead; the next refresh, with a settled screen list, sorts it out.
        // Ported from AeroSpace-edge: https://github.com/vitorebatista/AeroSpace-edge/pull/64
        if let closest = pointToMonitor.values.minBy({ ($0.info.rect.topLeftCorner - rect.topLeftCorner).vectorLength }) {
            return closest
        }
        let placeholder = Monitor(self)
        pointToMonitor[rect.topLeftCorner] = placeholder
        return placeholder
    }

    @MainActor func setVisibleWorkspace(_ workspace: Workspace) -> Bool { // todo revisit this API (new name: setVisibleWorkspace)
        let container = toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        return container.setVisibleWorkspace(workspace)
    }

    @MainActor func bindWorkspace(_ workspace: Workspace) -> Bool {
        return toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate().bindWorkspace(workspace)
    }
}

@MainActor func gcMonitors() {
    let infos = monitorInfos
    // A monitor can keep its top-left corner and still change: resolution, Dock or menu bar size. Monitor caches its
    // MonitorInfo, and layout reads visibleRect from that cache, so refresh it whenever anything differs
    let changed = pointToMonitor.count != infos.count || infos.contains { info in
        guard let cached = pointToMonitor[info.rect.topLeftCorner]?.info else { return true }
        return cached.rect != info.rect || cached.visibleRect != info.visibleRect || cached.name != info.name ||
            cached.isMain != info.isMain || cached.monitorAppKitNsScreenScreensId != info.monitorAppKitNsScreenScreensId
    }
    if changed {
        rearrangeMonitors()
    }
}

/// Replaces the monitors that `monitorInfos` reports in tests and rebuilds the Monitor nodes for them.
/// `nil` restores the single default test monitor
@MainActor func setMonitorInfosForTests(_ infos: [MonitorInfo]?) {
    check(isUnitTest)
    monitorInfosForTests = infos
    rearrangeMonitors()
}
