extension Workspace {
    @MainActor func normalizeContainers() {
        let root = rootTilingContainer
        root.unbindEmptyAndFlattenContainersRecursive()
        // rootTilingContainer.deriveAxLifeStatusRecursive()
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            root.normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: nil)
        }
    }
}

extension TilingContainer {
    /// This function has probably way too many responsibilities:
    /// 1. It unbinds empty containers
    /// 2. It flattens containers that contain only a single child (excluding the root container)
    /// 3. It sets correct lifeStatus values
    ///
    /// todo: It's not clear what happens with mru in this function (does mru get rewritten by the recursive calls?).
    ///       Is it O(n^2) complexity?
    @MainActor fileprivate func unbindEmptyAndFlattenContainersRecursive() {
        if isRootContainer { // Special logic for root node to keep it always bound
            if let child = children.singleOrNil() as? TilingContainer, config.enableNormalizationFlattenContainers {
                let mruChildren = Array(child._mruChildren)
                changeOrientation(child.orientation)
                layout = child.layout
                child.unbindFromParent()
                // Unbinding shrinks the source array, so data.index would be zero on every
                // iteration and reverse the order. Use indices from the original snapshot.
                for (index, grandChild) in child.children.enumerated() {
                    let data = grandChild.unbindFromParent()
                    grandChild.bind(to: self, adaptiveWeight: data.adaptiveWeight, index: index)
                }
                for grandChild in mruChildren.reversed() { grandChild.markAsMostRecentChild() }
            }
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive()
            }
            self.lifeStatus = .alive
        } else if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent() // Kill the current node
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            var inhabitedChildrenCount = 0
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive()
                inhabitedChildrenCount += child.tilingTreeNodeCasesOrDie().isInhabited ? 1 : 0
            }
            if children.isEmpty {
                unbindFromParent()
            }
            if inhabitedChildrenCount == 1 && config.enableNormalizationFlattenContainers {
                lifeStatus = .mustBeFlattened
            } else {
                lifeStatus = inhabitedChildrenCount > 0 ? .alive : .deadOrInvisible
            }
        }
    }
}
