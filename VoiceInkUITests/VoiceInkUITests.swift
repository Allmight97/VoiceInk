import XCTest

final class VoiceInkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesMenuBarApplication() throws {
        let app = XCUIApplication()
        app.launch()

        // Xcode 27 imports XCUIApplicationState cases with capitalized names;
        // raw values keep this assertion stable across importer spellings.
        XCTAssertGreaterThan(app.state.rawValue, 1)
    }
}
