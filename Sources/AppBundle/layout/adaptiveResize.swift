import AppKit
import Common

private let adaptiveGeometryEpsilon: CGFloat = 0.000_001

struct AdaptiveTopologyItem {
    let node: ObjectIdentifier
    let orientation: Int
    let layout: String
    let children: [ObjectIdentifier]

    func matches(_ other: AdaptiveTopologyItem) -> Bool {
        node == other.node &&
            orientation == other.orientation &&
            layout == other.layout &&
            children == other.children
    }
}

func adaptiveTopologyMatches(_ lhs: [AdaptiveTopologyItem], _ rhs: [AdaptiveTopologyItem]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.matches($1) }
}

struct AdaptiveWeightSnapshot {
    let node: TreeNode
    let weight: CGFloat
}

enum AdaptiveHorizontalResizeAnchorEdge {
    case minX
    case maxX
}

struct AdaptiveHorizontalResizeAnchor {
    let edge: AdaptiveHorizontalResizeAnchorEdge
    let fixedTargetEdge: CGFloat
    let baselineTargetWidth: CGFloat
}

struct AdaptiveHorizontalResizeResult {
    let acceptedPhysicalWidth: CGFloat
}

@MainActor
func adaptiveParticipatingChildren(_ container: TilingContainer) -> [TreeNode] {
    container.children.filter {
        ($0 as? Window)?.isAwaitingOnWindowDetected != true && $0.tilingFootprint != nil
    }
}

@MainActor
func adaptiveTopologySignature(_ root: TilingContainer) -> [AdaptiveTopologyItem] {
    var result: [AdaptiveTopologyItem] = []
    func visit(_ container: TilingContainer) {
        let children = adaptiveParticipatingChildren(container)
        result.append(AdaptiveTopologyItem(
            node: ObjectIdentifier(container),
            orientation: container.orientation == .h ? 0 : 1,
            layout: container.layout.rawValue,
            children: children.map(ObjectIdentifier.init),
        ))
        for child in children {
            if let child = child as? TilingContainer {
                visit(child)
            }
        }
    }
    visit(root)
    return result
}

@MainActor
func adaptiveWeightSnapshot(_ root: TilingContainer) -> [AdaptiveWeightSnapshot] {
    var result: [AdaptiveWeightSnapshot] = []
    func visit(_ container: TilingContainer) {
        if container.layout == .tiles, container.orientation == .h {
            for child in adaptiveParticipatingChildren(container) {
                result.append(AdaptiveWeightSnapshot(
                    node: child,
                    weight: child.getWeight(.h),
                ))
            }
        }
        for child in adaptiveParticipatingChildren(container) {
            if let child = child as? TilingContainer {
                visit(child)
            }
        }
    }
    visit(root)
    return result
}

@MainActor
func restoreAdaptiveWeightSnapshot(_ snapshot: [AdaptiveWeightSnapshot]) {
    for item in snapshot {
        item.node.setWeight(.h, item.weight)
    }
}

@MainActor
private func adaptiveContainerProportionsAreInitialized(
    _ container: TilingContainer,
    children: [TreeNode],
) -> Bool {
    guard let cache = container.adaptiveLayoutProportionCache else { return false }
    return cache.adaptiveLayoutEnabled &&
        cache.orientation == container.orientation &&
        cache.layout == container.layout &&
        cache.participatingChildren == children.map(ObjectIdentifier.init)
}

private func adaptiveGapInset(index: Int, count: Int, gap: CGFloat) -> CGFloat {
    guard count > 1 else { return 0 }
    return gap - (index == 0 ? gap / 2 : 0) - (index == count - 1 ? gap / 2 : 0)
}

@MainActor
func adaptiveEffectiveHorizontalGap(configuredGap: CGFloat, width: CGFloat, childCount: Int) -> CGFloat {
    guard configuredGap > 0, childCount > 1 else { return configuredGap }
    let maximumGap = max(0, (width - CGFloat(childCount)) / CGFloat(childCount - 1))
    return min(configuredGap, maximumGap)
}

