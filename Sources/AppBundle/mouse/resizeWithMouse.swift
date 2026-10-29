import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

private enum AdaptiveMouseResizeEdge {
    case left
    case right
}

private let adaptiveMouseGeometryEpsilon: CGFloat = 0.000_001

private struct AdaptiveMouseHorizontalClampAttempt {
    let observedX: CGFloat
    let observedWidth: CGFloat
    let acceptedX: CGFloat
    let acceptedWidth: CGFloat

    func matches(_ other: AdaptiveMouseHorizontalClampAttempt) -> Bool {
        observedX == other.observedX &&
            observedWidth == other.observedWidth &&
            acceptedX == other.acceptedX &&
            acceptedWidth == other.acceptedWidth
    }
}

private struct VerticalMouseClampAttempt {
    let windowId: UInt32
    let observedY: CGFloat
    let observedHeight: CGFloat
    let acceptedY: CGFloat
    let acceptedHeight: CGFloat

    func matches(_ other: VerticalMouseClampAttempt) -> Bool {
        windowId == other.windowId &&
            observedY == other.observedY &&
            observedHeight == other.observedHeight &&
            acceptedY == other.acceptedY &&
            acceptedHeight == other.acceptedHeight
    }
}

private struct VerticalMouseResizeState {
    let windowId: UInt32
    let workspace: ObjectIdentifier
    let monitorId: Int
    let available: Rect
    let adaptivePolicy: AdaptiveMouseResizePolicy
    let topology: [AdaptiveTopologyItem]
    let minimumWindowHeight: Int
    let verticalGap: CGFloat
    let accordionPadding: Int
    let target: TreeNode?
    let parent: TilingContainer?
    let donorIndices: [Int]
    let lowerEdge: Bool
    let baselineWindowFrame: Rect
    let baselineTargetHeight: CGFloat?
    let baselineWeights: [CGFloat]
}

private struct AdaptiveMouseResizePolicy {
    let enabled: Bool
    let oneColumnWidthPercent: Int
    let twoColumnWidthPercent: Int
    let singleRowHeightPercent: Int
    let minimumWindowWidthPercent: Int
    let horizontalGap: CGFloat
    let accordionPadding: Int

    func matches(_ other: AdaptiveMouseResizePolicy) -> Bool {
        enabled == other.enabled &&
            oneColumnWidthPercent == other.oneColumnWidthPercent &&
            twoColumnWidthPercent == other.twoColumnWidthPercent &&
            singleRowHeightPercent == other.singleRowHeightPercent &&
            minimumWindowWidthPercent == other.minimumWindowWidthPercent &&
            horizontalGap == other.horizontalGap &&
            accordionPadding == other.accordionPadding
    }
}

private struct AdaptiveMouseResizeState {
    let windowId: UInt32
    let workspace: ObjectIdentifier
    let monitorId: Int
    let available: Rect
    let policy: AdaptiveMouseResizePolicy
    let topology: [AdaptiveTopologyItem]
    let target: TreeNode
    let parent: TilingContainer
    let edge: AdaptiveMouseResizeEdge
    let baselineWindowFrame: Rect
    let baselineTargetFrame: Rect
    let baselineWorkspaceFrame: Rect
    let fixedTargetEdge: CGFloat
    let weights: [AdaptiveWeightSnapshot]
    var lastAttemptedHorizontalClamp: AdaptiveMouseHorizontalClampAttempt?
}

@MainActor
private var adaptiveMouseResizeState: AdaptiveMouseResizeState?

@MainActor
private var adaptiveMouseResizeInvalidatedWindowId: UInt32?

@MainActor
private var verticalMouseClampAttempt: VerticalMouseClampAttempt?

@MainActor
private var verticalMouseResizeState: VerticalMouseResizeState?

