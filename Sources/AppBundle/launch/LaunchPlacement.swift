import Common
import Foundation

/// PID alone does not identify a process after a relaunch/PID reuse.
struct LaunchProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    // Keep this explicit: process identity includes launch time, not only PID.
    // swiftformat:disable:next redundantEquatable
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.startSeconds == rhs.startSeconds && lhs.startMicroseconds == rhs.startMicroseconds
    }
}

struct LaunchWindowBaseline {
    let process: LaunchProcessIdentity?
    let windowIds: Set<OpaqueWindowId>
}

struct LaunchWindowObservation {
    let process: LaunchProcessIdentity
    let windowId: OpaqueWindowId
    let windowType: AxUiElementWindowType
    let isAliveAndComplete: Bool
    let nativeMappingIsStable: Bool
    let isHidden: Bool
    let isMinimized: Bool?
    let isFullscreen: Bool?
    let isRegistered: Bool
    let restoresClosedWindow: Bool

    var isEligible: Bool {
        windowType == .window && isAliveAndComplete && nativeMappingIsStable &&
            !isHidden && isMinimized == false && isFullscreen == false &&
            !isRegistered && !restoresClosedWindow
    }
}

/// Value-only matching state; the injected bridges own AX, processes and the clock.
/// No workspace/monitor objects, focus changes or alternate window identities live here.
@MainActor
final class LaunchPlacement {
    struct Dependencies {
        var now: @MainActor () -> ContinuousClock.Instant
        var sleep: @MainActor (Duration) async throws -> Void
        var runningProcesses: @MainActor (String) throws -> [LaunchProcessIdentity]
        var baseline: @MainActor (String) async throws -> LaunchWindowBaseline
        var startAdapter: @MainActor ([String], [String: String], @escaping @MainActor (Bool) -> Void) throws -> (@MainActor () -> Void)
        var log: @MainActor (String) -> Void
    }

    private final class Request {
        let token = UUID()
        let bundleId: String
        let workspaceName: String
        let deadline: ContinuousClock.Instant
        var baseline: Set<OpaqueWindowId>?
        var process: LaunchProcessIdentity?
        var placed = false
        var adapterSucceeded = false
        var adapterStarted = false
        var adapterExited = false
        var draining = false
        var worker: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var cancelAdapter: (@MainActor () -> Void)?

        init(bundleId: String, workspaceName: String, deadline: ContinuousClock.Instant) {
            self.bundleId = bundleId
            self.workspaceName = workspaceName
            self.deadline = deadline
        }
    }

    private let dependencies: Dependencies
    private var requests: [String: Request] = [:]

    init(_ dependencies: Dependencies) { self.dependencies = dependencies }

    var pendingCount: Int { requests.count }

    func accept(bundleId: String, workspaceName: String, timeout: Double, adapter: [String], environment: [String: String]) -> ResOrStr<UUID> {
        if let previous = requests[bundleId] {
            _ = validate(previous)
            if requests[bundleId] != nil { return .failure("launch-window: target app is busy") }
        }
        let request = Request(bundleId: bundleId, workspaceName: workspaceName, deadline: dependencies.now().advanced(by: .seconds(timeout)))
        requests[bundleId] = request
        request.worker = Task.startUnstructured { @MainActor [self] in
            do {
                guard current(bundleId, request.token) != nil, !Task.isCancelled else { return }
                let baseline = try await dependencies.baseline(bundleId)
                guard current(bundleId, request.token) != nil, validate(request) else { return }
                // The complete baseline and process must still describe the world just before spawn.
                let processes = try dependencies.runningProcesses(bundleId)
                guard processes.count <= 1, processes.first == baseline.process else {
                    finish(request, "failed-process-changed-before-launch")
                    return
                }
                request.baseline = baseline.windowIds
                request.process = baseline.process
                log(request, "armed")
                request.adapterStarted = true
                let token = request.token // Do not retain Request through Process -> completion.
                let cancel: @MainActor () -> Void
                do {
                    cancel = try dependencies.startAdapter(adapter, environment) { [weak self] succeeded in
                        self?.adapterFinished(bundleId: bundleId, token: token, succeeded: succeeded)
                    }
                } catch {
                    request.adapterStarted = false
                    throw error
                }
                // A synchronous injected completion (or cancellation) must not attach to a newer request.
                guard current(bundleId, request.token) != nil else { cancel(); return }
                request.cancelAdapter = cancel
            } catch {
                if current(bundleId, request.token) != nil { finish(request, "failed-baseline-or-adapter-spawn") }
            }
        }
        request.watchdog = Task.startUnstructured { @MainActor [self] in
            do {
                while current(bundleId, request.token) != nil {
                    try await dependencies.sleep(.milliseconds(100))
                    if Task.isCancelled { return }
                    if !validate(request) { return }
                }
            } catch {
                // Cancellation is owned by finish/cancelAll, not a second completion.
            }
        }
        return .success(request.token)
    }