@MainActor
private func adaptiveAccordionHorizontalPadding(
    _ container: TilingContainer,
    children: [TreeNode],
    index: Int,
) -> (left: CGFloat, right: CGFloat) {
    guard container.orientation == .h else { return (0, 0) }
    let padding = CGFloat(config.accordionPadding)
    let mruIndex = children.firstIndex { $0 === container.mostRecentChild } ?? 0
    return switch index {
        case 0 where children.count == 1: (0, 0)
        case 0: (0, padding)
        case children.indices.last: (padding, 0)
        case mruIndex - 1: (0, 2 * padding)
        case mruIndex + 1: (2 * padding, 0)
        default: (padding, padding)
    }
}

@MainActor
func adaptiveMinimumWindowPhysicalWidth(availableWidth: CGFloat, config: AdaptiveLayoutConfig) -> CGFloat {
    let normalOneColumnWidth = availableWidth * CGFloat(config.oneColumnWidthPercent) / 100
    return max(
        1,
        normalOneColumnWidth * CGFloat(config.minimumWindowWidthPercent) / 100,
    )
}

@MainActor
func adaptiveMinimumPhysicalWidth(
    _ node: TreeNode,
    minimumWindowWidth: CGFloat,
    horizontalGap: CGFloat,
) -> CGFloat {
    if let window = node as? Window { return window.tiledMinimumWidth(floor: minimumWindowWidth) }
    guard let container = node as? TilingContainer else { return minimumWindowWidth }
    let children = adaptiveParticipatingChildren(container)
    guard !children.isEmpty else { return 1 }
    let childMinimums = children.map {
        adaptiveMinimumPhysicalWidth(
            $0,
            minimumWindowWidth: minimumWindowWidth,
            horizontalGap: horizontalGap,
        )
    }
    switch container.layout {
        case .tiles where container.orientation == .h:
            return max(
                1,
                childMinimums.reduce(0, +) + horizontalGap * CGFloat(children.count - 1),
            )
        case .tiles:
            return childMinimums.max() ?? 1
        case .accordion:
            return children.indices.map { index in
                let padding = adaptiveAccordionHorizontalPadding(container, children: children, index: index)
                return childMinimums[index] + padding.left + padding.right
            }.max() ?? 1
    }
}

@MainActor
private func adaptiveRequiredPhysicalWidth(
    _ node: TreeNode,
    minimumWindowWidth: CGFloat,
    horizontalGap: CGFloat,
    overrideContainer: TilingContainer? = nil,
    overrideNode: TreeNode? = nil,
    overridePhysicalWidth: CGFloat? = nil,
) -> CGFloat {
    if let window = node as? Window { return window.tiledMinimumWidth(floor: minimumWindowWidth) }
    guard let container = node as? TilingContainer else { return minimumWindowWidth }
    let children = adaptiveParticipatingChildren(container)
    guard !children.isEmpty else { return 1 }

    if container === overrideContainer,
       container.layout == .tiles,
       container.orientation == .h,
       let overrideNode,
       let overridePhysicalWidth
    {
        return children.enumerated().reduce(0) { result, pair in
            let (index, child) = pair
            let childWidth = child === overrideNode
                ? overridePhysicalWidth
                : adaptiveMinimumPhysicalWidth(
                    child,
                    minimumWindowWidth: minimumWindowWidth,
                    horizontalGap: horizontalGap,
                )
            return result + childWidth + adaptiveGapInset(
                index: index,
                count: children.count,
                gap: horizontalGap,
            )
        }
    }

    let requirements = children.map {
        adaptiveRequiredPhysicalWidth(
            $0,
            minimumWindowWidth: minimumWindowWidth,
            horizontalGap: horizontalGap,
            overrideContainer: overrideContainer,
            overrideNode: overrideNode,
            overridePhysicalWidth: overridePhysicalWidth,
        )
    }
    switch container.layout {
        case .tiles where container.orientation == .h:
            let weights = children.map { $0.getWeight(.h) }
            let totalWeight = weights.reduce(0, +)
            guard adaptiveContainerProportionsAreInitialized(container, children: children),
                  totalWeight > 0,
                  weights.allSatisfy({ $0 > 0 && $0.isFinite })
            else {
                return max(1, requirements.reduce(0, +) + horizontalGap * CGFloat(children.count - 1))
            }
            return children.indices.map { index in
                let share = weights[index] / totalWeight
                let rawMinimum = max(
                    adaptiveGeometryEpsilon,
                    requirements[index] + adaptiveGapInset(
                        index: index,
                        count: children.count,
                        gap: horizontalGap,
                    ),
                )
                return rawMinimum / share
            }.max() ?? 1
        case .tiles:
            return requirements.max() ?? 1
        case .accordion:
            return children.indices.map { index in
                let padding = adaptiveAccordionHorizontalPadding(container, children: children, index: index)
                return requirements[index] + padding.left + padding.right
            }.max() ?? 1
    }
}

