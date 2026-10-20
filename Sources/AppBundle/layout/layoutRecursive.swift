import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        let adaptiveLayoutEnabled = config.adaptiveLayout.enabled.getValue(for: workspaceMonitor)
        var layoutRect = rect
        if adaptiveLayoutEnabled {
            if let footprint = rootTilingContainer.tilingFootprint {
                layoutRect = adaptiveWorkspaceRect(available: rect, footprint: footprint, config: config.adaptiveLayout)
                let participatingWindows = rootTilingContainer.allLeafWindowsRecursive.filter { !$0.isAwaitingOnWindowDetected }
                if footprint.columns == 1, let loneWindow = participatingWindows.singleOrNil() {
                    let width = loneWindow.singleWindowWidth(base: layoutRect.width, available: rect.width)
                    layoutRect = Rect(
                        topLeftX: rect.topLeftX + (rect.width - width) / 2,
                        topLeftY: layoutRect.topLeftY,
                        width: width,
                        height: layoutRect.height,
                    )
                }
            }
        } else if shouldApplyAspectRatio(to: rootTilingContainer),
                  let constrainedWidth = config.singleWindowWidth(
                      monitorWidth: workspaceMonitor.width,
                      availableWidth: rect.width,
                      height: rect.height - 1,
                  )
        {
            let loneWindow = rootTilingContainer.hasSingleLeafWindowRecursive
                ? rootTilingContainer.anyLeafWindowRecursive : nil
            let targetWidth = loneWindow?.singleWindowWidth(base: constrainedWidth, available: rect.width)
                ?? min(constrainedWidth, rect.width)
            if targetWidth < rect.width {
                let xOffset = (rect.width - targetWidth) / 2
                layoutRect = Rect(topLeftX: rect.topLeftX + xOffset, topLeftY: rect.topLeftY, width: targetWidth, height: rect.height)
            }
        }
        try await layoutRecursive(
            layoutRect.topLeftCorner,
            width: layoutRect.width,
            height: layoutRect.height - 1,
            virtual: layoutRect,
            LayoutContext(self, adaptiveLayoutEnabled: adaptiveLayoutEnabled),
        )
    }
}