@MainActor
private func adaptiveMouseResizePolicy(_ workspace: Workspace) -> AdaptiveMouseResizePolicy {
    let adaptive = config.adaptiveLayout
    return AdaptiveMouseResizePolicy(
        enabled: adaptive.enabled.getValue(for: workspace.workspaceMonitorInfo),
        oneColumnWidthPercent: adaptive.oneColumnWidthPercent,
        twoColumnWidthPercent: adaptive.twoColumnWidthPercent,
        singleRowHeightPercent: adaptive.singleRowHeightPercent,
        minimumWindowWidthPercent: adaptive.minimumWindowWidthPercent,
        horizontalGap: CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.horizontal),
        accordionPadding: config.accordionPadding,
    )
}

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    guard let windowId = currentlyManipulatedWithMouseWindowId ?? adaptiveMouseResizeInvalidatedWindowId else { return }
    currentlyManipulatedWithMouseWindowId = nil
    adaptiveMouseResizeState = nil
    adaptiveMouseResizeInvalidatedWindowId = nil
    verticalMouseClampAttempt = nil
    verticalMouseResizeState = nil
    for workspace in Workspace.all {
        workspace.resetResizeWeightBeforeResizeRecursive()
    }
    defer {
        if !isUnitTest {
            scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
        }
    }
    // A dropped floating window belongs to the monitor it was dropped on. The rebinding during the
    // drag (moveWithMouse) can lag behind the pointer, and the refresh scheduled on exit would then lay the window
    // out on the monitor of its stale workspace.
    if let window = Window.get(byId: windowId) {
        if window.parent is TilingContainer {
            window.lastAppliedLayoutPhysicalRect = nil
        }
        if window.isFloating {
            try await window.bindFloatingWindowToMonitorUnderCenter()
        }
    }
}

@MainActor
func cancelResizeWithMouseGesture(for workspace: Workspace) {
    workspace.resetResizeWeightBeforeResizeRecursive()
    guard let windowId = currentlyManipulatedWithMouseWindowId,
          Window.get(byId: windowId)?.nodeWorkspace === workspace
    else { return }
    resizeWithMouseTask?.cancel()
    resizeWithMouseTask = nil
    adaptiveMouseResizeState = nil
    verticalMouseClampAttempt = nil
    verticalMouseResizeState = nil
    currentlyManipulatedWithMouseWindowId = nil
    // Refuse any already queued AX notification from the cancelled gesture. The
    // normal mouse-release cleanup clears this before a new gesture starts.
    adaptiveMouseResizeInvalidatedWindowId = windowId
}

