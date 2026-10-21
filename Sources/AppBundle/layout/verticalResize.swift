import AppKit

private let verticalGeometryEpsilon: CGFloat = 0.000_001

struct VerticalResizeResult {
    let acceptedDelta: CGFloat
}

@MainActor
func tiledParticipatingChildren(_ container: TilingContainer) -> [TreeNode] {
    container.children.filter { $0.tilingFootprint != nil }
}

private func verticalGapInset(index: Int, count: Int, gap: CGFloat) -> CGFloat {
    guard count > 1 else { return 0 }
    return gap - (index == 0 ? gap / 2 : 0) - (index == count - 1 ? gap / 2 : 0)
}

private struct VerticalAllocationPlan {
    let gap: CGFloat
    let minimumPhysicalHeights: [CGFloat]
}

private struct IntendedVerticalAllocation {
    let plan: VerticalAllocationPlan
    let weights: [CGFloat]
}

@MainActor
private func verticalAllocationPlan(
    children: [TreeNode],
    height: CGFloat,
    configuredGap: CGFloat,
    minimumWindowHeight: CGFloat,
) -> VerticalAllocationPlan {
    let preferredMinimums = children.map {
        minimumTiledPhysicalHeight(
            $0,
            minimumWindowHeight: minimumWindowHeight,
            verticalGap: configuredGap,
        )
    }
    let preferredTotal = preferredMinimums.reduce(0, +) + configuredGap * CGFloat(max(0, children.count - 1))
    if preferredTotal <= height + verticalGeometryEpsilon {
        return VerticalAllocationPlan(gap: configuredGap, minimumPhysicalHeights: preferredMinimums)
    }

    // Preserve content floors before inner gaps. Descendant vertical gaps are
    // also allowed to collapse when their allocated container is laid out.
    let noGapMinimums = children.map {
        minimumTiledPhysicalHeight(
            $0,
            minimumWindowHeight: minimumWindowHeight,
            verticalGap: 0,
        )
    }
    let gap = children.count > 1
        ? min(configuredGap, max(0, (height - noGapMinimums.reduce(0, +)) / CGFloat(children.count - 1)))
        : 0
    return VerticalAllocationPlan(gap: gap, minimumPhysicalHeights: noGapMinimums)
}