@MainActor
private func shouldApplyAspectRatio(to root: TilingContainer) -> Bool {
    if root.hasSingleLeafWindowRecursive { return true }
    let accordion: TilingContainer
    if root.layout == .accordion {
        accordion = root
    } else if root.children.count == 1,
              let child = root.children.first as? TilingContainer,
              child.layout == .accordion
    {
        accordion = child
    } else {
        return false
    }
    return accordion.children.allSatisfy { $0 is Window }
        && config.applyAspectToAccordion.matches(accordion.orientation)
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    if window.isAwaitingOnWindowDetected { continue }
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    if window.windowId == currentlyManipulatedWithMouseWindowId { continue } // Follows the pointer
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.isAwaitingOnWindowDetected { break }
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if let focusFrame = FocusMode.shared.frame(for: window, in: context.workspace) {
                        // Record the frame actually applied, not the tile rect, so the tiled frame is
                        // written again when Focus Mode ends (the redundant-write skip below compares rects)
                        lastAppliedLayoutPhysicalRect = focusFrame
                        window.setAxFrame(focusFrame.topLeftCorner, focusFrame.size)
                    } else if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        // Skip the AX frame write entirely when the target rect didn't change since the last
                        // layout pass. Besides avoiding pointless AXUIElementSetAttributeValue calls, this breaks
                        // a resize feedback loop with apps that don't accept the imposed frame and report back a
                        // different one (e.g. Xcode 27 Device Hub's compact view): such an app's own AX resize
                        // notification would otherwise retrigger another relayout that recomputes and re-writes
                        // the exact same (already applied) frame, ad infinitum.
                        let frameChanged = lastAppliedLayoutPhysicalRect != physicalRect
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        if frameChanged {
                            window.setAxFrame(point, CGSize(width: width, height: height))
                        }
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps
    let adaptiveLayoutEnabled: Bool

    @MainActor
    init(_ workspace: Workspace, adaptiveLayoutEnabled: Bool) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
        self.adaptiveLayoutEnabled = adaptiveLayoutEnabled
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        if let focusFrame = FocusMode.shared.frame(for: self, in: context.workspace) {
            setAxFrame(focusFrame.topLeftCorner, focusFrame.size)
            return
        }
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    /// Children that take part in the layout. Windows still awaiting their `on-window-detected`
    /// callbacks are left out: reserving space for a window that is about to be moved elsewhere
    /// makes its siblings jump, and the space is handed back a moment later.
    @MainActor
    private func layoutChildren(adaptiveLayoutEnabled: Bool) -> [TreeNode] {
        children.filter {
            ($0 as? Window)?.isAwaitingOnWindowDetected != true &&
                (!adaptiveLayoutEnabled || $0.tilingFootprint != nil)
        }
    }

    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner
        let children = layoutChildren(adaptiveLayoutEnabled: context.adaptiveLayoutEnabled)
        let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()

        preserveAdaptiveProportionsIfNeeded(
            children: children,
            dimension: orientation == .h ? width : height,
            innerGap: rawGap,
            adaptiveLayoutEnabled: context.adaptiveLayoutEnabled,
        )

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mostRecentChild else { return }
        let children = layoutChildren(adaptiveLayoutEnabled: context.adaptiveLayoutEnabled)
        adaptiveLayoutProportionCache = AdaptiveLayoutProportionCache(
            orientation: orientation,
            layout: layout,
            participatingChildren: children.map(ObjectIdentifier.init),
            dimension: orientation == .h ? width : height,
            adaptiveLayoutEnabled: context.adaptiveLayoutEnabled,
        )
        let mruIndex: Int = children.firstIndex { $0 === mostRecentChild } ?? 0
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }

    @MainActor
    private func preserveAdaptiveProportionsIfNeeded(
        children: [TreeNode],
        dimension: CGFloat,
        innerGap: CGFloat,
        adaptiveLayoutEnabled: Bool,
    ) {
        let nextCache = AdaptiveLayoutProportionCache(
            orientation: orientation,
            layout: layout,
            participatingChildren: children.map(ObjectIdentifier.init),
            dimension: dimension,
            adaptiveLayoutEnabled: adaptiveLayoutEnabled,
        )
        let previousCache = adaptiveLayoutProportionCache
        adaptiveLayoutProportionCache = nextCache

        let currentWeights = children.map { $0.getWeight(orientation) }
        let totalWeight = currentWeights.reduce(0, +)
        guard totalWeight > 0, currentWeights.allSatisfy({ $0 > 0 }) else { return }
        let wasOrIsAdaptive = adaptiveLayoutEnabled || previousCache?.adaptiveLayoutEnabled == true
        let topologyIsUnchanged = previousCache?.orientation == nextCache.orientation &&
            previousCache?.layout == nextCache.layout &&
            previousCache?.participatingChildren == nextCache.participatingChildren
        let additiveDelta = (dimension - totalWeight).div(children.count)
        let additiveWouldCollapseAChild = additiveDelta.map { delta in
            currentWeights.enumerated().contains { index, weight in
                let requiredGap = innerGap -
                    (index == children.indices.first ? innerGap / 2 : 0) -
                    (index == children.indices.last ? innerGap / 2 : 0)
                return weight + delta <= requiredGap
            }
        } ?? false
        guard wasOrIsAdaptive,
              (topologyIsUnchanged && previousCache?.dimension != dimension || additiveWouldCollapseAChild)
        else { return }

        let scale = dimension / totalWeight
        let proportionalWeights = currentWeights.map { $0 * scale }
        let requiredGaps = children.indices.map { index in
            innerGap -
                (index == children.indices.first ? innerGap / 2 : 0) -
                (index == children.indices.last ? innerGap / 2 : 0)
        }
        let proportionalWouldCollapseAChild = zip(proportionalWeights, requiredGaps)
            .contains { weight, requiredGap in weight <= requiredGap }
        if proportionalWouldCollapseAChild {
            let contentWeights = zip(currentWeights, requiredGaps).map { weight, requiredGap in
                weight - requiredGap
            }
            let availableContent = dimension - requiredGaps.reduce(0, +)
            let totalContentWeight = contentWeights.reduce(0, +)
            if availableContent > 0,
               totalContentWeight > 0,
               contentWeights.allSatisfy({ $0 > 0 })
            {
                let contentScale = availableContent / totalContentWeight
                for index in children.indices {
                    children[index].setWeight(
                        orientation,
                        requiredGaps[index] + contentWeights[index] * contentScale,
                    )
                }
                return
            }
        }
        for (child, weight) in zip(children, proportionalWeights) {
            child.setWeight(orientation, weight)
        }
    }
}
