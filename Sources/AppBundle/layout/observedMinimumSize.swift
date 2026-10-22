import AppKit
import Common

/// The smallest frame a window has been seen to accept. macOS gives no Accessibility attribute for
/// an app's minimum window size, so AeroSpace learns it: after writing a frame it reads the size
/// back, and a window that stays larger than requested has shown its minimum. Tiling floors then
/// keep the window's tile at least that large, so the window no longer spills over its neighbours.
///
/// A minimum is replaced, not maximised, by each refusal, because an app reports its current
/// minimum when asked for less (a browser's minimum grows when a sidebar opens and shrinks when
/// it closes). It is forgotten when the window accepts a size below it, and by `balance-sizes`.
struct ObservedMinimumSize: Equatable, Sendable {
    var width: CGFloat? = nil
    var height: CGFloat? = nil

    func updated(requested: CGSize, observed: CGSize) -> ObservedMinimumSize {
        ObservedMinimumSize(
            width: observedMinimum(current: width, requested: requested.width, observed: observed.width),
            height: observedMinimum(current: height, requested: requested.height, observed: observed.height),
        )
    }
}

/// Sub-point differences are rounding by the app or the window server, not a refusal.
private let observedMinimumTolerance: CGFloat = 1

/// Long enough for an app that applies frames asynchronously to have settled.
private let observedMinimumConfirmationDelay: Duration = .milliseconds(150)

private func observedMinimum(current: CGFloat?, requested: CGFloat, observed: CGFloat) -> CGFloat? {
    if observed > requested + observedMinimumTolerance {
        // Keep the known value when the refusal only repeats it, so rounding noise cannot relayout forever
        if let current, abs(observed - current) <= observedMinimumTolerance { return current }
        return observed
    }
    if let current, requested < current - observedMinimumTolerance { return nil }
    return current
}

extension Window {
    func tiledMinimumWidth(floor: CGFloat) -> CGFloat { max(floor, observedMinimumSize.width ?? 0) }
    func tiledMinimumHeight(floor: CGFloat) -> CGFloat { max(floor, observedMinimumSize.height ?? 0) }

    /// Called when the size read back after a frame write would change `observedMinimumSize`. The app
    /// may still be applying the frame, so the size is read again once it has settled, and only kept
    /// if AeroSpace hasn't laid the window out differently in the meantime.
    @MainActor
    func confirmObservedMinimumSize(requested: CGSize) async throws {
        if !isUnitTest { try await Task.sleep(for: observedMinimumConfirmationDelay) }
        guard lastAppliedLayoutPhysicalRect?.size == requested,
              let observed = try await getAxSize(.cancellable) else { return }
        let updated = observedMinimumSize.updated(requested: requested, observed: observed)
        guard updated != observedMinimumSize else { return }
        observedMinimumSize = updated
        // A mouse resize reads the new floor on its next event and relayouts when the button is released
        if !isUnitTest && currentlyManipulatedWithMouseWindowId == nil {
            scheduleCancellableCompleteRefreshSession(.observedMinimumSizeChanged)
        }
    }
}
