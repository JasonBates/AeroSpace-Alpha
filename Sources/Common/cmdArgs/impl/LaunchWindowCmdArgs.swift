public struct LaunchWindowCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .launchWindow,
        help: launch_window_help_generated,
        flags: [
            "--app-bundle-id": singleValueSubArgParser(\.appBundleId, "<bundle-id>", Result.success),
            "--workspace": workspaceSubArgParser(),
            "--timeout": singleValueSubArgParser(\._timeout, "<seconds>") { value in
                guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 120 else {
                    return .failure("timeout must be greater than zero and at most 120 seconds")
                }
                return .success(seconds)
            },
        ],
        posArgs: [
            doubleDashArg(mandatory: true),
            newMandatoryPosArgParser(\.adapter, { input in
                let argv = input.args.slice(input.index...).orDie().toArray()
                return .succ(argv, advanceBy: argv.count)
            }, placeholder: "<adapter> [<arg>...]"),
        ],
    )

    public var appBundleId: String?
    public var _timeout: Double?
    public var adapter: Lateinit<[String]> = .uninitialized
    public var timeout: Double { _timeout ?? 10 }
}

func parseLaunchWindowCmdArgs(_ args: StrArrSlice) -> ParsedCmd<LaunchWindowCmdArgs> {
    parseSpecificCmdArgs(LaunchWindowCmdArgs(rawArgs: args), args)
        .filter("--app-bundle-id is mandatory and must not be empty") { $0.appBundleId?.isEmpty == false }
        .filter("adapter must be an absolute executable path") { $0.adapter.val.first?.hasPrefix("/") == true }
}