@MainActor
private func configuredAccordionVerticalPadding(
    _ container: TilingContainer,
    children: [TreeNode],
    index: Int,
) -> (top: CGFloat, bottom: CGFloat) {
    guard container.orientation == .v else { return (0, 0) }
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
func minimumTiledPhysicalHeight(
    _ node: TreeNode,
    minimumWindowHeight: CGFloat,
    verticalGap: CGFloat,
) -> CGFloat {
    if node is Window { return minimumWindowHeight }
    guard let container = node as? TilingContainer else { return minimumWindowHeight }
    let children = tiledParticipatingChildren(container)
    guard !children.isEmpty else { return 1 }
    let childMinimums = children.map {
        minimumTiledPhysicalHeight(
            $0,
            minimumWindowHeight: minimumWindowHeight,
            verticalGap: verticalGap,
        )
    }
    switch container.layout {
        case .tiles where container.orientation == .v:
            return childMinimums.reduce(0, +) + verticalGap * CGFloat(children.count - 1)
        case .tiles:
            return childMinimums.max() ?? 1
        case .accordion where container.orientation == .v:
            return children.indices.map { index in
                let padding = configuredAccordionVerticalPadding(container, children: children, index: index)
                return childMinimums[index] + padding.top + padding.bottom
            }.max() ?? 1
        case .accordion:
            return childMinimums.max() ?? 1
    }
}

@MainActor
func effectiveAccordionVerticalPadding(
    _ container: TilingContainer,
    children: [TreeNode],
    index: Int,
    height: CGFloat,
    verticalGap: CGFloat,
) -> (top: CGFloat, bottom: CGFloat) {
    let configured = configuredAccordionVerticalPadding(container, children: children, index: index)
    let total = configured.top + configured.bottom
    guard total > 0 else { return configured }
    let childMinimum = minimumTiledPhysicalHeight(
        children[index],
        minimumWindowHeight: CGFloat(config.minimumWindowHeight),
        verticalGap: verticalGap,
    )
    let availablePadding = max(0, height - min(childMinimum, height))
    let scale = min(1, availablePadding / total)
    return (configured.top * scale, configured.bottom * scale)
}

private func allocatePositivePhysicalHeights(total: CGFloat, priorities: [CGFloat]) -> [CGFloat] {
    guard !priorities.isEmpty else { return [] }
    guard total > 0 else { return Array(repeating: verticalGeometryEpsilon, count: priorities.count) }
    let equalFloor = min(1, total / CGFloat(priorities.count))
    let remaining = max(0, total - equalFloor * CGFloat(priorities.count))
    let priorityTotal = priorities.reduce(0, +)
    return priorities.map { priority in
        equalFloor + (priorityTotal > 0 ? remaining * priority / priorityTotal : remaining / CGFloat(priorities.count))
    }
}

private func allocateRawHeights(
    desired: [CGFloat],
    minimumPhysicalHeights: [CGFloat],
    height: CGFloat,
    gap: CGFloat,
) -> [CGFloat] {
    guard desired.count == minimumPhysicalHeights.count, !desired.isEmpty else { return [] }
    let insets = desired.indices.map { verticalGapInset(index: $0, count: desired.count, gap: gap) }
    let minimumRaw = zip(minimumPhysicalHeights, insets).map(+)
    if minimumRaw.reduce(0, +) > height + verticalGeometryEpsilon {
        let contentHeight = max(0, height - gap * CGFloat(desired.count - 1))
        let physical = allocatePositivePhysicalHeights(total: contentHeight, priorities: minimumPhysicalHeights)
        return zip(physical, insets).map(+)
    }

    var result = Array(repeating: CGFloat.zero, count: desired.count)
    var active = Array(desired.indices)
    var remaining = height
    while !active.isEmpty {
        let desiredTotal = active.reduce(CGFloat.zero) { $0 + desired[$1] }
        let delta = (remaining - desiredTotal) / CGFloat(active.count)
        let constrained = active.filter { desired[$0] + delta < minimumRaw[$0] }
        if constrained.isEmpty {
            for index in active {
                result[index] = desired[index] + delta
            }
            break
        }
        for index in constrained {
            result[index] = minimumRaw[index]
            remaining -= minimumRaw[index]
        }
        active.removeAll { constrained.contains($0) }
    }
    return result
}

@MainActor
private func adaptiveAdjustedVerticalWeights(
    container: TilingContainer,
    children: [TreeNode],
    desired: [CGFloat],
    height: CGFloat,
    gap: CGFloat,
    adaptiveLayoutEnabled: Bool,
) -> [CGFloat] {
    guard desired.count == children.count,
          let previousCache = container.adaptiveLayoutProportionCache
    else { return desired }
    let total = desired.reduce(0, +)
    guard total > 0, desired.allSatisfy({ $0 > 0 }) else { return desired }
    let childIds = children.map(ObjectIdentifier.init)
    let topologyIsUnchanged = previousCache.orientation == container.orientation &&
        previousCache.layout == container.layout &&
        previousCache.participatingChildren == childIds
    let additiveDelta = (height - total).div(children.count)
    let additiveWouldCollapse = additiveDelta.map { delta in
        desired.enumerated().contains { index, weight in
            weight + delta <= verticalGapInset(index: index, count: children.count, gap: gap)
        }
    } ?? false
    guard adaptiveLayoutEnabled || previousCache.adaptiveLayoutEnabled,
          topologyIsUnchanged && previousCache.dimension != height || additiveWouldCollapse
    else { return desired }

    let proportional = desired.map { $0 * height / total }
    let insets = children.indices.map { verticalGapInset(index: $0, count: children.count, gap: gap) }
    if zip(proportional, insets).contains(where: { $0 <= $1 }) {
        let contentWeights = zip(desired, insets).map(-)
        let availableContent = height - insets.reduce(0, +)
        let totalContent = contentWeights.reduce(0, +)
        if availableContent > 0, totalContent > 0, contentWeights.allSatisfy({ $0 > 0 }) {
            return zip(contentWeights, insets).map { content, inset in
                inset + content * availableContent / totalContent
            }
        }
    }
    return proportional
}

@MainActor
private func intendedVerticalAllocation(
    container: TilingContainer,
    children: [TreeNode],
    height: CGFloat,
    workspace: Workspace,
    desiredWeights: [CGFloat]? = nil,
) -> IntendedVerticalAllocation {
    let configuredGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor).inner.vertical)
    let plan = verticalAllocationPlan(
        children: children,
        height: height,
        configuredGap: configuredGap,
        minimumWindowHeight: CGFloat(config.minimumWindowHeight),
    )
    let desired = desiredWeights.flatMap { $0.count == children.count ? $0 : nil }
        ?? children.map { $0.getWeight(.v) }
    let adjusted = adaptiveAdjustedVerticalWeights(
        container: container,
        children: children,
        desired: desired,
        height: height,
        gap: plan.gap,
        adaptiveLayoutEnabled: config.adaptiveLayout.enabled.getValue(for: workspace.workspaceMonitor),
    )
    return IntendedVerticalAllocation(
        plan: plan,
        weights: allocateRawHeights(
            desired: adjusted,
            minimumPhysicalHeights: plan.minimumPhysicalHeights,
            height: height,
            gap: plan.gap,
        ),
    )
}

