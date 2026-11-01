import AppKit

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

struct HideSpot: Equatable {
    let corner: OptimalHideCorner
    /// Index of the monitor whose corner the windows are parked in
    let monitorIndex: Int
}

/// Where to park the windows of each monitor's invisible workspaces, given every monitor's rect.
///
/// A corner is clean when no other monitor touches the area next to it. When both bottom corners of a monitor touch
/// a neighbour, as for the middle of three side-by-side monitors, macOS and some apps (e.g. Activity Monitor) pull a
/// parked window onto the neighbour so its title bar is visible, AeroSpace parks it again, and the window flickers
/// there. Such a monitor borrows the nearest clean corner of another monitor instead.
func hideSpots(_ monitorRects: [Rect]) -> [HideSpot] {
    func score(_ rect: Rect, _ corner: OptimalHideCorner) -> Int {
        let xOff = rect.width * 0.1
        let yOff = rect.height * 0.1
        let points: [CGPoint] = switch corner {
            case .bottomRightCorner: [
                    rect.bottomRightCorner + CGPoint(x: 2, y: -yOff),
                    rect.bottomRightCorner + CGPoint(x: -xOff, y: 2),
                    rect.bottomRightCorner + CGPoint(x: 2, y: 2),
                ]
            case .bottomLeftCorner: [
                    rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff),
                    rect.bottomLeftCorner + CGPoint(x: xOff, y: 2),
                    rect.bottomLeftCorner + CGPoint(x: -2, y: 2),
                ]
        }
        let important = 10
        let weights = [1, 1, important]
        return zip(points, weights).lazy.map { point, weight in
            monitorRects.count(where: { $0.contains(point) }) * weight
        }.reduce(0, +)
    }
    func cornerPoint(_ rect: Rect, _ corner: OptimalHideCorner) -> CGPoint {
        corner == .bottomLeftCorner ? rect.bottomLeftCorner : rect.bottomRightCorner
    }
    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    let own: [(corner: OptimalHideCorner, score: Int)] = monitorRects.map { rect in
        let left = score(rect, .bottomLeftCorner)
        let right = score(rect, .bottomRightCorner)
        return left < right ? (.bottomLeftCorner, left) : (.bottomRightCorner, right)
    }
    return monitorRects.indices.map { i in
        if own[i].score == 0 { return HideSpot(corner: own[i].corner, monitorIndex: i) }
        let from = cornerPoint(monitorRects[i], own[i].corner)
        let nearestClean = monitorRects.indices
            .filter { $0 != i && own[$0].score == 0 }
            .min { a, b in
                distance(from, cornerPoint(monitorRects[a], own[a].corner)) < distance(from, cornerPoint(monitorRects[b], own[b].corner))
            }
        guard let nearestClean else { return HideSpot(corner: own[i].corner, monitorIndex: i) }
        return HideSpot(corner: own[nearestClean].corner, monitorIndex: nearestClean)
    }
}