    /// Capture before AX reads. A request armed later cannot claim an older observation.
    func candidateToken(bundleId: String) -> UUID? {
        guard let request = requests[bundleId], validate(request), request.baseline != nil, !request.placed else { return nil }
        return request.token
    }

    /// Call only in the synchronous section that immediately inserts the new logical window.
    func claim(bundleId: String, token: UUID?, observation: LaunchWindowObservation) -> String? {
        guard let token, let request = current(bundleId, token), validate(request),
              let baseline = request.baseline, !request.placed, observation.isEligible,
              !baseline.contains(observation.windowId), request.process == observation.process else { return nil }
        request.placed = true
        let name = request.workspaceName
        log(request, "placed")
        completeIfReady(request)
        return name
    }

    func cancelAll(reason: String) {
        for request in Array(requests.values) { finish(request, "cancelled-\(reason)") }
    }

    func processTerminated(_ identity: LaunchProcessIdentity) {
        for request in Array(requests.values) where request.process == identity {
            finish(request, "failed-target-terminated")
        }
    }

    private func current(_ bundleId: String, _ token: UUID) -> Request? {
        requests[bundleId].flatMap { $0.token == token ? $0 : nil }
    }

    private func validate(_ request: Request) -> Bool {
        guard current(request.bundleId, request.token) != nil, !request.draining else { return false }
        guard dependencies.now() < request.deadline else {
            finish(request, "failed-timeout")
            return false
        }
        if request.baseline != nil {
            do {
                let processes = try dependencies.runningProcesses(request.bundleId)
                guard processes.count <= 1 else { finish(request, "failed-ambiguous-process"); return false }
                if let expected = request.process {
                    guard processes.first == expected else { finish(request, "failed-target-replaced-or-terminated"); return false }
                } else if let process = processes.first {
                    request.process = process // Cold launch: pin the first observed process incarnation.
                }
            } catch {
                finish(request, "failed-process-identity")
                return false
            }
        }
        return true
    }

    private func adapterFinished(bundleId: String, token: UUID, succeeded: Bool) {
        guard let request = current(bundleId, token) else { return }
        request.adapterExited = true
        request.cancelAdapter = nil
        if request.draining {
            requests[bundleId] = nil
            log(request, "drained")
            return
        }
        guard validate(request) else { return }
        guard succeeded else { finish(request, "failed-adapter-exit"); return }
        request.adapterSucceeded = true
        completeIfReady(request)
    }

    private func completeIfReady(_ request: Request) {
        if request.placed && request.adapterSucceeded { finish(request, "succeeded") }
    }

    private func log(_ request: Request, _ status: String) {
        dependencies.log("launch-window \(request.token.uuidString) \(status)")
    }

    private func finish(_ request: Request, _ status: String) {
        guard current(request.bundleId, request.token) != nil, !request.draining else { return }
        // Never let an adapter that is still executing overlap a new same-app operation.
        // Its exit callback drains this token even after the placement deadline has passed.
        request.draining = request.adapterStarted && !request.adapterExited
        if !request.draining { requests[request.bundleId] = nil }
        request.worker?.cancel()
        request.watchdog?.cancel()
        request.worker = nil
        request.watchdog = nil
        let cancelAdapter = request.cancelAdapter
        if !request.draining { request.cancelAdapter = nil }
        if request.draining { cancelAdapter?() }
        log(request, status)
    }
}
