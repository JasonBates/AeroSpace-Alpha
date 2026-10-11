@testable import AppBundle
import AppKit
import XCTest

// https://github.com/nikitabobko/AeroSpace/issues/1216 (upstream PR #2317), combined with the native-tab
// retirement from upstream PR #2225
final class UnresponsiveAppWindowsTest: XCTestCase {
    func testRespondingWindowIsAlive() {
        var isAppUnresponsive = false
        XCTAssertTrue(isAlive(.success, windowStillExists: false, &isAppUnresponsive))
        XCTAssertFalse(isAppUnresponsive)
    }

    func testClosedWindowIsDead() {
        var isAppUnresponsive = false
        XCTAssertFalse(isAlive(.invalidUIElement, windowStillExists: true, &isAppUnresponsive))
        XCTAssertFalse(isAlive(.failure, windowStillExists: true, &isAppUnresponsive))
        XCTAssertFalse(isAppUnresponsive)
    }

    func testTimedOutWindowThatStillExistsIsKeptEvenWhenOffScreen() {
        var isAppUnresponsive = false
        XCTAssertTrue(isAlive(.cannotComplete, windowStillExists: true, &isAppUnresponsive))
        XCTAssertTrue(isAppUnresponsive)
    }

    func testTimedOutWindowAbsentFromWindowServerIsDead() {
        var isAppUnresponsive = false
        XCTAssertFalse(isAlive(.cannotComplete, windowStillExists: false, &isAppUnresponsive))
        XCTAssertTrue(isAppUnresponsive)
    }

    func testNoMoreAxRequestsOnceTheAppTimedOut() {
        var isAppUnresponsive = true
        var axRequests = 0
        let alive = isTrackedWindowAlive(
            isRetiredNativeTab: false,
            isAppUnresponsive: &isAppUnresponsive,
            containingWindowIdError: { axRequests += 1; return .success },
            windowStillExists: { true },
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
                windowStillExists: { true },
            )
            XCTAssertFalse(alive)
            assertEquals(axRequests, 0)
            assertEquals(isAppUnresponsive, isAppUnresponsiveBefore)
        }
    }
}

private func isAlive(_ error: AXError, windowStillExists: Bool, _ isAppUnresponsive: inout Bool) -> Bool {
    isTrackedWindowAlive(
        isRetiredNativeTab: false,
        isAppUnresponsive: &isAppUnresponsive,
        containingWindowIdError: { error },
        windowStillExists: { windowStillExists },
    )
}
