@testable import AppBundle
import XCTest

final class HideSpotsTest: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 2560, _ height: CGFloat = 1440) -> Rect {
        Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }

    func testHideCornerCoverIsAOnePointStripAlongTheParkingEdge() {
        let visible = rect(2560, 25, 2560, 1400)
        assertEquals(hideCornerCoverRect(visibleRect: visible, corner: .bottomRightCorner), rect(5119, 1265, 1, 160))
        assertEquals(hideCornerCoverRect(visibleRect: visible, corner: .bottomLeftCorner), rect(2560, 1265, 1, 160))
        let short = rect(0, 0, 800, 100)
        assertEquals(hideCornerCoverRect(visibleRect: short, corner: .bottomRightCorner), rect(799, 0, 1, 100))
    }

    func testSingleMonitorUsesItsOwnCorner() {
        assertEquals(hideSpots([rect(0, 0)]), [HideSpot(corner: .bottomRightCorner, monitorIndex: 0)])
    }

    func testMiddleOfThreeBorrowsNearestCleanOuterCorner() {
        // Side monitors raised by 50 points: their bottoms are above the middle's bottom, but they still touch
        // the area next to both of the middle monitor's bottom corners
        let middle = rect(0, 0)
        let right = rect(2560, -50)
        let left = rect(-2560, -50)
        assertEquals(hideSpots([middle, right, left]), [
            HideSpot(corner: .bottomRightCorner, monitorIndex: 1),
            HideSpot(corner: .bottomRightCorner, monitorIndex: 1),
            HideSpot(corner: .bottomLeftCorner, monitorIndex: 2),
        ])
    }

    func testMonitorWithOneCleanCornerKeepsIt() {
        let laptop = rect(0, 0, 1512, 982)
        let external = rect(1512, -400)
        assertEquals(hideSpots([laptop, external]), [
            HideSpot(corner: .bottomLeftCorner, monitorIndex: 0),
            HideSpot(corner: .bottomRightCorner, monitorIndex: 1),
        ])
    }
}