@MainActor
func adaptiveMouseAnchoredWorkspaceRect(
    workspace: Workspace,
    centered: Rect,
    available: Rect,
) -> Rect {
    guard let state = adaptiveMouseResizeState,
          currentlyManipulatedWithMouseWindowId == state.windowId,
          state.workspace == ObjectIdentifier(workspace),
          state.monitorId == workspace.workspaceMonitorInfo.monitorAppKitNsScreenScreensId,
          state.available == available,
          state.policy.matches(adaptiveMouseResizePolicy(workspace)),
          adaptiveTopologyMatches(state.topology, adaptiveTopologySignature(workspace.rootTilingContainer))
    else { return centered }

    let horizontalGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.horizontal)
    guard let targetRect = adaptiveRelativeHorizontalRect(
        of: state.target,
        in: workspace.rootTilingContainer,
        width: centered.width,
        configuredHorizontalGap: horizontalGap,
    ) else { return centered }
    let requestedX = switch state.edge {
        case .left: state.fixedTargetEdge - targetRect.maxX
        case .right: state.fixedTargetEdge - targetRect.minX
    }
    let x = requestedX.coerce(in: available.minX ... max(available.minX, available.maxX - centered.width))
    return centered.copy(\.topLeftX, x)
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
func resizeWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case nil: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard var rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            let isFirstEvent = currentlyManipulatedWithMouseWindowId != window.windowId
            if isFirstEvent {
                adaptiveMouseResizeState = nil
                verticalMouseClampAttempt = nil
                verticalMouseResizeState = nil
                if adaptiveMouseResizeInvalidatedWindowId != window.windowId {
                    adaptiveMouseResizeInvalidatedWindowId = nil
                }
            }
            let workspace = window.nodeWorkspace.orDie()
            if adaptiveMouseResizeInvalidatedWindowId == window.windowId {
                currentlyManipulatedWithMouseWindowId = window.windowId
                return
            }
            let mousePolicy = adaptiveMouseResizePolicy(workspace)
            let adaptiveEnabled = mousePolicy.enabled
            let isInFocusMode = FocusMode.shared.frame(for: window, in: workspace) != nil
            var adaptiveHorizontalResizeHandled = adaptiveMouseResizeInvalidatedWindowId == window.windowId

            if adaptiveMouseResizeState != nil, !adaptiveEnabled || isInFocusMode {
                adaptiveMouseResizeState = nil
                adaptiveMouseResizeInvalidatedWindowId = window.windowId
                adaptiveHorizontalResizeHandled = true
            }

            if adaptiveEnabled, !isInFocusMode {
                let resizeNode = window.parentsWithSelf.first { node in
                    guard let parent = node.parent as? TilingContainer else { return false }
                    return parent.layout == .tiles && parent.orientation == .h
                }
                if let resizeNode, let resizeParent = resizeNode.parent as? TilingContainer {
                    let leftDiff = lastAppliedLayoutRect.minX - rect.minX
                    let rightDiff = rect.maxX - lastAppliedLayoutRect.maxX
                    let detectedEdge: AdaptiveMouseResizeEdge = abs(leftDiff) > abs(rightDiff) ? .left : .right
                    let detectedDiff = detectedEdge == .left ? leftDiff : rightDiff
                    if adaptiveMouseResizeState == nil,
                       adaptiveMouseResizeInvalidatedWindowId != window.windowId,
                       abs(detectedDiff) > 5
                    {
                        if
                            let baselineTargetFrame = resizeNode.lastAppliedLayoutPhysicalRect,
                            let baselineWorkspaceFrame = workspace.lastAppliedLayoutPhysicalRect,
                            adaptiveProportionsAreInitialized(workspace.rootTilingContainer)
                        {
                            let available = workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
                            adaptiveMouseResizeState = AdaptiveMouseResizeState(
                                windowId: window.windowId,
                                workspace: ObjectIdentifier(workspace),
                                monitorId: workspace.workspaceMonitorInfo.monitorAppKitNsScreenScreensId,
                                available: available,
                                policy: mousePolicy,
                                topology: adaptiveTopologySignature(workspace.rootTilingContainer),
                                target: resizeNode,
                                parent: resizeParent,
                                edge: detectedEdge,
                                baselineWindowFrame: lastAppliedLayoutRect,
                                baselineTargetFrame: baselineTargetFrame,
                                baselineWorkspaceFrame: baselineWorkspaceFrame,
                                fixedTargetEdge: detectedEdge == .left ? baselineTargetFrame.maxX : baselineTargetFrame.minX,
                                weights: adaptiveWeightSnapshot(workspace.rootTilingContainer),
                                lastAttemptedHorizontalClamp: nil,
                            )
                        }
                    }
                    if let state = adaptiveMouseResizeState {
                        guard state.windowId == window.windowId,
                              state.workspace == ObjectIdentifier(workspace),
                              state.monitorId == workspace.workspaceMonitorInfo.monitorAppKitNsScreenScreensId,
                              state.available == workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps,
                              state.policy.matches(mousePolicy),
                              adaptiveTopologyMatches(
                                  state.topology,
                                  adaptiveTopologySignature(workspace.rootTilingContainer),
                              ),
                              state.target === resizeNode,
                              state.parent === resizeParent
                        else {
                            adaptiveMouseResizeState = nil
                            adaptiveMouseResizeInvalidatedWindowId = window.windowId
                            currentlyManipulatedWithMouseWindowId = window.windowId
                            return
                        }

                        restoreAdaptiveWeightSnapshot(state.weights)
                        let baselineDiff = switch state.edge {
                            case .left: state.baselineWindowFrame.minX - rect.minX
                            case .right: rect.maxX - state.baselineWindowFrame.maxX
                        }
                        let screenLimitedTargetWidth = switch state.edge {
                            case .left: state.fixedTargetEdge - state.available.minX
                            case .right: state.available.maxX - state.fixedTargetEdge
                        }
                        let pointerRequestedTargetWidth = state.baselineTargetFrame.width + baselineDiff
                        let requestedTargetWidth = min(
                            screenLimitedTargetWidth,
                            pointerRequestedTargetWidth,
                        )
                        let maximumWorkspaceWidth = switch state.edge {
                            case .left: state.baselineWorkspaceFrame.maxX - state.available.minX
                            case .right: state.available.maxX - state.baselineWorkspaceFrame.minX
                        }
                        guard let resizeResult = resizeAdaptiveHorizontally(
                            node: state.target,
                            parent: state.parent,
                            requestedPhysicalWidth: requestedTargetWidth,
                            workspace: workspace,
                            maximumWorkspaceWidth: maximumWorkspaceWidth,
                            anchor: AdaptiveHorizontalResizeAnchor(
                                edge: state.edge == .left ? .maxX : .minX,
                                fixedTargetEdge: state.fixedTargetEdge,
                                baselineTargetWidth: state.baselineTargetFrame.width,
                            ),
                        ) else {
                            adaptiveMouseResizeState = nil
                            adaptiveMouseResizeInvalidatedWindowId = window.windowId
                            currentlyManipulatedWithMouseWindowId = window.windowId
                            return
                        }
                        if abs(pointerRequestedTargetWidth - resizeResult.acceptedPhysicalWidth) > adaptiveMouseGeometryEpsilon {
                            let acceptedWindowWidth = max(
                                1,
                                state.baselineWindowFrame.width +
                                    resizeResult.acceptedPhysicalWidth - state.baselineTargetFrame.width,
                            )
                            let acceptedWindowX = switch state.edge {
                                case .left: state.baselineWindowFrame.maxX - acceptedWindowWidth
                                case .right: state.baselineWindowFrame.minX
                            }
                            let clampedFrame = Rect(
                                topLeftX: acceptedWindowX,
                                topLeftY: rect.minY,
                                width: acceptedWindowWidth,
                                height: rect.height,
                            )
                            let attempt = AdaptiveMouseHorizontalClampAttempt(
                                observedX: rect.minX,
                                observedWidth: rect.width,
                                acceptedX: clampedFrame.minX,
                                acceptedWidth: clampedFrame.width,
                            )
                            if state.lastAttemptedHorizontalClamp?.matches(attempt) != true {
                                var updatedState = state
                                updatedState.lastAttemptedHorizontalClamp = attempt
                                adaptiveMouseResizeState = updatedState
                                window.setAxFrame(clampedFrame.topLeftCorner, clampedFrame.size)
                            }
                            rect = clampedFrame
                        } else if state.lastAttemptedHorizontalClamp != nil {
                            var updatedState = state
                            updatedState.lastAttemptedHorizontalClamp = nil
                            adaptiveMouseResizeState = updatedState
                        }
                        adaptiveHorizontalResizeHandled = true
                    } else if adaptiveMouseResizeInvalidatedWindowId == window.windowId {
                        adaptiveHorizontalResizeHandled = true
                    }
                } else if adaptiveMouseResizeState != nil {
                    adaptiveMouseResizeState = nil
                    adaptiveMouseResizeInvalidatedWindowId = window.windowId
                    adaptiveHorizontalResizeHandled = true
                }
            }

            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let horizontalTable: [(CGFloat, TilingContainer?, Int?, Int?)] = adaptiveHorizontalResizeHandled ? [] : [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0, lOwnIndex),
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count),
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in horizontalTable {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }

            if verticalMouseResizeState == nil {
                let verticalAttempts: [(diff: CGFloat, parent: TilingContainer?, ownIndex: Int?, lowerEdge: Bool)] = [
                    (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex, true),
                    (lastAppliedLayoutRect.minY - rect.minY, uParent, uOwnIndex, false),
                ]
                if let attempt = verticalAttempts
                    .filter({ abs($0.diff) > 5 })
                    .max(by: { abs($0.diff) < abs($1.diff) })
                {
                    var target: TreeNode?
                    var parent: TilingContainer?
                    var donorIndices: [Int] = []
                    var baselineWeights: [CGFloat] = []
                    var baselineTargetHeight: CGFloat?
                    if let attemptParent = attempt.parent, let ownIndex = attempt.ownIndex {
                        let attemptTarget = attemptParent.children[ownIndex]
                        let children = tiledParticipatingChildren(attemptParent)
                        if let targetIndex = children.firstIndex(where: { $0 === attemptTarget }) {
                            let donors = attempt.lowerEdge
                                ? Array(children.indices.suffix(from: targetIndex + 1))
                                : Array(children.indices.prefix(upTo: targetIndex))
                            let rawWeights = children.map { $0.getWeightBeforeResize(.v) }
                            let weights = intendedTiledVerticalWeights(
                                parent: attemptParent,
                                workspace: workspace,
                                desiredWeights: rawWeights,
                            ) ?? rawWeights
                            if !donors.isEmpty, let targetHeight = tiledPhysicalHeight(
                                node: attemptTarget,
                                parent: attemptParent,
                                workspace: workspace,
                                desiredWeights: weights,
                            ) {
                                target = attemptTarget
                                parent = attemptParent
                                donorIndices = donors
                                baselineWeights = weights
                                baselineTargetHeight = targetHeight
                            }
                        }
                    }
                    verticalMouseResizeState = VerticalMouseResizeState(
                        windowId: window.windowId,
                        workspace: ObjectIdentifier(workspace),
                        monitorId: workspace.workspaceMonitorInfo.monitorAppKitNsScreenScreensId,
                        available: workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps,
                        adaptivePolicy: mousePolicy,
                        topology: adaptiveTopologySignature(workspace.rootTilingContainer),
                        minimumWindowHeight: config.minimumWindowHeight,
                        verticalGap: CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.vertical),
                        accordionPadding: config.accordionPadding,
                        target: target,
                        parent: parent,
                        donorIndices: donorIndices,
                        lowerEdge: attempt.lowerEdge,
                        baselineWindowFrame: lastAppliedLayoutRect,
                        baselineTargetHeight: baselineTargetHeight,
                        baselineWeights: baselineWeights,
                    )
                }
            }
            if let state = verticalMouseResizeState {
                let verticalGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.vertical)
                guard state.windowId == window.windowId,
                      state.workspace == ObjectIdentifier(workspace),
                      state.monitorId == workspace.workspaceMonitorInfo.monitorAppKitNsScreenScreensId,
                      state.available == workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps,
                      state.adaptivePolicy.matches(mousePolicy),
                      state.minimumWindowHeight == config.minimumWindowHeight,
                      state.verticalGap == verticalGap,
                      state.accordionPadding == config.accordionPadding,
                      adaptiveTopologyMatches(state.topology, adaptiveTopologySignature(workspace.rootTilingContainer))
                else {
                    verticalMouseResizeState = nil
                    adaptiveMouseResizeInvalidatedWindowId = window.windowId
                    currentlyManipulatedWithMouseWindowId = window.windowId
                    return
                }
                let diff = state.lowerEdge
                    ? rect.maxY - state.baselineWindowFrame.maxY
                    : state.baselineWindowFrame.minY - rect.minY
                var acceptedDelta: CGFloat? = 0 // Outer workspace edges cannot move.
                if let target = state.target,
                   let parent = state.parent,
                   let baselineTargetHeight = state.baselineTargetHeight
                {
                    acceptedDelta = resizeTiledVertically(
                        node: target,
                        parent: parent,
                        requestedPhysicalHeight: baselineTargetHeight + diff,
                        workspace: workspace,
                        donorIndices: state.donorIndices,
                        baselineWeights: state.baselineWeights,
                    )?.acceptedDelta
                }
                if let acceptedDelta {
                    if abs(diff - acceptedDelta) > adaptiveMouseGeometryEpsilon {
                        let acceptedWindowHeight = max(
                            adaptiveMouseGeometryEpsilon,
                            state.baselineWindowFrame.height + acceptedDelta,
                        )
                        let acceptedWindowY = state.lowerEdge
                            ? state.baselineWindowFrame.minY
                            : state.baselineWindowFrame.maxY - acceptedWindowHeight
                        let clampedFrame = Rect(
                            topLeftX: rect.minX,
                            topLeftY: acceptedWindowY,
                            width: rect.width,
                            height: acceptedWindowHeight,
                        )
                        let clampAttempt = VerticalMouseClampAttempt(
                            windowId: window.windowId,
                            observedY: rect.minY,
                            observedHeight: rect.height,
                            acceptedY: acceptedWindowY,
                            acceptedHeight: acceptedWindowHeight,
                        )
                        if verticalMouseClampAttempt?.matches(clampAttempt) != true {
                            verticalMouseClampAttempt = clampAttempt
                            window.setAxFrame(clampedFrame.topLeftCorner, clampedFrame.size)
                        }
                    } else {
                        verticalMouseClampAttempt = nil
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
