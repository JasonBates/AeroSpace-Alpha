import Common
import Foundation

struct LaunchWindowCommand: Command {
    let args: LaunchWindowCmdArgs
    let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        run(env, io, placement: launchPlacement)
    }

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo, placement: LaunchPlacement) -> BinaryExitCode {
        // Capture destination and creation hints before any asynchronous work or app activation.
        let workspaceName = args.workspaceName?.raw ?? globalFocus.workspace.name
        guard TrayMenuModel.shared.isEnabled, !serverArgs.isReadOnly, !isStartup else {
            return .fail(io.err("launch-window is unavailable while disabled, read-only or starting up"))
        }
        let bounds = Workspace.get(byName: workspaceName).workspaceMonitorInfo.visibleRect
        let boundsJson = String(data: try! JSONEncoder().encode([bounds.topLeftX, bounds.topLeftY, bounds.width, bounds.height]), encoding: .utf8)!
        let hints = ["AEROSPACE_LAUNCH_WORKSPACE": workspaceName, "AEROSPACE_LAUNCH_MONITOR_BOUNDS": boundsJson]
        switch placement.accept(
            bundleId: args.appBundleId.orDie(),
            workspaceName: workspaceName,
            timeout: args.timeout,
            adapter: args.adapter.val,
            environment: config.execConfig.envVariables + env.asMap + hints,
        ) {
            case .success(let token): return .succ(io.out("accepted \(token.uuidString)"))
            case .failure(let message): return .fail(io.err(message))
        }
    }
}