@MainActor
@discardableResult
func enforceVerticalMinimums(
    children: [TreeNode],
    height: CGFloat,
    configuredGap: CGFloat,
    minimumWindowHeight: CGFloat,
) -> CGFloat {
    guard !children.isEmpty else { return max(0, configuredGap) }
    let plan = verticalAllocationPlan(
        children: children,
        height: height,
        configuredGap: configuredGap,
        minimumWindowHeight: minimumWindowHeight,
    )
    let allocated = allocateRawHeights(
        desired: children.map { $0.getWeight(.v) },
        minimumPhysicalHeights: plan.minimumPhysicalHeights,
        height: height,
        gap: plan.gap,
    )
    for (child, rawHeight) in zip(children, allocated) {
        child.setWeight(.v, rawHeight)
    }
    return plan.gap
}

private func reduceWithSaturation(
    values: [CGFloat],
    minimums: [CGFloat],
    reduction: CGFloat,
) -> [CGFloat] {
    var result = values
    var remaining = max(0, reduction)
    var active = result.indices.filter { result[$0] > minimums[$0] + verticalGeometryEpsilon }
    while remaining > verticalGeometryEpsilon, !active.isEmpty {
        let equalReduction = remaining / CGFloat(active.count)
        var applied: CGFloat = 0
        for index in active {
            let amount = min(equalReduction, result[index] - minimums[index])
            result[index] -= amount
            applied += amount
        }
        remaining -= applied
        active.removeAll { result[$0] <= minimums[$0] + verticalGeometryEpsilon }
        if applied <= verticalGeometryEpsilon { break }
    }
    return result
}

@MainActor
private func intendedPhysicalHeight(
    of target: TreeNode,
    within node: TreeNode,
    height: CGFloat,
    workspace: Workspace,
) -> CGFloat? {
    if node === target { return height }
    guard let container = node as? TilingContainer else { return nil }
    let children = tiledParticipatingChildren(container)
    guard let childIndex = children.firstIndex(where: { child in
        target.parentsWithSelf.contains { $0 === child }
    }) else { return nil }
    let child = children[childIndex]
    let childHeight: CGFloat
    switch container.layout {
        case .tiles where container.orientation == .v:
            let allocation = intendedVerticalAllocation(
                container: container,
                children: children,
                height: height,
                workspace: workspace,
            )
            childHeight = allocation.weights[childIndex] - verticalGapInset(
                index: childIndex,
                count: children.count,
                gap: allocation.plan.gap,
            )
        case .tiles:
            childHeight = height
        case .accordion where container.orientation == .v:
            let verticalGap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor).inner.vertical)
            let padding = effectiveAccordionVerticalPadding(
                container,
                children: children,
                index: childIndex,
                height: height,
                verticalGap: verticalGap,
            )
            childHeight = max(verticalGeometryEpsilon, height - padding.top - padding.bottom)
        case .accordion:
            childHeight = height
    }
    return intendedPhysicalHeight(of: target, within: child, height: childHeight, workspace: workspace)
}

@MainActor
private func intendedParentHeight(_ parent: TilingContainer, workspace: Workspace) -> CGFloat? {
    guard let workspaceHeight = workspace.lastAppliedLayoutPhysicalRect?.height else { return nil }
    return intendedPhysicalHeight(
        of: parent,
        within: workspace.rootTilingContainer,
        height: workspaceHeight,
        workspace: workspace,
    )
}

@MainActor
func intendedTiledVerticalWeights(
    parent: TilingContainer,
    workspace: Workspace,
    desiredWeights: [CGFloat]? = nil,
) -> [CGFloat]? {
    let children = tiledParticipatingChildren(parent)
    guard !children.isEmpty else { return nil }
    let height = intendedParentHeight(parent, workspace: workspace)
        ?? parent.lastAppliedLayoutPhysicalRect?.height
        ?? CGFloat(children.sumOfDouble { $0.getWeight(.v) })
    return intendedVerticalAllocation(
        container: parent,
        children: children,
        height: height,
        workspace: workspace,
        desiredWeights: desiredWeights,
    ).weights
}

