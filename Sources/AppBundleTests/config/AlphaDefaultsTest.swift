@testable import AppBundle
import Common
import XCTest

@MainActor
final class AlphaDefaultsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    func testStarterBindingsResizeFocusAndRestoreNormalTiles() async throws {
        config = defaultConfig
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(first.focusWindow())
        try await workspace.layoutWorkspace()
        let loneFrame = try await first.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(loneFrame.width, 1267.2, accuracy: 0.001)

        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        let firstFrame = try await first.getAxRect(.nonCancellable).orDie()
        let secondFrame = try await second.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(firstFrame.width, 960, accuracy: 0.001)
        XCTAssertEqual(secondFrame.width, 960, accuracy: 0.001)

        try await press("alt-enter")
        assertTrue(FocusMode.shared.isActive)
        try await workspace.layoutWorkspace()
        let focusFrame = try await first.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(focusFrame.width, 1267.2, accuracy: 0.001)
        try await press("alt-equal")
        try await press("alt-shift-minus")
        try await workspace.layoutWorkspace()
        let resized = try await first.getAxRect(.nonCancellable).orDie()
        XCTAssertEqual(resized.width, focusFrame.width + 50, accuracy: 0.001)
        XCTAssertEqual(resized.height, focusFrame.height - 50, accuracy: 0.001)

        try await press("alt-enter")
        assertFalse(FocusMode.shared.isActive)
        try await workspace.layoutWorkspace()
        assertEquals(try await first.getAxRect(.nonCancellable), firstFrame)
        assertEquals(try await second.getAxRect(.nonCancellable), secondFrame)
    }

    func testExistingConfigDoesNotInheritStarterSizingOrShortcuts() {
        let result = parseConfig(
            """
            config-version = 2
            [mode.main.binding]
                alt-enter = 'layout tiles horizontal vertical'
            """,
        )
        assertEquals(result.errors, [])
        assertTrue(result.config.singleWindowWidthRules.isEmpty)
        assertEquals(result.config.adaptiveLayout, .default)
        assertEquals(result.config.modes[mainModeId]?.bindings.count, 1)
        assertTrue(result.config.modes[mainModeId]?.bindings["alt-enter"]?.commands.strictEquals(
            parseCommand("layout tiles horizontal vertical").cmdOrDie,
        ) == true)
    }

    private func press(_ key: String) async throws {
        let binding = try XCTUnwrap(config.modes[mainModeId]?.bindings[key])
        let result = await binding.commands.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
    }
}
