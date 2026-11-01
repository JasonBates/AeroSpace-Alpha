import Common

struct LaunchWindowCommand: Command {
    let args: LaunchWindowCmdArgs
    let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        run(env, io, placement: launchPlacement)
    }

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo, placement: LaunchPlacement) -> BinaryExitCode {
        // Capture the name before starting any asynchronous work or activating an app.
        let workspaceName = args.workspaceName?.raw ?? globalFocus.workspace.name
        guard TrayMenuModel.shared.isEnabled, !serverArgs.isReadOnly, !isStartup else {
            return .fail(io.err("launch-window is unavailable while disabled, read-only or starting up"))
        }
        switch placement.accept(
            bundleId: args.appBundleId.orDie(),
            workspaceName: workspaceName,
            timeout: args.timeout,
            adapter: args.adapter.val,
            environment: config.execConfig.envVariables + env.asMap,
        ) {
            case .success(let token): return .succ(io.out("accepted \(token.uuidString)"))
            case .failure(let message): return .fail(io.err(message))
        }
    }
}
