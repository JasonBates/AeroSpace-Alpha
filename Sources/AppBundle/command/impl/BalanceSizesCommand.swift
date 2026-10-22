import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        cancelResizeWithMouseGesture(for: target.workspace)
        balance(target.workspace.rootTilingContainer)
        let workspaceWindows = target.workspace.rootTilingContainer.allLeafWindowsRecursive + target.workspace.floatingWindows
        for window in workspaceWindows {
            window.singleWindowWidthAdjustment = 0
            window.focusModeHeightAdjustment = 0
            // A minimum learned before an app shrank its own (a closed sidebar) would otherwise never be retested
            window.observedMinimumSize = ObservedMinimumSize()
        }
        return .succ
    }
}

@MainActor
private func balance(_ parent: TilingContainer) {
    for child in parent.children {
        switch parent.layout {
            case .tiles: child.setWeight(parent.orientation, 1)
            case .accordion: break // Do nothing
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}
