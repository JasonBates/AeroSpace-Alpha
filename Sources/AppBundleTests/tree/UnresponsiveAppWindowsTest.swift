@testable import AppBundle
import AppKit
import XCTest

// https://github.com/nikitabobko/AeroSpace/issues/1216 (upstream PR #2317), combined with the native-tab
// retirement from upstream PR #2225
final class UnresponsiveAppWindowsTest: XCTestCase {
    func testRespondingWindowIsAlive() {
        var isAppUnresponsive = false
        XCTAssertTrue(isAlive(.success, onScreen: false, &isAppUnresponsive))
        XCTAssertFalse(isAppUnresponsive)
    }

    func testClosedWindowIsDead() {
        var isAppUnresponsive = false
        XCTAssertFalse(isAlive(.invalidUIElement, onScreen: true, &isAppUnresponsive))
        XCTAssertFalse(isAlive(.failure, onScreen: true, &isAppUnresponsive))
        XCTAssertFalse(isAppUnresponsive)
    }

    func testTimedOutWindowThatIsStillOnScreenIsKept() {
        var isAppUnresponsive = false
        XCTAssertTrue(isAlive(.cannotComplete, onScreen: true, &isAppUnresponsive))
        XCTAssertTrue(isAppUnresponsive)
    }

    func testTimedOutWindowThatIsOffScreenIsDead() {
        var isAppUnresponsive = false
        XCTAssertFalse(isAlive(.cannotComplete, onScreen: false, &isAppUnresponsive))
        XCTAssertTrue(isAppUnresponsive)
    }

    func testNoMoreAxRequestsOnceTheAppTimedOut() {
        var isAppUnresponsive = true
        var axRequests = 0
        let alive = isTrackedWindowAlive(
            isRetiredNativeTab: false,
            isAppUnresponsive: &isAppUnresponsive,
            containingWindowIdError: { axRequests += 1; return .success },
            isWindowOnScreen: { true },
        )
        XCTAssertTrue(alive)
        assertEquals(axRequests, 0)
    }

    func testRetiredNativeTabIsDeadEvenIfTheAppTimedOut() {
        for isAppUnresponsiveBefore in [false, true] {
            var isAppUnresponsive = isAppUnresponsiveBefore
            var axRequests = 0
            let alive = isTrackedWindowAlive(
                isRetiredNativeTab: true,
                isAppUnresponsive: &isAppUnresponsive,
                containingWindowIdError: { axRequests += 1; return .cannotComplete },
                isWindowOnScreen: { true },
            )
            XCTAssertFalse(alive)
            assertEquals(axRequests, 0)
            assertEquals(isAppUnresponsive, isAppUnresponsiveBefore)
        }
    }
}

private func isAlive(_ error: AXError, onScreen: Bool, _ isAppUnresponsive: inout Bool) -> Bool {
    isTrackedWindowAlive(
        isRetiredNativeTab: false,
        isAppUnresponsive: &isAppUnresponsive,
        containingWindowIdError: { error },
        isWindowOnScreen: { onScreen },
    )
}
