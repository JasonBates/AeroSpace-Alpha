import AppKit
import Common
import os

private let launchWindowLogger = Logger(subsystem: aeroSpaceAppId, category: "launch-window")

@MainActor
let launchPlacement = makeLaunchPlacement()

@MainActor
private func makeLaunchPlacement() -> LaunchPlacement {
    LaunchPlacement(.init(
        now: { ContinuousClock.now },
        sleep: { try await Task.sleep(for: $0) },
        runningProcesses: launchWindowRunningProcesses,
        baseline: { try await MacApp.launchWindowBaseline(bundleId: $0) },
        startAdapter: { argv, environment, completion in
            let process = Process()
            process.executableURL = URL(filePath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                process.terminationHandler = nil
                Task.startUnstructured { @MainActor in completion(succeeded) }
            }
            try process.run()
            return { if process.isRunning { process.terminate() } }
        },
        log: { message in
            // The component emits generated tokens and fixed lifecycle statuses only.
            launchWindowLogger.notice("\(message, privacy: .public)")
            eprint(message)
        },
    ))
}

func launchWindowProcessIdentity(_ app: NSRunningApplication) -> LaunchProcessIdentity? {
    app.launchDate.map { LaunchProcessIdentity(pid: app.processIdentifier, launchedAt: $0) }
}

@MainActor
func launchWindowRunningProcesses(_ bundleId: String) throws -> [LaunchProcessIdentity] {
    try NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { !$0.isTerminated }
        .map { app in
            guard let identity = launchWindowProcessIdentity(app) else { throw LaunchWindowBaselineError.unavailable }
            return identity
        }
}

enum LaunchWindowBaselineError: Error {
    case unavailable
}

/// A successful AX array is not sufficient: mouse dragging/subscription failure can
/// defer upstream registration of an already existing native window.
func launchWindowEnumerationIsComplete(attributeSucceeded: Bool, enumerated: Set<UInt32>?, tracked: Set<UInt32>) -> Bool {
    attributeSucceeded && enumerated.map { $0.isSubset(of: tracked) } == true
}

func launchWindowDecodedEnumerationIsComplete(rawCount: Int?, decodedCount: Int) -> Bool {
    rawCount == decodedCount
}

extension Ax {
    /// Upstream's normal AXWindows decoder intentionally compactMaps non-window objects.
    /// A strict baseline rejects any such omission, including an unreadable native ID.
    static let launchBaselineWindowsAttr = ReadableAttrImpl<[WindowIdAndAxUiElement]>(
        key: windowsAttr.key,
        getter: { raw in
            guard let decoded = windowsAttr.getter(raw),
                  launchWindowDecodedEnumerationIsComplete(rawCount: (raw as? NSArray)?.count, decodedCount: decoded.count) else { return nil }
            return decoded
        },
    )
}