@MainActor
func adaptiveProportionsAreInitialized(_ root: TilingContainer) -> Bool {
    func visit(_ container: TilingContainer) -> Bool {
        let children = adaptiveParticipatingChildren(container)
        guard adaptiveContainerProportionsAreInitialized(container, children: children) else { return false }
        return children.allSatisfy { child in
            guard let child = child as? TilingContainer else { return true }
            return visit(child)
        }
    }
    return visit(root)
}

@MainActor
func adaptiveExpandedWorkspaceWidth(
    normalWidth: CGFloat,
    availableWidth: CGFloat,
    root: TilingContainer,
    config: AdaptiveLayoutConfig,
    horizontalGap: CGFloat,
) -> CGFloat {
    let minimumWindowWidth = adaptiveMinimumWindowPhysicalWidth(
        availableWidth: availableWidth,
        config: config,
    )
    let required = adaptiveRequiredPhysicalWidth(
        root,
        minimumWindowWidth: minimumWindowWidth,
        horizontalGap: horizontalGap,
    )
    guard required.isFinite else { return min(normalWidth, availableWidth) }
    return max(normalWidth, min(availableWidth, required))
}

private func adaptiveLowerBoundedAllocation(
    desired: [CGFloat],
    minimums: [CGFloat],
    total: CGFloat,
) -> [CGFloat] {
    guard !desired.isEmpty else { return [] }
    var result = Array(repeating: CGFloat(0), count: desired.count)
    var active = Array(desired.indices)
    var remaining = total
    while !active.isEmpty {
        let desiredTotal = active.reduce(CGFloat(0)) { result, index in
            result + max(adaptiveGeometryEpsilon, desired[index])
        }
        let belowMinimum = active.filter { index in
            remaining * max(adaptiveGeometryEpsilon, desired[index]) / desiredTotal < minimums[index]
        }
        if belowMinimum.isEmpty {
            for index in active {
                result[index] = remaining * max(adaptiveGeometryEpsilon, desired[index]) / desiredTotal
            }
            break
        }
        for index in belowMinimum {
            result[index] = minimums[index]
            remaining -= minimums[index]
        }
        active.removeAll { belowMinimum.contains($0) }
    }
    return result
}

private func adaptiveRawAllocation(
    desiredRawWidths: [CGFloat],
    minimumPhysicalWidths: [CGFloat],
    gapInsets: [CGFloat],
    total: CGFloat,
) -> [CGFloat] {
    let minimumRawWidths = zip(minimumPhysicalWidths, gapInsets).map {
        max(adaptiveGeometryEpsilon, $0 + $1)
    }
    if minimumRawWidths.reduce(0, +) <= total {
        return adaptiveLowerBoundedAllocation(
            desired: desiredRawWidths,
            minimums: minimumRawWidths,
            total: total,
        )
    }

    let contentAvailable = max(0, total - gapInsets.reduce(0, +))
    let minimumContentTotal = minimumPhysicalWidths.reduce(0, +)
    return minimumPhysicalWidths.indices.map { index in
        let content = minimumContentTotal > 0
            ? contentAvailable * minimumPhysicalWidths[index] / minimumContentTotal
            : contentAvailable / CGFloat(minimumPhysicalWidths.count)
        return max(adaptiveGeometryEpsilon, gapInsets[index] + content)
    }
}

@MainActor
func enforceAdaptiveHorizontalMinimums(
    children: [TreeNode],
    width: CGFloat,
    horizontalGap: CGFloat,
    minimumWindowWidth: CGFloat,
) {
    guard children.count > 1 else { return }
    let insets = children.indices.map {
        adaptiveGapInset(index: $0, count: children.count, gap: horizontalGap)
    }
    let minimums = children.map {
        adaptiveMinimumPhysicalWidth(
            $0,
            minimumWindowWidth: minimumWindowWidth,
            horizontalGap: horizontalGap,
        )
    }
    let current = children.map { $0.getWeight(.h) }
    let result = adaptiveRawAllocation(
        desiredRawWidths: current,
        minimumPhysicalWidths: minimums,
        gapInsets: insets,
        total: width,
    )
    for (child, weight) in zip(children, result) {
        child.setWeight(.h, weight)
    }
}

