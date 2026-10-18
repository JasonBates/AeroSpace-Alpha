import AppKit
import Common

/// Covers the on-screen sliver of windows parked in a hide corner so macOS reports them as occluded.
///
/// AeroSpace parks the windows of invisible workspaces one point inside a bottom corner of a monitor, and macOS
/// keeps a window's title bar on screen, so each parked window shows a one-point column as tall as its title bar.
/// That column keeps the window's NSWindow.occlusionState at .visible, and apps that throttle on occlusion
/// (browsers, Electron, games) keep rendering their hidden windows at full rate. An opaque, click-through panel
/// over the corner makes every parked window fully covered, so the apps throttle themselves.
/// https://github.com/nikitabobko/AeroSpace/discussions/2323
@MainActor
final class HideCornerCovers {
    static let shared = HideCornerCovers()

    private var panels: [HideCornerCoverSpot: HideCornerCoverPanel] = [:]

    /// `spots` are the corners that currently have windows parked in them. Covers elsewhere are removed.
    func sync(_ spots: [HideCornerCoverSpot: Rect]) {
        guard !isUnitTest else { return }
        for (spot, panel) in panels where spots[spot] == nil {
            panel.orderOut(nil)
            panels[spot] = nil
        }
        for (spot, rect) in spots {
            let panel = panels[spot] ?? HideCornerCoverPanel()
            panels[spot] = panel
            let frame = NSRect(x: rect.minX, y: mainMonitorInfo.height - rect.maxY, width: rect.width, height: rect.height)
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    func hideAll() {
        sync([:])
    }
}

struct HideCornerCoverSpot: Hashable {
    // The properties only feed the synthesized Hashable and Equatable
    // periphery:ignore
    let monitorTopLeft: CGPoint
    // periphery:ignore
    let corner: OptimalHideCorner
}

/// Tall enough for the title bar of any parked window (Telegram's is 66 points, most are about 30)
let hideCornerCoverHeight: CGFloat = 160

/// Where a cover goes: a one-point-wide strip along the monitor edge at the parking corner, in AeroSpace's
/// top-left-origin coordinates, as high as hideCornerCoverHeight allows inside the visible rect.
func hideCornerCoverRect(visibleRect: Rect, corner: OptimalHideCorner) -> Rect {
    let width: CGFloat = 1
    let height = min(visibleRect.height, hideCornerCoverHeight)
    let x = switch corner {
        case .bottomLeftCorner: visibleRect.minX
        case .bottomRightCorner: visibleRect.maxX - width
    }
    return Rect(topLeftX: x, topLeftY: visibleRect.maxY - height, width: width, height: height)
}

@MainActor
private final class HideCornerCoverPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        // Above the parked windows, which sit at the normal level
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        hasShadow = false
        // Opaque is the point: only a fully covered window reports itself as occluded
        isOpaque = true
        backgroundColor = .black
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
