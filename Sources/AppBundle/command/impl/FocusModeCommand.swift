import Common

struct FocusModeCommand: Command {
    let args: FocusModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        if FocusMode.shared.isActive {
            FocusMode.shared.stop()
            return .succ
        }
        guard let window = globalFocus.windowOrNil,
              !window.isFullscreen,
              window.isFloating || window.parent is TilingContainer
        else {
            return .fail(io.err("Focus Mode needs a focused tiled or floating window"))
        }
        guard await FocusMode.shared.start(window: window, workspace: globalFocus.workspace, stayOnMonitor: args.stayOnMonitor) else {
            return .fail(io.err("Could not read the floating window's frame"))
        }
        return .succ
    }
}