/// Without adaptive layout there is no configured width floor, only the minimums apps have shown
/// (`ObservedMinimumSize`). They take space from the other children while they all fit; when they
/// can't, the weights are left as they are.
@MainActor
func enforceObservedHorizontalMinimums(
    children: [TreeNode],
    width: CGFloat,
    horizontalGap: CGFloat,
) {
    guard children.count > 1 else { return }
    let minimumRawWidths = children.indices.map { index in
        adaptiveMinimumPhysicalWidth(children[index], minimumWindowWidth: 1, horizontalGap: horizontalGap) +
            adaptiveGapInset(index: index, count: children.count, gap: horizontalGap)
    }
    // The widths layoutTiles would give the children: it spreads the weight deficit equally
    let current = children.map { $0.getWeight(.h) }
    let delta = (width - current.reduce(0, +)) / CGFloat(children.count)
    let projected = current.map { $0 + delta }
    guard minimumRawWidths.reduce(0, +) <= width,
          zip(projected, minimumRawWidths).contains(where: { $0 < $1 - adaptiveGeometryEpsilon })
    else { return }
    let result = adaptiveLowerBoundedAllocation(desired: projected, minimums: minimumRawWidths, total: width)
    for (child, weight) in zip(children, result) {
        child.setWeight(.h, weight)
    }
}

@MainActor
func adaptiveCurrentPhysicalWidth(
    of node: TreeNode,
    in parent: TilingContainer,
    workspace: Workspace,
) -> CGFloat? {
    let children = adaptiveParticipatingChildren(parent)
    guard let index = children.firstIndex(where: { $0 === node }) else { return nil }
    let intendedParentWidth = children.sumOfDouble { $0.getWeight(.h) }
    let configuredGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.horizontal)
    let gap = adaptiveEffectiveHorizontalGap(
        configuredGap: configuredGap,
        width: intendedParentWidth,
        childCount: children.count,
    )
    return node.getWeight(.h) - adaptiveGapInset(index: index, count: children.count, gap: gap)
}

@MainActor
private func adaptivePredictedPhysicalWidth(
    of target: TilingContainer,
    in container: TilingContainer,
    width: CGFloat,
    horizontalGap: CGFloat,
) -> CGFloat? {
    if target === container { return width }
    let children = adaptiveParticipatingChildren(container)
    let weights = children.map {
        container.layout == .tiles && container.orientation == .h ? $0.getWeight(.h) : 1
    }
    let totalWeight = weights.reduce(0, +)
    for index in children.indices {
        guard let child = children[index] as? TilingContainer else { continue }
        let accordionPadding = adaptiveAccordionHorizontalPadding(container, children: children, index: index)
        let childWidth: CGFloat = switch container.layout {
            case .tiles where container.orientation == .h:
                width * weights[index] / max(totalWeight, adaptiveGeometryEpsilon) - adaptiveGapInset(
                    index: index,
                    count: children.count,
                    gap: horizontalGap,
                )
            case .tiles:
                width
            case .accordion:
                width - accordionPadding.left - accordionPadding.right
        }
        if let result = adaptivePredictedPhysicalWidth(
            of: target,
            in: child,
            width: childWidth,
            horizontalGap: horizontalGap,
        ) {
            return result
        }
    }
    return nil
}

private func adaptiveEqualRedistribution(
    current: [CGFloat],
    minimums: [CGFloat],
    desiredTotal: CGFloat,
) -> [CGFloat] {
    guard !current.isEmpty else { return [] }
    let delta = desiredTotal - current.reduce(0, +)
    if delta >= 0 {
        let addition = delta / CGFloat(current.count)
        return current.map { $0 + addition }
    }

    var result = current
    var remainingReduction = -delta
    var active = result.indices.filter { result[$0] > minimums[$0] + adaptiveGeometryEpsilon }
    while remainingReduction > adaptiveGeometryEpsilon, !active.isEmpty {
        let equalReduction = remainingReduction / CGFloat(active.count)
        var applied: CGFloat = 0
        for index in active {
            let reduction = min(equalReduction, result[index] - minimums[index])
            result[index] -= reduction
            applied += reduction
        }
        remainingReduction -= applied
        active.removeAll { result[$0] <= minimums[$0] + adaptiveGeometryEpsilon }
        if applied <= adaptiveGeometryEpsilon { break }
    }
    return result
}

