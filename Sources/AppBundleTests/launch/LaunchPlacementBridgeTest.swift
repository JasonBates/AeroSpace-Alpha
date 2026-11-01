@testable import AppBundle
import AppKit
import Darwin
import XCTest

private final class LaunchRunningApplicationStub: NSRunningApplication, @unchecked Sendable {
    private let reportedLaunchDate: Date?
    override var processIdentifier: pid_t { 42 }
    override var isTerminated: Bool { false }
    override var launchDate: Date? { reportedLaunchDate }

    init(launchDate: Date?) {
        self.reportedLaunchDate = launchDate
        super.init()
    }
}

private struct LaunchAxEntry {
    var nativeId: UInt32 = 0
    var nativeError: AXError = .illegalArgument
    var role: String? = kAXScrollAreaRole
    var roleError: AXError = .success
}

@MainActor
final class LaunchPlacementBridgeTest: XCTestCase {
    private func processInfo(pid: UInt32 = 42, seconds: UInt64 = 100, microseconds: UInt64 = 123) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_pid = pid
        info.pbi_start_tvsec = seconds
        info.pbi_start_tvusec = microseconds
        return info
    }

    func testKernelIdentityWorksWithoutLaunchDateAndDoesNotChangeWhenDateAppears() {
        let info = processInfo()
        let expected = LaunchProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 123)
        for date in [nil, Date(timeIntervalSince1970: 999)] {
            let app = LaunchRunningApplicationStub(launchDate: date)
            XCTAssertEqual(launchWindowProcessIdentity(app, processInfo: { pid in
                XCTAssertEqual(pid, 42)
                return (info, Int32(MemoryLayout<proc_bsdinfo>.size))
            }), expected)
        }
    }

    func testKernelIdentityRejectsUnavailableShortMismatchedAndInvalidSamples() {
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        for byteCount in [-1, 0, expectedSize - 1, expectedSize + 1] {
            XCTAssertNil(launchWindowProcessIdentity(pid: 42, isTerminated: { false }, processInfo: { _ in (self.processInfo(), byteCount) }))
        }
        for info in [processInfo(pid: 43), processInfo(seconds: 0), processInfo(microseconds: 1_000_000), processInfo(microseconds: .max)] {
            XCTAssertNil(launchWindowProcessIdentity(pid: 42, isTerminated: { false }, processInfo: { _ in (info, expectedSize) }))
        }
        for pid: Int32 in [-1, 0] {
            XCTAssertNil(launchWindowProcessIdentity(pid: pid, isTerminated: { false }, processInfo: { _ in
                XCTFail("Invalid PID must not be queried")
                return (self.processInfo(), expectedSize)
            }))
        }
    }

    func testKernelIdentityRejectsTerminationBeforeOrDuringLookup() {
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertNil(launchWindowProcessIdentity(pid: 42, isTerminated: { true }, processInfo: { _ in
            XCTFail("Terminated app must not be queried")
            return (self.processInfo(), expectedSize)
        }))
        var terminated = false
        XCTAssertNil(launchWindowProcessIdentity(pid: 42, isTerminated: { terminated }, processInfo: { _ in
            terminated = true
            return (self.processInfo(), expectedSize)
        }))
    }

    private func decode(_ entries: [LaunchAxEntry]) -> [(windowId: UInt32, ax: LaunchAxEntry)]? {
        launchWindowDecodeEnumeration(
            entries as NSArray,
            element: { $0 as? LaunchAxEntry },
            nativeWindow: { ($0.nativeId, $0.nativeError) },
            role: { ($0.role, $0.roleError) },
        )
    }

    func testStrictDecoderAcceptsCompleteEmptyDesktopOnlyAndMixedInventories() {
        XCTAssertEqual(decode([])?.count, 0)
        XCTAssertEqual(decode([LaunchAxEntry()])?.count, 0)
        let window = LaunchAxEntry(nativeId: 10, nativeError: .success, role: kAXWindowRole)
        XCTAssertEqual(decode([window])?.map(\.windowId), [10])
        XCTAssertEqual(decode([LaunchAxEntry(), window])?.map(\.windowId), [10])
        XCTAssertEqual(decode([window, LaunchAxEntry()])?.map(\.windowId), [10])
        XCTAssertEqual(Ax.launchBaselineWindowsAttr.getter([] as NSArray)?.count, 0)
    }

    func testStrictDecoderRetainsSuccessfulNativeIDsWithoutReadingRole() {
        let entries = [LaunchAxEntry(nativeId: 10, nativeError: .success, role: nil, roleError: .cannotComplete)]
        let decoded = launchWindowDecodeEnumeration(
            entries as NSArray,
            element: { $0 as? LaunchAxEntry },
            nativeWindow: { ($0.nativeId, $0.nativeError) },
            role: { _ in
                XCTFail("A successful native window ID must survive regardless of role")
                return (nil, .cannotComplete)
            },
        )
        XCTAssertEqual(decoded?.map(\.windowId), [10])
        XCTAssertEqual(decode([LaunchAxEntry(nativeId: 11, nativeError: .success)])?.map(\.windowId), [11])
    }

    func testStrictDecoderRejectsUnreadableUnknownAndMalformedEntries() {
        let invalid = [
            LaunchAxEntry(role: kAXWindowRole),
            LaunchAxEntry(role: nil),
            LaunchAxEntry(role: "AXUnknown"),
            LaunchAxEntry(role: kAXButtonRole),
            LaunchAxEntry(roleError: .cannotComplete),
            LaunchAxEntry(roleError: .invalidUIElement),
            LaunchAxEntry(nativeError: .success),
            LaunchAxEntry(nativeError: .cannotComplete),
            LaunchAxEntry(nativeError: .invalidUIElement),
            LaunchAxEntry(nativeError: .failure),
            LaunchAxEntry(nativeId: 10),
        ]
        let window = LaunchAxEntry(nativeId: 11, nativeError: .success, role: kAXWindowRole)
        for entry in invalid {
            XCTAssertNil(decode([entry]))
            XCTAssertNil(decode([window, entry])) // A partial real inventory must never escape.
        }
        XCTAssertNil(Ax.launchBaselineWindowsAttr.getter("invalid" as NSString))
        XCTAssertNil(Ax.launchBaselineWindowsAttr.getter([42] as NSArray))
    }
}
