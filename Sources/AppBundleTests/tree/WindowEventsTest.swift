@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class WindowEventsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        _ = collectWindowMovedEvents() // Start every test from a fresh snapshot
    }

    func testReportsMoveBetweenWorkspaces() {
        let window = TestWindow.new(id: 1, parent: globalFocus.workspace.rootTilingContainer)
        assertEquals(collectWindowMovedEvents().count, 0) // First sighting is not a move

        window.bind(to: Workspace.get(byName: "b").rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let events = collectWindowMovedEvents().map(json)
        assertEquals(events.count, 1)
        assertTrue(events[0].contains(#""_event":"window-moved""#))
        assertTrue(events[0].contains(#""prevWorkspace":"setUpWorkspacesForTests""#))
        assertTrue(events[0].contains(#""workspace":"b""#))
        assertTrue(events[0].contains(#""windowId":1"#))

        assertEquals(collectWindowMovedEvents().count, 0) // Reported once
    }

    func testReportsMoveFromDetectionWorkspace() {
        let window = TestWindow.new(id: 1, parent: globalFocus.workspace.rootTilingContainer)
        rememberWindowWorkspace(window) // As onWindowDetected does, before callbacks run
        window.bind(to: Workspace.get(byName: "b").rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(collectWindowMovedEvents().count, 1)
    }

    func testIgnoresMovesWithinWorkspace() {
        let window = TestWindow.new(id: 1, parent: globalFocus.workspace.rootTilingContainer)
        _ = collectWindowMovedEvents()
        window.bind(to: globalFocus.workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(collectWindowMovedEvents().count, 0)
    }

    func testReportsMinimizeAndRestore() {
        let window = TestWindow.new(id: 1, parent: globalFocus.workspace.rootTilingContainer)
        _ = collectWindowMovedEvents()

        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let minimized = collectWindowMovedEvents().map(json)
        assertEquals(minimized.count, 1)
        assertTrue(minimized[0].contains(#""prevWorkspace":"setUpWorkspacesForTests""#))
        assertFalse(minimized[0].contains(#""workspace":"#))

        window.bind(to: globalFocus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let restored = collectWindowMovedEvents().map(json)
        assertEquals(restored.count, 1)
        assertTrue(restored[0].contains(#""workspace":"setUpWorkspacesForTests""#))
        assertFalse(restored[0].contains("prevWorkspace"))
        window.unbindFromParent()
    }

    private func json(_ event: ServerEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(event), as: UTF8.self)
    }
}