@MainActor
@discardableResult
func resizeAdaptiveHorizontally(
    node: TreeNode,
    parent: TilingContainer,
    requestedPhysicalWidth: CGFloat,
    workspace: Workspace,
    maximumWorkspaceWidth: CGFloat? = nil,
    anchor: AdaptiveHorizontalResizeAnchor? = nil,
) -> AdaptiveHorizontalResizeResult? {
    guard parent.layout == .tiles, parent.orientation == .h else { return nil }
    guard adaptiveProportionsAreInitialized(workspace.rootTilingContainer) else { return nil }
    let children = adaptiveParticipatingChildren(parent)
    guard children.count > 1,
          let targetIndex = children.firstIndex(where: { $0 === node })
    else { return nil }

    let available = workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
    let configuredGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo).inner.horizontal)
    let minimumWindowWidth = adaptiveMinimumWindowPhysicalWidth(
        availableWidth: available.width,
        config: config.adaptiveLayout,
    )
    let targetMinimum = adaptiveMinimumPhysicalWidth(
        node,
        minimumWindowWidth: minimumWindowWidth,
        horizontalGap: configuredGap,
    )
    var targetWidth = max(targetMinimum, requestedPhysicalWidth)
    guard let footprint = workspace.rootTilingContainer.tilingFootprint else { return nil }
    let normalWidth = adaptiveWorkspaceRect(
        available: available,
        footprint: footprint,
        config: config.adaptiveLayout,
    ).width
    let workspaceLimit = max(1, min(available.width, maximumWorkspaceWidth ?? available.width))

    func requiredWidth(for candidate: CGFloat) -> CGFloat {
        adaptiveRequiredPhysicalWidth(
            workspace.rootTilingContainer,
            minimumWindowWidth: minimumWindowWidth,
            horizontalGap: configuredGap,
            overrideContainer: parent,
            overrideNode: node,
            overridePhysicalWidth: candidate,
        )
    }

    if let maximumParentWidth = adaptivePredictedPhysicalWidth(
        of: parent,
        in: workspace.rootTilingContainer,
        width: workspaceLimit,
        horizontalGap: configuredGap,
    ) {
        let maximumLocalGap = adaptiveEffectiveHorizontalGap(
            configuredGap: configuredGap,
            width: maximumParentWidth,
            childCount: children.count,
        )
        let maximumInsets = children.indices.map {
            adaptiveGapInset(index: $0, count: children.count, gap: maximumLocalGap)
        }
        let siblingMinimumRawTotal = children.indices
            .filter { $0 != targetIndex }
            .reduce(CGFloat(0)) { result, index in
                result + adaptiveMinimumPhysicalWidth(
                    children[index],
                    minimumWindowWidth: minimumWindowWidth,
                    horizontalGap: configuredGap,
                ) + maximumInsets[index]
            }
        let maximumTargetWidth = maximumParentWidth - siblingMinimumRawTotal - maximumInsets[targetIndex]
        if maximumTargetWidth >= targetMinimum {
            targetWidth = min(targetWidth, maximumTargetWidth)
        }
    }

    struct Plan {
        let workspaceWidth: CGFloat
        let rawWeights: [CGFloat]
        let minimumRawWeights: [CGFloat]
        let targetGapInset: CGFloat
    }

    func plan(for candidate: CGFloat) -> Plan? {
        let workspaceWidth = min(workspaceLimit, max(normalWidth, requiredWidth(for: candidate)))
        guard let parentWidth = adaptivePredictedPhysicalWidth(
            of: parent,
            in: workspace.rootTilingContainer,
            width: workspaceWidth,
            horizontalGap: configuredGap,
        ), parentWidth > 0, parentWidth.isFinite
        else { return nil }

        let localGap = adaptiveEffectiveHorizontalGap(
            configuredGap: configuredGap,
            width: parentWidth,
            childCount: children.count,
        )
        let insets = children.indices.map {
            adaptiveGapInset(index: $0, count: children.count, gap: localGap)
        }
        let minimums = children.map {
            adaptiveMinimumPhysicalWidth(
                $0,
                minimumWindowWidth: minimumWindowWidth,
                horizontalGap: configuredGap,
            )
        }
        let minimumRawWeights = children.indices.map {
            max(adaptiveGeometryEpsilon, minimums[$0] + insets[$0])
        }
        let targetRawWidth = candidate + insets[targetIndex]
        let siblingIndices = children.indices.filter { $0 != targetIndex }
        let siblingMinimums = siblingIndices.map { minimumRawWeights[$0] }
        let siblingTotal = max(0, parentWidth - targetRawWidth)

        if targetRawWidth + siblingMinimums.reduce(0, +) > parentWidth {
            return Plan(
                workspaceWidth: workspaceWidth,
                rawWeights: adaptiveRawAllocation(
                    desiredRawWidths: children.map { $0.getWeight(.h) },
                    minimumPhysicalWidths: minimums,
                    gapInsets: insets,
                    total: parentWidth,
                ),
                minimumRawWeights: minimumRawWeights,
                targetGapInset: insets[targetIndex],
            )
        }

        var rawWeights = children.map { $0.getWeight(.h) }
        rawWeights[targetIndex] = targetRawWidth
        let siblingWeights = adaptiveEqualRedistribution(
            current: siblingIndices.map { rawWeights[$0] },
            minimums: siblingMinimums,
            desiredTotal: siblingTotal,
        )
        for (index, weight) in zip(siblingIndices, siblingWeights) {
            rawWeights[index] = weight
        }
        return Plan(
            workspaceWidth: workspaceWidth,
            rawWeights: rawWeights,
            minimumRawWeights: minimumRawWeights,
            targetGapInset: insets[targetIndex],
        )
    }

    enum AnchorAdjustment {
        case feasible([CGFloat])
        case infeasible(shortfall: CGFloat)
    }

    func applyAnchor(_ anchor: AdaptiveHorizontalResizeAnchor, to plan: Plan) -> AnchorAdjustment {
        let overrides = Dictionary(uniqueKeysWithValues: zip(children, plan.rawWeights).map {
            (ObjectIdentifier($0.0), $0.1)
        })
        guard let targetRect = adaptiveRelativeHorizontalRect(
            of: node,
            in: workspace.rootTilingContainer,
            width: plan.workspaceWidth,
            configuredHorizontalGap: configuredGap,
            horizontalWeightOverrides: overrides,
        ) else { return .infeasible(shortfall: abs(targetWidth - anchor.baselineTargetWidth)) }

        let relativeEdge = switch anchor.edge {
            case .minX: targetRect.minX
            case .maxX: targetRect.maxX
        }
        let minimumOrigin = available.minX
        let maximumOrigin = max(minimumOrigin, available.maxX - plan.workspaceWidth)
        let requestedOrigin = anchor.fixedTargetEdge - relativeEdge
        let constrainedOrigin = requestedOrigin.coerce(in: minimumOrigin ... maximumOrigin)
        let adjustment = anchor.fixedTargetEdge - constrainedOrigin - relativeEdge
        guard abs(adjustment) > adaptiveGeometryEpsilon else { return .feasible(plan.rawWeights) }

        let before = Array(children.indices.prefix(upTo: targetIndex))
        let after = Array(children.indices.suffix(from: targetIndex + 1))
        let shrinking = adjustment > 0 ? after : before
        let growing = adjustment > 0 ? before : after
        let amount = abs(adjustment)
        guard !shrinking.isEmpty, !growing.isEmpty else {
            return .infeasible(shortfall: amount)
        }

        var result = plan.rawWeights
        let shrinkCapacity = shrinking.reduce(CGFloat(0)) { partial, index in
            partial + max(0, result[index] - plan.minimumRawWeights[index])
        }
        let applied = min(amount, shrinkCapacity)
        guard applied > adaptiveGeometryEpsilon else { return .infeasible(shortfall: amount) }

        let shrunken = adaptiveEqualRedistribution(
            current: shrinking.map { result[$0] },
            minimums: shrinking.map { plan.minimumRawWeights[$0] },
            desiredTotal: shrinking.reduce(CGFloat(0)) { $0 + result[$1] } - applied,
        )
        let grown = adaptiveEqualRedistribution(
            current: growing.map { result[$0] },
            minimums: growing.map { plan.minimumRawWeights[$0] },
            desiredTotal: growing.reduce(CGFloat(0)) { $0 + result[$1] } + applied,
        )
        for (index, weight) in zip(shrinking, shrunken) {
            result[index] = weight
        }
        for (index, weight) in zip(growing, grown) {
            result[index] = weight
        }
        let shortfall = amount - applied
        return shortfall <= adaptiveGeometryEpsilon
            ? .feasible(result)
            : .infeasible(shortfall: shortfall)
    }

    // Moving raw width across the target changes its relative anchored edge one-for-one. If the
    // shrinking side saturates, that unmet transfer is therefore the exact target-width correction.
    // Rebuild and validate the corrected plan; the spare pass only absorbs floating-point saturation.
    var finalPlan: Plan?
    for _ in 0 ..< 3 {
        guard let candidatePlan = plan(for: targetWidth) else { return nil }
        guard let anchor else {
            finalPlan = candidatePlan
            break
        }
        switch applyAnchor(anchor, to: candidatePlan) {
            case .feasible(let weights):
                finalPlan = Plan(
                    workspaceWidth: candidatePlan.workspaceWidth,
                    rawWeights: weights,
                    minimumRawWeights: candidatePlan.minimumRawWeights,
                    targetGapInset: candidatePlan.targetGapInset,
                )
            case .infeasible(let shortfall):
                let nextTargetWidth = max(targetMinimum, targetWidth > anchor.baselineTargetWidth
                    ? max(anchor.baselineTargetWidth, targetWidth - shortfall)
                    : min(anchor.baselineTargetWidth, targetWidth + shortfall))
                guard abs(nextTargetWidth - targetWidth) > adaptiveGeometryEpsilon else { return nil }
                targetWidth = nextTargetWidth
                continue
        }
        break
    }
    guard let finalPlan else { return nil }
    for (child, weight) in zip(children, finalPlan.rawWeights) {
        child.setWeight(.h, weight)
    }
    return AdaptiveHorizontalResizeResult(
        acceptedPhysicalWidth: max(1, finalPlan.rawWeights[targetIndex] - finalPlan.targetGapInset),
    )
}

