import AppKit
import Common

struct CenterCommand: Command {
    let args: CenterCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard window.isFloating else { return .fail(io.err("center command only supports floating windows")) }
        // A window on a hidden workspace is parked in a screen corner. Moving it would reveal it on another workspace
        guard target.workspace.isVisible else { return .fail(io.err("The window's workspace isn't visible")) }
        guard let rect = try? await window.getAxRect(.nonCancellable) else { return .fail(io.err("Can't read the window's frame")) }
        let bounds = target.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        let frame = floatingFrame(center: bounds.center, size: rect.size, within: bounds)
        window.setAxFrame(frame.topLeftCorner, frame.size)
        return .succ
    }
}
