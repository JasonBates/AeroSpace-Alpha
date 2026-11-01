@testable import AppBundle
import Common
import XCTest

@MainActor
final class LaunchWindowCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseArgvAndHelp() {
        testParseSingleCommandSucc(
            "launch-window --app-bundle-id example.app --workspace 9 --timeout 2.5 -- /adapter 'one argument' --help '$HOME'",
            LaunchWindowCmdArgs(rawArgs: [])
                .with(\.appBundleId, "example.app")
                .with(\.workspaceName, .parse("9").getOrDie())
                .with(\._timeout, 2.5)
                .with(\.adapter, .initialized(["/adapter", "one argument", "--help", "$HOME"])),
        )
        testParseCommandHelp("launch-window --help")
        testParseCommandHelp("launch-window -h")
        XCTAssertNotNil(parseCommand("launch-window -- /adapter").errorOrNil)
        XCTAssertNotNil(parseCommand("launch-window --app-bundle-id app -- relative").errorOrNil)
        XCTAssertNotNil(parseCommand("launch-window --app-bundle-id app /adapter").errorOrNil)
        for timeout in ["0", "-1", "nan", "inf", "121"] {
            XCTAssertNotNil(parseCommand("launch-window --app-bundle-id app --timeout \(timeout) -- /adapter").errorOrNil)
        }
    }
}
