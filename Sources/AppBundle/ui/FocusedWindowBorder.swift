import AppKit
import Common
import SwiftUI

/// A transparent, click-through overlay panel that draws a coloured border around the focused window.
/// A native replacement for JankyBorders for the common "highlight the focused window" case.
/// Upstream PR #2107, reworked here for speed: the frame comes from the WindowServer rather than an
/// Accessibility round trip to the app, the border is redrawn the moment AeroSpace's focus changes
/// rather than after the next layout pass, and it follows the pointer at 60 Hz while a mouse button is
/// held, so a dragged or resized window keeps its border.
@MainActor
final class FocusedWindowBorder {
    static let shared = FocusedWindowBorder()

    private var panel: FocusedWindowBorderPanel?
    private var trackingTimer: Timer?

    /// Redraw for the current focus and config. Cheap: one WindowServer query, no AX.
    func refresh() {
        guard !isUnitTest else { return }
        guard config.focusedWindowBorder,
              let window = globalFocus.windowOrNil,
              window.visualWorkspace?.isVisible == true,
              isBorderable(window),
              let rect = windowServerFrame(windowId: window.windowId),
              rect.width > 0, rect.height > 0,
              !isAwaitingPlacement(window, at: rect)
        else {
            hide()
            return
        }
        let panel = panel ?? FocusedWindowBorderPanel()
        self.panel = panel
        panel.show(
            around: rect,
            style: FocusedWindowBorderStyle(
                colorHex: config.focusedWindowBorderColor,
                width: config.focusedWindowBorderWidth,
                opacityPercent: config.focusedWindowBorderOpacity,
                cornerRadius: config.borderCornerRadius(appId: window.app.rawAppBundleId),
                inset: config.focusedWindowBorderInset,
            ),
        )
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// While a mouse button is held the focused window may be dragged or resized by the user. AX moved
    /// notifications arrive a few times a second, so the border follows the WindowServer frame instead.
    func startTracking() {
        guard !isUnitTest, config.focusedWindowBorder, trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            Task.startUnstructured { @MainActor in FocusedWindowBorder.shared.refresh() }
        }
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        refresh()
    }

    /// A new window is focused before the layout pass moves it into its tile, so it still sits wherever the
    /// app opened it (often the main screen's bottom-left). Skip it until its top-left reaches the tile; the
    /// AX moved notification from that move redraws the border in the right place.
    private func isAwaitingPlacement(_ window: Window, at rect: Rect) -> Bool {
        if window.isAwaitingOnWindowDetected { return true }
        guard case .tilingContainer = window.windowParentCases,
              window.windowId != currentlyManipulatedWithMouseWindowId // Follows the pointer while dragged
        else { return false }
        // No tile yet: the window joined the tree but hasn't been laid out. Fullscreen windows have none either
        guard let target = window.lastAppliedLayoutPhysicalRect else { return !window.isFullscreen }
        let tolerance: CGFloat = 8
        return abs(rect.topLeftX - target.topLeftX) > tolerance || abs(rect.topLeftY - target.topLeftY) > tolerance
    }

    private func isBorderable(_ window: Window) -> Bool {
        switch window.windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: true
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer, nil: false
        }
    }
}

/// The window's frame as the WindowServer has it, in AeroSpace's top-left-origin coordinates
private func windowServerFrame(windowId: UInt32) -> Rect? {
    guard let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowId)) as? [[String: Any]],
          let info = infos.first,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
          let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
    else { return nil }
    return Rect(topLeftX: x, topLeftY: y, width: width, height: height)
}

struct FocusedWindowBorderStyle: Equatable {
    let colorHex: String
    let width: Int
    let opacityPercent: Int
    let cornerRadius: Int
    let inset: Int
}

final class FocusedWindowBorderPanel: NSPanel {
    private var hosting: NSHostingView<FocusedWindowBorderView>?
    private var appliedStyle: FocusedWindowBorderStyle?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @MainActor func show(around rect: Rect, style: FocusedWindowBorderStyle) {
        let w = CGFloat(style.width)
        // `inset` pulls the stroke that many points back into the window. With inset 0 the stroke sits
        // fully outside. With inset > 0 the border overlaps the window's own rounded corner, so the real
        // corner masks any mismatch between the configured radius and the window's true radius.
        let inset = CGFloat(min(max(style.inset, 0), style.width))
        let grow = w - inset // net expansion beyond the window edge on every side
        let frame = NSRect(
            x: rect.topLeftX - grow,
            y: mainMonitorInfo.height - rect.topLeftY - rect.height - grow,
            width: rect.width + 2 * grow,
            height: rect.height + 2 * grow,
        )
        if appliedStyle != style || hosting == nil {
            let baseColor = NSColor(argbHex: style.colorHex) ?? .systemGreen
            let opacityFactor = CGFloat(min(max(style.opacityPercent, 0), 100)) / 100
            let finalColor = baseColor.withAlphaComponent(baseColor.alphaComponent * opacityFactor)
            // Outer radius = the window's corner radius plus how far the stroke's outer edge sits
            // outside the window edge, so the outer edge stays concentric with the window corner.
            let view = FocusedWindowBorderView(
                color: Color(nsColor: finalColor),
                width: w,
                cornerRadius: CGFloat(style.cornerRadius) + grow,
            )
            if let hosting {
                hosting.rootView = view
            } else {
                let hostingView = NSHostingView(rootView: view)
                hostingView.autoresizingMask = [.width, .height]
                contentView?.addSubview(hostingView)
                hosting = hostingView
            }
            appliedStyle = style
        }
        if self.frame != frame {
            setFrame(frame, display: true)
            hosting?.frame = NSRect(origin: .zero, size: frame.size)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }
}

struct FocusedWindowBorderView: View {
    let color: Color
    let width: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: width)
    }
}

extension NSColor {
    /// Parse an `0xAARRGGBB` (or `0xRRGGBB`) hex string, matching the format used by JankyBorders (e.g. `0xff12B981`).
    convenience init?(argbHex: String) {
        var str = argbHex.trimmingCharacters(in: .whitespaces).lowercased()
        if str.hasPrefix("0x") { str.removeFirst(2) }
        if str.hasPrefix("#") { str.removeFirst() }
        guard let value = UInt64(str, radix: 16) else { return nil }
        let a: CGFloat
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        switch str.count {
            case 8: // AARRGGBB
                a = CGFloat((value >> 24) & 0xFF) / 255
                r = CGFloat((value >> 16) & 0xFF) / 255
                g = CGFloat((value >> 8) & 0xFF) / 255
                b = CGFloat(value & 0xFF) / 255
            case 6: // RRGGBB
                a = 1
                r = CGFloat((value >> 16) & 0xFF) / 255
                g = CGFloat((value >> 8) & 0xFF) / 255
                b = CGFloat(value & 0xFF) / 255
            default:
                return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
