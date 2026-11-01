import AppKit
import Common
import Darwin
import os
import PrivateApi

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

func launchWindowProcessIdentity(
    _ app: NSRunningApplication,
    processInfo: (Int32) -> (info: proc_bsdinfo, byteCount: Int32) = launchWindowProcessInfo,
) -> LaunchProcessIdentity? {
    launchWindowProcessIdentity(pid: app.processIdentifier, isTerminated: { app.isTerminated }, processInfo: processInfo)
}

private func launchWindowProcessInfo(_ pid: Int32) -> (info: proc_bsdinfo, byteCount: Int32) {
    var info = proc_bsdinfo()
    let byteCount = unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return (info, byteCount)
}

/// LaunchServices can omit launchDate. Always use the same kernel incarnation,
/// including when observing an app that later acquires a LaunchServices date.
func launchWindowProcessIdentity(
    pid: Int32,
    isTerminated: () -> Bool,
    processInfo: (Int32) -> (info: proc_bsdinfo, byteCount: Int32),
) -> LaunchProcessIdentity? {
    guard pid > 0, !isTerminated() else { return nil }
    let (info, byteCount) = processInfo(pid)
    guard byteCount == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_pid == UInt32(pid),
          info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000, !isTerminated() else { return nil }
    return LaunchProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
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

/// Account for every entry: retain native IDs, exclude only a proven non-window,
/// and fail the entire inventory for anything whose identity is unavailable.
func launchWindowDecodeEnumeration<Element>(
    _ raw: AnyObject,
    element: (Any) -> Element?,
    nativeWindow: (Element) -> (id: UInt32, error: AXError),
    role: (Element) -> (value: String?, error: AXError),
) -> [(windowId: UInt32, ax: Element)]? {
    guard let entries = raw as? NSArray else { return nil }
    var result: [(windowId: UInt32, ax: Element)] = []
    for entry in entries {
        guard let ax = element(entry) else { return nil }
        let native = nativeWindow(ax)
        if native.error == .success, native.id != 0 {
            result.append((native.id, ax))
        } else {
            guard native.error == .illegalArgument, native.id == 0 else { return nil }
            let role = role(ax)
            guard role.error == .success, role.value == kAXScrollAreaRole else { return nil }
        }
    }
    return result
}

extension Ax {
    /// Upstream's normal AXWindows decoder intentionally compactMaps non-window objects.
    /// The strict baseline accounts for each entry and rejects unreadable native IDs.
    static let launchBaselineWindowsAttr = ReadableAttrImpl<[WindowIdAndAxUiElement]>(
        key: windowsAttr.key,
        getter: { raw in
            launchWindowDecodeEnumeration(
                raw,
                element: { value in
                    let object = value as AnyObject
                    guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
                    return (object as! AXUIElement)
                },
                nativeWindow: { ax in
                    var id: UInt32 = 0
                    let error = unsafe _AXUIElementGetWindow(ax, &id)
                    return (id, error)
                },
                role: { $0.getOrError(Ax.roleAttr) },
            )
        },
    )
}