@MainActor
func adaptiveRelativeHorizontalRect(
    of target: TreeNode,
    in root: TilingContainer,
    width: CGFloat,
    configuredHorizontalGap: CGFloat,
    horizontalWeightOverrides: [ObjectIdentifier: CGFloat] = [:],
) -> Rect? {
    if target === root {
        return Rect(topLeftX: 0, topLeftY: 0, width: width, height: 0)
    }

    func visit(_ container: TilingContainer, x: CGFloat, width: CGFloat) -> Rect? {
        let children = adaptiveParticipatingChildren(container)
        let horizontalGap = container.layout == .tiles && container.orientation == .h
            ? adaptiveEffectiveHorizontalGap(
                configuredGap: configuredHorizontalGap,
                width: width,
                childCount: children.count,
            )
            : configuredHorizontalGap
        let weights = children.map {
            if container.layout == .tiles, container.orientation == .h {
                return horizontalWeightOverrides[ObjectIdentifier($0)] ?? $0.getWeight(.h)
            }
            return 1
        }
        let totalWeight = weights.reduce(0, +)
        var rawX = x
        for index in children.indices {
            let child = children[index]
            let childX: CGFloat
            let childWidth: CGFloat
            switch container.layout {
                case .tiles where container.orientation == .h:
                    let rawWidth = width * weights[index] / max(totalWeight, adaptiveGeometryEpsilon)
                    childX = rawX + (index == 0 ? 0 : horizontalGap / 2)
                    childWidth = rawWidth - adaptiveGapInset(
                        index: index,
                        count: children.count,
                        gap: horizontalGap,
                    )
                    rawX += rawWidth
                case .tiles:
                    childX = x
                    childWidth = width
                case .accordion:
                    let padding = adaptiveAccordionHorizontalPadding(container, children: children, index: index)
                    childX = x + padding.left
                    childWidth = width - padding.left - padding.right
            }
            if child === target {
                return Rect(topLeftX: childX, topLeftY: 0, width: childWidth, height: 0)
            }
            if let child = child as? TilingContainer,
               let result = visit(child, x: childX, width: childWidth)
            {
                return result
            }
        }
        return nil
    }
    return visit(root, x: 0, width: width)
}