@MainActor
func tiledPhysicalHeight(
    node: TreeNode,
    parent: TilingContainer,
    workspace: Workspace,
    desiredWeights: [CGFloat]? = nil,
) -> CGFloat? {
    guard parent.layout == .tiles, parent.orientation == .v else { return nil }
    let children = tiledParticipatingChildren(parent)
    guard let targetIndex = children.firstIndex(where: { $0 === node }) else { return nil }
    let parentHeight = intendedParentHeight(parent, workspace: workspace)
        ?? parent.lastAppliedLayoutPhysicalRect?.height
        ?? CGFloat(children.sumOfDouble { $0.getWeight(.v) })
    let allocation = intendedVerticalAllocation(
        container: parent,
        children: children,
        height: parentHeight,
        workspace: workspace,
        desiredWeights: desiredWeights,
    )
    return allocation.weights[targetIndex] - verticalGapInset(
        index: targetIndex,
        count: children.count,
        gap: allocation.plan.gap,
    )
}

@MainActor
func resizeTiledVertically(
    node: TreeNode,
    parent: TilingContainer,
    requestedPhysicalHeight: CGFloat,
    workspace: Workspace,
    donorIndices requestedDonorIndices: [Int]? = nil,
    baselineWeights: [CGFloat]? = nil,
) -> VerticalResizeResult? {
    guard parent.layout == .tiles, parent.orientation == .v else { return nil }
    let children = tiledParticipatingChildren(parent)
    guard let targetIndex = children.firstIndex(where: { $0 === node }), children.count > 1 else { return nil }
    let donorIndices = (requestedDonorIndices ?? Array(children.indices.filter { $0 != targetIndex }))
        .filter { children.indices.contains($0) && $0 != targetIndex }
    guard !donorIndices.isEmpty else { return nil }

    let parentHeight = intendedParentHeight(parent, workspace: workspace)
        ?? parent.lastAppliedLayoutPhysicalRect?.height
        ?? CGFloat(children.sumOfDouble { $0.getWeight(.v) })
    let allocation = intendedVerticalAllocation(
        container: parent,
        children: children,
        height: parentHeight,
        workspace: workspace,
        desiredWeights: baselineWeights,
    )
    var weights = allocation.weights
    let insets = children.indices.map {
        verticalGapInset(index: $0, count: children.count, gap: allocation.plan.gap)
    }
    let requestedMinimumRaw = zip(allocation.plan.minimumPhysicalHeights, insets).map(+)
    let minimumRaw = if requestedMinimumRaw.reduce(0, +) <= parentHeight + verticalGeometryEpsilon {
        requestedMinimumRaw
    } else {
        allocateRawHeights(
            desired: requestedMinimumRaw,
            minimumPhysicalHeights: allocation.plan.minimumPhysicalHeights,
            height: parentHeight,
            gap: allocation.plan.gap,
        )
    }
    let baselinePhysicalHeight = weights[targetIndex] - insets[targetIndex]
    let requestedRawHeight = requestedPhysicalHeight + insets[targetIndex]
    let donorPool = donorIndices.reduce(CGFloat.zero) { $0 + weights[$1] }
    let donorMinimum = donorIndices.reduce(CGFloat.zero) { $0 + minimumRaw[$1] }
    let acceptedRawHeight = requestedRawHeight.coerce(
        in: minimumRaw[targetIndex] ... weights[targetIndex] + donorPool - donorMinimum,
    )
    let delta = acceptedRawHeight - weights[targetIndex]
    if delta > 0 {
        let reduced = reduceWithSaturation(
            values: donorIndices.map { weights[$0] },
            minimums: donorIndices.map { minimumRaw[$0] },
            reduction: delta,
        )
        for (index, value) in zip(donorIndices, reduced) {
            weights[index] = value
        }
    } else if delta < 0 {
        let increase = -delta / CGFloat(donorIndices.count)
        for index in donorIndices {
            weights[index] += increase
        }
    }
    weights[targetIndex] = acceptedRawHeight
    for (child, weight) in zip(children, weights) {
        child.setWeight(.v, weight)
    }
    return VerticalResizeResult(
        acceptedDelta: acceptedRawHeight - insets[targetIndex] - baselinePhysicalHeight,
    )
}
