import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        if let window = target.windowOrNil,
           args.dimension.val == .height,
           let workspace = window.nodeWorkspace,
           let frame = FocusMode.shared.frame(for: window, in: workspace)
        {
            let monitor = FocusMode.shared.destinationMonitor(for: workspace.workspaceMonitor, among: monitorInfos)
            let fullHeight = monitor.visibleRectPaddedByOuterGaps.height - 1
            let requestedHeight: CGFloat = switch args.units.val {
                case .set(let unit): CGFloat(unit)
                case .add(let unit): frame.height + CGFloat(unit)
                case .subtract(let unit): frame.height - CGFloat(unit)
            }
            window.focusModeHeightAdjustment = min(fullHeight, max(min(200, fullHeight), requestedHeight)) - fullHeight
            return .succ
        }

        if let window = target.windowOrNil,
           args.dimension.val == .smart || args.dimension.val == .width,
           let workspace = window.nodeWorkspace
        {
            let isInFocusMode = FocusMode.shared.frame(for: window, in: workspace) != nil
            let isAdaptiveLayoutEnabled = config.adaptiveLayout.enabled.getValue(for: workspace.workspaceMonitor)
            let isAdaptiveLoneTilingWindow = workspace.rootTilingContainer.allLeafWindowsRecursive
                .filter { !$0.isAwaitingOnWindowDetected }
                .singleOrNil() === window
            let isLegacyLoneTilingWindow = workspace.rootTilingContainer.hasSingleLeafWindowRecursive &&
                workspace.rootTilingContainer.anyLeafWindowRecursive === window
            let monitor = isInFocusMode
                ? FocusMode.shared.destinationMonitor(for: workspace.workspaceMonitor, among: monitorInfos)
                : workspace.workspaceMonitor
            let rect = monitor.visibleRectPaddedByOuterGaps
            let baseWidth: CGFloat? = if isInFocusMode {
                config.singleWindowWidth(
                    monitorWidth: monitor.width,
                    availableWidth: rect.width,
                    height: rect.height - 1,
                ) ?? rect.width * 0.66
            } else if isAdaptiveLayoutEnabled && isAdaptiveLoneTilingWindow {
                rect.width * CGFloat(config.adaptiveLayout.oneColumnWidthPercent) / 100
            } else if !isAdaptiveLayoutEnabled && isLegacyLoneTilingWindow {
                config.singleWindowWidth(
                    monitorWidth: monitor.width,
                    availableWidth: rect.width,
                    height: rect.height - 1,
                )
            } else {
                nil
            }
            if let baseWidth {
                let currentWidth = window.singleWindowWidth(base: baseWidth, available: rect.width)
                let requestedWidth: CGFloat = switch args.units.val {
                    case .set(let unit): CGFloat(unit)
                    case .add(let unit): currentWidth + CGFloat(unit)
                    case .subtract(let unit): currentWidth - CGFloat(unit)
                }
                let newWidth = min(rect.width, max(min(200, rect.width), requestedWidth))
                window.singleWindowWidthAdjustment = newWidth - baseWidth
                return .succ
            }
        }

        if let window = target.windowOrNil, window.isFloating {
            return await resizeFloating(window, target.workspace, io)
        }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else { return .fail(io.err("The window isn't inside a tiles container that can be resized")) }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }

    /// Floating windows are resized around their centre and kept inside the monitor.
    /// `smart` sets or changes the longer side and `smart-opposite` the shorter one, keeping the aspect ratio.
    @MainActor
    private func resizeFloating(_ window: Window, _ workspace: Workspace, _ io: CmdIo) async -> BinaryExitCode {
        guard let rect = try? await window.getAxRect(.nonCancellable), rect.width > 0, rect.height > 0 else {
            return .fail(io.err("Can't read the window's frame"))
        }
        let isWidthLonger = rect.width >= rect.height
        let axisIsWidth: Bool = switch args.dimension.val {
            case .width: true
            case .height: false
            case .smart: isWidthLonger
            case .smartOpposite: !isWidthLonger
        }
        let keepAspectRatio = args.dimension.val == .smart || args.dimension.val == .smartOpposite
        let current = axisIsWidth ? rect.width : rect.height
        let requested: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit)
            case .add(let unit): current + CGFloat(unit)
            case .subtract(let unit): current - CGFloat(unit)
        }
        let newValue = max(requested, minFloatingWindowSide)
        var size = rect.size
        if keepAspectRatio {
            let scale = newValue / current
            size = CGSize(width: max(rect.width * scale, minFloatingWindowSide), height: max(rect.height * scale, minFloatingWindowSide))
        } else if axisIsWidth {
            size.width = newValue
        } else {
            size.height = newValue
        }
        let bounds = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        if keepAspectRatio && (size.width > bounds.width || size.height > bounds.height) {
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        let frame = floatingFrame(center: rect.center, size: size, within: bounds)
        // A window on a hidden workspace is parked in a screen corner. Change only its size so it stays hidden
        window.setAxFrame(workspace.isVisible ? frame.topLeftCorner : nil, frame.size)
        return .succ
    }
}

private let minFloatingWindowSide: CGFloat = 100
