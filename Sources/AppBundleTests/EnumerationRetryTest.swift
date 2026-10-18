@testable import AppBundle
import XCTest

// Upstream PR #2326: retry the refresh when an app didn't answer the window enumeration in time
final class EnumerationRetryTest: XCTestCase {
    func testBackoffDoublesAndCapsAtThirtySeconds() {
        assertEquals((0 ..< 8).map { enumerationRetryDelaySeconds(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testEmptyRefreshResultIsComplete() {
        assertFalse(MacAppRefreshResult.empty.incomplete)
    }
}
